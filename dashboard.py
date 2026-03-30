#!/usr/bin/env python3
"""cmux Auto-Approve Dashboard — single-file harness engine + web UI."""

import hashlib
import json
import os
import re
import socket
import sys
import threading
import time
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
        return _cmux_send(sock, command)
    except OSError:
        return None
    finally:
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
        sock.close()


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# LLM classification (Ollama local model)
# ---------------------------------------------------------------------------

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.5:2b")
USE_LLM = os.environ.get("USE_LLM", "1") != "0"  # enabled by default

_LLM_SYSTEM = """You classify terminal prompts from Claude Code (an AI coding assistant).
When the terminal shows a PERMISSION prompt or confirmation dialog, decide the correct response.
Reply with ONLY a JSON object, no markdown, no explanation.

Rules:
- Simple confirmations (Yes/No, Y/n, proceed, approve, allow tool) → auto-approve
- Domain-specific choices (which file, which section, pick a number) → needs human
- Claude Code idle REPL showing "❯" with "Model:" and "Cost:" lines → NOT waiting, this is just the input prompt
- A shell prompt (like "user@host %") → NOT waiting
- Claude Code showing "Musing…" or "Thinking…" → NOT waiting, it's working
- If the terminal is NOT waiting for a permission prompt → not waiting

JSON format: {"waiting": bool, "action": "enter"|"y"|"skip", "safe": bool, "reason": "brief"}
- action "enter" = press Enter key (for menus where cursor is on the right option)
- action "y" = type the letter y (for Y/n prompts)
- action "skip" = needs human decision, don't send anything
- waiting = true ONLY for permission/approval prompts, NOT for idle REPLs or shell prompts"""


def llm_classify(screen_text):
    """Ask a local Ollama model to classify the terminal screen.
    Returns (pattern_name, action) or None on failure."""
    if not USE_LLM:
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
_CURSOR_CHARS = r"[❯)\>]"
_NUMBERED_MENU_RE = re.compile(r"^\s*\d+[.)]\s+")
_AFFIRM_RE = re.compile(r"(Yes|Allow|Confirm|Approve|Accept|Proceed|Continue)", re.I)


# Regex to detect Claude Code's idle REPL (not a permission prompt)
_REPL_IDLE_RE = re.compile(r"(Model:\s*(Sonnet|Opus|Haiku|Claude)|Cost:\s*\$|Ctx:\s*\d)")


def _is_permission_menu(options_text):
    """Check if menu options are all Yes/No variants (permission prompt)
    vs domain-specific choices (needs human).
    Returns True if it's a standard permission prompt."""
    # Extract option text (everything after "N. " or "N) ")
    option_texts = re.findall(r"\d+[.)]\s+(.+)", options_text)
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
    Returns ("needs_human", "skip") if a menu needs manual intervention."""
    if not screen_text:
        return None
    lines = screen_text.splitlines()
    tail = "\n".join(lines[-25:]) if len(lines) > 25 else screen_text

    # SKIP: Claude Code idle REPL (has ❯ but also Model:/Cost: lines)
    if _REPL_IDLE_RE.search(tail):
        return None

    # FIRST: Check for numbered menus (Enter to select / Esc to cancel).
    has_menu_footer = bool(re.search(r"Enter to select|Esc to cancel", tail))
    if has_menu_footer:
        # Check if this is a standard permission menu (Yes/No variants)
        # or a domain-specific choice menu
        if not _is_permission_menu(tail):
            return ("needs_human", "skip")

        # It's a permission menu. Check if cursor is on an affirmative option.
        cursor_re = re.compile(r"^\s*" + _CURSOR_CHARS + r"\s*\d+[.)]\s+")
        for line in tail.splitlines():
            if cursor_re.match(line) or ("❯" in line and _NUMBERED_MENU_RE.search(line)):
                if _AFFIRM_RE.search(line):
                    return ("confirm_menu", "enter")
                else:
                    return ("needs_human", "skip")
        # Also check for cursor on a non-numbered line
        cursor_plain_re = re.compile(r"^\s*" + _CURSOR_CHARS + r"\s+")
        for line in tail.splitlines():
            if cursor_plain_re.match(line):
                if _AFFIRM_RE.search(line):
                    return ("confirm_menu", "enter")
                else:
                    return ("needs_human", "skip")
        return ("needs_human", "skip")

    # Non-menu prompts (regex fast-path)
    for name, primary, secondary, action in PROMPT_PATTERNS:
        if re.search(primary, tail):
            if secondary is None or re.search(secondary, tail):
                return (name, action)

    # If regex found nothing, try the LLM as a fallback.
    # This catches prompt formats we haven't seen before.
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
LOG_FILE = LOG_DIR / "approval-log.jsonl"
DEBUG_LOG = LOG_DIR / "debug-log.jsonl"


def _debug_log(entry):
    """Append a debug entry to the debug log file (full data dump)."""
    entry["_ts"] = datetime.now(timezone.utc).isoformat()
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


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
        self._lock = threading.Lock()
        self.model = OLLAMA_MODEL

    def set_enabled(self, val):
        with self._lock:
            self.enabled = bool(val)

    def set_workspace_enabled(self, index, val):
        with self._lock:
            self.workspace_enabled[index] = bool(val)

    def set_poll_interval(self, val):
        with self._lock:
            self.poll_interval = max(2, min(30, int(val)))

    def set_model(self, name):
        with self._lock:
            self.model = name

    def get_status(self):
        with self._lock:
            ws_list = []
            for ws in self.workspaces:
                idx = ws.get("index", ws.get("id"))
                screen_tail = self.screen_cache.get(idx, "")
                # Get last 5 lines for card preview
                lines = screen_tail.strip().splitlines() if screen_tail else []
                preview = "\n".join(lines[-5:]) if lines else ""
                # Detect if Claude Code is running in this terminal
                has_claude = _detect_claude_session(screen_tail) if screen_tail else False
                ws_list.append({
                    "hasClaude": has_claude,
                    "index": idx,
                    "name": ws.get("name", f"workspace-{idx}"),
                    "uuid": ws.get("uuid", ""),
                    "enabled": self.workspace_enabled.get(idx, False),
                    "lastCheck": ws.get("_lastCheck", ""),
                    "screenTail": preview,
                    "screenFull": screen_tail,
                    "cwd": ws.get("_cwd", ""),
                    "branch": ws.get("_branch", ""),
                })
            return {
                "enabled": self.enabled,
                "workspaces": ws_list,
                "pollInterval": self.poll_interval,
                "socketFound": _find_socket_path() is not None,
                "model": self.model,
            }

    def get_log(self, limit=200):
        with self._lock:
            return list(reversed(self.approval_log[-limit:]))

    def _append_log(self, entry):
        with self._lock:
            self.approval_log.append(entry)
            if len(self.approval_log) > 500:
                self.approval_log = self.approval_log[-500:]
        try:
            with open(LOG_FILE, "a") as f:
                f.write(json.dumps(entry) + "\n")
        except OSError:
            pass
        ts = entry.get("timestamp", "")
        ws_name = entry.get("workspaceName", "?")
        ptype = entry.get("promptType", "?")
        action = entry.get("action", "?")
        print(f"[{ts}] approved ws={ws_name} type={ptype} action={action}")

    def refresh_workspaces(self):
        raw = cmux_command("list_workspaces")
        if raw is None:
            return
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
        with self._lock:
            self.workspaces = workspaces

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
                # Always refresh workspace list so the UI shows them
                # even before the global toggle is enabled.
                self.refresh_workspaces()

                # Read screens for ALL workspaces so the UI has data
                with self._lock:
                    ws_snap = list(self.workspaces)
                for ws in ws_snap:
                    ws_uuid = ws.get("uuid", "")
                    idx = ws.get("index", ws.get("id"))
                    if ws_uuid:
                        screen = cmux_read_workspace(idx, 0, lines=40, workspace_uuid=ws_uuid)
                        if screen:
                            with self._lock:
                                self.screen_cache[idx] = screen
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
.conn-dot.err{background:var(--red);box-shadow:0 0 6px rgba(248,81,73,.5)}
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
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(540px,1fr));gap:16px;padding:24px 28px}
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
.card-name{font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card-header-right{display:flex;align-items:center;gap:8px;flex-shrink:0}
.badge{padding:3px 10px;border-radius:20px;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.5px}
.badge-active{background:rgba(63,185,80,.15);color:var(--green)}
.badge-waiting{background:rgba(210,153,34,.15);color:var(--yellow)}
.badge-idle{background:rgba(139,148,158,.15);color:var(--text-muted)}

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
.card-terminal{padding:12px 18px;font-family:'JetBrains Mono','SF Mono','Menlo',monospace;font-size:12px;line-height:1.6;color:var(--text-muted);background:rgba(0,0,0,.2);min-height:80px;max-height:120px;overflow:hidden;position:relative;white-space:pre-wrap;word-break:break-all}
.card-terminal::after{content:'';position:absolute;bottom:0;left:0;right:0;height:24px;background:linear-gradient(transparent,rgba(0,0,0,.3))}
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
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-left">
    <div class="logo"><span>cmux</span> harness<span class="conn-dot" id="connDot"></span></div>
    <div class="topbar-stats" id="topStats">
      <div class="stat"><span class="stat-dot" style="background:var(--green)"></span> <span id="statActive">0</span> active</div>
      <div class="stat"><span class="stat-dot" style="background:var(--yellow)"></span> <span id="statWaiting">0</span> waiting</div>
      <div class="stat"><span class="stat-dot" style="background:var(--text-muted);opacity:.5"></span> <span id="statIdle">0</span> idle</div>
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

<div class="grid" id="grid">
  <div class="grid-empty">Connecting to cmux...</div>
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
    <div class="settings-row">
      <div>
        <div class="settings-label">LLM Model</div>
        <div class="settings-sublabel">Ollama model for fallback classification</div>
      </div>
      <select class="settings-select" id="settingsModel" onchange="saveSetting('model',this.value)">
        <option>Loading...</option>
      </select>
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
  </div>
</div>

<script>
(function(){
var state = {enabled:false,workspaces:[],model:'',pollInterval:5,socketFound:false};
var logData = [];
var expandedWsIndex = null;

function api(method,path,body){
  var opts={method:method,headers:{'Content-Type':'application/json'}};
  if(body!==undefined)opts.body=JSON.stringify(body);
  return fetch(path,opts).then(function(r){return r.json()}).catch(function(){return null});
}

function esc(s){var d=document.createElement('div');d.textContent=s||'';return d.innerHTML}

function fmtTime(iso){
  if(!iso)return '\u2014';
  try{return new Date(iso).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}catch(e){return iso}
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

  // Sort: waiting first
  var sorted=ws.slice().sort(function(a,b){
    var sa=classifyWs(a)==='waiting'?0:1;
    var sb=classifyWs(b)==='waiting'?0:1;
    return sa-sb;
  });

  var html='';
  sorted.forEach(function(w){
    var s=classifyWs(w);
    var isWaiting=s==='waiting';
    var isIdle=s==='idle';
    var cardClass='card'+(isWaiting?' needs-attention':'');
    var statusClass='card-status '+s;
    var badgeClass=isWaiting?'badge badge-waiting':isIdle?'badge badge-idle':'badge badge-active';
    var badgeText=isWaiting?'Needs You':isIdle?'Idle':'Active';
    var autoOn=w.enabled===true;
    var autoClass='auto-toggle'+(autoOn?' on':'');
    var opacity=isIdle?' style="opacity:.6"':'';

    html+='<div class="'+cardClass+'"'+opacity+'>';
    html+='<div class="card-header">';
    html+='<div class="card-title-row"><div class="'+statusClass+'"></div><span class="card-name">'+esc(w.name)+'</span></div>';
    html+='<div class="card-header-right">';
    html+='<span class="'+badgeClass+'">'+badgeText+'</span>';
    html+='<div class="'+autoClass+'" onclick="toggleWsAuto('+w.index+',this)"><span class="auto-toggle-label">Auto</span><div class="toggle-track"></div></div>';
    html+='<button class="expand-btn" onclick="openExpanded('+w.index+')">&#10530;</button>';
    html+='</div></div>';

    html+='<div class="card-meta">';
    html+='<span>\uD83D\uDCC2 '+esc(w.cwd||'—')+'</span>';
    if(w.branch)html+='<span>\uD83C\uDF3F '+esc(w.branch)+'</span>';
    if(w.lastCheck)html+='<span>\u23F1 '+fmtTime(w.lastCheck)+'</span>';
    html+='</div>';

    html+='<div class="card-terminal">'+(w.screenTail?esc(w.screenTail):'<span style="color:var(--text-muted);font-style:italic">(no data yet)</span>')+'</div>';

    html+='<div class="card-footer">';
    html+='<input class="card-input" placeholder="Send message..." id="input-'+w.index+'" onkeydown="if(event.key===\'Enter\')sendToWs('+w.index+')">';
    html+='<button class="card-send" onclick="sendToWs('+w.index+')">Send</button>';
    html+='</div></div>';
  });
  grid.innerHTML=html;
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
  document.getElementById('expTitle').textContent=ws.name;
  var meta='';
  if(ws.cwd)meta+='\uD83D\uDCC2 '+esc(ws.cwd)+'  ';
  if(ws.branch)meta+='\uD83C\uDF3F '+esc(ws.branch)+'  ';
  if(ws.lastCheck)meta+='\u23F1 '+fmtTime(ws.lastCheck);
  document.getElementById('expMeta').innerHTML=meta;

  var autoEl=document.getElementById('expAutoToggle');
  if(ws.enabled!==false)autoEl.classList.add('on');
  else autoEl.classList.remove('on');

  document.getElementById('expTerminal').textContent=ws.screenFull||ws.screenTail||'(no data yet)';

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
window.openSettings=function(){
  document.getElementById('settingsOverlay').classList.add('visible');
  document.getElementById('settingsPoll').value=String(state.pollInterval);
  // Load models
  api('GET','/api/models').then(function(r){
    if(!r)return;
    var sel=document.getElementById('settingsModel');
    sel.innerHTML='';
    var models=r.models||[];
    if(models.length===0){sel.innerHTML='<option>No models found</option>';return}
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

// ─── New session (placeholder) ───
window.newSession=function(){
  // Future: create workspace via cmux API
  alert('New session creation coming in v3!');
};

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
    document.getElementById('connDot').className=status.socketFound?'conn-dot ok':'conn-dot err';
    state.enabled=status.enabled;
    state.pollInterval=status.pollInterval;
    state.model=status.model||'';
    state.workspaces=status.workspaces||[];
    state.socketFound=status.socketFound;
    logData=log||[];
    updateGlobalToggle();
    buildGrid();
    if(expandedWsIndex!==null)updateExpanded();
  });
}
refresh();
setInterval(refresh,2000);
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
        elif self.path == "/api/config":
            with _engine._lock:
                self._json_response({"pollInterval": _engine.poll_interval, "model": _engine.model})
        elif self.path == "/api/models":
            try:
                import urllib.request as _ur
                with _ur.urlopen(f"{OLLAMA_URL}/api/tags", timeout=4) as r:
                    data = json.loads(r.read())
                names = [m["name"] for m in data.get("models", [])]
                self._json_response({"models": names})
            except Exception as e:
                self._json_response({"models": [], "error": str(e)})
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
