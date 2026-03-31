#!/usr/bin/env python3
"""cmux Auto-Approve Dashboard — single-file harness engine + web UI."""

import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# ---------------------------------------------------------------------------
# cmux socket helpers
# ---------------------------------------------------------------------------

def _find_socket_path():
    env = os.environ.get("CMUX_SOCKET_PATH")
    if env and os.path.exists(env):
        return env
    candidates = [
        os.path.expanduser("~/Library/Application Support/cmux/cmux.sock"),
        "/tmp/cmux.sock",
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return None


def _cmux_send(sock, command):
    """Send a command string to a cmux Unix socket and return the response."""
    sock.sendall((command + "\n").encode())
    chunks = []
    sock.settimeout(3)
    try:
        while True:
            data = sock.recv(65536)
            if not data:
                break
            chunks.append(data)
            if data.endswith(b"\n"):
                break
    except socket.timeout:
        pass
    return b"".join(chunks).decode(errors="replace").strip()


def cmux_command(command):
    """Open a fresh connection, run one command, return the response string."""
    path = _find_socket_path()
    if not path:
        return None
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
        result = _cmux_send(sock, command)
        return result
    except OSError:
        return None
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


def _v2_request(method, params):
    """Send a v2 JSON-RPC request to the cmux socket. Returns parsed result or None."""
    path = _find_socket_path()
    if not path:
        return None
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
        req = json.dumps({"id": f"h-{id(params)}", "method": method, "params": params})
        raw = _cmux_send(sock, req)
        if not raw:
            return None
        parsed = json.loads(raw)
        if parsed.get("ok"):
            return parsed.get("result", {})
        return None
    except (OSError, json.JSONDecodeError):
        return None
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


def cmux_read_workspace(ws_index, surface_index=0, lines=40, workspace_uuid=None):
    """Read terminal text from a workspace WITHOUT switching to it.
    Uses the v2 JSON-RPC API with workspace_id parameter."""
    if workspace_uuid:
        result = _v2_request("surface.read_text", {
            "workspace_id": workspace_uuid,
            "lines": lines,
        })
        if result:
            return result.get("text", "")
    # Fallback to v1 (requires workspace switching)
    path = _find_socket_path()
    if not path:
        return None
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
        _cmux_send(sock, f"select_workspace {ws_index}")
        screen = _cmux_send(sock, f"read_screen {surface_index} --lines {lines}")
        return screen
    except OSError:
        return None
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


def cmux_send_to_workspace(ws_index, surface_index, text=None, key=None, workspace_uuid=None):
    """Send text or a key to a surface WITHOUT switching workspaces.
    Uses the v2 JSON-RPC API with workspace_id parameter."""
    if workspace_uuid:
        if text is not None:
            result = _v2_request("surface.send_text", {
                "workspace_id": workspace_uuid,
                "text": text,
            })
            return result is not None
        if key is not None:
            result = _v2_request("surface.send_key", {
                "workspace_id": workspace_uuid,
                "key": key.lower(),
            })
            return result is not None
    # Fallback to v1 (requires workspace switching)
    path = _find_socket_path()
    if not path:
        return False
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
        _cmux_send(sock, f"select_workspace {ws_index}")
        if text is not None:
            _cmux_send(sock, f"send_surface {surface_index} {text}")
        if key is not None:
            _cmux_send(sock, f"send_key_surface {surface_index} {key}")
        return True
    except OSError:
        return False
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# LLM classification (Ollama local model)
# ---------------------------------------------------------------------------

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.5:35b-a3b-nvfp4")
USE_LLM = os.environ.get("USE_LLM", "1") != "0"  # enabled by default

_LLM_SYSTEM = """You classify terminal prompts from Claude Code (an AI coding assistant).
When the terminal shows a PERMISSION prompt or confirmation dialog, decide the correct response.
Reply with ONLY a JSON object, no markdown, no explanation.

Rules:
- Permission/confirmation prompts with Yes/No options → auto-approve (action: "enter")
- Y/n or Yes/no inline prompts → auto-approve (action: "y")
- "Allow <tool>" prompts → auto-approve (action: "y")
- Menus where ALL options are permission variants (Yes, No, "Yes and don't ask again", "Yes, allow X from Y") → auto-approve by pressing Enter if cursor is on a Yes/Allow option
- Domain-specific choices requiring human judgment (which file to edit, which approach to take, pick a specific item) → needs human (action: "skip")
- Claude Code idle REPL showing "❯" with "Model:" and "Cost:" lines nearby → NOT waiting
- A shell prompt (like "user@host %") → NOT waiting
- Claude Code showing "Musing…" or "Thinking…" → NOT waiting, it's working
- Claude Code actively running a tool (showing "⚡ Read", "⚡ Bash", etc.) → NOT waiting
- If the terminal is NOT waiting for a permission prompt → not waiting

IMPORTANT: Options like "Yes, allow reading from X", "Yes, and don't ask again for: bash ...", "Yes, allow X from this project" are ALL permission grants, NOT domain-specific choices. They should be auto-approved.

JSON format: {"waiting": bool, "action": "enter"|"y"|"skip", "safe": bool, "reason": "brief"}
- action "enter" = press Enter key (for menus where cursor ›/❯ is on the right option)
- action "y" = type the letter y (for Y/n prompts)
- action "skip" = needs human decision, don't send anything
- waiting = true ONLY for permission/approval prompts, NOT for idle REPLs or shell prompts"""


def llm_classify(screen_text):
    """Ask a local Ollama model to classify the terminal screen.
    Returns (pattern_name, action) or None on failure."""
    if not USE_LLM:
        return None
    if _engine is not None and not _engine._check_ollama():
        return None
    # Only send the last 25 lines to keep token count low
    lines = screen_text.splitlines()
    tail = "\n".join(lines[-25:]) if len(lines) > 25 else screen_text

    active_model = _engine.model if _engine is not None else OLLAMA_MODEL
    payload = {
        "model": active_model,
        "system": _LLM_SYSTEM,
        "prompt": f"Terminal screen:\n\n{tail}\n\nClassify this terminal screen.",
        "stream": False,
        "think": False,
        "options": {"num_predict": 80, "temperature": 0.1},
    }
    try:
        import urllib.request
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
        raw = result.get("response", "").strip()
        # Extract JSON from response (model might add whitespace)
        # Find first { and last }
        start = raw.find("{")
        end = raw.rfind("}") + 1
        if start < 0 or end <= start:
            return None
        parsed = json.loads(raw[start:end])
        _debug_log({
            "event": "llm_response",
            "raw": raw,
            "parsed": parsed,
            "model": active_model,
        })
        if not parsed.get("waiting", False):
            return None
        action = parsed.get("action", "skip")
        safe = parsed.get("safe", False)
        reason = parsed.get("reason", "")
        if action == "skip" or not safe:
            return ("needs_human", "skip")
        # Fix action mismatch: if the screen is a numbered menu (Enter to select),
        # always use "enter" even if the LLM said "y". Typing "y" in a menu does nothing.
        if action == "y" and re.search(r"Enter to select|Esc to cancel", tail):
            action = "enter"
        return (f"llm:{reason[:40]}", action)
    except Exception as e:
        print(f"[harness] LLM error: {e}")
        _debug_log({"event": "llm_error", "error": str(e)})
        return None


def _detect_claude_session(screen_text):
    """Return True if Claude Code appears to be running in this terminal.
    Looks for Claude Code REPL indicators, active thinking/musing, tool use,
    or the characteristic prompt/status lines."""
    if not screen_text:
        return False
    # Check last 30 lines for Claude Code signatures
    lines = screen_text.strip().splitlines()
    tail = "\n".join(lines[-30:]) if len(lines) > 30 else screen_text
    # Claude Code REPL: "❯" with Model:/Cost:/Ctx: lines nearby
    if re.search(r"(Model:\s*(Sonnet|Opus|Haiku|Claude|claude)|Cost:\s*\$|Ctx:\s*\d)", tail):
        return True
    # Active Claude Code: thinking, musing, tool use
    if re.search(r"(Musing\.\.\.|Thinking\.\.\.|⚡\s*(Read|Edit|Write|Bash|MultiEdit|Search|Glob|Grep|ListDir|Fetch|Browse|TodoRead|TodoWrite|WebFetch|MCP))", tail):
        return True
    # Claude Code permission prompts
    if re.search(r"(Allow\s+(Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit)|Do you want to proceed|\(Y/n\)|\(y/n\))", tail):
        return True
    # Claude Code compact prompt with ❯ (not a regular shell prompt)
    # The ❯ followed by claude-specific content
    if re.search(r"[❯)]\s*(Yes|No|Allow|Deny|Approve|Confirm)", tail):
        return True
    # "claude" command was recently run (visible in scrollback)
    if re.search(r"^\$?\s*claude\s*$", tail, re.MULTILINE):
        return True
    return False


# ---------------------------------------------------------------------------
# Prompt detection (regex fast-path + LLM fallback)
# ---------------------------------------------------------------------------

PROMPT_PATTERNS = [
    # (name, primary_regex, secondary_regex_or_None, action: "enter" | "y")
    # confirm_menu and yes_menu are handled in the menu detection block
    # inside detect_prompt() before these patterns are checked.
    ("yn_prompt",     r"\([Yy](?:/[Nn]|es/no)\)", None, "y"),
    ("tool_approval", r"Allow (Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit|ListDir|Glob|Grep|TodoRead|TodoWrite|WebFetch|WebSearch|Search|Task|NotebookRead|NotebookEdit)", None, "y"),
    ("button_yes",    r"[❯)\>]\s*(Yes|Allow)", None, "enter"),
    # allow_generic removed — too broad, caused false matches on menu content above the cursor
    ("run_command",   r"(Run|Execute) (this|the) (command|script)?", None, "y"),
    ("apply_changes", r"(Apply|Write|Save) (these |the )?(changes|edits|file)?", None, "y"),
    ("trust_prompt",  r"Do you (trust|want to allow)", None, "y"),
]

# Claude Code's Ink UI renders ❯ as the menu cursor, but cmux read_screen
# often captures it as ) instead. Match both characters as cursor indicators.
_CURSOR_CHARS = r"[❯›)\>]"
_NUMBERED_MENU_RE = re.compile(r"^\s*\d+[.)]\s+")
_AFFIRM_RE = re.compile(r"(Yes|Allow|Confirm|Approve|Accept|Proceed|Continue)", re.I)


# Regex to detect Claude Code's idle REPL (not a permission prompt)
_REPL_IDLE_RE = re.compile(r"(Model:\s*(Sonnet|Opus|Haiku|Claude)|Cost:\s*\$|Ctx:\s*\d)")


def _is_permission_menu(options_text):
    """Check if menu options are all Yes/No variants (permission prompt)
    vs domain-specific choices (needs human).
    Returns True if it's a standard permission prompt."""
    # Extract option text (everything after "N. " or "N) " — also handles "N.Text" with no space)
    option_texts = re.findall(r"\d+[.)]\s*(.+)", options_text)
    has_affirmative = False
    has_domain_specific = False
    for opt in option_texts:
        opt_lower = opt.strip().lower()
        # Skip "Type something" and "Chat about this" — always present in Claude Code menus
        if opt_lower.startswith("type something") or opt_lower.startswith("chat about"):
            continue
        # Standard permission/confirmation options
        if any(opt_lower.startswith(w) for w in ["yes", "no", "allow", "deny", "skip",
                "confirm", "approve", "accept", "proceed", "continue", "cancel",
                "modify", "re-search", "add more", "change", "replace"]):
            if any(opt_lower.startswith(w) for w in ["yes", "allow", "confirm", "approve",
                    "accept", "proceed", "continue"]):
                has_affirmative = True
            continue
        # If we find anything else, it's domain-specific
        has_domain_specific = True
    # It's a permission menu if there's an affirmative option and no domain-specific ones
    return has_affirmative and not has_domain_specific


def detect_prompt(screen_text):
    """Return (pattern_name, action) or None if no prompt detected.
    Returns ("needs_human", "skip") if a prompt needs manual intervention.

    Strategy: LLM-primary. The local model classifies every screen.
    Only two fast pre-checks:
    1. Idle REPL detection (skip without burning LLM tokens)
    2. Plain shell prompt detection (skip without burning LLM tokens)
    """
    if not screen_text:
        return None
    # Strip trailing blank lines — read_screen returns fixed-height output
    # with blank padding below the actual terminal content
    lines = screen_text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return None
    tail = "\n".join(lines[-25:]) if len(lines) > 25 else "\n".join(lines)

    # SKIP: Claude Code idle REPL (has ❯ but also Model:/Cost: lines)
    if _REPL_IDLE_RE.search(tail):
        return None

    # SKIP: Plain shell prompt with no Claude Code indicators
    last_chunk = "\n".join(lines[-10:]) if len(lines) > 10 else "\n".join(lines)
    if not re.search(r"(Allow |Do you want|proceed|\([Yy](?:/[Nn]|es/no)\)|Enter to select|Esc to cancel|Musing|Thinking|⚡|Model:|Cost:|Ctx:)", last_chunk):
        # No prompt indicators at all — likely just a shell
        return None

    # LLM classifies everything else
    llm_result = llm_classify(screen_text)
    if llm_result is not None:
        return llm_result

    return None


def fingerprint(screen_text):
    """Hash of last 5 lines — used to avoid double-approving."""
    lines = screen_text.strip().splitlines()
    chunk = "\n".join(lines[-5:]) if len(lines) >= 5 else screen_text
    return hashlib.md5(chunk.encode()).hexdigest()


# ---------------------------------------------------------------------------
# Persistent log directory
# ---------------------------------------------------------------------------

LOG_DIR = Path.home() / ".cmux-harness"
LOG_DIR.mkdir(parents=True, exist_ok=True)
REVIEWS_DIR = LOG_DIR / "reviews"
REVIEWS_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = LOG_DIR / "approval-log.jsonl"
DEBUG_LOG = LOG_DIR / "debug-log.jsonl"
CONFIG_FILE = LOG_DIR / "workspace-config.json"

MAX_DEBUG_LOG_SIZE = 10 * 1024 * 1024  # 10MB


def _rotate_log_file(log_path, max_size=MAX_DEBUG_LOG_SIZE):
    """Rotate a log file if it exceeds max_size. Keeps one .1.jsonl backup."""
    try:
        if log_path.exists() and log_path.stat().st_size > max_size:
            backup = log_path.parent / (log_path.stem + ".1.jsonl")
            if backup.exists():
                backup.unlink()
            log_path.rename(backup)
            print(f"[harness] Rotated {log_path.name} ({max_size // 1024 // 1024}MB limit)")
    except OSError as e:
        print(f"[harness] Log rotation error: {e}")


def _rotate_debug_log():
    """Rotate debug log if it exceeds MAX_DEBUG_LOG_SIZE."""
    _rotate_log_file(DEBUG_LOG)


_debug_log_writes = 0


def _debug_log(entry):
    """Append a debug entry to the debug log file (full data dump)."""
    global _debug_log_writes
    _debug_log_writes += 1
    if _debug_log_writes % 100 == 0:
        _rotate_debug_log()
    entry["_ts"] = datetime.now(timezone.utc).isoformat()
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _read_review_file(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _list_reviews():
    reviews = []
    try:
        for path in REVIEWS_DIR.glob("*.json"):
            review = _read_review_file(path)
            if review is not None:
                reviews.append(review)
    except OSError:
        return []
    reviews.sort(key=lambda r: r.get("completedAt", ""), reverse=True)
    return reviews


def _get_review(session_id):
    if not session_id:
        return None
    for review in _list_reviews():
        if review.get("sessionId") == session_id:
            return review
    return None


def _get_review_path(session_id):
    if not session_id:
        return None
    try:
        for path in REVIEWS_DIR.glob("*.json"):
            review = _read_review_file(path)
            if review and review.get("sessionId") == session_id:
                return path
    except OSError:
        return None
    return None


# ---------------------------------------------------------------------------
# Session cost parser
# ---------------------------------------------------------------------------

def _parse_session_cost(screen_text):
    """Parse Claude Code session cost from terminal output.
    Checks the last 5 lines where the statusline renders.
    Returns a dollar amount string like "$0.45" or None if not found."""
    if not screen_text:
        return None
    lines = screen_text.splitlines()
    tail = "\n".join(lines[-5:]) if len(lines) > 5 else screen_text
    # Pattern order matters: more specific patterns first
    # Cost: $X.XX
    m = re.search(r"Cost:\s*(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    # 💰$X.XX or 💰 $X.XX
    m = re.search(r"\U0001f4b0\s*(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    # $X.XX block (ccstatusline block cost format)
    m = re.search(r"(\$\d+\.\d{2})\s+block", tail)
    if m:
        return m.group(1)
    # bare $X.XX (catch-all)
    m = re.search(r"(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    return None


# ---------------------------------------------------------------------------
# Harness engine (background thread)
# ---------------------------------------------------------------------------

class HarnessEngine(threading.Thread):
    def __init__(self):
        super().__init__()
        self.daemon = True
        self.enabled = False
        self.workspace_enabled = {}
        self.poll_interval = 5
        self.approval_log = []
        self.workspaces = []
        self.fingerprints = {}
        self.screen_cache = {}   # idx -> last screen text (tail)
        self.ws_has_claude = {}  # idx -> bool (tracks active Claude sessions per workspace)
        self.idle_last_read = {} # idx -> float (timestamp of last screen read for idle workspaces)
        self.session_start = {}  # idx -> float (when hasClaude first went True)
        self.session_cost = {}   # idx -> str (parsed cost like "$0.45")
        self.session_ids = {}    # idx -> str (workspace UUID + session start timestamp)
        self.socket_connected = False   # current socket connection state
        self.last_successful_poll = 0   # timestamp of last successful socket read
        self.connection_lost_at = 0     # when we first noticed the socket was gone
        self.consecutive_failures = 0   # count of consecutive failed polls
        self._lock = threading.Lock()
        self.model = OLLAMA_MODEL
        self.review_enabled = True
        self.review_model = OLLAMA_MODEL
        self.review_backend = "ollama"
        self.ollama_available = None   # None=unknown, True=available, False=unavailable
        self.ollama_last_check = 0     # timestamp of last Ollama health check
        self.ollama_retry_interval = 60  # seconds between retries after failure
        self._review_errors = {}
        self._review_models = {}
        config = self._load_config()
        self.ws_config = config.get("workspaces", {})
        review_settings = config.get("reviewSettings", {})
        if isinstance(review_settings, dict):
            self.review_enabled = bool(review_settings.get("enabled", self.review_enabled))
            self.review_model = review_settings.get("model", self.review_model) or self.review_model
            self.review_backend = review_settings.get("backend", self.review_backend) or self.review_backend

    def _load_config(self):
        """Read workspace config from JSON file. Returns normalized config."""
        try:
            with open(CONFIG_FILE, "r") as f:
                data = json.load(f)
            if not isinstance(data, dict):
                return {"workspaces": {}, "reviewSettings": {}}
            workspaces = data.get("workspaces", {})
            review_settings = data.get("reviewSettings", {})
            if not isinstance(workspaces, dict):
                workspaces = {}
            if not isinstance(review_settings, dict):
                review_settings = {}
            return {
                "workspaces": workspaces,
                "reviewSettings": review_settings,
            }
        except (FileNotFoundError, json.JSONDecodeError, KeyError, OSError):
            return {"workspaces": {}, "reviewSettings": {}}

    def _save_config(self):
        """Write current ws_config to the JSON file. Call while holding self._lock."""
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump({
                    "workspaces": self.ws_config,
                    "reviewSettings": {
                        "enabled": self.review_enabled,
                        "model": self.review_model,
                        "backend": self.review_backend,
                    },
                }, f, indent=2)
        except OSError as e:
            print(f"[harness] config save error: {e}")

    def _check_ollama(self):
        """Check if Ollama is reachable. Rate-limited to once per retry_interval."""
        now = time.time()
        with self._lock:
            if self.ollama_available is not None and (now - self.ollama_last_check) < self.ollama_retry_interval:
                return self.ollama_available
        try:
            import urllib.request
            with urllib.request.urlopen(f"{OLLAMA_URL}/api/tags", timeout=3) as r:
                r.read()
            with self._lock:
                self.ollama_available = True
                self.ollama_last_check = now
            return True
        except Exception:
            with self._lock:
                if self.ollama_available is not False:
                    print("[harness] ⚠ Ollama unavailable, will retry every 60s")
                self.ollama_available = False
                self.ollama_last_check = now
            return False

    def set_enabled(self, val):
        with self._lock:
            self.enabled = bool(val)

    def set_workspace_enabled(self, index, val):
        with self._lock:
            self.workspace_enabled[index] = bool(val)
            # Persist by UUID so state survives index shifts
            ws_uuid = None
            for w in self.workspaces:
                if w.get("index", w.get("id")) == index:
                    ws_uuid = w.get("uuid")
                    break
            if ws_uuid:
                if ws_uuid not in self.ws_config:
                    self.ws_config[ws_uuid] = {}
                self.ws_config[ws_uuid]["autoEnabled"] = bool(val)
                self._save_config()

    def set_poll_interval(self, val):
        with self._lock:
            self.poll_interval = max(2, min(30, int(val)))

    def set_model(self, name):
        with self._lock:
            self.model = name

    def set_review_config(self, enabled=None, model=None, backend=None):
        with self._lock:
            if enabled is not None:
                self.review_enabled = bool(enabled)
            if model is not None:
                self.review_model = str(model) or self.review_model
            if backend is not None:
                backend_name = str(backend).strip().lower()
                if backend_name in {"ollama", "lmstudio", "claude"}:
                    self.review_backend = backend_name
            self._save_config()

    def set_custom_name(self, index, name):
        """Set a custom display name for the workspace at the given index.
        Persists to config keyed by UUID so it survives index shifts.
        Also renames the workspace in cmux so the sidebar stays in sync."""
        with self._lock:
            ws_uuid = None
            for w in self.workspaces:
                if w.get("index", w.get("id")) == index:
                    ws_uuid = w.get("uuid")
                    break
            if ws_uuid is None:
                return False
            if ws_uuid not in self.ws_config:
                self.ws_config[ws_uuid] = {}
            self.ws_config[ws_uuid]["customName"] = name
            self._save_config()

        # Rename in cmux so the sidebar name stays in sync
        _v2_request("workspace.rename", {"workspace_id": ws_uuid, "name": name})
        return True

    def get_status(self):
        with self._lock:
            ws_list = []
            for ws in self.workspaces:
                idx = ws.get("index", ws.get("id"))
                uuid = ws.get("uuid", "")
                screen_tail = self.screen_cache.get(idx, "")
                # Get last 25 lines for card preview
                lines = screen_tail.strip().splitlines() if screen_tail else []
                preview = "\n".join(lines[-25:]) if lines else ""
                # Use cached Claude session detection (updated in run() loop)
                has_claude = self.ws_has_claude.get(idx, False)
                # Look up saved config state (keyed by UUID)
                cfg = self.ws_config.get(uuid, {})
                if "autoEnabled" in cfg:
                    enabled = cfg["autoEnabled"]
                else:
                    enabled = self.workspace_enabled.get(idx, False)
                ws_list.append({
                    "hasClaude": has_claude,
                    "index": idx,
                    "name": ws.get("name", f"workspace-{idx}"),
                    "uuid": uuid,
                    "enabled": enabled,
                    "customName": cfg.get("customName"),
                    "lastCheck": ws.get("_lastCheck", ""),
                    "screenTail": preview,
                    "screenFull": screen_tail,
                    "cwd": ws.get("_cwd", ""),
                    "branch": ws.get("_branch", ""),
                    "sessionStart": self.session_start.get(idx, 0),
                    "sessionCost": self.session_cost.get(idx, ""),
                })
            return {
                "enabled": self.enabled,
                "workspaces": ws_list,
                "pollInterval": self.poll_interval,
                "socketFound": _find_socket_path() is not None,
                "model": self.model,
                "reviewEnabled": self.review_enabled,
                "reviewModel": self.review_model,
                "reviewBackend": self.review_backend,
                "connected": self.socket_connected,
                "lastSuccessfulPoll": self.last_successful_poll,
                "connectionLostAt": self.connection_lost_at,
                "staleData": not self.socket_connected,
                "ollamaAvailable": self.ollama_available,
            }

    def get_log(self, limit=200):
        with self._lock:
            return list(reversed(self.approval_log[-limit:]))

    def _append_log(self, entry):
        with self._lock:
            idx = entry.get("workspace")
            if idx is not None and "session_id" not in entry:
                session_id = self.session_ids.get(idx)
                if session_id:
                    entry["session_id"] = session_id
            self.approval_log.append(entry)
            if len(self.approval_log) > 500:
                self.approval_log = self.approval_log[-500:]
        try:
            with open(LOG_FILE, "a") as f:
                f.write(json.dumps(entry) + "\n")
        except OSError:
            pass
        self._log_write_count = getattr(self, "_log_write_count", 0) + 1
        if self._log_write_count % 100 == 0:
            _rotate_log_file(LOG_FILE)
        ts = entry.get("timestamp", "")
        ws_name = entry.get("workspaceName", "?")
        ptype = entry.get("promptType", "?")
        action = entry.get("action", "?")
        print(f"[{ts}] approved ws={ws_name} type={ptype} action={action}")

    def _run_git_command(self, cwd, args, max_bytes=None):
        if not cwd:
            return ""
        try:
            if not os.path.isdir(cwd):
                return f"[error] cwd not found: {cwd}"
            result = subprocess.run(
                ["git"] + args,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=10,
            )
        except subprocess.TimeoutExpired:
            return f"[error] git {' '.join(args)} timed out after 10s"
        except OSError as e:
            return f"[error] git {' '.join(args)} failed: {e}"

        output = result.stdout or ""
        if result.returncode != 0:
            err = (result.stderr or "").strip()
            if err:
                output = err if not output.strip() else f"{output.rstrip()}\n{err}"
        if max_bytes is not None:
            raw = output.encode("utf-8", errors="replace")
            if len(raw) > max_bytes:
                marker = b"\n...[truncated]..."
                output = (raw[: max_bytes - len(marker)] + marker).decode("utf-8", errors="replace")
        return output.strip()

    def _get_session_approval_log(self, idx, session_id, start_ts, end_ts):
        entries = []
        start_iso = datetime.fromtimestamp(start_ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if start_ts else ""
        end_iso = datetime.fromtimestamp(end_ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            with open(LOG_FILE, "r") as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if entry.get("workspace") != idx:
                        continue
                    if session_id and entry.get("session_id") == session_id:
                        entries.append(entry)
                        continue
                    ts = entry.get("timestamp", "")
                    if start_iso and start_iso <= ts <= end_iso:
                        entries.append(entry)
        except FileNotFoundError:
            return []
        except OSError:
            return []
        return entries

    def _set_review_error(self, message):
        self._review_errors[threading.get_ident()] = message

    def _pop_review_error(self):
        return self._review_errors.pop(threading.get_ident(), "")

    def _set_review_model_used(self, model_name):
        self._review_models[threading.get_ident()] = model_name

    def _pop_review_model_used(self):
        return self._review_models.pop(threading.get_ident(), "")

    def _write_review_file(self, path, data):
        with open(path, "w") as f:
            json.dump(data, f, indent=2)

    def _parse_review_json(self, raw):
        if not raw:
            return None
        text = raw.strip()
        if text.startswith("```"):
            text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.IGNORECASE)
            text = re.sub(r"\s*```$", "", text)
        start = text.find("{")
        end = text.rfind("}") + 1
        if start < 0 or end <= start:
            return None
        try:
            parsed = json.loads(text[start:end])
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None

    def _build_review_prompt(self, review_data):
        approval_log = review_data.get("approvalLog") or []
        approved_count = 0
        flagged_count = 0
        for entry in approval_log:
            action = str(entry.get("action", "")).lower()
            if "needs human" in action or "flagged" in action:
                flagged_count += 1
            else:
                approved_count += 1

        git_diff = (review_data.get("gitDiff") or "").strip()
        git_diff_stat = (review_data.get("gitDiffStat") or "").strip()
        git_log = (review_data.get("gitLog") or "").strip()
        has_code_changes = bool(git_diff or git_diff_stat)

        prompt = (
            "You are reviewing a completed AI coding agent (Claude Code) session.\n"
            "Your job is to summarize what happened and tell the developer what to do next.\n"
            "EVERY session gets a review, whether or not code was changed.\n\n"
            f"Workspace: {review_data.get('workspaceName', '')}\n"
            f"Branch: {review_data.get('branch', '')}\n"
            f"Working directory: {review_data.get('cwd', '')}\n"
            f"Session duration: {review_data.get('duration', 0)} seconds\n"
            f"Session cost: {review_data.get('finalCost', '')}\n"
            f"Actions auto-approved: {approved_count}\n"
            f"Actions flagged for human: {flagged_count}\n\n"
            "── Claude Code's final output (last 50 lines) ──\n"
            f"{review_data.get('terminalSnapshot', '')}\n\n"
        )

        if has_code_changes:
            prompt += (
                "── Git diff summary ──\n"
                f"{git_diff_stat}\n\n"
                "── Recent commits ──\n"
                f"{git_log}\n\n"
                "── Full diff ──\n"
                f"{git_diff}\n\n"
            )
        else:
            prompt += (
                "── Note: No uncommitted code changes detected ──\n"
                "This session may have involved exploration, debugging, planning,\n"
                "reading code, answering questions, or changes that were already committed.\n"
                "Review the terminal output above to determine what happened.\n\n"
            )
            if git_log:
                prompt += (
                    "── Recent commits (may include this session's work) ──\n"
                    f"{git_log}\n\n"
                )

        prompt += (
            "Respond with ONLY a JSON object:\n"
            "{\n"
            '  "summary": "One-line description of what happened in this session",\n'
            '  "whatHappened": "2-4 sentence description of what Claude did, what was accomplished, and any important context",\n'
            '  "filesChanged": ["list", "of", "files"] or [] if no changes,\n'
            '  "linesAdded": number or 0,\n'
            '  "linesRemoved": number or 0,\n'
            '  "confidence": "high" | "medium" | "low",\n'
            '  "issues": ["list of concerns, empty if none"],\n'
            '  "readyForPR": true | false (false if no code changes),\n'
            '  "nextSteps": "What should the developer do next based on this session",\n'
            '  "recommendation": "Brief recommendation for the developer",\n'
            '  "highlights": ["Notable good decisions or patterns worth calling out"]\n'
            "}\n"
        )
        _debug_log({
            "event": "review_prompt_built",
            "workspace": review_data.get("workspaceIndex"),
            "approved_count": approved_count,
            "flagged_count": flagged_count,
            "prompt_chars": len(prompt),
        })
        return prompt

    def _run_review_ollama(self, prompt, model_override=None):
        self._set_review_error("")
        model = model_override or self.review_model or self.model or OLLAMA_MODEL
        self._set_review_model_used(model)
        payload = {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "think": False,
            "options": {"num_predict": 1200, "temperature": 0.1},
        }
        _debug_log({"event": "review_ollama_start", "model": model})
        try:
            req = urllib.request.Request(
                f"{OLLAMA_URL}/api/generate",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                result = json.loads(resp.read())
            raw = result.get("response", "")
            parsed = self._parse_review_json(raw)
            if parsed is None:
                self._set_review_error("invalid JSON response from Ollama")
                _debug_log({"event": "review_ollama_parse_error", "model": model, "raw": raw[:2000]})
                return None
            _debug_log({"event": "review_ollama_success", "model": model, "keys": sorted(parsed.keys())})
            return parsed
        except urllib.error.HTTPError as e:
            msg = f"Ollama returned {e.code}: model '{model}' not found — run 'ollama pull {model}'" if e.code == 404 else str(e)
            self._set_review_error(msg)
            _debug_log({"event": "review_ollama_error", "model": model, "error": msg})
            return None
        except Exception as e:
            self._set_review_error(str(e))
            _debug_log({"event": "review_ollama_error", "model": model, "error": str(e)})
            return None

    def _run_review_lmstudio(self, prompt, model_override=None):
        self._set_review_error("")
        endpoint = "http://100.89.93.84:1234/v1/chat/completions"
        model = model_override or self.review_model or OLLAMA_MODEL
        try:
            with urllib.request.urlopen("http://100.89.93.84:1234/v1/models", timeout=5) as resp:
                models_data = json.loads(resp.read())
            loaded = models_data.get("data") or []
            if loaded and isinstance(loaded[0], dict):
                model = loaded[0].get("id", model) or model
        except Exception as e:
            _debug_log({"event": "review_lmstudio_models_error", "error": str(e), "fallback_model": model})
        self._set_review_model_used(model)
        payload = {
            "model": model,
            "messages": [
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.1,
            "stream": False,
        }
        _debug_log({"event": "review_lmstudio_start", "model": model})
        try:
            req = urllib.request.Request(
                endpoint,
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                result = json.loads(resp.read())
            choices = result.get("choices") or []
            message = choices[0].get("message", {}) if choices else {}
            raw = message.get("content", "")
            parsed = self._parse_review_json(raw)
            if parsed is None:
                self._set_review_error("invalid JSON response from LM Studio")
                _debug_log({"event": "review_lmstudio_parse_error", "model": model, "raw": raw[:2000]})
                return None
            _debug_log({"event": "review_lmstudio_success", "model": model, "keys": sorted(parsed.keys())})
            return parsed
        except Exception as e:
            self._set_review_error(str(e))
            _debug_log({"event": "review_lmstudio_error", "model": model, "error": str(e)})
            return None

    def _run_review_claude(self, prompt, model_override=None):
        self._set_review_error("")
        claude_bin = shutil.which("claude")
        if not claude_bin:
            self._set_review_error("claude binary not found")
            _debug_log({"event": "review_claude_missing", "fallback": "ollama"})
            return self._run_review_ollama(prompt, model_override=model_override)
        self._set_review_model_used(model_override or "claude")
        _debug_log({"event": "review_claude_start", "binary": claude_bin})
        try:
            result = subprocess.run(
                [claude_bin, "--print", "-p", prompt],
                capture_output=True,
                text=True,
                timeout=120,
            )
            raw = (result.stdout or "").strip()
            if result.returncode != 0 and not raw:
                err = (result.stderr or "").strip() or f"claude exited with {result.returncode}"
                self._set_review_error(err)
                _debug_log({"event": "review_claude_error", "error": err})
                return None
            parsed = self._parse_review_json(raw)
            if parsed is None:
                self._set_review_error("invalid JSON response from Claude")
                _debug_log({"event": "review_claude_parse_error", "raw": raw[:2000], "stderr": (result.stderr or "")[:1000]})
                return None
            _debug_log({"event": "review_claude_success", "keys": sorted(parsed.keys())})
            return parsed
        except Exception as e:
            self._set_review_error(str(e))
            _debug_log({"event": "review_claude_exception", "error": str(e)})
            return None

    def _run_review(self, review_path, model_override=None, backend_override=None):
        start_ts = time.time()
        path = Path(review_path)
        review_data = _read_review_file(path)
        if review_data is None:
            _debug_log({"event": "review_load_error", "path": str(path)})
            return

        review_data["reviewStatus"] = "reviewing"
        review_data.pop("reviewError", None)
        try:
            self._write_review_file(path, review_data)
        except OSError as e:
            _debug_log({"event": "review_write_error", "path": str(path), "stage": "reviewing", "error": str(e)})
            return

        prompt = self._build_review_prompt(review_data)
        with self._lock:
            backend = backend_override or self.review_backend
            configured_model = model_override or self.review_model
        _debug_log({"event": "review_start", "path": str(path), "backend": backend, "model": configured_model})

        if backend == "lmstudio":
            review_result = self._run_review_lmstudio(prompt, model_override=configured_model)
        elif backend == "ollama":
            review_result = self._run_review_ollama(prompt, model_override=configured_model)
        else:
            review_result = self._run_review_claude(prompt, model_override=configured_model)

        error_message = self._pop_review_error()
        resolved_model = self._pop_review_model_used() or configured_model or self.model or OLLAMA_MODEL
        review_data = _read_review_file(path) or review_data
        duration = round(time.time() - start_ts, 1)

        if review_result is None:
            review_data["reviewStatus"] = "error"
            review_data["reviewError"] = error_message or "review backend failed"
            review_data["reviewDuration"] = duration
            review_data["reviewModel"] = resolved_model
            review_data["reviewedAt"] = datetime.now(timezone.utc).isoformat()
            try:
                self._write_review_file(path, review_data)
            except OSError as e:
                _debug_log({"event": "review_write_error", "path": str(path), "stage": "error", "error": str(e)})
            _debug_log({"event": "review_failed", "path": str(path), "backend": backend, "error": review_data["reviewError"]})
            return

        confidence = str(review_result.get("confidence", "")).lower()
        issues = review_result.get("issues") or []
        review_data["review"] = review_result
        review_data["reviewStatus"] = "flagged" if confidence == "low" or bool(issues) else "reviewed"
        review_data["reviewedAt"] = datetime.now(timezone.utc).isoformat()
        review_data["reviewModel"] = resolved_model
        review_data["reviewDuration"] = duration
        review_data.pop("reviewError", None)
        try:
            self._write_review_file(path, review_data)
        except OSError as e:
            _debug_log({"event": "review_write_error", "path": str(path), "stage": "success", "error": str(e)})
            return
        _debug_log({
            "event": "review_completed",
            "path": str(path),
            "backend": backend,
            "status": review_data["reviewStatus"],
            "duration": duration,
        })

    def _capture_completion_snapshot(self, snapshot):
        completed_at = datetime.now(timezone.utc)
        completed_ts = completed_at.timestamp()
        completed_iso = completed_at.isoformat()

        idx = snapshot.get("workspaceIndex")
        terminal_snapshot = snapshot.get("terminalSnapshot", "")
        final_cost = snapshot.get("finalCost", "")
        start_ts = snapshot.get("sessionStart", 0)
        session_id = snapshot.get("sessionId", "")
        workspace_uuid = snapshot.get("workspaceUuid", "")
        workspace_name = snapshot.get("workspaceName", f"workspace-{idx}")
        cwd = snapshot.get("cwd", "")
        branch = snapshot.get("branch", "")

        duration = max(0.0, completed_ts - start_ts) if start_ts else 0.0
        approval_entries = self._get_session_approval_log(idx, session_id, start_ts, completed_ts)
        review = {
            "sessionId": session_id,
            "workspaceIndex": idx,
            "workspaceUuid": workspace_uuid,
            "workspaceName": workspace_name,
            "completedAt": completed_iso,
            "duration": round(duration, 1),
            "finalCost": final_cost,
            "terminalSnapshot": terminal_snapshot,
            "gitDiffStat": self._run_git_command(cwd, ["diff", "--stat"]),
            "gitDiff": self._run_git_command(cwd, ["diff"], max_bytes=50 * 1024),
            "gitLog": self._run_git_command(cwd, ["log", "--oneline", "-5"]),
            "cwd": cwd,
            "branch": branch,
            "approvalLog": approval_entries,
            "reviewStatus": "pending",
        }

        timestamp = completed_at.strftime("%Y%m%dT%H%M%SZ")
        file_uuid = workspace_uuid or f"workspace-{idx}"
        path = REVIEWS_DIR / f"{file_uuid}_{timestamp}.json"
        try:
            self._write_review_file(path, review)
            _debug_log({
                "event": "completion_snapshot_captured",
                "workspace": idx,
                "workspace_uuid": workspace_uuid,
                "session_id": session_id,
                "path": str(path),
            })
            with self._lock:
                review_enabled = self.review_enabled
            if review_enabled:
                self._run_review(path)
        except OSError as e:
            _debug_log({
                "event": "completion_snapshot_error",
                "workspace": idx,
                "workspace_uuid": workspace_uuid,
                "session_id": session_id,
                "error": str(e),
            })

    def _capture_completion_snapshot_async(self, ws, idx):
        with self._lock:
            current_ws = next(
                (w for w in self.workspaces if w.get("index", w.get("id")) == idx),
                {},
            )
            screen = self.screen_cache.get(idx, "")
            snapshot = {
                "sessionId": self.session_ids.get(idx, ""),
                "workspaceIndex": idx,
                "workspaceUuid": current_ws.get("uuid", ws.get("uuid", "")),
                "workspaceName": current_ws.get("name", ws.get("name", f"workspace-{idx}")),
                "sessionStart": self.session_start.get(idx, 0),
                "finalCost": self.session_cost.get(idx, ""),
                "terminalSnapshot": "\n".join(screen.splitlines()[-50:]) if screen else "",
                "cwd": current_ws.get("_cwd", ws.get("_cwd", "")),
                "branch": current_ws.get("_branch", ws.get("_branch", "")),
            }
        threading.Thread(
            target=self._capture_completion_snapshot,
            args=(snapshot,),
            daemon=True,
        ).start()

    def refresh_workspaces(self):
        raw = cmux_command("list_workspaces")
        if raw is None:
            return False
        # cmux returns plain text lines like:
        #   * 0: UUID Name
        #     1: UUID Name2
        workspaces = []
        for line in raw.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            selected = line.startswith("*")
            line = line.lstrip("* ")
            parts = line.split(":", 1)
            if len(parts) < 2:
                continue
            try:
                idx = int(parts[0].strip())
            except ValueError:
                continue
            rest = parts[1].strip()
            # rest is "UUID Name" — split on first space
            rest_parts = rest.split(" ", 1)
            uuid = rest_parts[0] if rest_parts else ""
            name = rest_parts[1] if len(rest_parts) > 1 else f"workspace-{idx}"
            workspaces.append({
                "index": idx,
                "uuid": uuid,
                "name": name,
                "selected": selected,
            })
        if not workspaces:
            return False
        with self._lock:
            self.workspaces = workspaces
        return True

    def get_workspaces_needing_attention(self):
        """Check list_notifications (no workspace switching!) to find
        which workspaces have unread notifications. Returns a set of
        workspace UUIDs that have unread items."""
        raw = cmux_command("list_notifications")
        if not raw or raw == "No notifications":
            return set()
        uuids_needing_attention = set()
        for line in raw.strip().split("\n"):
            # Format: index:notifUUID|tabUUID|surfaceUUID|read/unread|title|subtitle|body
            parts = line.split("|")
            if len(parts) >= 4 and parts[3] == "unread":
                tab_uuid = parts[1]
                uuids_needing_attention.add(tab_uuid)
        return uuids_needing_attention

    def check_workspace(self, ws):
        idx = ws.get("index", ws.get("id"))
        ws_name = ws.get("name", f"workspace-{idx}")

        surface_index = 0
        ws_uuid = ws.get("uuid", None)

        screen = cmux_read_workspace(idx, surface_index, lines=40, workspace_uuid=ws_uuid)
        now_str = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Try to get sidebar state (cwd, git branch) via v2 API
        sidebar = _v2_request("sidebar.state", {"workspace_id": ws_uuid}) if ws_uuid else None

        with self._lock:
            for w in self.workspaces:
                if w.get("index", w.get("id")) == idx:
                    w["_lastCheck"] = now_str
                    if sidebar:
                        w["_cwd"] = sidebar.get("cwd", "")
                        w["_branch"] = sidebar.get("gitBranch", sidebar.get("git_branch", ""))
                    break
            # Cache screen text for UI
            if screen:
                self.screen_cache[idx] = screen

        if not screen:
            _debug_log({"event": "empty_screen", "workspace": idx, "name": ws_name})
            return

        fp = fingerprint(screen)
        with self._lock:
            if self.fingerprints.get(idx) == fp:
                return

        result = detect_prompt(screen)
        screen_tail = "\n".join(screen.splitlines()[-15:])

        # Log EVERYTHING to debug log
        _debug_log({
            "event": "check",
            "workspace": idx,
            "name": ws_name,
            "surface": surface_index,
            "screen_tail": screen_tail,
            "detect_result": list(result) if result else None,
        })

        if result is None:
            # No prompt detected — do NOT send anything
            return

        pattern_name, action = result

        if action == "skip":
            print(f"[harness] ⚠ ws:{idx} ({ws_name}) needs human input: {pattern_name}")
            _debug_log({
                "event": "needs_human",
                "workspace": idx,
                "name": ws_name,
                "pattern": pattern_name,
                "screen_tail": screen_tail,
            })
            self._append_log({
                "timestamp": now_str,
                "workspace": idx,
                "workspaceName": ws_name,
                "promptType": pattern_name,
                "action": "⚠ needs human",
                "surface": surface_index,
            })
            return

        if action == "enter":
            ok = cmux_send_to_workspace(idx, surface_index, key="enter", workspace_uuid=ws_uuid)
        else:
            ok = cmux_send_to_workspace(idx, surface_index, text="y", workspace_uuid=ws_uuid)

        _debug_log({
            "event": "approved",
            "workspace": idx,
            "name": ws_name,
            "pattern": pattern_name,
            "action_sent": "Enter" if action == "enter" else "y",
            "ok": ok,
            "screen_tail": screen_tail,
        })

        if ok:
            # Clear fingerprint so the next identical prompt gets a fresh check.
            # Without this, back-to-back identical permission prompts (same last 5
            # lines) get deduped and the harness stalls on the repeat.
            with self._lock:
                self.fingerprints.pop(idx, None)
            print(f"[harness] ✓ ws:{idx} ({ws_name}) {pattern_name} → {'Enter' if action == 'enter' else 'y'}")
            self._append_log({
                "timestamp": now_str,
                "workspace": idx,
                "workspaceName": ws_name,
                "promptType": pattern_name,
                "action": f"sent {'Enter' if action == 'enter' else 'y'}",
                "surface": surface_index,
            })

    def run(self):
        while True:
            try:
                with self._lock:
                    enabled = self.enabled
                    interval = self.poll_interval
                    had_workspaces = len(self.workspaces) > 0
                    was_connected = self.socket_connected
                # Always refresh workspace list so the UI shows them
                # even before the global toggle is enabled.
                got_data = self.refresh_workspaces()

                now_ts = time.time()
                if got_data:
                    # Successful poll — reset failure counters
                    with self._lock:
                        self.last_successful_poll = now_ts
                        if not self.socket_connected:
                            # Reconnection event
                            print(f"[harness] ✓ cmux socket reconnected after {now_ts - self.connection_lost_at:.0f}s")
                            self.socket_connected = True
                            self.consecutive_failures = 0
                            # Clear stale state to force fresh detection
                            self.ws_has_claude = {}
                            self.screen_cache = {}
                        else:
                            self.consecutive_failures = 0
                else:
                    # Failed poll
                    with self._lock:
                        if had_workspaces:
                            self.consecutive_failures += 1
                            if self.consecutive_failures >= 3 and self.socket_connected:
                                self.socket_connected = False
                                self.connection_lost_at = now_ts
                                print(f"[harness] ✗ cmux socket lost after {self.consecutive_failures} consecutive failures")

                # Read screens for ALL workspaces so the UI has data.
                # Active workspaces (hasClaude=True) are read every cycle.
                # Idle workspaces are read at most once every 30 seconds.
                IDLE_READ_INTERVAL = 30  # seconds
                with self._lock:
                    ws_snap = list(self.workspaces)
                now_ts = time.time()
                for ws in ws_snap:
                    ws_uuid = ws.get("uuid", "")
                    idx = ws.get("index", ws.get("id"))
                    if not ws_uuid:
                        continue
                    # Determine if this workspace is idle (no Claude session)
                    with self._lock:
                        is_idle = not self.ws_has_claude.get(idx, False)
                        last_read = self.idle_last_read.get(idx, 0)
                    # Skip idle workspaces that were read recently
                    if is_idle and (now_ts - last_read) < IDLE_READ_INTERVAL:
                        continue
                    screen = cmux_read_workspace(idx, 0, lines=40, workspace_uuid=ws_uuid)
                    if screen:
                        has_claude = _detect_claude_session(screen)
                        cost = _parse_session_cost(screen)
                        should_capture_snapshot = False
                        with self._lock:
                            self.screen_cache[idx] = screen
                            prev_has_claude = self.ws_has_claude.get(idx, False)
                            self.ws_has_claude[idx] = has_claude
                            self.idle_last_read[idx] = now_ts
                            # Track session start/end transitions
                            if has_claude and not prev_has_claude:
                                start_ts = time.time()
                                self.session_start[idx] = start_ts
                                self.session_ids[idx] = f"{ws_uuid}_{int(start_ts)}"
                            elif not has_claude and prev_has_claude:
                                should_capture_snapshot = True
                            # Update cost if Claude is active
                            if has_claude and cost is not None:
                                self.session_cost[idx] = cost
                        if should_capture_snapshot:
                            self._capture_completion_snapshot_async(ws, idx)
                            with self._lock:
                                self.session_start.pop(idx, None)
                                self.session_cost.pop(idx, None)
                                self.session_ids.pop(idx, None)
                    else:
                        with self._lock:
                            self.idle_last_read[idx] = now_ts
                    # Also try sidebar state
                    sidebar = _v2_request("sidebar.state", {"workspace_id": ws_uuid})
                    if sidebar:
                        with self._lock:
                            for w in self.workspaces:
                                if w.get("index", w.get("id")) == idx:
                                    w["_cwd"] = sidebar.get("cwd", "")
                                    w["_branch"] = sidebar.get("gitBranch", sidebar.get("git_branch", ""))
                                    break

                if enabled:
                    # Phase 1: Check which workspaces have unread
                    # notifications WITHOUT switching workspaces.
                    attention_uuids = self.get_workspaces_needing_attention()

                    # Fail-open: if notifications exist but none match
                    # any known workspace UUID, the UUIDs are likely tab
                    # UUIDs (not workspace UUIDs). Bypass the filter so
                    # we don't silently skip all workspaces.
                    known_uuids = {w.get("uuid", "") for w in ws_snap}
                    filter_is_useful = not attention_uuids or bool(attention_uuids & known_uuids)

                    for ws in ws_snap:
                        idx = ws.get("index", ws.get("id"))
                        ws_uuid = ws.get("uuid", "")
                        with self._lock:
                            # Check persistent config first (keyed by UUID),
                            # fall back to runtime state (keyed by index).
                            cfg = self.ws_config.get(ws_uuid, {})
                            if "autoEnabled" in cfg:
                                ws_on = cfg["autoEnabled"]
                            else:
                                ws_on = self.workspace_enabled.get(idx, True)
                        if not ws_on:
                            continue
                        # Phase 2: Only filter by notifications when the
                        # UUIDs actually match known workspaces.
                        if filter_is_useful and attention_uuids and ws_uuid not in attention_uuids:
                            continue
                        self.check_workspace(ws)
            except Exception as exc:
                print(f"[harness] error: {exc}")
            time.sleep(interval)


# ---------------------------------------------------------------------------
# Dashboard HTML — embedded as string
# ---------------------------------------------------------------------------

DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>cmux harness — Command Center</title>
<style>
:root{--bg:#0d1117;--surface:#161b22;--surface-hover:#1c2129;--border:#30363d;--text:#e6edf3;--text-muted:#8b949e;--accent:#58a6ff;--green:#3fb950;--yellow:#d29922;--red:#f85149;--purple:#bc8cff;--radius:12px}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Segoe UI',sans-serif;background:var(--bg);color:var(--text);min-height:100vh}

/* Top Bar */
.topbar{display:flex;align-items:center;justify-content:space-between;padding:14px 28px;border-bottom:1px solid var(--border);background:var(--surface);position:sticky;top:0;z-index:100}
.topbar-left{display:flex;align-items:center;gap:20px}
.logo{font-size:18px;font-weight:700;letter-spacing:-.5px}
.logo span{color:var(--accent)}
.view-switcher{display:flex;align-items:center;gap:8px}
.view-btn{display:flex;align-items:center;gap:8px;padding:8px 14px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text-muted);font-size:12px;cursor:pointer;transition:all .15s}
.view-btn.active{background:rgba(88,166,255,.12);border-color:var(--accent);color:var(--accent);font-weight:600}
.view-btn:hover:not(.active){background:var(--surface-hover);color:var(--text)}
.review-badge{display:none;min-width:18px;height:18px;padding:0 6px;border-radius:999px;background:var(--red);color:#fff;font-size:11px;line-height:18px;text-align:center}
.conn-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-left:6px;vertical-align:middle}
.conn-dot.ok{background:var(--green);box-shadow:0 0 6px rgba(63,185,80,.5)}
.conn-dot.warn{background:var(--yellow);box-shadow:0 0 6px rgba(210,153,34,.5);animation:pulse-dot 2s infinite}
.conn-dot.err{background:var(--red);box-shadow:0 0 6px rgba(248,81,73,.5)}
@keyframes pulse-dot{0%,100%{opacity:1}50%{opacity:.4}}
.conn-status{font-size:12px;color:var(--yellow);margin-left:4px}
.stale-banner{display:none;align-items:center;justify-content:center;padding:10px 28px;background:rgba(210,153,34,.1);border-bottom:1px solid rgba(210,153,34,.3);color:var(--yellow);font-size:13px;gap:8px}
.card.stale{opacity:.45;pointer-events:auto}
.topbar-stats{display:flex;gap:20px}
.stat{display:flex;align-items:center;gap:6px;font-size:13px;color:var(--text-muted)}
.stat-dot{width:8px;height:8px;border-radius:50%;display:inline-block}
.topbar-actions{display:flex;gap:10px}
.btn{padding:8px 16px;border-radius:8px;border:1px solid var(--border);background:var(--surface);color:var(--text);font-size:13px;cursor:pointer;transition:all .15s}
.btn:hover{background:var(--surface-hover);border-color:var(--accent)}
.btn-primary{background:var(--accent);border-color:var(--accent);color:#000;font-weight:600}
.btn-primary:hover{opacity:.9}

/* Global toggle in topbar */
.global-toggle{display:flex;align-items:center;gap:8px;padding:6px 14px;border-radius:8px;border:1px solid var(--border);background:var(--bg)}
.global-toggle-label{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.3px}

/* Grid */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(540px,1fr));gap:16px;padding:24px 28px 50px}
.grid-empty{text-align:center;padding:80px 20px;color:var(--text-muted);font-size:15px;grid-column:1/-1}
.reviews-container{padding:20px 28px 60px}
.reviews-filters{position:sticky;top:73px;z-index:40;display:flex;align-items:center;justify-content:space-between;gap:16px;padding:14px 16px;margin-bottom:18px;border:1px solid var(--border);border-radius:14px;background:rgba(22,27,34,.96);backdrop-filter:blur(10px)}
.reviews-filters-left{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.reviews-count{font-size:13px;color:var(--text-muted);white-space:nowrap}
.reviews-list{display:flex;flex-direction:column;gap:16px}
.reviews-empty{text-align:center;padding:72px 20px;border:1px dashed var(--border);border-radius:14px;background:rgba(0,0,0,.12);color:var(--text-muted);font-size:14px}
.review-card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:18px;display:flex;flex-direction:column;gap:14px;transition:border-color .2s,box-shadow .2s}
.review-card:hover{border-color:#444c56}
.review-card.dismissed{opacity:.5}
.review-card.pending-card{border-color:rgba(188,140,255,.35)}
.review-card.error-card{border-color:rgba(248,81,73,.35)}
.review-header{display:flex;align-items:flex-start;justify-content:space-between;gap:12px}
.review-head-main{display:flex;align-items:center;gap:10px;min-width:0}
.review-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.review-dot.green{background:var(--green);box-shadow:0 0 8px rgba(63,185,80,.4)}
.review-dot.yellow{background:var(--yellow);box-shadow:0 0 8px rgba(210,153,34,.35)}
.review-dot.red{background:var(--red);box-shadow:0 0 8px rgba(248,81,73,.35)}
.review-dot.purple{background:var(--purple);box-shadow:0 0 8px rgba(188,140,255,.4)}
.review-dot.blue{background:var(--accent);box-shadow:0 0 8px rgba(88,166,255,.4)}
.review-dot.pulse{animation:pulse 1.6s infinite}
.review-dot.gray{background:var(--text-muted);opacity:.7}
.review-title{font-size:16px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.review-meta-right{display:flex;align-items:center;gap:14px;flex-shrink:0;font-size:12px;color:var(--text-muted)}
.review-cost{font-family:'JetBrains Mono','SF Mono','Menlo',monospace}
.review-summary{font-size:14px;line-height:1.5;color:var(--text)}
.review-stats{display:flex;flex-wrap:wrap;gap:16px;font-size:12px;color:var(--text-muted)}
.review-status-row{display:flex;align-items:center;justify-content:space-between;gap:12px}
.review-status-badge{display:inline-flex;align-items:center;gap:8px;padding:6px 12px;border-radius:999px;font-size:12px;font-weight:700;border:1px solid transparent}
.review-status-badge.ready{background:rgba(63,185,80,.14);color:var(--green)}
.review-status-badge.issues{background:rgba(210,153,34,.15);color:var(--yellow)}
.review-status-badge.attention,.review-status-badge.error{background:rgba(248,81,73,.14);color:var(--red)}
.review-status-badge.pending{background:rgba(188,140,255,.14);color:var(--purple)}
.review-status-badge.dismissed,.review-status-badge.skipped{background:rgba(139,148,158,.12);color:var(--text-muted)}
.review-status-badge.reviewed{background:rgba(88,166,255,.14);color:var(--accent)}
.review-issues,.review-highlights{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:8px}
.review-issues li,.review-highlights li{font-size:13px;line-height:1.5}
.review-highlights{padding:12px 18px;border-radius:12px;background:rgba(63,185,80,.08);border:1px solid rgba(63,185,80,.15)}
.review-highlights li{color:#b7f0bf}
.review-what-happened{font-size:13px;line-height:1.6;color:var(--text-muted);margin:8px 0 12px;padding:10px 14px;background:rgba(139,148,158,.06);border-radius:8px}
.review-next-steps{margin:0 0 8px;padding:12px 14px;border-left:3px solid var(--green);border-radius:8px;background:rgba(63,185,80,.08);color:var(--text);font-size:13px;line-height:1.6}
.review-recommendation{margin:0;padding:12px 14px;border-left:3px solid var(--accent);border-radius:8px;background:rgba(88,166,255,.08);color:var(--text);font-size:13px;line-height:1.6}
.review-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.review-action-btn{padding:8px 12px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text);font-size:12px;cursor:pointer;transition:all .15s}
.review-action-btn:hover{border-color:var(--accent);color:var(--accent)}
.review-action-btn.danger:hover{border-color:var(--red);color:var(--red)}
.review-more{padding:0;border:none;background:none;color:var(--accent);font-size:12px;cursor:pointer;text-align:left}

/* Card */
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);overflow:hidden;transition:border-color .2s,box-shadow .2s}
.card:hover{border-color:#444c56}
.card.needs-attention{border-color:var(--yellow);box-shadow:0 0 16px rgba(210,153,34,.1);order:-1}
.card-header{display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border-bottom:1px solid var(--border)}
.card-title-row{display:flex;align-items:center;gap:10px;min-width:0;flex:1}
.card-status{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.card-status.active{background:var(--green);box-shadow:0 0 8px rgba(63,185,80,.4)}
.card-status.waiting{background:var(--yellow);animation:pulse 2s infinite}
.card-status.idle{background:var(--text-muted);opacity:.5}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.card-name{font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer;border-bottom:1px solid transparent;transition:border-color .15s}
.card-name:hover{border-bottom-color:var(--accent)}
.card-name-edit{font-size:15px;font-weight:600;background:transparent;border:none;border-bottom:2px solid var(--accent);color:var(--text);outline:none;width:180px;font-family:inherit;padding:0}
.card-name-original{font-size:11px;color:var(--text-muted);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card-header-right{display:flex;align-items:center;gap:8px;flex-shrink:0}
.badge{padding:3px 10px;border-radius:20px;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.5px}
.badge-active{background:rgba(63,185,80,.15);color:var(--green)}
.badge-waiting{background:rgba(210,153,34,.15);color:var(--yellow)}
.badge-idle{background:rgba(139,148,158,.15);color:var(--text-muted)}

/* Collapsed idle card */
.card-collapsed{opacity:0.7;order:1}
.card-collapsed .card-header{border-bottom:none}
.card-collapsed:hover{opacity:0.9}
.card-collapsed.expanded-inline .card-header{border-bottom:1px solid var(--border)}
.card-collapsed .card-meta,.card-collapsed .card-terminal,.card-collapsed .card-footer{display:none}
.card-collapsed.expanded-inline .card-meta,.card-collapsed.expanded-inline .card-terminal,.card-collapsed.expanded-inline .card-footer{display:flex}
.card-collapsed.expanded-inline .card-terminal{display:block}
.card-expand-caret{width:28px;height:28px;border-radius:6px;border:1px solid var(--border);background:var(--bg);color:var(--text-muted);font-size:12px;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all .15s;flex-shrink:0}
.card-expand-caret:hover{border-color:var(--accent);color:var(--accent)}
.card-collapsed.expanded-inline .card-expand-caret{background:rgba(88,166,255,.1);color:var(--accent);border-color:var(--accent)}
/* Active cards always show full content */
.card:not(.card-collapsed) .card-meta{display:flex}
.card:not(.card-collapsed) .card-terminal{display:block}
.card:not(.card-collapsed) .card-footer{display:flex}
/* Smooth transition for idle→active expansion */
.card{transition:border-color .2s,box-shadow .2s,opacity .3s}

/* Auto toggle */
.auto-toggle{display:flex;align-items:center;gap:5px;cursor:pointer;user-select:none}
.auto-toggle-label{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.3px;color:var(--text-muted);transition:color .2s}
.auto-toggle.on .auto-toggle-label{color:var(--green)}
.toggle-track{width:34px;height:18px;background:var(--border);border-radius:9px;position:relative;transition:background .2s;flex-shrink:0}
.auto-toggle.on .toggle-track{background:var(--green)}
.toggle-track::after{content:'';width:14px;height:14px;background:#fff;border-radius:50%;position:absolute;top:2px;left:2px;transition:transform .2s;box-shadow:0 1px 3px rgba(0,0,0,.3)}
.auto-toggle.on .toggle-track::after{transform:translateX(16px)}

/* Global toggle track (slightly larger) */
.global-track{width:40px;height:22px;background:var(--border);border-radius:11px;position:relative;transition:background .2s;flex-shrink:0;cursor:pointer}
.global-track.on{background:var(--green)}
.global-track::after{content:'';width:18px;height:18px;background:#fff;border-radius:50%;position:absolute;top:2px;left:2px;transition:transform .2s;box-shadow:0 1px 3px rgba(0,0,0,.3)}
.global-track.on::after{transform:translateX(18px)}

.expand-btn{width:32px;height:32px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text-muted);font-size:16px;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all .15s}
.expand-btn:hover{border-color:var(--accent);color:var(--accent)}

.card-meta{display:flex;gap:14px;padding:10px 18px 0;font-size:12px;color:var(--text-muted);flex-wrap:wrap}
.card-terminal{padding:12px 18px;font-family:'JetBrains Mono','SF Mono','Menlo',monospace;font-size:12px;line-height:1.6;color:var(--text-muted);background:rgba(0,0,0,.2);min-height:120px;max-height:300px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.card-terminal::-webkit-scrollbar{width:6px}
.card-terminal::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
.card-terminal::-webkit-scrollbar-thumb:hover{background:var(--text-muted)}
.card-footer{display:flex;align-items:center;gap:8px;padding:12px 18px;border-top:1px solid var(--border)}
.card-input{flex:1;padding:9px 14px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text);font-size:13px;outline:none}
.card-input:focus{border-color:var(--accent)}
.card-input::placeholder{color:var(--text-muted)}
.card-send{padding:9px 16px;border-radius:8px;border:none;background:var(--accent);color:#000;font-size:13px;font-weight:600;cursor:pointer;white-space:nowrap}

/* Expanded overlay */
.overlay{display:none;position:fixed;inset:0;z-index:1000;background:rgba(0,0,0,.7);backdrop-filter:blur(4px);animation:fadeIn .15s ease}
.overlay.visible{display:flex}
@keyframes fadeIn{from{opacity:0}to{opacity:1}}
.expanded-panel{display:flex;width:92vw;max-width:1400px;height:85vh;margin:auto;background:var(--surface);border:1px solid var(--border);border-radius:16px;overflow:hidden;box-shadow:0 24px 80px rgba(0,0,0,.5);animation:slideUp .2s ease}
@keyframes slideUp{from{transform:translateY(20px);opacity:0}to{transform:translateY(0);opacity:1}}
.exp-main{flex:1;display:flex;flex-direction:column;overflow:hidden}
.exp-header{padding:20px 24px;border-bottom:1px solid var(--border);display:flex;align-items:flex-start;justify-content:space-between}
.exp-title{font-size:22px;font-weight:700;margin-bottom:8px}
.exp-meta{display:flex;gap:20px;font-size:13px;color:var(--text-muted);flex-wrap:wrap}
.exp-header-actions{display:flex;gap:8px;align-items:center}
.exp-header-actions.hidden,.exp-input.hidden{display:none}
.exp-tabs{display:none;padding:0 24px 16px;border-bottom:1px solid var(--border);background:var(--surface)}
.exp-tabs.visible{display:block}
.exp-close{width:36px;height:36px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text-muted);font-size:18px;cursor:pointer;display:flex;align-items:center;justify-content:center}
.exp-close:hover{border-color:var(--red);color:var(--red)}
.exp-terminal{flex:1;overflow-y:auto;padding:16px 24px;font-family:'JetBrains Mono','SF Mono',monospace;font-size:13px;line-height:1.8;background:rgba(0,0,0,.15);white-space:pre-wrap;word-break:break-all}
.exp-terminal.activity-list{padding:0;background:var(--bg);font-family:inherit;white-space:normal;word-break:normal}
.exp-terminal.activity-list .act-item{padding:14px 18px}
.exp-input{display:flex;align-items:center;gap:10px;padding:16px 24px;border-top:1px solid var(--border);background:var(--surface)}
.mode-toggle{display:flex;border-radius:8px;overflow:hidden;border:1px solid var(--border);flex-shrink:0}
.mode-btn{padding:8px 14px;font-size:12px;background:var(--bg);color:var(--text-muted);border:none;cursor:pointer;transition:all .15s}
.mode-btn.active{background:var(--accent);color:#000;font-weight:600}
.mode-btn:hover:not(.active){background:var(--surface-hover)}
.exp-input-field{flex:1;padding:10px 16px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text);font-size:14px;outline:none}
.exp-input-field:focus{border-color:var(--accent)}
.exp-input-field::placeholder{color:var(--text-muted)}
.exp-send{padding:10px 22px;border-radius:8px;border:none;background:var(--accent);color:#000;font-size:14px;font-weight:600;cursor:pointer;white-space:nowrap}

/* Activity panel */
.exp-activity{width:300px;border-left:1px solid var(--border);background:var(--bg);display:flex;flex-direction:column;flex-shrink:0}
.exp-activity-header{padding:16px 18px;font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:1px;color:var(--text-muted);border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between}
.exp-activity-count{padding:2px 8px;border-radius:10px;font-size:11px;background:rgba(88,166,255,.1);color:var(--accent)}
.exp-activity-list{flex:1;overflow-y:auto;padding:4px 0}
.act-item{padding:12px 18px;border-bottom:1px solid rgba(48,54,61,.4)}
.act-item:last-child{border-bottom:none}
.act-time{font-size:10px;color:var(--text-muted);margin-bottom:4px}
.act-text{font-size:12px;color:var(--text);line-height:1.5}
.act-type{display:inline-block;padding:2px 7px;border-radius:4px;font-size:10px;font-weight:700;margin-right:4px}
.act-type.approved{background:rgba(63,185,80,.15);color:var(--green)}
.act-type.flagged{background:rgba(210,153,34,.15);color:var(--yellow)}
.act-type.action{background:rgba(88,166,255,.1);color:var(--accent)}
.esc-hint{position:fixed;top:16px;right:16px;padding:4px 10px;border-radius:6px;background:rgba(0,0,0,.5);color:var(--text-muted);font-size:11px;pointer-events:none;z-index:1001;display:none}
.overlay.visible .esc-hint-show{display:block}

/* Settings modal */
.settings-overlay{display:none;position:fixed;inset:0;z-index:2000;background:rgba(0,0,0,.6);backdrop-filter:blur(3px)}
.settings-overlay.visible{display:flex;align-items:center;justify-content:center}
.settings-panel{background:var(--surface);border:1px solid var(--border);border-radius:16px;padding:28px;width:420px;max-width:90vw;box-shadow:0 16px 60px rgba(0,0,0,.5)}
.settings-title{font-size:18px;font-weight:700;margin-bottom:20px;display:flex;align-items:center;justify-content:space-between}
.settings-row{display:flex;align-items:center;justify-content:space-between;padding:12px 0;border-bottom:1px solid var(--border)}
.settings-row:last-child{border-bottom:none}
.settings-label{font-size:14px;color:var(--text)}
.settings-sublabel{font-size:11px;color:var(--text-muted);margin-top:2px}
.settings-section{padding:14px 0 8px;font-size:12px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--text-muted);border-bottom:1px solid var(--border)}
.settings-select{background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:8px;padding:8px 12px;font-size:13px;outline:none;min-width:160px}
.settings-select:focus{border-color:var(--accent)}
.ollama-status{display:flex;align-items:center;gap:5px;font-size:12px;color:var(--text-muted);margin-top:4px}
.ollama-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.ollama-dot.green{background:var(--green)}
.ollama-dot.red{background:var(--red)}
.ollama-dot.gray{background:var(--text-muted);opacity:.5}
.backend-status-list{display:flex;gap:10px;flex-wrap:wrap;margin-top:6px;font-size:11px;color:var(--text-muted)}
.backend-status-item{display:flex;align-items:center;gap:5px}
.backend-status-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0;background:var(--text-muted);opacity:.5}
.backend-status-dot.green{background:var(--green);opacity:1}
.backend-status-dot.red{background:var(--red);opacity:1}
.llm-unavail{font-size:11px;color:var(--red);opacity:.85;margin-left:4px}

/* Global Activity Feed panel */
.activity-panel{position:fixed;bottom:0;left:0;right:0;z-index:50;background:var(--surface);border-top:1px solid var(--border);transition:transform 0.2s ease}
.activity-panel-header{display:flex;align-items:center;justify-content:space-between;padding:10px 28px;cursor:pointer;font-size:13px;font-weight:600;color:var(--text-muted)}
.activity-panel-header:hover{color:var(--text)}
.activity-count{padding:2px 8px;border-radius:10px;font-size:11px;background:rgba(88,166,255,0.1);color:var(--accent);margin-left:8px}
.activity-panel-body{max-height:250px;overflow-y:auto;padding:0 28px}
.activity-panel.collapsed .activity-panel-body{display:none}
.activity-panel.collapsed .activity-chevron{transform:rotate(180deg)}
.activity-entry{display:flex;align-items:center;gap:12px;padding:6px 0;border-bottom:1px solid var(--border);font-size:12px}
.activity-entry:last-child{border-bottom:none}
.ae-time{color:var(--text-muted);font-family:monospace;white-space:nowrap}
.ae-ws{color:var(--accent);font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:200px}
.ae-type{padding:1px 6px;border-radius:4px;font-size:10px;font-weight:700}
.ae-type.approved{background:rgba(63,185,80,0.15);color:var(--green)}
.ae-type.flagged{background:rgba(210,153,34,0.15);color:var(--yellow)}
.ae-prompt{color:var(--text-muted);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}

@media (max-width: 960px){
  .topbar{padding:14px 18px;flex-wrap:wrap;gap:12px}
  .topbar-left,.topbar-actions{width:100%;justify-content:space-between;flex-wrap:wrap}
  .reviews-container,.grid{padding-left:18px;padding-right:18px}
  .reviews-filters{top:120px;flex-direction:column;align-items:stretch}
  .reviews-filters-left{width:100%}
  .reviews-count{text-align:right}
  .expanded-panel{width:96vw;height:92vh;flex-direction:column}
  .exp-activity{width:100%;height:240px;border-left:none;border-top:1px solid var(--border)}
}
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-left">
    <div class="logo"><span>cmux</span> harness<span class="conn-dot" id="connDot"></span><span class="conn-status" id="connStatus"></span></div>
    <div class="view-switcher">
      <button class="view-btn active" id="viewBtn-center" onclick="switchView('center')">&#128308; Command Center</button>
      <button class="view-btn" id="viewBtn-reviews" onclick="switchView('reviews')">&#128203; Reviews <span class="review-badge" id="reviewBadge"></span></button>
    </div>
    <div class="topbar-stats" id="topStats">
      <div class="stat"><span class="stat-dot" style="background:var(--green)"></span> <span id="statActive">0</span> active</div>
      <div class="stat"><span class="stat-dot" style="background:var(--yellow)"></span> <span id="statWaiting">0</span> waiting</div>
      <div class="stat"><span class="stat-dot" style="background:var(--text-muted);opacity:.5"></span> <span id="statIdle">0</span> idle</div>
      <div class="stat" id="statLlm" style="display:none"><span class="stat-dot" style="background:var(--red)"></span> <span class="llm-unavail">LLM ✗</span></div>
    </div>
  </div>
  <div class="topbar-actions">
    <div class="global-toggle">
      <span class="global-toggle-label" id="globalLabel">OFF</span>
      <div class="global-track" id="globalTrack" onclick="toggleGlobal()"></div>
    </div>
    <button class="btn" onclick="openSettings()">&#9881; Settings</button>
    <button class="btn btn-primary" onclick="newSession()">+ New Session</button>
  </div>
</div>

<div class="stale-banner" id="staleBanner">&#9888; Showing stale data — cmux connection lost. Attempting to reconnect...</div>
<div class="grid" id="grid">
  <div class="grid-empty">Connecting to cmux...</div>
</div>
<div class="reviews-container" id="reviewsContainer" style="display:none">
  <div class="reviews-filters" id="reviewsFilters">
    <div class="reviews-filters-left">
      <select class="settings-select" id="reviewStatusFilter" onchange="setReviewFilter('status',this.value)">
        <option value="all">All statuses</option>
        <option value="ready">Ready for PR</option>
        <option value="issues">Has Issues</option>
        <option value="attention">Needs Attention</option>
        <option value="pending">Pending</option>
        <option value="error">Error</option>
        <option value="dismissed">Dismissed</option>
      </select>
      <select class="settings-select" id="reviewTimeFilter" onchange="setReviewFilter('time',this.value)">
        <option value="today">Today</option>
        <option value="24h">Last 24h</option>
        <option value="7d">Last 7 days</option>
        <option value="all">All time</option>
      </select>
      <select class="settings-select" id="reviewSortFilter" onchange="setReviewFilter('sort',this.value)">
        <option value="newest">Newest first</option>
        <option value="oldest">Oldest first</option>
        <option value="files">Most files</option>
        <option value="cost">Highest cost</option>
      </select>
    </div>
    <div class="reviews-count" id="reviewsCount">0 reviews</div>
  </div>
  <div class="reviews-list" id="reviewsList"></div>
</div>

<!-- Global Activity Feed -->
<div class="activity-panel collapsed" id="activityPanel">
  <div class="activity-panel-header" onclick="toggleActivityPanel()">
    <span>Activity Feed</span>
    <span class="activity-count" id="activityCount">0</span>
    <span class="activity-chevron" id="activityChevron">&#9650;</span>
  </div>
  <div class="activity-panel-body" id="activityBody">
    <!-- populated by JS -->
  </div>
</div>

<!-- Expanded overlay -->
<div class="overlay" id="overlay" onclick="if(event.target===this)closeExpanded()">
  <div class="expanded-panel">
    <div class="exp-main">
      <div class="exp-header">
        <div>
          <div class="exp-title" id="expTitle">—</div>
          <div class="exp-meta" id="expMeta"></div>
        </div>
        <div class="exp-header-actions">
          <div class="auto-toggle" id="expAutoToggle" onclick="toggleExpAuto()">
            <span class="auto-toggle-label">Auto</span>
            <div class="toggle-track"></div>
          </div>
          <button class="btn" style="font-size:12px" onclick="closeExpanded()">&#10005; Close</button>
        </div>
      </div>
      <div class="exp-tabs" id="expReviewTabs">
        <div class="mode-toggle">
          <button class="mode-btn" id="expTab-diff" onclick="switchReviewOverlayTab('diff')">Diff</button>
          <button class="mode-btn" id="expTab-terminal" onclick="switchReviewOverlayTab('terminal')">Terminal</button>
          <button class="mode-btn" id="expTab-approval" onclick="switchReviewOverlayTab('approval')">Approval Log</button>
        </div>
      </div>
      <div class="exp-terminal" id="expTerminal">(no data)</div>
      <div class="exp-input">
        <div class="mode-toggle">
          <button class="mode-btn active" onclick="setMode(this,'raw')">Raw</button>
          <button class="mode-btn" onclick="setMode(this,'intent')">Intent</button>
        </div>
        <input class="exp-input-field" id="expInput" placeholder="Type a message or instruction..." onkeydown="if(event.key==='Enter')sendExp()">
        <button class="exp-send" onclick="sendExp()">Send &#8629;</button>
      </div>
    </div>
    <div class="exp-activity">
      <div class="exp-activity-header">Activity <span class="exp-activity-count" id="expActCount">0</span></div>
      <div class="exp-activity-list" id="expActList"></div>
    </div>
  </div>
</div>
<div class="esc-hint" id="escHint"><kbd style="padding:2px 6px;border-radius:4px;background:rgba(255,255,255,.1);font-family:inherit;font-size:10px">esc</kbd> to close</div>

<!-- Settings overlay -->
<div class="settings-overlay" id="settingsOverlay" onclick="if(event.target===this)closeSettings()">
  <div class="settings-panel">
    <div class="settings-title">Settings <button class="exp-close" onclick="closeSettings()" style="width:32px;height:32px;font-size:14px">&#10005;</button></div>
    <div class="settings-row">
      <div>
        <div class="settings-label">Poll Interval</div>
        <div class="settings-sublabel">How often to check workspaces</div>
      </div>
      <select class="settings-select" id="settingsPoll" onchange="saveSetting('pollInterval',parseInt(this.value))">
        <option value="2">2 seconds</option>
        <option value="3">3 seconds</option>
        <option value="5">5 seconds</option>
        <option value="10">10 seconds</option>
      </select>
    </div>
    <div class="settings-row" style="flex-direction:column;align-items:flex-start;gap:8px">
      <div style="display:flex;align-items:center;justify-content:space-between;width:100%">
        <div>
          <div class="settings-label">LLM Model</div>
          <div class="settings-sublabel">Ollama model for fallback classification</div>
          <div class="ollama-status" id="ollamaStatus">
            <span class="ollama-dot gray" id="ollamaDot"></span>
            <span id="ollamaStatusText">Unknown</span>
          </div>
        </div>
        <select class="settings-select" id="settingsModel" onchange="saveSetting('model',this.value)">
          <option>Loading...</option>
        </select>
      </div>
    </div>
    <div class="settings-row">
      <div>
        <div class="settings-label">LLM Enabled</div>
        <div class="settings-sublabel">Use LLM when regex doesn't match</div>
      </div>
      <div class="auto-toggle on" id="settingsLlm" onclick="this.classList.toggle('on')">
        <span class="auto-toggle-label">On</span>
        <div class="toggle-track"></div>
      </div>
    </div>
    <div class="settings-section">Session Reviews</div>
    <div class="settings-row">
      <div>
        <div class="settings-label">Review Enabled</div>
        <div class="settings-sublabel">Enable reviews for completed sessions</div>
      </div>
      <div class="auto-toggle on" id="settingsReviewEnabled" onclick="toggleReviewEnabled()">
        <span class="auto-toggle-label">On</span>
        <div class="toggle-track"></div>
      </div>
    </div>
    <div class="settings-row" style="flex-direction:column;align-items:flex-start;gap:8px">
      <div style="display:flex;align-items:center;justify-content:space-between;width:100%;gap:12px">
        <div>
          <div class="settings-label">Review Backend</div>
          <div class="settings-sublabel">Choose which backend runs reviews</div>
          <div class="backend-status-list" id="reviewBackendStatus">
            <span class="backend-status-item"><span class="backend-status-dot" id="backendDot-claude"></span>Claude</span>
            <span class="backend-status-item"><span class="backend-status-dot" id="backendDot-lmstudio"></span>LM Studio</span>
            <span class="backend-status-item"><span class="backend-status-dot" id="backendDot-ollama"></span>Ollama</span>
          </div>
        </div>
        <select class="settings-select" id="settingsReviewBackend" onchange="changeReviewBackend(this.value)">
          <option value="claude">Claude (Sonnet 4)</option>
          <option value="lmstudio">LM Studio (27B)</option>
          <option value="ollama">Ollama (local)</option>
        </select>
      </div>
    </div>
    <div class="settings-row" id="settingsReviewModelRow" style="flex-direction:column;align-items:flex-start;gap:8px">
      <div style="display:flex;align-items:center;justify-content:space-between;width:100%;gap:12px">
        <div>
          <div class="settings-label">Review Model</div>
          <div class="settings-sublabel">Only shown when Review Backend is Ollama</div>
        </div>
        <select class="settings-select" id="settingsReviewModel" onchange="saveReviewSetting('reviewModel',this.value)">
          <option value="">Loading...</option>
        </select>
      </div>
    </div>
    <div class="settings-row">
      <div>
        <div class="settings-label">Auto-review on complete</div>
        <div class="settings-sublabel">Same toggle as Review Enabled</div>
      </div>
      <div class="auto-toggle on" id="settingsReviewAuto" onclick="toggleReviewEnabled()">
        <span class="auto-toggle-label">On</span>
        <div class="toggle-track"></div>
      </div>
    </div>
    <div class="settings-row">
      <div>
        <div class="settings-label">Notifications</div>
        <div class="settings-sublabel">Browser alerts + sound on state changes</div>
      </div>
      <div class="auto-toggle on" id="settingsNotif" onclick="toggleNotifications(this)">
        <span class="auto-toggle-label">On</span>
        <div class="toggle-track"></div>
      </div>
    </div>
    <div class="settings-row" style="flex-direction:column;align-items:flex-start;gap:8px">
      <div>
        <div class="settings-label">Default Working Directory</div>
        <div class="settings-sublabel">Used when creating new sessions</div>
      </div>
      <input class="settings-select" id="settingsCwd" type="text"
        style="width:100%;min-width:0;font-family:inherit"
        placeholder="~/Documents/Development/Doximity-Cloud"
        onchange="defaultCwd=this.value.trim()||'~/Documents/Development/Doximity-Cloud'">
    </div>
  </div>
</div>

<script>
(function(){
var state = {
  enabled:false,
  workspaces:[],
  model:'',
  pollInterval:5,
  socketFound:false,
  connected:undefined,
  ollamaAvailable:null,
  reviewEnabled:true,
  reviewModel:'',
  reviewBackend:'claude',
  backendAvailability:{claude:null,lmstudio:null,ollama:null}
};
var logData = [];
var expandedWsIndex = null;
var expandedReview = null;
var expandedMode = 'workspace';
var currentView = 'center';
var prevWsStates = {};
var notificationsEnabled = true;
var audioCtx = null;
var reviewsData = [];
var reviewsLoaded = false;
var reviewsRefreshTimer = null;
var reviewFilters = {status:'all',time:'today',sort:'newest'};
var notifiedReviewSessions = new Set();
var lastGlobalReviewsRefresh = 0;

// Request notification permission on page load
if ('Notification' in window && Notification.permission === 'default') {
  Notification.requestPermission();
}

function api(method,path,body){
  var opts={method:method,headers:{'Content-Type':'application/json'}};
  if(body!==undefined)opts.body=JSON.stringify(body);
  return fetch(path,opts).then(function(r){return r.json()}).catch(function(){return null});
}

function esc(s){var d=document.createElement('div');d.textContent=s||'';return d.innerHTML}

function colorize(text){
  if(!text)return '<span style="color:var(--text-muted);font-style:italic">(no data yet)</span>';
  var h=esc(text);
  // Claude Code tool actions: ⚡ Read/Edit/Write/Bash etc
  h=h.replace(/(⚡\s*)(Read|Edit|Write|Bash|MultiEdit|Search|Glob|Grep|ListDir|Fetch|Browse|TodoRead|TodoWrite|WebFetch|MCP|WebSearch|Task|NotebookRead|NotebookEdit)(\s+)/g,
    '<span style="color:var(--purple);font-weight:600">$1$2</span>$3');
  // File paths after tool actions (anything that looks like a path)
  h=h.replace(/((?:Sources|Tests|Packages|App|src|lib|test|spec|config|public|views|models|controllers)\/[^\s<]+)/g,
    '<span style="color:var(--accent)">$1</span>');
  // Also color generic file paths with extensions
  h=h.replace(/([A-Za-z0-9_\-]+\.(?:swift|ts|tsx|js|jsx|py|rb|go|rs|json|yaml|yml|toml|css|html|md|sh|sql|xml|plist|h|m|c|cpp|java|kt))/g,
    '<span style="color:var(--accent)">$1</span>');
  // Musing.../Thinking.../Processing...
  h=h.replace(/(Musing\.\.\.|Thinking\.\.\.|Processing\.\.\.)/g,
    '<span style="color:var(--green);font-style:italic">$1</span>');
  // Claude Code REPL prompt ❯ (and the ) variant)
  h=h.replace(/^(\s*[❯)]\s*)/gm,
    '<span style="color:var(--green);font-weight:600">$1</span>');
  // Shell prompts ($ at start of line)
  h=h.replace(/^(\$\s)/gm,
    '<span style="color:var(--green)">$1</span>');
  // (Y/n) and (y/n) prompts
  h=h.replace(/(\([Yy](?:\/[Nn]|es\/no)\))/g,
    '<span style="color:var(--yellow);font-weight:600">$1</span>');
  // "Allow <Tool>" prompts
  h=h.replace(/(Allow\s+(?:Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit))/g,
    '<span style="color:var(--yellow);font-weight:600">$1</span>');
  // Numbered menu items with cursor
  h=h.replace(/^(\s*[❯)]\s*\d+[.)]\s+.*)$/gm,
    '<span style="color:var(--yellow)">$1</span>');
  // Model:/Cost:/Ctx: info lines
  h=h.replace(/(Model:\s*[^\n]+)/g,'<span style="color:var(--text-muted)">$1</span>');
  h=h.replace(/(Cost:\s*\$[^\n]+)/g,'<span style="color:var(--text-muted)">$1</span>');
  h=h.replace(/(Ctx:\s*[^\n]+)/g,'<span style="color:var(--text-muted)">$1</span>');
  // Success messages
  h=h.replace(/(Build complete!|All \d+ tests passed|✓[^\n]*|Done[.!]?)/g,
    '<span style="color:var(--green)">$1</span>');
  // Error/warning keywords
  h=h.replace(/(error:|Error:|ERROR|failed|Failed|FAILED|warning:|Warning:)/g,
    '<span style="color:var(--red);font-weight:600">$1</span>');
  // Diff-style lines
  h=h.replace(/^(\+[^\n]+)$/gm,'<span style="color:var(--green)">$1</span>');
  h=h.replace(/^(-[^\n]+)$/gm,'<span style="color:var(--red)">$1</span>');
  return h;
}

function fmtTime(iso){
  if(!iso)return '\u2014';
  try{return new Date(iso).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}catch(e){return iso}
}

function formatDuration(start) {
  if (!start) return '';
  var secs = Math.floor(Date.now()/1000 - start);
  if (secs < 60) return secs + 's';
  var mins = Math.floor(secs / 60);
  if (mins < 60) return mins + 'm';
  var hrs = Math.floor(mins / 60);
  return hrs + 'h ' + (mins % 60) + 'm';
}

function costColor(cost) {
  if (!cost) return '';
  var m = cost.match(/\$([\d.]+)/);
  if (!m) return 'var(--green)';
  var val = parseFloat(m[1]);
  if (val < 1) return 'var(--green)';
  if (val <= 5) return 'var(--yellow)';
  return 'var(--red)';
}

function diffColorize(text){
  if(!text)return '<span style="color:var(--text-muted);font-style:italic">(no diff available)</span>';
  return text.split('\n').map(function(line){
    if(line==='')return '';
    var rendered=colorize(line);
    if(/^diff --git /.test(line) || /^--- /.test(line) || /^\+\+\+ /.test(line)){
      return '<span style="color:var(--accent);font-weight:700">'+rendered+'</span>';
    }
    if(/^@@/.test(line)){
      return '<span style="color:var(--purple);font-weight:700">'+rendered+'</span>';
    }
    if(/^\+/.test(line) && !/^\+\+\+ /.test(line)){
      return '<span style="color:var(--green)">'+rendered+'</span>';
    }
    if(/^-/.test(line) && !/^--- /.test(line)){
      return '<span style="color:var(--red)">'+rendered+'</span>';
    }
    return rendered;
  }).join('\n');
}

function plural(n,word){return n+' '+word+(n===1?'':'s')}

function parseIso(ts){
  var d=ts?new Date(ts):null;
  return d&&isFinite(d.getTime())?d:null;
}

function formatReviewTimestamp(ts){
  var d=parseIso(ts);
  if(!d)return '—';
  return d.toLocaleString([],{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'});
}

function formatReviewDuration(seconds){
  var total=Math.max(0,Math.round(Number(seconds)||0));
  var mins=Math.floor(total/60);
  var secs=total%60;
  if(mins===0)return secs+'s';
  return mins+'m '+secs+'s';
}

function reviewCostValue(cost){
  var m=(cost||'').match(/\$([\d.]+)/);
  return m?parseFloat(m[1]):0;
}

function reviewFilesChanged(review){
  var data=review.review||{};
  if(Array.isArray(data.filesChanged)&&data.filesChanged.length)return data.filesChanged.length;
  return 0;
}

function getUnreadReviewCount(){
  return reviewsData.filter(function(r){return ['pending','reviewing','error'].indexOf(r.reviewStatus)!==-1}).length;
}

function updateReviewBadge(){
  var badge=document.getElementById('reviewBadge');
  if(!badge)return;
  var count=getUnreadReviewCount();
  badge.textContent=String(count);
  badge.style.display=count>0?'inline-block':'none';
}

function reviewStatusMeta(item){
  var status=item.reviewStatus||'pending';
  var review=item.review||{};
  var issues=Array.isArray(review.issues)?review.issues:[];
  if(status==='dismissed')return {key:'dismissed',label:'Dismissed',icon:'⦸',dot:'gray',card:'dismissed'};
  if(status==='error')return {key:'error',label:'Error',icon:'❌',dot:'red',card:'error-card'};
  if(status==='skipped')return {key:'skipped',label:'No Code Changes',icon:'📝',dot:'blue'};
  if(status==='pending' || status==='reviewing')return {key:'pending',label:'Pending',icon:'⏳',dot:'purple pulse',card:'pending-card'};
  if(status==='flagged'){
    if((review.confidence||'').toLowerCase()==='low')return {key:'attention',label:'Needs Attention',icon:'🔴',dot:'red'};
    return {key:'issues',label:'Has Issues'+(issues.length?' ('+issues.length+')':''),icon:'⚠️',dot:'yellow'};
  }
  if(review.readyForPR)return {key:'ready',label:'Ready for PR',icon:'✅',dot:'green'};
  if(issues.length)return {key:'issues',label:'Has Issues ('+issues.length+')',icon:'⚠️',dot:'yellow'};
  if((review.confidence||'').toLowerCase()==='low')return {key:'attention',label:'Needs Attention',icon:'🔴',dot:'red'};
  var noChanges=!review.filesChanged||review.filesChanged.length===0;
  if(noChanges)return {key:'reviewed',label:'Reviewed',icon:'📝',dot:'blue'};
  return {key:'ready',label:'Ready for PR',icon:'✅',dot:'green'};
}

function reviewSummaryText(item){
  var status=item.reviewStatus||'pending';
  var review=item.review||{};
  if(review.summary)return review.summary;
  if(status==='pending')return 'Queued for review.';
  if(status==='reviewing')return 'Review is running.';
  if(status==='error')return item.reviewError||'Review failed.';
  if(status==='skipped')return 'Session reviewed (no code changes detected).';
  if(status==='dismissed')return 'Review dismissed.';
  return 'No summary available.';
}

function reviewIssueCount(item){
  var review=item.review||{};
  return Array.isArray(review.issues)?review.issues.length:0;
}

function isCompletedReviewStatus(status){
  return ['reviewed','flagged','error'].indexOf(status)!==-1;
}

function checkReviewNotifications(items){
  if(!items || !items.length)return;
  items.forEach(function(item){
    var sessionId=String(item.sessionId||'');
    var status=item.reviewStatus||'pending';
    if(!sessionId)return;
    if(!isCompletedReviewStatus(status)){
      notifiedReviewSessions.delete(sessionId);
      return;
    }
    if(!reviewsLoaded){
      notifiedReviewSessions.add(sessionId);
      return;
    }
    if(notifiedReviewSessions.has(sessionId))return;
    var workspaceName=item.workspaceName||'Unknown workspace';
    var summary=reviewSummaryText(item);
    var issueCount=reviewIssueCount(item);
    if(status==='error'){
      notify('Review Complete','❌ Review failed: '+workspaceName,'review-'+sessionId);
    } else if(status==='reviewed' && issueCount===0){
      notify('Review Complete','✅ Review: '+workspaceName+' — '+summary+'. Ready for PR.','review-'+sessionId);
    } else if(issueCount>0){
      notify('Review Complete','⚠️ Review: '+workspaceName+' — '+summary+'. '+issueCount+' issues found.','review-'+sessionId);
    } else {
      notify('Review Complete','⚠️ Review: '+workspaceName+' — '+summary+'. Needs attention.','review-'+sessionId);
    }
    notifiedReviewSessions.add(sessionId);
  });
}

// ─── Notification helpers ───
function playNotifSound() {
  try {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    var osc = audioCtx.createOscillator();
    var gain = audioCtx.createGain();
    osc.connect(gain);
    gain.connect(audioCtx.destination);
    osc.frequency.setValueAtTime(523, audioCtx.currentTime);
    osc.frequency.setValueAtTime(659, audioCtx.currentTime + 0.1);
    gain.gain.setValueAtTime(0.3, audioCtx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + 0.3);
    osc.start(audioCtx.currentTime);
    osc.stop(audioCtx.currentTime + 0.3);
  } catch(e) {}
}

function notify(title, body, tag) {
  if (!notificationsEnabled) return;
  if ('Notification' in window && Notification.permission === 'granted') {
    try {
      var n = new Notification(title, {body: body, tag: tag});
      setTimeout(function() { n.close(); }, 8000);
    } catch(e) {}
  }
  playNotifSound();
}

function updatePageTitle() {
  var waitingCount = 0;
  state.workspaces.forEach(function(w) {
    if (classifyWs(w) === 'waiting') waitingCount++;
  });
  var unreadCount = getUnreadReviewCount();
  var badgeCount = currentView==='reviews' ? unreadCount : waitingCount;
  var baseTitle = currentView==='reviews' ? 'cmux harness \u2014 Reviews' : 'cmux harness \u2014 Command Center';
  document.title = badgeCount > 0 ? '(' + badgeCount + ') ' + baseTitle : baseTitle;
}

function checkNotifications(newWorkspaces) {
  if (!notificationsEnabled) return;
  newWorkspaces.forEach(function(w) {
    var idx = w.index;
    var newStatus = classifyWs(w);
    var newHasClaude = w.hasClaude;
    var prev = prevWsStates[idx];
    if (prev !== undefined) {
      // Workspace transitioned TO waiting
      if (prev.status !== 'waiting' && newStatus === 'waiting') {
        var wsName = w.customName || w.name;
        notify('\u26A0\uFE0F Needs Your Attention', wsName + ' is waiting for input.', 'ws-waiting-' + idx);
      }
      // Claude Code session completed: hasClaude went true → false
      if (prev.hasClaude && !newHasClaude) {
        var wsName = w.customName || w.name;
        notify('\u2705 Session Complete', wsName + ' — Claude Code has finished.', 'ws-done-' + idx);
      }
    }
    prevWsStates[idx] = {hasClaude: newHasClaude, status: newStatus};
  });
}

// ─── Global toggle ───
window.toggleGlobal=function(){
  state.enabled=!state.enabled;
  api('POST','/api/toggle',{enabled:state.enabled});
  updateGlobalToggle();
};
function updateGlobalToggle(){
  var t=document.getElementById('globalTrack');
  var l=document.getElementById('globalLabel');
  if(state.enabled){t.classList.add('on');l.textContent='ON';l.style.color='var(--green)'}
  else{t.classList.remove('on');l.textContent='OFF';l.style.color='var(--red)'}
}

function updateOllamaStatus(){
  var avail=state.ollamaAvailable;
  // Top bar LLM indicator
  var statLlm=document.getElementById('statLlm');
  if(statLlm)statLlm.style.display=(avail===false)?'':'none';
  // Settings modal indicator
  var dot=document.getElementById('ollamaDot');
  var txt=document.getElementById('ollamaStatusText');
  if(!dot||!txt)return;
  if(avail===true){
    dot.className='ollama-dot green';txt.textContent='Connected';
  } else if(avail===false){
    dot.className='ollama-dot red';txt.textContent='Unavailable';
  } else {
    dot.className='ollama-dot gray';txt.textContent='Unknown';
  }
}

window.switchView=function(view){
  currentView=view==='reviews'?'reviews':'center';
  document.getElementById('grid').style.display=currentView==='center'?'grid':'none';
  document.getElementById('reviewsContainer').style.display=currentView==='reviews'?'block':'none';
  ['center','reviews'].forEach(function(name){
    var btn=document.getElementById('viewBtn-'+name);
    if(btn)btn.classList.toggle('active',currentView===name);
  });
  updatePageTitle();
  if(currentView==='reviews'){
    refreshReviews();
    if(reviewsRefreshTimer===null){
      reviewsRefreshTimer=setInterval(function(){
        if(currentView==='reviews')refreshReviews();
      },5000);
    }
  } else if(reviewsRefreshTimer!==null){
    clearInterval(reviewsRefreshTimer);
    reviewsRefreshTimer=null;
  }
};

window.setReviewFilter=function(key,value){
  reviewFilters[key]=value;
  buildReviews();
};

function filterReviews(items){
  var now=Date.now();
  return items.filter(function(item){
    var meta=reviewStatusMeta(item);
    if(reviewFilters.status!=='all' && meta.key!==reviewFilters.status)return false;
    if(reviewFilters.time!=='all'){
      var ts=parseIso(item.completedAt||item.reviewedAt);
      if(!ts)return false;
      var age=now-ts.getTime();
      if(reviewFilters.time==='today'){
        var start=new Date();
        start.setHours(0,0,0,0);
        if(ts.getTime()<start.getTime())return false;
      } else if(reviewFilters.time==='24h' && age>24*60*60*1000)return false;
      else if(reviewFilters.time==='7d' && age>7*24*60*60*1000)return false;
    }
    return true;
  }).sort(function(a,b){
    if(reviewFilters.sort==='oldest')return (parseIso(a.completedAt)||0)-(parseIso(b.completedAt)||0);
    if(reviewFilters.sort==='files')return reviewFilesChanged(b)-reviewFilesChanged(a);
    if(reviewFilters.sort==='cost')return reviewCostValue(b.finalCost)-reviewCostValue(a.finalCost);
    return (parseIso(b.completedAt)||0)-(parseIso(a.completedAt)||0);
  });
}

function buildIssueList(items, sessionId){
  if(!items || !items.length)return '';
  var sid=String(sessionId||'');
  var visible=items.slice(0,3);
  var extra=items.slice(3);
  var html='<ul class="review-issues">';
  visible.forEach(function(issue){html+='<li>'+esc(issue)+'</li>';});
  html+='</ul>';
  if(extra.length){
    html+='<ul class="review-issues" id="review-more-'+esc(sid)+'" style="display:none">';
    extra.forEach(function(issue){html+='<li>'+esc(issue)+'</li>';});
    html+='</ul>';
    html+='<button class="review-more" onclick="toggleReviewIssues(\''+esc(sid)+'\')">Show '+extra.length+' more</button>';
  }
  return html;
}

window.toggleReviewIssues=function(sessionId){
  var wrap=document.getElementById('review-more-'+sessionId);
  if(!wrap)return;
  var btn=wrap.nextElementSibling;
  var open=wrap.style.display!=='none';
  wrap.style.display=open?'none':'block';
  if(btn&&btn.tagName==='BUTTON'){
    var extraCount=wrap.querySelectorAll('li').length;
    btn.textContent=open?'Show '+extraCount+' more':'Show less';
  }
};

function buildReviewCard(item){
  var sessionId=String(item.sessionId||'');
  var meta=reviewStatusMeta(item);
  var review=item.review||{};
  var issues=Array.isArray(review.issues)?review.issues:[];
  var highlights=Array.isArray(review.highlights)?review.highlights:[];
  var filesChanged=reviewFilesChanged(item);
  var summary=reviewSummaryText(item);
  var cardClass='review-card '+(meta.card||'');
  var cost=item.finalCost?'<span class="review-cost" style="color:'+costColor(item.finalCost)+'">'+esc(item.finalCost)+'</span>':'';
  var lines='+'+String(review.linesAdded||0)+' / -'+String(review.linesRemoved||0);
  var branch=item.branch||'—';
  var duration=formatReviewDuration(item.reviewDuration || item.duration);
  var highlightHtml='';
  if(highlights.length){
    highlightHtml='<ul class="review-highlights">';
    highlights.forEach(function(h){highlightHtml+='<li>'+esc(h)+'</li>';});
    highlightHtml+='</ul>';
  }
  return ''+
    '<div class="'+cardClass+'" id="review-card-'+esc(item.sessionId)+'">'+
      '<div class="review-header">'+
        '<div class="review-head-main">'+
          '<div class="review-dot '+meta.dot+'"></div>'+
          '<div class="review-title">'+esc(item.workspaceName||'Unknown workspace')+'</div>'+
        '</div>'+
        '<div class="review-meta-right">'+
          '<span>'+esc(formatReviewTimestamp(item.completedAt||item.reviewedAt))+'</span>'+
          cost+
        '</div>'+
      '</div>'+
      '<div class="review-summary">'+esc(summary)+'</div>'+
      (review.whatHappened?'<div class="review-what-happened">'+esc(review.whatHappened)+'</div>':'')+
      '<div class="review-stats">'+
        '<span>📁 '+filesChanged+' files changed</span>'+
        '<span>'+esc(lines)+'</span>'+
        '<span>🌿 '+esc(branch)+'</span>'+
        '<span>⏱ '+esc(duration)+'</span>'+
      '</div>'+
      '<div class="review-status-row">'+
        '<span class="review-status-badge '+meta.key+'">'+meta.icon+' '+esc(meta.label)+'</span>'+
      '</div>'+
      (issues.length?buildIssueList(issues,sessionId):'')+
      (review.nextSteps?'<blockquote class="review-next-steps">⏭ <strong>Next:</strong> '+esc(review.nextSteps)+'</blockquote>':'')+
      (review.recommendation?'<blockquote class="review-recommendation">'+esc(review.recommendation)+'</blockquote>':'')+
      highlightHtml+
      '<div class="review-actions">'+
        '<button class="review-action-btn" onclick="openReviewOverlay(\''+esc(sessionId)+'\',\'diff\')">View Diff</button>'+
        '<button class="review-action-btn" onclick="openReviewOverlay(\''+esc(sessionId)+'\',\'terminal\')">View Terminal</button>'+
        '<button class="review-action-btn" onclick="rerunReview(\''+esc(sessionId)+'\')">Rerun Review &#9662;</button>'+
        '<button class="review-action-btn danger" onclick="dismissReview(\''+esc(sessionId)+'\')">Dismiss</button>'+
      '</div>'+
    '</div>';
}

function buildReviews(){
  var list=document.getElementById('reviewsList');
  var countEl=document.getElementById('reviewsCount');
  if(!list || !countEl)return;
  var filtered=filterReviews(reviewsData.slice());
  countEl.textContent=plural(filtered.length,'review');
  if(!filtered.length){
    list.innerHTML='<div class="reviews-empty">No reviews match the current filters.</div>';
    return;
  }
  list.innerHTML=filtered.map(buildReviewCard).join('');
}

function refreshReviews(){
  return api('GET','/api/reviews').then(function(result){
    if(!result)return;
    var nextReviews=result||[];
    checkReviewNotifications(nextReviews);
    reviewsData=nextReviews;
    reviewsLoaded=true;
    updateReviewBadge();
    buildReviews();
    updatePageTitle();
  });
}

window.rerunReview=function(sessionId){
  api('POST','/api/reviews/'+encodeURIComponent(sessionId)+'/rerun',{}).then(function(r){
    if(r&&r.ok)refreshReviews();
  });
};

window.dismissReview=function(sessionId){
  api('POST','/api/reviews/'+encodeURIComponent(sessionId)+'/dismiss',{}).then(function(r){
    if(r&&r.ok)refreshReviews();
  });
};

// ─── Build cards ───
function buildGrid(){
  var grid=document.getElementById('grid');
  var ws=state.workspaces;
  if(!ws||ws.length===0){grid.innerHTML='<div class="grid-empty">No workspaces detected. Is cmux running?</div>';return}

  // Count stats
  var active=0,waiting=0,idle=0;
  ws.forEach(function(w){
    var s=classifyWs(w);
    if(s==='waiting')waiting++;
    else if(s==='active')active++;
    else idle++;
  });
  document.getElementById('statActive').textContent=active;
  document.getElementById('statWaiting').textContent=waiting;
  document.getElementById('statIdle').textContent=idle;

  // Sort: active/waiting first (grouped), idle last. Stable order within groups.
  var sorted=ws.slice().sort(function(a,b){
    var aIdle=classifyWs(a)==='idle'?1:0;
    var bIdle=classifyWs(b)==='idle'?1:0;
    if(aIdle!==bIdle)return aIdle-bIdle;
    // Within the same group, preserve original index order
    return a.index-b.index;
  });

  // Preserve focus: if user is typing in an input, save it
  var activeEl=document.activeElement;
  var focusedInputId=null;
  var focusedValue='';
  var focusedCursor=0;
  if(activeEl&&activeEl.classList&&activeEl.classList.contains('card-input')){
    focusedInputId=activeEl.id;
    focusedValue=activeEl.value;
    focusedCursor=activeEl.selectionStart||0;
  }

  var html='';
  sorted.forEach(function(w){
    var s=classifyWs(w);
    var isWaiting=s==='waiting';
    var isIdle=s==='idle';
    var isStale=state.connected===false;
    var cardClass='card'+(isWaiting?' needs-attention':'')+(isIdle?' card-collapsed':'')+(isStale?' stale':'');
    var statusClass='card-status '+s;
    var badgeClass=isWaiting?'badge badge-waiting':isIdle?'badge badge-idle':'badge badge-active';
    var badgeText=isWaiting?'Needs You':isIdle?'Idle':'Active';
    var autoOn=w.enabled===true;
    var autoClass='auto-toggle'+(autoOn?' on':'');

    html+='<div class="'+cardClass+'" id="card-'+w.index+'">';
    var displayName=w.customName||w.name;
    html+='<div class="card-header">';
    html+='<div class="card-title-row"><div class="'+statusClass+'"></div>';
    html+='<div style="min-width:0">';
    html+='<span class="card-name" onclick="startRename('+w.index+',this)" title="Click to rename">'+esc(displayName)+'</span>';
    if(w.customName)html+='<div class="card-name-original">'+esc(w.name)+'</div>';
    html+='</div>';
    html+='</div>';
    html+='<div class="card-header-right">';
    html+='<span class="'+badgeClass+'">'+badgeText+'</span>';
    html+='<div class="'+autoClass+'" onclick="toggleWsAuto('+w.index+',this)"><span class="auto-toggle-label">Auto</span><div class="toggle-track"></div></div>';
    if(isIdle)html+='<button class="card-expand-caret" onclick="toggleInlineExpand('+w.index+')" title="Show details">&#9660;</button>';
    html+='<button class="expand-btn" onclick="openExpanded('+w.index+')">&#10530;</button>';
    html+='</div></div>';

    html+='<div class="card-meta">';
    html+='<span>\uD83D\uDCC2 '+esc(w.cwd||'—')+'</span>';
    if(w.branch)html+='<span>\uD83C\uDF3F '+esc(w.branch)+'</span>';
    if(w.lastCheck)html+='<span>\u23F1 '+fmtTime(w.lastCheck)+'</span>';
    if(w.hasClaude&&w.sessionCost){var cc=costColor(w.sessionCost);html+='<span>\uD83D\uDCB0 <span style="color:'+cc+';font-family:\'JetBrains Mono\',\'SF Mono\',monospace;font-size:11px">'+esc(w.sessionCost)+'</span></span>';}
    html+='</div>';

    html+='<div class="card-terminal">'+colorize(w.screenTail)+'</div>';

    html+='<div class="card-footer">';
    html+='<input class="card-input" placeholder="Send message..." id="input-'+w.index+'" onkeydown="if(event.key===\'Enter\')sendToWs('+w.index+')">';
    html+='<button class="card-send" onclick="sendToWs('+w.index+')">Send</button>';
    html+='</div></div>';
  });
  // Structural hash: only workspace indices and their status classification
  var structHash=sorted.map(function(w){return w.index+'_'+classifyWs(w)}).join(',');
  var needsRebuild=!window._lastStructHash||window._lastStructHash!==structHash||!grid.children.length;

  if(needsRebuild){
    grid.innerHTML=html;
    window._lastStructHash=structHash;
    // Auto-scroll all terminal previews to bottom
    document.querySelectorAll('.card-terminal').forEach(function(el){el.scrollTop=el.scrollHeight});
    // Restore focus if user was typing
    if(focusedInputId){
      var el=document.getElementById(focusedInputId);
      if(el){el.value=focusedValue;el.focus();el.setSelectionRange(focusedCursor,focusedCursor)}
    }
  } else {
    // Surgical update: terminal content, meta, names, and badge — no DOM destruction
    sorted.forEach(function(w){
      var card=document.getElementById('card-'+w.index);
      if(!card)return;
      // Update workspace name (fixes stale titles when names change between rebuilds)
      var nameEl=card.querySelector('.card-name');
      if(nameEl&&!nameEl.isContentEditable&&nameEl.tagName!=='INPUT'){
        var displayName=w.customName||w.name;
        if(nameEl.textContent!==displayName)nameEl.textContent=displayName;
      }
      // Update original-name subtitle
      var origEl=card.querySelector('.card-name-original');
      if(w.customName){
        if(origEl){
          if(origEl.textContent!==w.name)origEl.textContent=w.name;
        }else{
          // Need to add the original-name element
          var nameWrapper=nameEl?nameEl.parentElement:null;
          if(nameWrapper){
            var newOrig=document.createElement('div');
            newOrig.className='card-name-original';
            newOrig.textContent=w.name;
            nameWrapper.appendChild(newOrig);
          }
        }
      }else if(origEl){
        origEl.remove();
      }
      // Update terminal preview (only if user hasn't scrolled up)
      var term=card.querySelector('.card-terminal');
      if(term){
        var isAtBottom=term.scrollHeight-term.scrollTop-term.clientHeight<30;
        var newContent=colorize(w.screenTail);
        if(term.innerHTML!==newContent){
          term.innerHTML=newContent;
          if(isAtBottom)term.scrollTop=term.scrollHeight;
        }
      }
      // Update meta line
      var meta=card.querySelector('.card-meta');
      if(meta){
        var spans=[];
        spans.push('<span>\uD83D\uDCC2 '+esc(w.cwd||'\u2014')+'</span>');
        if(w.branch)spans.push('<span>\uD83C\uDF3F '+esc(w.branch)+'</span>');
        if(w.lastCheck)spans.push('<span>\u23F1 '+fmtTime(w.lastCheck)+'</span>');
        if(w.hasClaude&&w.sessionCost){var cc=costColor(w.sessionCost);spans.push('<span>\uD83D\uDCB0 <span style="color:'+cc+';font-family:\'JetBrains Mono\',\'SF Mono\',monospace;font-size:11px">'+esc(w.sessionCost)+'</span></span>');}
        var newMeta=spans.join('');
        if(meta.innerHTML!==newMeta)meta.innerHTML=newMeta;
      }
    });
  }
  // Restore inline-expanded state for idle cards
  Object.keys(inlineExpanded).forEach(function(idx){
    var card=document.getElementById('card-'+idx);
    if(card&&card.classList.contains('card-collapsed'))card.classList.add('expanded-inline');
  });
}

function classifyWs(w){
  // Check if any recent log entry flagged this workspace as needs_human
  var recent=logData.filter(function(e){return e.workspace===w.index});
  if(recent.length>0){
    var last=recent[0]; // logData is already reversed (newest first)
    if(last.action&&last.action.indexOf('human')!==-1)return 'waiting';
  }
  // Active = Claude Code is running in this terminal
  // Idle = just a regular shell prompt, no Claude session
  return w.hasClaude ? 'active' : 'idle';
}

// ─── Inline expand for collapsed idle cards ───
var inlineExpanded={};
window.toggleInlineExpand=function(idx){
  var card=document.getElementById('card-'+idx);
  if(!card)return;
  if(inlineExpanded[idx]){
    card.classList.remove('expanded-inline');
    delete inlineExpanded[idx];
  }else{
    card.classList.add('expanded-inline');
    inlineExpanded[idx]=true;
    // scroll terminal to bottom
    var term=card.querySelector('.card-terminal');
    if(term)term.scrollTop=term.scrollHeight;
  }
};

// ─── Per-workspace auto toggle ───
window.toggleWsAuto=function(idx,el){
  el.classList.toggle('on');
  var on=el.classList.contains('on');
  api('POST','/api/workspace',{index:idx,enabled:on});
};

// ─── Send to workspace ───
window.sendToWs=function(idx){
  var inp=document.getElementById('input-'+idx);
  if(!inp||!inp.value.trim())return;
  var text=inp.value.trim()+'\n';
  api('POST','/api/send',{index:idx,text:text});
  inp.value='';
};

// ─── Expanded view ───
window.openExpanded=function(idx){
  expandedMode='workspace';
  expandedWsIndex=idx;
  expandedReview=null;
  document.getElementById('overlay').classList.add('visible');
  document.getElementById('escHint').style.display='block';
  document.body.style.overflow='hidden';
  updateExpanded();
};
window.closeExpanded=function(){
  expandedWsIndex=null;
  expandedReview=null;
  expandedMode='workspace';
  document.getElementById('overlay').classList.remove('visible');
  document.getElementById('escHint').style.display='none';
  document.body.style.overflow='';
};
window.toggleExpAuto=function(){
  if(expandedWsIndex===null)return;
  var el=document.getElementById('expAutoToggle');
  el.classList.toggle('on');
  var on=el.classList.contains('on');
  api('POST','/api/workspace',{index:expandedWsIndex,enabled:on});
};
window.sendExp=function(){
  if(expandedWsIndex===null)return;
  var inp=document.getElementById('expInput');
  if(!inp.value.trim())return;
  api('POST','/api/send',{index:expandedWsIndex,text:inp.value.trim()+'\n'});
  inp.value='';
};
window.setMode=function(btn){
  btn.parentElement.querySelectorAll('.mode-btn').forEach(function(b){b.classList.remove('active')});
  btn.classList.add('active');
};

function updateExpanded(){
  if(expandedMode==='review'){
    updateExpandedReview();
    return;
  }
  if(expandedWsIndex===null)return;
  document.getElementById('expReviewTabs').classList.remove('visible');
  document.getElementById('expTerminal').classList.remove('activity-list');
  var ws=state.workspaces.find(function(w){return w.index===expandedWsIndex});
  if(!ws)return;
  document.querySelector('.exp-header-actions').classList.remove('hidden');
  document.querySelector('.exp-input').classList.remove('hidden');
  var expDisplayName=ws.customName||ws.name;
  document.getElementById('expTitle').textContent=expDisplayName;
  var origNameEl=document.getElementById('expOrigName');
  if(ws.customName){
    if(!origNameEl){
      origNameEl=document.createElement('div');
      origNameEl.id='expOrigName';
      origNameEl.style.cssText='font-size:12px;color:var(--text-muted);margin-top:2px';
      document.getElementById('expTitle').insertAdjacentElement('afterend',origNameEl);
    }
    origNameEl.textContent=ws.name;
  } else if(origNameEl){
    origNameEl.remove();
  }
  var meta='';
  if(ws.cwd)meta+='\uD83D\uDCC2 '+esc(ws.cwd)+'  ';
  if(ws.branch)meta+='\uD83C\uDF3F '+esc(ws.branch)+'  ';
  if(ws.lastCheck)meta+='\u23F1 '+fmtTime(ws.lastCheck)+'  ';
  if(ws.hasClaude&&ws.sessionCost){var cc=costColor(ws.sessionCost);meta+='\uD83D\uDCB0 <span style="color:'+cc+';font-family:\'JetBrains Mono\',\'SF Mono\',monospace;font-size:12px">'+esc(ws.sessionCost)+'</span>  ';}
  document.getElementById('expMeta').innerHTML=meta;

  var autoEl=document.getElementById('expAutoToggle');
  if(ws.enabled!==false)autoEl.classList.add('on');
  else autoEl.classList.remove('on');

  document.getElementById('expTerminal').innerHTML=colorize(ws.screenFull||ws.screenTail);

  // Activity feed for this workspace
  var wsLog=logData.filter(function(e){return e.workspace===expandedWsIndex});
  var listEl=document.getElementById('expActList');
  document.getElementById('expActCount').textContent=wsLog.length+' events';
  if(wsLog.length===0){
    listEl.innerHTML='<div style="padding:40px 18px;text-align:center;color:var(--text-muted);font-size:13px">No activity yet for this workspace.</div>';
    return;
  }
  var h='';
  wsLog.forEach(function(e){
    var isHuman=e.action&&e.action.indexOf('human')!==-1;
    var typeClass=isHuman?'flagged':'approved';
    var typeText=isHuman?'\u26A0 FLAGGED':'\u2713 AUTO';
    h+='<div class="act-item"><div class="act-time">'+fmtTime(e.timestamp)+'</div>';
    h+='<div class="act-text"><span class="act-type '+typeClass+'">'+typeText+'</span> '+esc(e.promptType||'')+'</div>';
    h+='</div>';
  });
  listEl.innerHTML=h;
}

function buildReviewActivityHtml(item){
  var review=item.review||{};
  var issues=Array.isArray(review.issues)?review.issues:[];
  var highlights=Array.isArray(review.highlights)?review.highlights:[];
  var html='<div class="act-item"><div class="act-time">'+esc(formatReviewTimestamp(item.completedAt||item.reviewedAt))+'</div><div class="act-text">'+esc(reviewSummaryText(item))+'</div></div>';
  if(issues.length){
    html+='<div class="act-item"><div class="act-time">Issues</div><div class="act-text">'+issues.map(function(issue){return '• '+esc(issue);}).join('<br>')+'</div></div>';
  }
  if(review.recommendation){
    html+='<div class="act-item"><div class="act-time">Recommendation</div><div class="act-text">'+esc(review.recommendation)+'</div></div>';
  }
  if(highlights.length){
    html+='<div class="act-item"><div class="act-time">Highlights</div><div class="act-text">'+highlights.map(function(h){return '• '+esc(h);}).join('<br>')+'</div></div>';
  }
  return html;
}

function buildApprovalLogHtml(item){
  var entries=Array.isArray(item.approvalLog)?item.approvalLog:[];
  if(!entries.length){
    return '<div style="padding:40px 18px;text-align:center;color:var(--text-muted);font-size:13px">No approval log entries captured for this review.</div>';
  }
  return entries.map(function(entry){
    var action=String(entry.action||'');
    var isFlagged=/needs human|flagged/i.test(action);
    var typeClass=isFlagged?'flagged':'approved';
    var typeText=isFlagged?'FLAGGED':'AUTO';
    var detail=[
      esc(entry.promptType||'Unknown prompt'),
      esc(action||'No action'),
      isFlagged?'Flagged for review':'Auto-approved'
    ].join(' • ');
    return '<div class="act-item"><div class="act-time">'+esc(formatReviewTimestamp(entry.timestamp)||entry.timestamp||'—')+'</div><div class="act-text"><span class="act-type '+typeClass+'">'+typeText+'</span> '+detail+'</div></div>';
  }).join('');
}

function updateReviewOverlayTabs(activeTab){
  ['diff','terminal','approval'].forEach(function(tab){
    var btn=document.getElementById('expTab-'+tab);
    if(btn)btn.classList.toggle('active',activeTab===tab);
  });
}

function updateExpandedReview(){
  if(!expandedReview)return;
  document.querySelector('.exp-header-actions').classList.add('hidden');
  document.querySelector('.exp-input').classList.add('hidden');
  document.getElementById('expReviewTabs').classList.add('visible');
  document.getElementById('expTitle').textContent=expandedReview.workspaceName||'Review';
  var origNameEl=document.getElementById('expOrigName');
  if(origNameEl)origNameEl.remove();
  var review=expandedReview.review||{};
  var meta='';
  meta+='<span>🌿 '+esc(expandedReview.branch||'—')+'</span>';
  meta+='<span>📁 '+reviewFilesChanged(expandedReview)+' files changed</span>';
  meta+='<span>+'+esc(String(review.linesAdded||0))+' / -'+esc(String(review.linesRemoved||0))+'</span>';
  document.getElementById('expMeta').innerHTML=meta;
  var tab=expandedReview._overlayTab||'diff';
  var terminalEl=document.getElementById('expTerminal');
  terminalEl.classList.toggle('activity-list',tab==='approval');
  terminalEl.innerHTML=tab==='terminal'
    ? colorize(expandedReview.terminalSnapshot||'')
    : tab==='approval'
      ? buildApprovalLogHtml(expandedReview)
      : diffColorize(expandedReview.gitDiff||'');
  updateReviewOverlayTabs(tab);
  document.getElementById('expActCount').textContent='review';
  document.getElementById('expActList').innerHTML=buildReviewActivityHtml(expandedReview);
}

window.switchReviewOverlayTab=function(tab){
  if(expandedMode!=='review' || !expandedReview)return;
  expandedReview._overlayTab=tab||'diff';
  updateExpandedReview();
};

window.openReviewOverlay=function(sessionId,tab){
  api('GET','/api/reviews/'+encodeURIComponent(sessionId)).then(function(review){
    if(!review)return;
    expandedMode='review';
    expandedWsIndex=null;
    expandedReview=review;
    expandedReview._overlayTab=tab||'diff';
    document.getElementById('overlay').classList.add('visible');
    document.getElementById('escHint').style.display='block';
    document.body.style.overflow='hidden';
    updateExpandedReview();
  });
};

// ─── Settings ───
window.toggleNotifications=function(el){
  el.classList.toggle('on');
  notificationsEnabled = el.classList.contains('on');
  el.querySelector('.auto-toggle-label').textContent = notificationsEnabled ? 'On' : 'Off';
};

function setToggleState(el,on){
  if(!el)return;
  el.classList.toggle('on',!!on);
  var label=el.querySelector('.auto-toggle-label');
  if(label)label.textContent=on?'On':'Off';
}

function updateReviewEnabledUI(){
  setToggleState(document.getElementById('settingsReviewEnabled'),state.reviewEnabled);
  setToggleState(document.getElementById('settingsReviewAuto'),state.reviewEnabled);
}

function backendMeta(){
  return {
    claude:{label:'Claude (Sonnet 4)'},
    lmstudio:{label:'LM Studio (27B)'},
    ollama:{label:'Ollama (local)'}
  };
}

function backendOptionLabel(key,available){
  var meta=backendMeta()[key];
  var dot=available===true?'🟢':available===false?'🔴':'⚪';
  return dot+' '+meta.label;
}

function updateBackendAvailabilityUI(){
  ['claude','lmstudio','ollama'].forEach(function(key){
    var dot=document.getElementById('backendDot-'+key);
    if(!dot)return;
    var avail=state.backendAvailability[key];
    dot.className='backend-status-dot'+(avail===true?' green':avail===false?' red':'');
  });
  var select=document.getElementById('settingsReviewBackend');
  if(!select)return;
  Array.prototype.forEach.call(select.options,function(opt){
    opt.textContent=backendOptionLabel(opt.value,state.backendAvailability[opt.value]);
  });
  select.value=state.reviewBackend||'claude';
}

function updateReviewModelSelect(models){
  var sel=document.getElementById('settingsReviewModel');
  if(!sel)return;
  var list=Array.isArray(models)?models:[];
  sel.innerHTML='';
  if(!list.length){
    var empty=document.createElement('option');
    empty.value='';
    empty.textContent=state.backendAvailability.ollama===false?'Ollama unavailable':'No models found';
    sel.appendChild(empty);
    return;
  }
  list.forEach(function(model){
    var opt=document.createElement('option');
    opt.value=model;
    opt.textContent=model;
    if(model===state.reviewModel)opt.selected=true;
    sel.appendChild(opt);
  });
  if(state.reviewModel && list.indexOf(state.reviewModel)===-1){
    var custom=document.createElement('option');
    custom.value=state.reviewModel;
    custom.textContent=state.reviewModel+' (configured)';
    custom.selected=true;
    sel.appendChild(custom);
  } else if(!state.reviewModel && list.length){
    sel.value=list[0];
  }
}

function updateReviewSettingsVisibility(){
  var row=document.getElementById('settingsReviewModelRow');
  if(row)row.style.display=state.reviewBackend==='ollama'?'flex':'none';
}

function saveConfig(body){
  return api('POST','/api/config',body).then(function(result){
    if(!result)return result;
    state.pollInterval=result.pollInterval!==undefined?result.pollInterval:state.pollInterval;
    state.model=result.model||state.model;
    state.reviewEnabled=result.reviewEnabled!==undefined?!!result.reviewEnabled:state.reviewEnabled;
    state.reviewModel=result.reviewModel||state.reviewModel;
    state.reviewBackend=result.reviewBackend||state.reviewBackend;
    updateReviewEnabledUI();
    updateBackendAvailabilityUI();
    updateReviewSettingsVisibility();
    return result;
  });
}

function loadSettingsData(){
  return Promise.all([api('GET','/api/status'),api('GET','/api/models')]).then(function(results){
    var status=results[0]||{};
    var models=results[1]||{};
    var llmModels=models.models||[];
    state.pollInterval=status.pollInterval!==undefined?status.pollInterval:state.pollInterval;
    state.model=status.model||state.model;
    state.reviewEnabled=status.reviewEnabled!==undefined?!!status.reviewEnabled:state.reviewEnabled;
    state.reviewModel=status.reviewModel||state.reviewModel;
    state.reviewBackend=status.reviewBackend||state.reviewBackend;
    state.ollamaAvailable=models.available!==undefined?models.available:state.ollamaAvailable;
    state.backendAvailability={
      claude:models.claudeAvailable!==undefined?models.claudeAvailable:state.backendAvailability.claude,
      lmstudio:models.lmstudioAvailable!==undefined?models.lmstudioAvailable:state.backendAvailability.lmstudio,
      ollama:models.available!==undefined?models.available:state.backendAvailability.ollama
    };
    document.getElementById('settingsPoll').value=String(state.pollInterval);
    var llmSelect=document.getElementById('settingsModel');
    llmSelect.innerHTML='';
    if(!llmModels.length){
      llmSelect.innerHTML='<option>'+(models.available===false?'Ollama unavailable':'No models found')+'</option>';
    } else {
      llmModels.forEach(function(model){
        var opt=document.createElement('option');
        opt.value=model;
        opt.textContent=model;
        if(model===state.model)opt.selected=true;
        llmSelect.appendChild(opt);
      });
    }
    updateOllamaStatus();
    updateReviewEnabledUI();
    updateBackendAvailabilityUI();
    updateReviewModelSelect(llmModels);
    updateReviewSettingsVisibility();
  });
}

window.toggleReviewEnabled=function(){
  state.reviewEnabled=!state.reviewEnabled;
  updateReviewEnabledUI();
  saveConfig({reviewEnabled:state.reviewEnabled});
};

window.changeReviewBackend=function(value){
  state.reviewBackend=value||'claude';
  updateBackendAvailabilityUI();
  updateReviewSettingsVisibility();
  saveConfig({reviewBackend:state.reviewBackend});
};

window.saveReviewSetting=function(key,val){
  var body={};
  body[key]=val;
  if(key==='reviewModel')state.reviewModel=val;
  return saveConfig(body);
};

window.openSettings=function(){
  document.getElementById('settingsOverlay').classList.add('visible');
  document.getElementById('settingsCwd').value=defaultCwd;
  var notifEl=document.getElementById('settingsNotif');
  if(notificationsEnabled){notifEl.classList.add('on');notifEl.querySelector('.auto-toggle-label').textContent='On';}
  else{notifEl.classList.remove('on');notifEl.querySelector('.auto-toggle-label').textContent='Off';}
  updateOllamaStatus();
  loadSettingsData();
};
window.closeSettings=function(){
  document.getElementById('settingsOverlay').classList.remove('visible');
};
window.saveSetting=function(key,val){
  var body={};body[key]=val;
  if(key==='model')state.model=val;
  if(key==='pollInterval')state.pollInterval=val;
  saveConfig(body);
};

// ─── New session ───
var defaultCwd='~/Documents/Development/Doximity-Cloud';
window.newSession=function(){
  var btn=document.querySelector('.btn-primary');
  if(btn){btn.textContent='Creating...';btn.disabled=true;}
  api('POST','/api/new-session',{cwd:defaultCwd,command:'claude'}).then(function(r){
    if(btn){btn.textContent='+ New Session';btn.disabled=false;}
    if(!r||!r.ok){
      console.error('New session failed:',r&&r.error);
      return;
    }
    // New workspace will appear on next refresh cycle — nothing else needed
  }).catch(function(){
    if(btn){btn.textContent='+ New Session';btn.disabled=false;}
  });
};

// ─── Inline rename ───
window.startRename=function(idx,spanEl){
  // Prevent click propagation to expand-btn etc.
  var currentName=spanEl.textContent;
  var inp=document.createElement('input');
  inp.className='card-name-edit';
  inp.value=currentName;
  spanEl.replaceWith(inp);
  inp.focus();
  inp.select();

  var committed=false;
  function commit(){
    if(committed)return;
    committed=true;
    var newName=inp.value.trim();
    var newSpan=document.createElement('span');
    newSpan.className='card-name';
    newSpan.setAttribute('title','Click to rename');
    newSpan.onclick=function(){startRename(idx,newSpan)};
    if(!newName||newName===currentName){
      newSpan.textContent=currentName;
      inp.replaceWith(newSpan);
      return;
    }
    newSpan.textContent=newName;
    inp.replaceWith(newSpan);
    api('POST','/api/rename',{index:idx,name:newName}).then(function(r){
      if(!r||!r.ok){newSpan.textContent=currentName}
    });
  }
  function cancel(){
    if(committed)return;
    committed=true;
    var newSpan=document.createElement('span');
    newSpan.className='card-name';
    newSpan.setAttribute('title','Click to rename');
    newSpan.onclick=function(){startRename(idx,newSpan)};
    newSpan.textContent=currentName;
    inp.replaceWith(newSpan);
  }
  inp.addEventListener('blur',commit);
  inp.addEventListener('keydown',function(e){
    if(e.key==='Enter'){e.preventDefault();inp.removeEventListener('blur',commit);commit()}
    else if(e.key==='Escape'){e.preventDefault();inp.removeEventListener('blur',commit);cancel()}
  });
};

// ─── Global Activity Feed ───
var _lastActivityCount = -1;
window.toggleActivityPanel = function(){
  document.getElementById('activityPanel').classList.toggle('collapsed');
};
function updateActivityFeed(entries){
  var panel = document.getElementById('activityPanel');
  var bodyEl = document.getElementById('activityBody');
  var countEl = document.getElementById('activityCount');
  var isCollapsed = panel.classList.contains('collapsed');
  var newCount = entries ? entries.length : 0;
  // Skip rebuild if collapsed and count hasn't changed
  if(isCollapsed && newCount === _lastActivityCount) return;
  _lastActivityCount = newCount;
  countEl.textContent = newCount;
  if(isCollapsed) return;
  var last50 = entries ? entries.slice(0, 50) : [];
  if(last50.length === 0){
    bodyEl.innerHTML = '<div style="padding:20px 0;text-align:center;color:var(--text-muted);font-size:12px">No activity yet.</div>';
    return;
  }
  var h = '';
  last50.forEach(function(e){
    var isHuman = e.action && e.action.indexOf('human') !== -1;
    var typeClass = isHuman ? 'flagged' : 'approved';
    var typeText = isHuman ? 'FLAGGED' : 'APPROVED';
    // Resolve workspace name from state
    var wsName = '';
    if(e.workspace !== undefined){
      var ws = state.workspaces.find(function(w){ return w.index === e.workspace; });
      wsName = ws ? (ws.customName || ws.name || ('ws-' + e.workspace)) : ('ws-' + e.workspace);
    }
    h += '<div class="activity-entry">';
    h += '<span class="ae-time">' + fmtTime(e.timestamp) + '</span>';
    h += '<span class="ae-ws">' + esc(wsName) + '</span>';
    h += '<span class="ae-type ' + typeClass + '">' + typeText + '</span>';
    h += '<span class="ae-prompt">' + esc(e.promptType || '') + '</span>';
    h += '</div>';
  });
  bodyEl.innerHTML = h;
}

// ─── Keyboard ───
document.addEventListener('keydown',function(e){
  if(e.key==='Escape'){
    if(document.getElementById('settingsOverlay').classList.contains('visible'))closeSettings();
    else closeExpanded();
  }
});

// ─── Refresh loop ───
function refresh(){
  if(Date.now()-lastGlobalReviewsRefresh>5000){
    lastGlobalReviewsRefresh=Date.now();
    refreshReviews();
  }
  Promise.all([api('GET','/api/status'),api('GET','/api/log')]).then(function(results){
    var status=results[0];
    var log=results[1];
    if(!status){document.getElementById('connDot').className='conn-dot err';return}
    // Connection state handling
    var wasConnected = state.connected;
    state.connected = status.connected;
    if(status.connected){
      document.getElementById('connDot').className='conn-dot ok';
      document.getElementById('connStatus').textContent='';
      document.getElementById('staleBanner').style.display='none';
    } else if(status.socketFound){
      document.getElementById('connDot').className='conn-dot warn';
      var lostAgo=status.connectionLostAt?Math.round((Date.now()/1000-status.connectionLostAt)/60):0;
      document.getElementById('connStatus').textContent='Reconnecting'+(lostAgo>0?' \u00B7 lost '+lostAgo+'m ago':'...');
      document.getElementById('staleBanner').style.display='flex';
    } else {
      document.getElementById('connDot').className='conn-dot err';
      document.getElementById('connStatus').textContent='No socket';
      document.getElementById('staleBanner').style.display='flex';
    }
    // Clear prevWsStates on reconnection to prevent false triggers
    if(status.connected && !wasConnected && wasConnected!==undefined) prevWsStates={};
    state.enabled=status.enabled;
    state.pollInterval=status.pollInterval;
    state.model=status.model||'';
    state.reviewEnabled=status.reviewEnabled!==undefined?!!status.reviewEnabled:state.reviewEnabled;
    state.reviewModel=status.reviewModel||state.reviewModel;
    state.reviewBackend=status.reviewBackend||state.reviewBackend;
    state.workspaces=status.workspaces||[];
    state.socketFound=status.socketFound;
    state.ollamaAvailable=status.ollamaAvailable!==undefined?status.ollamaAvailable:state.ollamaAvailable;
    logData=log||[];
    updateGlobalToggle();
    updateOllamaStatus();
    checkNotifications(state.workspaces);
    buildGrid();
    updatePageTitle();
    updateActivityFeed(logData);
    if(expandedMode==='workspace' && expandedWsIndex!==null){
      // Don't clobber expanded input if user is typing
      var expFocused=document.activeElement&&document.activeElement.id==='expInput';
      updateExpanded();
      if(expFocused)document.getElementById('expInput').focus();
    }
  });
}
refresh();
refreshReviews();
setInterval(refresh,2000);
// Faster refresh for expanded view (500ms)
setInterval(function(){
  if(expandedMode!=='workspace' || expandedWsIndex===null)return;
  api('GET','/api/status').then(function(r){
    if(!r)return;
    state.workspaces=r.workspaces||[];
    var expFocused=document.activeElement&&document.activeElement.id==='expInput';
    updateExpanded();
    if(expFocused)document.getElementById('expInput').focus();
  });
},500);
})();
</script>
</body>
</html>
"""

# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

_engine = None  # set in __main__


class DashboardHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _json_response(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            return {}

    def do_GET(self):
        if self.path == "/":
            body = DASHBOARD_HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/status":
            self._json_response(_engine.get_status())
        elif self.path == "/api/log":
            self._json_response(_engine.get_log())
        elif self.path == "/api/reviews":
            reviews = []
            for review in _list_reviews():
                item = dict(review)
                item["gitDiff"] = (item.get("gitDiff") or "")[:500]
                reviews.append(item)
            self._json_response(reviews)
        elif self.path.startswith("/api/reviews/"):
            session_id = urllib.parse.unquote(self.path[len("/api/reviews/"):])
            review = _get_review(session_id)
            if review is None:
                self._json_response({"ok": False, "error": "review not found"}, 404)
                return
            self._json_response(review)
        elif self.path == "/api/config":
            with _engine._lock:
                self._json_response({
                    "pollInterval": _engine.poll_interval,
                    "model": _engine.model,
                    "reviewEnabled": _engine.review_enabled,
                    "reviewModel": _engine.review_model,
                    "reviewBackend": _engine.review_backend,
                })
        elif self.path == "/api/models":
            # Use cached availability — if already known unavailable, skip the connect attempt
            with _engine._lock:
                cached = _engine.ollama_available
            lmstudio_available = False
            claude_available = shutil.which("claude") is not None
            try:
                with urllib.request.urlopen("http://100.89.93.84:1234/v1/models", timeout=3) as r:
                    json.loads(r.read())
                lmstudio_available = True
            except Exception:
                lmstudio_available = False
            if cached is False:
                self._json_response({
                    "models": [],
                    "available": False,
                    "lmstudioAvailable": lmstudio_available,
                    "claudeAvailable": claude_available,
                })
            else:
                try:
                    import urllib.request as _ur
                    with _ur.urlopen(f"{OLLAMA_URL}/api/tags", timeout=4) as r:
                        data = json.loads(r.read())
                    names = [m["name"] for m in data.get("models", [])]
                    with _engine._lock:
                        _engine.ollama_available = True
                        _engine.ollama_last_check = time.time()
                    self._json_response({
                        "models": names,
                        "available": True,
                        "lmstudioAvailable": lmstudio_available,
                        "claudeAvailable": claude_available,
                    })
                except Exception as e:
                    with _engine._lock:
                        _engine.ollama_available = False
                        _engine.ollama_last_check = time.time()
                    self._json_response({
                        "models": [],
                        "available": False,
                        "lmstudioAvailable": lmstudio_available,
                        "claudeAvailable": claude_available,
                        "error": str(e),
                    })
        else:
            self.send_error(404)

    def do_POST(self):
        data = self._read_body()
        if self.path == "/api/toggle":
            _engine.set_enabled(data.get("enabled", False))
            self._json_response({"ok": True, "enabled": _engine.enabled})
        elif self.path == "/api/workspace":
            idx = data.get("index")
            enabled = data.get("enabled", True)
            if idx is not None:
                _engine.set_workspace_enabled(int(idx), enabled)
            self._json_response({"ok": True})
        elif self.path == "/api/config":
            pi = data.get("pollInterval")
            if pi is not None:
                _engine.set_poll_interval(pi)
            model = data.get("model")
            if model is not None:
                _engine.set_model(model)
            review_enabled = data.get("reviewEnabled")
            review_model = data.get("reviewModel")
            review_backend = data.get("reviewBackend")
            if review_enabled is not None or review_model is not None or review_backend is not None:
                _engine.set_review_config(
                    enabled=review_enabled,
                    model=review_model,
                    backend=review_backend,
                )
            with _engine._lock:
                self._json_response({
                    "ok": True,
                    "pollInterval": _engine.poll_interval,
                    "model": _engine.model,
                    "reviewEnabled": _engine.review_enabled,
                    "reviewModel": _engine.review_model,
                    "reviewBackend": _engine.review_backend,
                })
        elif self.path == "/api/rename":
            idx = data.get("index")
            name = data.get("name", "")
            if idx is None:
                self._json_response({"ok": False, "error": "index required"}, 400)
                return
            ok = _engine.set_custom_name(int(idx), name)
            if not ok:
                self._json_response({"ok": False, "error": "workspace not found"}, 404)
                return
            self._json_response({"ok": True})
        elif self.path == "/api/send":
            idx = data.get("index")
            text = data.get("text", "")
            if idx is None or not text:
                self._json_response({"ok": False, "error": "index and text required"}, 400)
                return
            idx = int(idx)
            with _engine._lock:
                ws_snap = list(_engine.workspaces)
            ws = next((w for w in ws_snap if w.get("index", w.get("id")) == idx), None)
            if ws is None:
                self._json_response({"ok": False, "error": "workspace not found"}, 404)
                return
            ok = cmux_send_to_workspace(idx, 0, text=text, workspace_uuid=ws.get("uuid"))
            self._json_response({"ok": ok})
        elif self.path.startswith("/api/reviews/") and self.path.endswith("/rerun"):
            session_id = urllib.parse.unquote(self.path[len("/api/reviews/"):-len("/rerun")]).rstrip("/")
            path = _get_review_path(session_id)
            if path is None:
                self._json_response({"ok": False, "error": "review not found"}, 404)
                return
            review = _read_review_file(path)
            if review is None:
                self._json_response({"ok": False, "error": "review not found"}, 404)
                return
            model_override = data.get("model")
            backend_override = data.get("backend")
            review["reviewStatus"] = "pending"
            review.pop("reviewedAt", None)
            review.pop("reviewDuration", None)
            review.pop("reviewError", None)
            review.pop("reviewModel", None)
            review.pop("review", None)
            try:
                _engine._write_review_file(path, review)
            except OSError as e:
                self._json_response({"ok": False, "error": str(e)}, 500)
                return
            threading.Thread(
                target=_engine._run_review,
                args=(path, model_override, backend_override),
                daemon=True,
            ).start()
            self._json_response({"ok": True})
        elif self.path.startswith("/api/reviews/") and self.path.endswith("/dismiss"):
            session_id = urllib.parse.unquote(self.path[len("/api/reviews/"):-len("/dismiss")]).rstrip("/")
            path = _get_review_path(session_id)
            if path is None:
                self._json_response({"ok": False, "error": "review not found"}, 404)
                return
            review = _read_review_file(path)
            if review is None:
                self._json_response({"ok": False, "error": "review not found"}, 404)
                return
            review["reviewStatus"] = "dismissed"
            try:
                _engine._write_review_file(path, review)
            except OSError as e:
                self._json_response({"ok": False, "error": str(e)}, 500)
                return
            self._json_response({"ok": True})
        elif self.path == "/api/new-session":
            cwd = data.get("cwd", "~/Documents/Development/Doximity-Cloud")
            command = data.get("command", "claude")

            # Step 1: Create workspace
            create_result = _v2_request("workspace.create", {})
            if create_result is None:
                self._json_response({"ok": False, "error": "Failed to create workspace"})
                return

            # Step 2: Wait for initialization
            time.sleep(0.5)

            # Step 3: Resolve UUID — try create result first, then list
            ws_uuid = None
            ws_idx = None
            if isinstance(create_result, dict):
                ws_uuid = (create_result.get("uuid") or
                           create_result.get("workspace_id") or
                           create_result.get("id"))
                ws_idx = create_result.get("index")

            if not ws_uuid:
                list_result = _v2_request("workspace.list", {})
                if list_result:
                    ws_list = list_result if isinstance(list_result, list) else list_result.get("workspaces", [])
                    if ws_list:
                        newest = ws_list[-1]
                        ws_uuid = newest.get("uuid") or newest.get("id")
                        ws_idx = newest.get("index")

            if not ws_uuid:
                self._json_response({"ok": False, "error": "Failed to get new workspace info"})
                return

            # If index still unknown, refresh engine and look it up
            if ws_idx is None:
                _engine.refresh_workspaces()
                with _engine._lock:
                    for w in _engine.workspaces:
                        if w.get("uuid") == ws_uuid:
                            ws_idx = w.get("index")
                            break

            # Step 4: cd to working directory (best-effort — don't abort on failure)
            try:
                _v2_request("surface.send_text", {
                    "workspace_id": ws_uuid,
                    "text": f"cd {cwd}\n",
                })
            except Exception:
                pass

            # Step 5: Brief pause before launching command
            time.sleep(0.3)

            # Step 6: Launch command (best-effort)
            try:
                _v2_request("surface.send_text", {
                    "workspace_id": ws_uuid,
                    "text": f"{command}\n",
                })
            except Exception:
                pass

            # Step 7: Return workspace info
            self._json_response({"ok": True, "workspace": {"index": ws_idx, "uuid": ws_uuid}})
        else:
            self.send_error(404)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9090

    engine = HarnessEngine()
    _engine = engine
    engine.start()

    print(f"⚡ cmux Auto-Approve Dashboard: http://localhost:{port}")
    webbrowser.open(f"http://localhost:{port}")

    server = HTTPServer(("0.0.0.0", port), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()
