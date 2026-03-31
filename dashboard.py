#!/usr/bin/env python3
"""cmux Auto-Approve Dashboard — single-file harness engine + web UI."""

import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
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
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.5:8b")
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
        with urllib.request.urlopen(req, timeout=5) as resp:
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
    lines = screen_text.splitlines()
    tail = "\n".join(lines[-25:]) if len(lines) > 25 else screen_text

    # SKIP: Claude Code idle REPL (has ❯ but also Model:/Cost: lines)
    if _REPL_IDLE_RE.search(tail):
        return None

    # SKIP: Plain shell prompt with no Claude Code indicators
    last_lines = "\n".join(lines[-5:]) if len(lines) > 5 else screen_text
    if not re.search(r"(Allow |Do you want|proceed|\([Yy](?:/[Nn]|es/no)\)|Enter to select|Esc to cancel|Musing|Thinking|⚡|Model:|Cost:|Ctx:)", last_lines):
        # No prompt indicators at all in the last 5 lines — likely just a shell
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
        self.ollama_available = None   # None=unknown, True=available, False=unavailable
        self.ollama_last_check = 0     # timestamp of last Ollama health check
        self.ollama_retry_interval = 60  # seconds between retries after failure
        self.ws_config = self._load_config()

    def _load_config(self):
        """Read workspace config from JSON file. Returns empty dict if not found or invalid."""
        try:
            with open(CONFIG_FILE, "r") as f:
                data = json.load(f)
            return data.get("workspaces", {})
        except (FileNotFoundError, json.JSONDecodeError, KeyError, OSError):
            return {}

    def _save_config(self):
        """Write current ws_config to the JSON file. Call while holding self._lock."""
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump({"workspaces": self.ws_config}, f, indent=2)
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

    def set_custom_name(self, index, name):
        """Set a custom display name for the workspace at the given index.
        Persists to config keyed by UUID so it survives index shifts."""
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
            with open(path, "w") as f:
                json.dump(review, f, indent=2)
            _debug_log({
                "event": "completion_snapshot_captured",
                "workspace": idx,
                "workspace_uuid": workspace_uuid,
                "session_id": session_id,
                "path": str(path),
            })
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

        with self._lock:
            self.fingerprints[idx] = fp

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

                    for ws in ws_snap:
                        idx = ws.get("index", ws.get("id"))
                        ws_uuid = ws.get("uuid", "")
                        with self._lock:
                            ws_on = self.workspace_enabled.get(idx, True)
                        if not ws_on:
                            continue
                        # Phase 2: Only run auto-approve on workspaces
                        # that have unread notifications.
                        if attention_uuids and ws_uuid not in attention_uuids:
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
.exp-close{width:36px;height:36px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text-muted);font-size:18px;cursor:pointer;display:flex;align-items:center;justify-content:center}
.exp-close:hover{border-color:var(--red);color:var(--red)}
.exp-terminal{flex:1;overflow-y:auto;padding:16px 24px;font-family:'JetBrains Mono','SF Mono',monospace;font-size:13px;line-height:1.8;background:rgba(0,0,0,.15);white-space:pre-wrap;word-break:break-all}
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
.settings-select{background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:8px;padding:8px 12px;font-size:13px;outline:none;min-width:160px}
.settings-select:focus{border-color:var(--accent)}
.ollama-status{display:flex;align-items:center;gap:5px;font-size:12px;color:var(--text-muted);margin-top:4px}
.ollama-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.ollama-dot.green{background:var(--green)}
.ollama-dot.red{background:var(--red)}
.ollama-dot.gray{background:var(--text-muted);opacity:.5}
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
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-left">
    <div class="logo"><span>cmux</span> harness<span class="conn-dot" id="connDot"></span><span class="conn-status" id="connStatus"></span></div>
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
var state = {enabled:false,workspaces:[],model:'',pollInterval:5,socketFound:false,connected:undefined,ollamaAvailable:null};
var logData = [];
var expandedWsIndex = null;
var prevWsStates = {};
var notificationsEnabled = true;
var audioCtx = null;

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
  if (waitingCount > 0) {
    document.title = '(' + waitingCount + ') cmux harness \u2014 Command Center';
  } else {
    document.title = 'cmux harness \u2014 Command Center';
  }
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

  // Sort: waiting first, active next, idle last
  var sorted=ws.slice().sort(function(a,b){
    var order={'waiting':0,'active':1,'idle':2};
    var sa=order[classifyWs(a)]||1;
    var sb=order[classifyWs(b)]||1;
    return sa-sb;
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
    if(w.hasClaude&&w.sessionStart){var dur=formatDuration(w.sessionStart);if(dur)html+='<span>\u23F1 '+esc(dur)+'</span>';}
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
    // Surgical update: only terminal content, meta, badge, and cost — no DOM destruction
    sorted.forEach(function(w){
      var card=document.getElementById('card-'+w.index);
      if(!card)return;
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
        if(w.hasClaude&&w.sessionStart){var dur=formatDuration(w.sessionStart);if(dur)spans.push('<span>\u23F1 '+esc(dur)+'</span>');}
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
  expandedWsIndex=idx;
  document.getElementById('overlay').classList.add('visible');
  document.getElementById('escHint').style.display='block';
  document.body.style.overflow='hidden';
  updateExpanded();
};
window.closeExpanded=function(){
  expandedWsIndex=null;
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
  if(expandedWsIndex===null)return;
  var ws=state.workspaces.find(function(w){return w.index===expandedWsIndex});
  if(!ws)return;
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
  if(ws.hasClaude&&ws.sessionStart){var dur=formatDuration(ws.sessionStart);if(dur)meta+='\u23F1 '+esc(dur)+'  ';}
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

// ─── Settings ───
window.toggleNotifications=function(el){
  el.classList.toggle('on');
  notificationsEnabled = el.classList.contains('on');
  el.querySelector('.auto-toggle-label').textContent = notificationsEnabled ? 'On' : 'Off';
};
window.openSettings=function(){
  document.getElementById('settingsOverlay').classList.add('visible');
  document.getElementById('settingsPoll').value=String(state.pollInterval);
  document.getElementById('settingsCwd').value=defaultCwd;
  var notifEl=document.getElementById('settingsNotif');
  if(notificationsEnabled){notifEl.classList.add('on');notifEl.querySelector('.auto-toggle-label').textContent='On';}
  else{notifEl.classList.remove('on');notifEl.querySelector('.auto-toggle-label').textContent='Off';}
  updateOllamaStatus();
  // Load models
  api('GET','/api/models').then(function(r){
    if(!r)return;
    // Update availability state from response
    if(r.available!==undefined){
      state.ollamaAvailable=r.available;
      updateOllamaStatus();
    }
    var sel=document.getElementById('settingsModel');
    sel.innerHTML='';
    var models=r.models||[];
    if(models.length===0){
      sel.innerHTML='<option>'+(r.available===false?'Ollama unavailable':'No models found')+'</option>';
      return;
    }
    models.forEach(function(m){
      var opt=document.createElement('option');
      opt.value=m;opt.textContent=m;
      if(m===state.model)opt.selected=true;
      sel.appendChild(opt);
    });
  });
};
window.closeSettings=function(){
  document.getElementById('settingsOverlay').classList.remove('visible');
};
window.saveSetting=function(key,val){
  var body={};body[key]=val;
  api('POST','/api/config',body);
  if(key==='model')state.model=val;
  if(key==='pollInterval')state.pollInterval=val;
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
    if(expandedWsIndex!==null){
      // Don't clobber expanded input if user is typing
      var expFocused=document.activeElement&&document.activeElement.id==='expInput';
      updateExpanded();
      if(expFocused)document.getElementById('expInput').focus();
    }
  });
}
refresh();
setInterval(refresh,2000);
// Faster refresh for expanded view (500ms)
setInterval(function(){
  if(expandedWsIndex===null)return;
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
                self._json_response({"pollInterval": _engine.poll_interval, "model": _engine.model})
        elif self.path == "/api/models":
            # Use cached availability — if already known unavailable, skip the connect attempt
            with _engine._lock:
                cached = _engine.ollama_available
            if cached is False:
                self._json_response({"models": [], "available": False})
            else:
                try:
                    import urllib.request as _ur
                    with _ur.urlopen(f"{OLLAMA_URL}/api/tags", timeout=4) as r:
                        data = json.loads(r.read())
                    names = [m["name"] for m in data.get("models", [])]
                    with _engine._lock:
                        _engine.ollama_available = True
                        _engine.ollama_last_check = time.time()
                    self._json_response({"models": names, "available": True})
                except Exception as e:
                    with _engine._lock:
                        _engine.ollama_available = False
                        _engine.ollama_last_check = time.time()
                    self._json_response({"models": [], "available": False, "error": str(e)})
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
            with _engine._lock:
                self._json_response({"ok": True, "pollInterval": _engine.poll_interval, "model": _engine.model})
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
