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

    payload = {
        "model": OLLAMA_MODEL,
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
            "model": OLLAMA_MODEL,
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
        self._lock = threading.Lock()

    def set_enabled(self, val):
        with self._lock:
            self.enabled = bool(val)

    def set_workspace_enabled(self, index, val):
        with self._lock:
            self.workspace_enabled[index] = bool(val)

    def set_poll_interval(self, val):
        with self._lock:
            self.poll_interval = max(2, min(30, int(val)))

    def get_status(self):
        with self._lock:
            ws_list = []
            for ws in self.workspaces:
                idx = ws.get("index", ws.get("id"))
                ws_list.append({
                    "index": idx,
                    "name": ws.get("name", f"workspace-{idx}"),
                    "uuid": ws.get("uuid", ""),
                    "enabled": self.workspace_enabled.get(idx, True),
                    "lastCheck": ws.get("_lastCheck", ""),
                })
            return {
                "enabled": self.enabled,
                "workspaces": ws_list,
                "pollInterval": self.poll_interval,
                "socketFound": _find_socket_path() is not None,
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
        with self._lock:
            for w in self.workspaces:
                if w.get("index", w.get("id")) == idx:
                    w["_lastCheck"] = now_str
                    break

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
                if enabled:
                    # Phase 1: Check which workspaces have unread
                    # notifications WITHOUT switching workspaces.
                    attention_uuids = self.get_workspaces_needing_attention()

                    with self._lock:
                        ws_snap = list(self.workspaces)
                    for ws in ws_snap:
                        idx = ws.get("index", ws.get("id"))
                        ws_uuid = ws.get("uuid", "")
                        with self._lock:
                            ws_on = self.workspace_enabled.get(idx, True)
                        if not ws_on:
                            continue
                        # Phase 2: Only switch to workspaces that have
                        # unread notifications (need attention).
                        if attention_uuids and ws_uuid not in attention_uuids:
                            continue
                        self.check_workspace(ws)
            except Exception as exc:
                print(f"[harness] error: {exc}")
            time.sleep(interval)


# ---------------------------------------------------------------------------
# Dashboard HTML — embedded as string
# ---------------------------------------------------------------------------

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>cmux Auto-Approve Dashboard</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#1a1a2e;color:#e0e0e0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;padding:20px;min-height:100vh}
.container{max-width:900px;margin:0 auto}
header{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px;flex-wrap:wrap;gap:12px}
header h1{font-size:1.5rem;font-weight:700;letter-spacing:-.5px}
.conn-dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-left:8px;vertical-align:middle}
.conn-dot.ok{background:#4caf50;box-shadow:0 0 6px #4caf50}
.conn-dot.err{background:#f44336;box-shadow:0 0 6px #f44336}
.card{background:#16213e;border-radius:12px;padding:20px;margin-bottom:20px;border:1px solid #0f3460}
.card h2{font-size:1.1rem;margin-bottom:14px;color:#a0c4ff}
.row{display:flex;align-items:center;gap:16px;flex-wrap:wrap}
.switch{position:relative;display:inline-block;width:56px;height:30px}
.switch input{opacity:0;width:0;height:0}
.slider{position:absolute;cursor:pointer;inset:0;background:#555;border-radius:30px;transition:.3s}
.slider:before{content:"";position:absolute;height:24px;width:24px;left:3px;bottom:3px;background:#fff;border-radius:50%;transition:.3s}
input:checked+.slider{background:#4caf50}
input:checked+.slider:before{transform:translateX(26px)}
.toggle-label{font-size:.95rem;font-weight:600}
select{background:#0f3460;color:#e0e0e0;border:1px solid #1a3a6e;border-radius:6px;padding:6px 10px;font-size:.9rem}
.ws-list{list-style:none}
.ws-list li{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid #0f3460}
.ws-list li:last-child{border-bottom:none}
.ws-list .name{flex:1;font-weight:500}
.ws-list .meta{font-size:.8rem;color:#888;font-family:'SF Mono',Menlo,monospace}
.ws-list input[type=checkbox]{width:18px;height:18px;accent-color:#4caf50}
.log-wrap{max-height:360px;overflow-y:auto;border-radius:8px}
.log-wrap::-webkit-scrollbar{width:6px}
.log-wrap::-webkit-scrollbar-thumb{background:#0f3460;border-radius:3px}
table{width:100%;border-collapse:collapse;font-family:'SF Mono',Menlo,monospace;font-size:.82rem}
th{text-align:left;padding:8px 10px;background:#0f3460;color:#a0c4ff;position:sticky;top:0;z-index:1}
td{padding:6px 10px;border-bottom:1px solid #162040}
tr:hover td{background:#1a2744}
.badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:.78rem;font-weight:600}
.badge-green{background:#1b5e20;color:#a5d6a7}
.badge-yellow{background:#4e3a00;color:#ffd54f}
.badge-red{background:#5e1a1a;color:#ff8a80}
.empty{text-align:center;color:#666;padding:32px;font-style:italic}
footer{text-align:center;color:#555;font-size:.75rem;margin-top:32px}
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>&#9889; cmux Auto-Approve<span class="conn-dot" id="connDot"></span></h1>
  </header>
  <div class="card">
    <div class="row">
      <label class="switch"><input type="checkbox" id="globalToggle"><span class="slider"></span></label>
      <span class="toggle-label" id="toggleLabel">OFF</span>
      <div style="margin-left:auto;display:flex;align-items:center;gap:8px">
        <label for="pollSelect" style="font-size:.85rem;color:#888">Poll interval</label>
        <select id="pollSelect">
          <option value="2">2 s</option>
          <option value="3">3 s</option>
          <option value="5" selected>5 s</option>
          <option value="10">10 s</option>
        </select>
      </div>
    </div>
  </div>
  <div class="card">
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
      <h2 style="margin:0">Workspaces</h2>
      <div style="display:flex;gap:8px">
        <button onclick="toggleAllWs(true)" style="background:#1b5e20;color:#a5d6a7;border:none;border-radius:6px;padding:4px 12px;font-size:.8rem;cursor:pointer">Select All</button>
        <button onclick="toggleAllWs(false)" style="background:#4e1a1a;color:#ff8a80;border:none;border-radius:6px;padding:4px 12px;font-size:.8rem;cursor:pointer">Deselect All</button>
      </div>
    </div>
    <ul class="ws-list" id="wsList"><li class="empty">Waiting for data...</li></ul>
  </div>
  <div class="card">
    <h2>Approval Log</h2>
    <div class="log-wrap">
      <table>
        <thead><tr><th>Time</th><th>Workspace</th><th>Prompt</th><th>Action</th></tr></thead>
        <tbody id="logBody"><tr><td colspan="4" class="empty">No approvals yet.</td></tr></tbody>
      </table>
    </div>
  </div>
  <footer>cmux-harness &middot; auto-approve dashboard</footer>
</div>
<script>
(function(){
  var globalToggle = document.getElementById('globalToggle');
  var toggleLabel = document.getElementById('toggleLabel');
  var pollSelect = document.getElementById('pollSelect');
  var connDot = document.getElementById('connDot');
  var wsList = document.getElementById('wsList');
  var logBody = document.getElementById('logBody');

  function toggleAllWs(enabled) {
    var checkboxes = document.querySelectorAll('#wsList input[type=checkbox]');
    checkboxes.forEach(function(cb) {
      cb.checked = enabled;
      var idx = parseInt(cb.dataset.idx);
      if (!isNaN(idx)) api('POST', '/api/workspace', {index: idx, enabled: enabled});
    });
  }

  function api(method, path, body) {
    var opts = {method: method, headers: {'Content-Type': 'application/json'}};
    if (body !== undefined) opts.body = JSON.stringify(body);
    return fetch(path, opts).then(function(r){ return r.json(); }).catch(function(){ return null; });
  }

  function esc(s) {
    var d = document.createElement('div');
    d.textContent = s || '';
    return d.innerHTML;
  }

  globalToggle.addEventListener('change', function(){
    api('POST', '/api/toggle', {enabled: globalToggle.checked});
  });
  pollSelect.addEventListener('change', function(){
    api('POST', '/api/config', {pollInterval: parseInt(pollSelect.value)});
  });

  function fmtTime(iso) {
    if (!iso) return '\\u2014';
    return new Date(iso).toLocaleTimeString();
  }

  function buildWsItem(ws) {
    var li = document.createElement('li');
    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = ws.enabled;
    cb.dataset.idx = ws.index;
    cb.style.width = '18px';
    cb.style.height = '18px';
    cb.style.accentColor = '#4caf50';
    cb.addEventListener('change', function(){
      api('POST', '/api/workspace', {index: ws.index, enabled: cb.checked});
    });
    var nameSpan = document.createElement('span');
    nameSpan.className = 'name';
    nameSpan.textContent = ws.name;
    var metaSpan = document.createElement('span');
    metaSpan.className = 'meta';
    metaSpan.textContent = ws.lastCheck ? fmtTime(ws.lastCheck) : '\\u2014';
    li.appendChild(cb);
    li.appendChild(nameSpan);
    li.appendChild(metaSpan);
    return li;
  }

  function buildLogRow(e) {
    var tr = document.createElement('tr');
    var td1 = document.createElement('td');
    td1.textContent = fmtTime(e.timestamp);
    var td2 = document.createElement('td');
    td2.textContent = e.workspaceName || String(e.workspace);
    var td3 = document.createElement('td');
    var b3 = document.createElement('span');
    b3.className = 'badge badge-yellow';
    b3.textContent = e.promptType;
    td3.appendChild(b3);
    var td4 = document.createElement('td');
    var b4 = document.createElement('span');
    var isHuman = e.action && e.action.indexOf('human') !== -1;
    b4.className = isHuman ? 'badge badge-red' : 'badge badge-green';
    b4.textContent = e.action;
    td4.appendChild(b4);
    if (isHuman) { tr.style.background = '#2a1a1a'; }
    tr.appendChild(td1);
    tr.appendChild(td2);
    tr.appendChild(td3);
    tr.appendChild(td4);
    return tr;
  }

  function refresh() {
    Promise.all([api('GET', '/api/status'), api('GET', '/api/log')]).then(function(results){
      var status = results[0];
      var log = results[1];
      if (!status) { connDot.className = 'conn-dot err'; return; }
      connDot.className = status.socketFound ? 'conn-dot ok' : 'conn-dot err';
      globalToggle.checked = status.enabled;
      toggleLabel.textContent = status.enabled ? 'ON' : 'OFF';
      toggleLabel.style.color = status.enabled ? '#4caf50' : '#f44336';
      pollSelect.value = String(status.pollInterval);

      wsList.textContent = '';
      if (status.workspaces.length === 0) {
        var emptyLi = document.createElement('li');
        emptyLi.className = 'empty';
        emptyLi.textContent = 'No workspaces detected.';
        wsList.appendChild(emptyLi);
      } else {
        status.workspaces.forEach(function(ws){ wsList.appendChild(buildWsItem(ws)); });
      }

      logBody.textContent = '';
      if (!log || log.length === 0) {
        var emptyTr = document.createElement('tr');
        var emptyTd = document.createElement('td');
        emptyTd.colSpan = 4;
        emptyTd.className = 'empty';
        emptyTd.textContent = 'No approvals yet.';
        emptyTr.appendChild(emptyTd);
        logBody.appendChild(emptyTr);
      } else {
        log.forEach(function(e){ logBody.appendChild(buildLogRow(e)); });
      }
    });
  }

  refresh();
  setInterval(refresh, 2000);
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
                self._json_response({"pollInterval": _engine.poll_interval})
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
            with _engine._lock:
                self._json_response({"ok": True, "pollInterval": _engine.poll_interval})
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
