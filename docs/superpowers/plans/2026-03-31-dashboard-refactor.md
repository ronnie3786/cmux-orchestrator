# Dashboard Refactor: Monolith to Package

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break the 4,185-line `dashboard.py` monolith into a proper Python package with focused modules and unit tests for the most critical logic.

**Architecture:** Extract 7 modules from `dashboard.py` into a `cmux_harness/` package, each with a single responsibility. Remove the `_engine` global by using a handler factory pattern. Extract the 2,100-line HTML template to a separate file loaded at runtime.

**Tech Stack:** Python 3.9+ stdlib only (no new dependencies). `unittest` for tests.

---

## File Structure

```
cmux-harness/
├── cmux_harness/                  # New package
│   ├── __init__.py                # Package init, exports key symbols
│   ├── cmux_api.py                # cmux socket helpers, v2 JSON-RPC, tree parsing
│   ├── detection.py               # Prompt detection, Claude session detection, LLM classify
│   ├── storage.py                 # Logging, config persistence, review file I/O
│   ├── review.py                  # Review engine: prompt builder, Ollama/Claude/LMStudio backends
│   ├── engine.py                  # HarnessEngine background thread
│   ├── server.py                  # DashboardHandler HTTP API + handler factory
│   └── static/
│       └── dashboard.html         # Extracted HTML template (was lines 1688-3770)
├── tests/
│   ├── __init__.py
│   ├── test_detection.py          # Prompt detection, session detection, fingerprint
│   ├── test_storage.py            # Cost parsing, review JSON parsing, log rotation
│   └── test_review.py             # Review prompt building, JSON extraction
├── dashboard.py                   # Slim entry point (~30 lines)
├── eval_models.py                 # Unchanged
└── ...
```

### Module responsibilities and approximate sizes:

| Module | Lines | Responsibility |
|---|---|---|
| `cmux_api.py` | ~200 | Socket discovery, v1/v2 commands, workspace read/send, tree parsing, constants |
| `detection.py` | ~200 | Regex patterns, `detect_prompt()`, `_detect_claude_session()`, `_is_permission_menu()`, `fingerprint()`, `llm_classify()` |
| `storage.py` | ~150 | `LOG_DIR`/`REVIEWS_DIR` constants, log rotation, `_debug_log()`, review file CRUD, config load/save, `_parse_session_cost()` |
| `review.py` | ~250 | `_build_review_prompt()`, `_run_review_ollama()`, `_run_review_lmstudio()`, `_run_review_claude()`, `_run_review()`, JSON parsing |
| `engine.py` | ~650 | `HarnessEngine` class: workspace polling, state management, session lifecycle, snapshot capture |
| `server.py` | ~400 | `DashboardHandler`, all GET/POST endpoints, `make_handler()` factory, HTML serving |
| `static/dashboard.html` | ~2,080 | Full HTML/CSS/JS template |
| `dashboard.py` (entry) | ~30 | Imports, engine creation, server startup |

### Dependency graph (no cycles):

```
cmux_api  ←  detection  ←  engine  ←  server  ←  dashboard.py (entry)
              storage   ←──┘    ↑
              review   ←────────┘
```

- `cmux_api` depends on nothing (stdlib only)
- `storage` depends on nothing (stdlib only)
- `detection` depends on `storage` (for `_debug_log`)
- `review` depends on `storage` (for `_debug_log`, review file I/O)
- `engine` depends on `cmux_api`, `detection`, `storage`, `review`
- `server` depends on `engine`, `storage`, `cmux_api`

### Key design decisions:

1. **Kill the `_engine` global.** Currently `llm_classify()` reads `_engine.model` and `_engine._check_ollama()`. Refactor `llm_classify()` to accept `model` and `ollama_checker` as parameters. The engine passes these when calling detection.
2. **Handler factory pattern.** `DashboardHandler` currently reads a module-level `_engine`. Replace with `make_handler(engine)` that returns a handler class with the engine reference closed over.
3. **HTML loaded from file.** `server.py` reads `dashboard.html` once at import time from `cmux_harness/static/dashboard.html`. Falls back to a "file not found" page if missing.

---

## Task 1: Create package skeleton and move constants

**Files:**
- Create: `cmux_harness/__init__.py`
- Create: `cmux_harness/cmux_api.py`
- Create: `tests/__init__.py`

- [ ] **Step 1: Create the package directory**

```bash
mkdir -p cmux_harness/static tests
```

- [ ] **Step 2: Create `cmux_harness/__init__.py`**

```python
"""cmux-harness: Auto-approve dashboard for Claude Code sessions."""
```

- [ ] **Step 3: Create `tests/__init__.py`**

```python
```

(Empty file, just marks directory as a package.)

- [ ] **Step 4: Create `cmux_harness/cmux_api.py` with socket helpers**

Extract lines 1-223 from `dashboard.py` (imports through `cmux_tree()`), plus the virtual index constants (lines 182-187).

```python
"""cmux socket communication and workspace management."""

import json
import os
import re
import socket
import subprocess

# Virtual index scheme: workspace idx 0 with 3 surfaces becomes idx 0, 10000, 10001.
VIRTUAL_BASE = 10000
VIRTUAL_STRIDE = 100
SURFACE_MAP_TTL = 15  # seconds between cmux tree refreshes


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


def cmux_read_workspace(ws_index, surface_index=0, lines=40, workspace_uuid=None, surface_id=None):
    """Read terminal text from a workspace WITHOUT switching to it."""
    if workspace_uuid:
        params = {"workspace_id": workspace_uuid, "lines": lines}
        if surface_id:
            params["surface_id"] = surface_id
        result = _v2_request("surface.read_text", params)
        if result:
            text = result.get("text", "")
            if text:
                return text
            import base64 as _b64
            b64 = result.get("base64", "")
            if b64:
                return _b64.b64decode(b64).decode(errors="replace")
            return ""
    # Fallback to v1
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


def cmux_send_to_workspace(ws_index, surface_index, text=None, key=None, workspace_uuid=None, surface_id=None):
    """Send text or a key to a surface WITHOUT switching workspaces."""
    if workspace_uuid:
        if text is not None:
            params = {"workspace_id": workspace_uuid, "text": text}
            if surface_id:
                params["surface_id"] = surface_id
            result = _v2_request("surface.send_text", params)
            return result is not None
        if key is not None:
            params = {"workspace_id": workspace_uuid, "key": key.lower()}
            if surface_id:
                params["surface_id"] = surface_id
            result = _v2_request("surface.send_key", params)
            return result is not None
    # Fallback to v1
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


def cmux_tree():
    """Fetch the full workspace/pane/surface hierarchy via cmux CLI.
    Returns {workspace_index: [{"ref", "title", "pane_ref"}]} or None."""
    try:
        r = subprocess.run(
            ["cmux", "tree", "--all", "--json"],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode != 0:
            return None
        data = json.loads(r.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return None
    result = {}
    for win in data.get("windows", []):
        for ws in win.get("workspaces", []):
            ws_idx = ws.get("index")
            if ws_idx is None:
                continue
            surfaces = []
            for pane in ws.get("panes", []):
                pane_ref = pane.get("ref", "")
                for surf in pane.get("surfaces", []):
                    if surf.get("type") != "terminal":
                        continue
                    surfaces.append({
                        "ref": surf.get("ref", ""),
                        "title": surf.get("title", ""),
                        "pane_ref": pane_ref,
                        "selected_in_pane": surf.get("selected_in_pane", False),
                    })
            if surfaces:
                result[ws_idx] = surfaces
    return result
```

- [ ] **Step 5: Verify the module imports cleanly**

Run: `python -c "from cmux_harness import cmux_api; print('OK')"`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add cmux_harness/__init__.py cmux_harness/cmux_api.py tests/__init__.py
git commit -m "refactor: extract cmux_api module from dashboard.py"
```

---

## Task 2: Extract storage module

**Files:**
- Create: `cmux_harness/storage.py`

- [ ] **Step 1: Create `cmux_harness/storage.py`**

Extract logging, config, and review file operations (dashboard.py lines 453-571, plus `_read_review_file`, `_list_reviews`, `_get_review`, `_get_review_path` from lines 499-539).

```python
"""Logging, configuration persistence, and review file I/O."""

import json
from datetime import datetime, timezone
from pathlib import Path

LOG_DIR = Path.home() / ".cmux-harness"
LOG_DIR.mkdir(parents=True, exist_ok=True)
REVIEWS_DIR = LOG_DIR / "reviews"
REVIEWS_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = LOG_DIR / "approval-log.jsonl"
DEBUG_LOG = LOG_DIR / "debug-log.jsonl"
CONFIG_FILE = LOG_DIR / "workspace-config.json"

MAX_DEBUG_LOG_SIZE = 10 * 1024 * 1024  # 10MB


def rotate_log_file(log_path, max_size=MAX_DEBUG_LOG_SIZE):
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


_debug_log_writes = 0


def debug_log(entry):
    """Append a debug entry to the debug log file."""
    global _debug_log_writes
    _debug_log_writes += 1
    if _debug_log_writes % 100 == 0:
        rotate_log_file(DEBUG_LOG)
    entry["_ts"] = datetime.now(timezone.utc).isoformat()
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def read_review_file(path):
    """Read and parse a review JSON file. Returns dict or None."""
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def write_review_file(path, data):
    """Write review data to a JSON file."""
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def list_reviews():
    """List all review files, sorted by completedAt descending."""
    reviews = []
    try:
        for path in REVIEWS_DIR.glob("*.json"):
            review = read_review_file(path)
            if review is not None:
                reviews.append(review)
    except OSError:
        return []
    reviews.sort(key=lambda r: r.get("completedAt", ""), reverse=True)
    return reviews


def get_review(session_id):
    """Find a review by session ID. Returns dict or None."""
    if not session_id:
        return None
    for review in list_reviews():
        if review.get("sessionId") == session_id:
            return review
    return None


def get_review_path(session_id):
    """Find the file path for a review by session ID. Returns Path or None."""
    if not session_id:
        return None
    try:
        for path in REVIEWS_DIR.glob("*.json"):
            review = read_review_file(path)
            if review and review.get("sessionId") == session_id:
                return path
    except OSError:
        return None
    return None


def load_config():
    """Read workspace config from JSON file. Returns normalized config dict."""
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
        return {"workspaces": workspaces, "reviewSettings": review_settings}
    except (FileNotFoundError, json.JSONDecodeError, KeyError, OSError):
        return {"workspaces": {}, "reviewSettings": {}}


def save_config(ws_config, review_enabled, review_model, review_backend):
    """Write config to disk."""
    try:
        with open(CONFIG_FILE, "w") as f:
            json.dump({
                "workspaces": ws_config,
                "reviewSettings": {
                    "enabled": review_enabled,
                    "model": review_model,
                    "backend": review_backend,
                },
            }, f, indent=2)
    except OSError as e:
        print(f"[harness] config save error: {e}")


def parse_session_cost(screen_text):
    """Parse Claude Code session cost from terminal output.
    Returns a dollar amount string like "$0.45" or None."""
    import re
    if not screen_text:
        return None
    lines = screen_text.splitlines()
    tail = "\n".join(lines[-5:]) if len(lines) > 5 else screen_text
    m = re.search(r"Cost:\s*(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    m = re.search(r"\U0001f4b0\s*(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    m = re.search(r"(\$\d+\.\d{2})\s+block", tail)
    if m:
        return m.group(1)
    m = re.search(r"(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    return None
```

- [ ] **Step 2: Verify the module imports cleanly**

Run: `python -c "from cmux_harness.storage import debug_log, parse_session_cost; print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add cmux_harness/storage.py
git commit -m "refactor: extract storage module (logging, config, review I/O)"
```

---

## Task 3: Extract detection module

**Files:**
- Create: `cmux_harness/detection.py`

The key refactor: `llm_classify()` currently reads `_engine.model` and calls `_engine._check_ollama()`. Refactor it to accept these as explicit parameters so the module has no global engine dependency.

- [ ] **Step 1: Create `cmux_harness/detection.py`**

Extract lines 231-446 from `dashboard.py`. Refactor `llm_classify` signature.

```python
"""Prompt detection for Claude Code terminal screens.

Multi-stage detection:
1. Fast regex pre-checks (skip idle REPLs and shell prompts)
2. LLM classification via Ollama (catches everything else)
"""

import hashlib
import json
import os
import re

from .storage import debug_log

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.5:35b-a3b-nvfp4")
USE_LLM = os.environ.get("USE_LLM", "1") != "0"

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


def llm_classify(screen_text, model=None, ollama_available_checker=None):
    """Ask a local Ollama model to classify the terminal screen.
    Returns (pattern_name, action) or None on failure.

    Args:
        screen_text: Terminal screen content to classify.
        model: Ollama model name to use (defaults to OLLAMA_MODEL env var).
        ollama_available_checker: Callable returning bool for Ollama availability.
            If provided and returns False, skips LLM classification.
    """
    if not USE_LLM:
        return None
    if ollama_available_checker is not None and not ollama_available_checker():
        return None
    lines = screen_text.splitlines()
    tail = "\n".join(lines[-25:]) if len(lines) > 25 else screen_text

    active_model = model or OLLAMA_MODEL
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
        start = raw.find("{")
        end = raw.rfind("}") + 1
        if start < 0 or end <= start:
            return None
        parsed = json.loads(raw[start:end])
        debug_log({
            "event": "llm_response",
            "raw": raw,
            "parsed": parsed,
            "model": active_model,
        })
        if not parsed.get("waiting", False):
            return None
        action = parsed.get("action", "skip")
        safe = parsed.get("safe", False)
        if action == "skip" or not safe:
            return ("needs_human", "skip")
        if action == "y" and re.search(r"Enter to select|Esc to cancel", tail):
            action = "enter"
        return (f"llm:{parsed.get('reason', '')[:40]}", action)
    except Exception as e:
        print(f"[harness] LLM error: {e}")
        debug_log({"event": "llm_error", "error": str(e)})
        return None


def detect_claude_session(screen_text):
    """Return True if Claude Code appears to be running in this terminal."""
    if not screen_text:
        return False
    lines = screen_text.strip().splitlines()
    tail = "\n".join(lines[-30:]) if len(lines) > 30 else screen_text
    if re.search(r"(Model:\s*(Sonnet|Opus|Haiku|Claude|claude)|Cost:\s*\$|Ctx:\s*\d)", tail):
        return True
    if re.search(r"(Musing\.\.\.|Thinking\.\.\.|⚡\s*(Read|Edit|Write|Bash|MultiEdit|Search|Glob|Grep|ListDir|Fetch|Browse|TodoRead|TodoWrite|WebFetch|MCP))", tail):
        return True
    if re.search(r"(Allow\s+(Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit)|Do you want to proceed|\(Y/n\)|\(y/n\))", tail):
        return True
    if re.search(r"[❯)]\s*(Yes|No|Allow|Deny|Approve|Confirm)", tail):
        return True
    if re.search(r"^\$?\s*claude\s*$", tail, re.MULTILINE):
        return True
    return False


# Regex patterns for known prompt types
PROMPT_PATTERNS = [
    ("yn_prompt",     r"\([Yy](?:/[Nn]|es/no)\)", None, "y"),
    ("tool_approval", r"Allow (Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit|ListDir|Glob|Grep|TodoRead|TodoWrite|WebFetch|WebSearch|Search|Task|NotebookRead|NotebookEdit)", None, "y"),
    ("button_yes",    r"[❯)\>]\s*(Yes|Allow)", None, "enter"),
    ("run_command",   r"(Run|Execute) (this|the) (command|script)?", None, "y"),
    ("apply_changes", r"(Apply|Write|Save) (these |the )?(changes|edits|file)?", None, "y"),
    ("trust_prompt",  r"Do you (trust|want to allow)", None, "y"),
]

_CURSOR_CHARS = r"[❯›)\>]"
_NUMBERED_MENU_RE = re.compile(r"^\s*\d+[.)]\s+")
_AFFIRM_RE = re.compile(r"(Yes|Allow|Confirm|Approve|Accept|Proceed|Continue)", re.I)
_REPL_IDLE_RE = re.compile(r"(Model:\s*(Sonnet|Opus|Haiku|Claude)|Cost:\s*\$|Ctx:\s*\d)")


def is_permission_menu(options_text):
    """Check if menu options are all Yes/No variants (permission prompt)
    vs domain-specific choices (needs human).
    Returns True if it's a standard permission prompt."""
    option_texts = re.findall(r"\d+[.)]\s*(.+)", options_text)
    has_affirmative = False
    has_domain_specific = False
    for opt in option_texts:
        opt_lower = opt.strip().lower()
        if opt_lower.startswith("type something") or opt_lower.startswith("chat about"):
            continue
        if any(opt_lower.startswith(w) for w in ["yes", "no", "allow", "deny", "skip",
                "confirm", "approve", "accept", "proceed", "continue", "cancel",
                "modify", "re-search", "add more", "change", "replace"]):
            if any(opt_lower.startswith(w) for w in ["yes", "allow", "confirm", "approve",
                    "accept", "proceed", "continue"]):
                has_affirmative = True
            continue
        has_domain_specific = True
    return has_affirmative and not has_domain_specific


def detect_prompt(screen_text, model=None, ollama_available_checker=None):
    """Return (pattern_name, action) or None if no prompt detected.
    Returns ("needs_human", "skip") if a prompt needs manual intervention.

    Args:
        screen_text: Terminal screen content.
        model: Ollama model name (passed through to llm_classify).
        ollama_available_checker: Callable for Ollama health check (passed through).
    """
    if not screen_text:
        return None
    lines = screen_text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return None
    tail = "\n".join(lines[-25:]) if len(lines) > 25 else "\n".join(lines)

    if _REPL_IDLE_RE.search(tail):
        return None

    last_chunk = "\n".join(lines[-10:]) if len(lines) > 10 else "\n".join(lines)
    if not re.search(r"(Allow |Do you want|proceed|\([Yy](?:/[Nn]|es/no)\)|Enter to select|Esc to cancel|Musing|Thinking|⚡|Model:|Cost:|Ctx:)", last_chunk):
        return None

    llm_result = llm_classify(screen_text, model=model, ollama_available_checker=ollama_available_checker)
    if llm_result is not None:
        return llm_result

    return None


def fingerprint(screen_text):
    """Hash of last 5 lines — used to avoid double-approving."""
    lines = screen_text.strip().splitlines()
    chunk = "\n".join(lines[-5:]) if len(lines) >= 5 else screen_text
    return hashlib.md5(chunk.encode()).hexdigest()
```

- [ ] **Step 2: Verify the module imports cleanly**

Run: `python -c "from cmux_harness.detection import detect_prompt, fingerprint, detect_claude_session; print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add cmux_harness/detection.py
git commit -m "refactor: extract detection module (prompt detection, LLM classify)"
```

---

## Task 4: Extract review module

**Files:**
- Create: `cmux_harness/review.py`

Extract the review backends (`_run_review_ollama`, `_run_review_lmstudio`, `_run_review_claude`), the prompt builder (`_build_review_prompt`), and the review orchestrator (`_run_review`) from `HarnessEngine`. These become standalone functions that receive their dependencies as arguments instead of reading `self`.

- [ ] **Step 1: Create `cmux_harness/review.py`**

```python
"""Session review engine: build prompts, call LLM backends, parse results."""

import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
from datetime import datetime, timezone

from .storage import debug_log, read_review_file, write_review_file

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.5:35b-a3b-nvfp4")


def parse_review_json(raw):
    """Extract a JSON object from LLM response text (handles markdown fences)."""
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


def build_review_prompt(review_data):
    """Build the LLM prompt for reviewing a completed session."""
    approval_log = review_data.get("approvalLog") or []
    approved_count = sum(1 for e in approval_log
                         if "needs human" not in str(e.get("action", "")).lower()
                         and "flagged" not in str(e.get("action", "")).lower())
    flagged_count = len(approval_log) - approved_count

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
        '  "whatHappened": "2-4 sentence description of what Claude did",\n'
        '  "filesChanged": ["list", "of", "files"] or [] if no changes,\n'
        '  "linesAdded": number or 0,\n'
        '  "linesRemoved": number or 0,\n'
        '  "confidence": "high" | "medium" | "low",\n'
        '  "issues": ["list of concerns, empty if none"],\n'
        '  "readyForPR": true | false (false if no code changes),\n'
        '  "nextSteps": "What should the developer do next",\n'
        '  "recommendation": "Brief recommendation",\n'
        '  "highlights": ["Notable good decisions or patterns"]\n'
        "}\n"
    )
    debug_log({
        "event": "review_prompt_built",
        "workspace": review_data.get("workspaceIndex"),
        "approved_count": approved_count,
        "flagged_count": flagged_count,
        "prompt_chars": len(prompt),
    })
    return prompt


def run_review_ollama(prompt, model=None):
    """Run a review using Ollama. Returns parsed dict or None."""
    model = model or OLLAMA_MODEL
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "think": False,
        "options": {"num_predict": 1200, "temperature": 0.1},
    }
    debug_log({"event": "review_ollama_start", "model": model})
    try:
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read())
        raw = result.get("response", "")
        parsed = parse_review_json(raw)
        if parsed is None:
            debug_log({"event": "review_ollama_parse_error", "model": model, "raw": raw[:2000]})
            return None, f"invalid JSON response from Ollama", model
        debug_log({"event": "review_ollama_success", "model": model})
        return parsed, "", model
    except urllib.error.HTTPError as e:
        msg = (f"Ollama returned {e.code}: model '{model}' not found — run 'ollama pull {model}'"
               if e.code == 404 else str(e))
        debug_log({"event": "review_ollama_error", "model": model, "error": msg})
        return None, msg, model
    except Exception as e:
        debug_log({"event": "review_ollama_error", "model": model, "error": str(e)})
        return None, str(e), model


def run_review_lmstudio(prompt, model=None, endpoint="http://100.89.93.84:1234"):
    """Run a review using LM Studio. Returns (parsed_dict, error_str, model_used)."""
    model = model or OLLAMA_MODEL
    try:
        with urllib.request.urlopen(f"{endpoint}/v1/models", timeout=5) as resp:
            models_data = json.loads(resp.read())
        loaded = models_data.get("data") or []
        if loaded and isinstance(loaded[0], dict):
            model = loaded[0].get("id", model) or model
    except Exception as e:
        debug_log({"event": "review_lmstudio_models_error", "error": str(e)})
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.1,
        "stream": False,
    }
    debug_log({"event": "review_lmstudio_start", "model": model})
    try:
        req = urllib.request.Request(
            f"{endpoint}/v1/chat/completions",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read())
        choices = result.get("choices") or []
        message = choices[0].get("message", {}) if choices else {}
        raw = message.get("content", "")
        parsed = parse_review_json(raw)
        if parsed is None:
            debug_log({"event": "review_lmstudio_parse_error", "model": model, "raw": raw[:2000]})
            return None, "invalid JSON response from LM Studio", model
        debug_log({"event": "review_lmstudio_success", "model": model})
        return parsed, "", model
    except Exception as e:
        debug_log({"event": "review_lmstudio_error", "model": model, "error": str(e)})
        return None, str(e), model


def run_review_claude(prompt, model_override=None):
    """Run a review using Claude CLI. Returns (parsed_dict, error_str, model_used).
    Falls back to Ollama if claude binary not found."""
    claude_bin = shutil.which("claude")
    if not claude_bin:
        debug_log({"event": "review_claude_missing", "fallback": "ollama"})
        return run_review_ollama(prompt, model=model_override)
    model_used = model_override or "claude"
    debug_log({"event": "review_claude_start", "binary": claude_bin})
    try:
        result = subprocess.run(
            [claude_bin, "--print", "-p", prompt],
            capture_output=True, text=True, timeout=120,
        )
        raw = (result.stdout or "").strip()
        if result.returncode != 0 and not raw:
            err = (result.stderr or "").strip() or f"claude exited with {result.returncode}"
            debug_log({"event": "review_claude_error", "error": err})
            return None, err, model_used
        parsed = parse_review_json(raw)
        if parsed is None:
            debug_log({"event": "review_claude_parse_error", "raw": raw[:2000]})
            return None, "invalid JSON response from Claude", model_used
        debug_log({"event": "review_claude_success"})
        return parsed, "", model_used
    except Exception as e:
        debug_log({"event": "review_claude_exception", "error": str(e)})
        return None, str(e), model_used


def run_review(review_path, review_model, review_backend, model_override=None, backend_override=None):
    """Orchestrate a full review: read file, call backend, write results.

    Args:
        review_path: Path to the review JSON file.
        review_model: Default model from engine config.
        review_backend: Default backend ("ollama", "lmstudio", "claude").
        model_override: Override model for this run.
        backend_override: Override backend for this run.
    """
    from pathlib import Path
    start_ts = time.time()
    path = Path(review_path)
    review_data = read_review_file(path)
    if review_data is None:
        debug_log({"event": "review_load_error", "path": str(path)})
        return

    review_data["reviewStatus"] = "reviewing"
    review_data.pop("reviewError", None)
    try:
        write_review_file(path, review_data)
    except OSError as e:
        debug_log({"event": "review_write_error", "path": str(path), "error": str(e)})
        return

    prompt = build_review_prompt(review_data)
    backend = backend_override or review_backend
    configured_model = model_override or review_model

    if backend == "lmstudio":
        review_result, error_msg, resolved_model = run_review_lmstudio(prompt, model=configured_model)
    elif backend == "ollama":
        review_result, error_msg, resolved_model = run_review_ollama(prompt, model=configured_model)
    else:
        review_result, error_msg, resolved_model = run_review_claude(prompt, model_override=configured_model)

    duration = round(time.time() - start_ts, 1)
    review_data = read_review_file(path) or review_data

    if review_result is None:
        review_data["reviewStatus"] = "error"
        review_data["reviewError"] = error_msg or "review backend failed"
        review_data["reviewDuration"] = duration
        review_data["reviewModel"] = resolved_model
        review_data["reviewedAt"] = datetime.now(timezone.utc).isoformat()
        try:
            write_review_file(path, review_data)
        except OSError:
            pass
        debug_log({"event": "review_failed", "path": str(path), "backend": backend})
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
        write_review_file(path, review_data)
    except OSError:
        pass
    debug_log({"event": "review_completed", "path": str(path), "backend": backend, "duration": duration})
```

- [ ] **Step 2: Verify the module imports cleanly**

Run: `python -c "from cmux_harness.review import build_review_prompt, parse_review_json, run_review; print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add cmux_harness/review.py
git commit -m "refactor: extract review module (backends, prompt builder, orchestrator)"
```

---

## Task 5: Extract engine module

**Files:**
- Create: `cmux_harness/engine.py`

The `HarnessEngine` class moves here. It becomes smaller since review logic is now in `review.py`, detection is in `detection.py`, and storage is in `storage.py`. The engine imports from those modules instead of defining everything inline.

- [ ] **Step 1: Create `cmux_harness/engine.py`**

This is the largest module. Extract `HarnessEngine` from dashboard.py lines 578-1681. Replace inline method calls with imports from extracted modules.

Key changes from the original:
- `self._run_review(...)` becomes `review.run_review(path, self.review_model, self.review_backend, ...)`
- `self._build_review_prompt(...)` is removed (lives in review.py)
- `self._run_review_ollama/lmstudio/claude(...)` are removed (live in review.py)
- `self._parse_review_json(...)` is removed (lives in review.py)
- `self._write_review_file(...)` becomes `storage.write_review_file(...)`
- `self._load_config()` becomes `storage.load_config()`
- `self._save_config()` becomes `storage.save_config(self.ws_config, ...)`
- `_detect_claude_session(screen)` becomes `detection.detect_claude_session(screen)`
- `detect_prompt(screen)` becomes `detection.detect_prompt(screen, model=self.model, ollama_available_checker=self._check_ollama)`
- `_parse_session_cost(screen)` becomes `storage.parse_session_cost(screen)`
- `fingerprint(screen)` becomes `detection.fingerprint(screen)`
- `_debug_log(...)` becomes `storage.debug_log(...)`

```python
"""HarnessEngine: background thread that polls cmux workspaces and auto-approves prompts."""

import os
import re
import subprocess
import threading
import time
from datetime import datetime, timezone

from . import cmux_api
from . import detection
from . import review as review_mod
from . import storage


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
        self.screen_cache = {}
        self.ws_has_claude = {}
        self.idle_last_read = {}
        self.session_start = {}
        self.session_cost = {}
        self.session_ids = {}
        self.surface_map = {}
        self.surface_map_ts = 0
        self.socket_connected = False
        self.last_successful_poll = 0
        self.connection_lost_at = 0
        self.consecutive_failures = 0
        self._lock = threading.Lock()
        self.model = detection.OLLAMA_MODEL
        self.review_enabled = True
        self.review_model = detection.OLLAMA_MODEL
        self.review_backend = "ollama"
        self.ollama_available = None
        self.ollama_last_check = 0
        self.ollama_retry_interval = 60
        config = storage.load_config()
        self.ws_config = config.get("workspaces", {})
        review_settings = config.get("reviewSettings", {})
        if isinstance(review_settings, dict):
            self.review_enabled = bool(review_settings.get("enabled", self.review_enabled))
            self.review_model = review_settings.get("model", self.review_model) or self.review_model
            self.review_backend = review_settings.get("backend", self.review_backend) or self.review_backend

    # --- The rest of the engine methods follow the same pattern ---
    # All methods from dashboard.py HarnessEngine are kept, but with
    # internal calls replaced by module-level function calls as described above.
    # See the full engine.py code in the implementation.
```

Due to the size of this module (~650 lines even after extraction), the full implementation is created by:
1. Copying `HarnessEngine` from dashboard.py (lines 578-1681)
2. Replacing all internal references with module imports as listed above
3. Removing methods that moved to `review.py` (`_build_review_prompt`, `_run_review_ollama`, `_run_review_lmstudio`, `_run_review_claude`, `_run_review`, `_parse_review_json`, `_write_review_file`, `_set_review_error`, `_pop_review_error`, `_set_review_model_used`, `_pop_review_model_used`)

The engine keeps: `__init__`, `_build_virtual_workspaces`, `_check_ollama`, `set_enabled`, `set_workspace_enabled`, `set_poll_interval`, `set_model`, `set_review_config`, `set_custom_name`, `get_status`, `get_log`, `_append_log`, `_run_git_command`, `_get_workspace_cwd`, `get_git_status`, `_get_session_approval_log`, `_capture_completion_snapshot`, `_capture_completion_snapshot_async`, `refresh_workspaces`, `get_workspaces_needing_attention`, `check_workspace`, `run`.

In `_capture_completion_snapshot`, replace:
```python
# Old:
self._run_review(path)
# New:
review_mod.run_review(path, self.review_model, self.review_backend)
```

In `check_workspace`, replace:
```python
# Old:
result = detect_prompt(screen)
# New:
result = detection.detect_prompt(screen, model=self.model, ollama_available_checker=self._check_ollama)
```

- [ ] **Step 2: Verify the module imports cleanly**

Run: `python -c "from cmux_harness.engine import HarnessEngine; print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add cmux_harness/engine.py
git commit -m "refactor: extract engine module (HarnessEngine background thread)"
```

---

## Task 6: Extract HTML template and server module

**Files:**
- Create: `cmux_harness/static/dashboard.html`
- Create: `cmux_harness/server.py`

- [ ] **Step 1: Extract `dashboard.html`**

Copy the HTML content from dashboard.py lines 1688-3770 (the content of the `DASHBOARD_HTML` string, without the Python string delimiters) to `cmux_harness/static/dashboard.html`.

The content starts with `<!DOCTYPE html>` and ends with `</html>`.

- [ ] **Step 2: Create `cmux_harness/server.py`**

The HTTP handler moves here. The key change: replace the `_engine` global with a factory function `make_handler(engine)` that returns a handler class with the engine reference bound.

```python
"""HTTP server and REST API for the dashboard."""

import json
import os
import shutil
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler
from pathlib import Path

from . import cmux_api
from . import storage
from .detection import OLLAMA_URL

# Load HTML template once at import time
_STATIC_DIR = Path(__file__).parent / "static"
_HTML_PATH = _STATIC_DIR / "dashboard.html"
try:
    DASHBOARD_HTML = _HTML_PATH.read_text(encoding="utf-8")
except FileNotFoundError:
    DASHBOARD_HTML = "<html><body><h1>dashboard.html not found</h1></body></html>"


def make_handler(engine):
    """Create a DashboardHandler class bound to the given engine instance.
    This avoids module-level globals."""

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
                self._json_response(engine.get_status())
            elif self.path == "/api/log":
                self._json_response(engine.get_log())
            elif self.path.startswith("/api/git-status"):
                qs = urllib.parse.urlparse(self.path).query
                params = urllib.parse.parse_qs(qs)
                idx_str = params.get("index", [None])[0]
                if idx_str is None:
                    self._json_response({"ok": False, "error": "index required"}, 400)
                    return
                result = engine.get_git_status(int(idx_str))
                if result is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                result["ok"] = True
                self._json_response(result)
            elif self.path == "/api/reviews":
                reviews = []
                for review in storage.list_reviews():
                    item = dict(review)
                    item["gitDiff"] = (item.get("gitDiff") or "")[:500]
                    reviews.append(item)
                self._json_response(reviews)
            elif self.path.startswith("/api/reviews/"):
                session_id = urllib.parse.unquote(self.path[len("/api/reviews/"):])
                review = storage.get_review(session_id)
                if review is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                self._json_response(review)
            elif self.path == "/api/config":
                with engine._lock:
                    self._json_response({
                        "pollInterval": engine.poll_interval,
                        "model": engine.model,
                        "reviewEnabled": engine.review_enabled,
                        "reviewModel": engine.review_model,
                        "reviewBackend": engine.review_backend,
                    })
            elif self.path == "/api/models":
                # ... (same logic as original, using engine reference)
                pass  # Full implementation copies the original logic
            else:
                self.send_error(404)

        def do_POST(self):
            data = self._read_body()
            # ... (same logic as original, using engine reference)
            # Full implementation copies all POST handlers from dashboard.py

    return DashboardHandler
```

The full `do_GET` and `do_POST` methods are copied directly from the original `DashboardHandler` in dashboard.py lines 3801-4163, with `_engine` replaced by the closure-captured `engine` variable.

- [ ] **Step 3: Verify the module imports cleanly**

Run: `python -c "from cmux_harness.server import make_handler; print('OK')"`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add cmux_harness/static/dashboard.html cmux_harness/server.py
git commit -m "refactor: extract server module and HTML template"
```

---

## Task 7: Rewrite dashboard.py as thin entry point

**Files:**
- Modify: `dashboard.py`

Replace the 4,185-line monolith with a ~30-line entry point that imports from the package.

- [ ] **Step 1: Replace dashboard.py contents**

```python
#!/usr/bin/env python3
"""cmux Auto-Approve Dashboard — entry point."""

import sys
import webbrowser
from http.server import HTTPServer

from cmux_harness.engine import HarnessEngine
from cmux_harness.server import make_handler


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9090

    engine = HarnessEngine()
    engine.start()

    handler_class = make_handler(engine)

    print(f"⚡ cmux Auto-Approve Dashboard: http://localhost:{port}")
    webbrowser.open(f"http://localhost:{port}")

    server = HTTPServer(("0.0.0.0", port), handler_class)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify the app starts**

Run: `python dashboard.py --help 2>&1 || python -c "from cmux_harness.engine import HarnessEngine; from cmux_harness.server import make_handler; print('Package imports OK')"`
Expected: `Package imports OK` (full startup requires cmux to be running)

- [ ] **Step 3: Commit**

```bash
git add dashboard.py
git commit -m "refactor: dashboard.py is now a thin entry point importing from cmux_harness package"
```

---

## Task 8: Write detection tests (TDD for most critical logic)

**Files:**
- Create: `tests/test_detection.py`

The detection module is the highest-risk code: misclassifications could auto-approve dangerous actions or miss real prompts. These tests cover the pure functions.

- [ ] **Step 1: Write tests for `detect_claude_session`**

```python
"""Tests for cmux_harness.detection module."""

import unittest
from cmux_harness.detection import (
    detect_claude_session,
    fingerprint,
    is_permission_menu,
)


class TestDetectClaudeSession(unittest.TestCase):
    def test_detects_idle_repl(self):
        screen = "Some output\n❯\nModel: Opus 4  Cost: $0.45  Ctx: 12k"
        self.assertTrue(detect_claude_session(screen))

    def test_detects_thinking(self):
        screen = "Processing request...\nMusing..."
        self.assertTrue(detect_claude_session(screen))

    def test_detects_tool_use(self):
        screen = "Working on it\n⚡ Read file.py"
        self.assertTrue(detect_claude_session(screen))

    def test_detects_permission_prompt(self):
        screen = "Allow Read access to /path/to/file? (Y/n)"
        self.assertTrue(detect_claude_session(screen))

    def test_plain_shell_prompt(self):
        screen = "user@host ~ %"
        self.assertFalse(detect_claude_session(screen))

    def test_empty_screen(self):
        self.assertFalse(detect_claude_session(""))
        self.assertFalse(detect_claude_session(None))

    def test_detects_claude_command_in_history(self):
        screen = "$ claude\nStarting Claude Code..."
        self.assertTrue(detect_claude_session(screen))
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `python -m unittest tests/test_detection.py -v`
Expected: All tests PASS (these test existing behavior, not new behavior)

- [ ] **Step 3: Write tests for `is_permission_menu`**

Add to the same file:

```python
class TestIsPermissionMenu(unittest.TestCase):
    def test_yes_no_menu(self):
        options = "1. Yes\n2. No\n3. Type something else"
        self.assertTrue(is_permission_menu(options))

    def test_allow_menu(self):
        options = "1. Yes, allow reading from /src\n2. No\n3. Type something else"
        self.assertTrue(is_permission_menu(options))

    def test_domain_specific_menu(self):
        options = "1. src/main.py\n2. src/utils.py\n3. tests/test.py"
        self.assertFalse(is_permission_menu(options))

    def test_mixed_menu_with_file_choice(self):
        options = "1. Yes\n2. No\n3. Pick a different file"
        self.assertFalse(is_permission_menu(options))

    def test_all_permission_variants(self):
        options = '1. Yes, and don\'t ask again for: bash\n2. Yes, allow from this project\n3. No\n4. Type something else'
        self.assertTrue(is_permission_menu(options))

    def test_empty_options(self):
        self.assertFalse(is_permission_menu(""))
```

- [ ] **Step 4: Run tests again**

Run: `python -m unittest tests/test_detection.py -v`
Expected: All tests PASS

- [ ] **Step 5: Write tests for `fingerprint`**

```python
class TestFingerprint(unittest.TestCase):
    def test_same_input_same_hash(self):
        screen = "line 1\nline 2\nline 3\nline 4\nline 5"
        self.assertEqual(fingerprint(screen), fingerprint(screen))

    def test_different_input_different_hash(self):
        screen1 = "line 1\nline 2\nline 3\nline 4\nline 5"
        screen2 = "line 1\nline 2\nline 3\nline 4\nline 6"
        self.assertNotEqual(fingerprint(screen1), fingerprint(screen2))

    def test_only_last_5_lines_matter(self):
        screen1 = "header\nline 1\nline 2\nline 3\nline 4\nline 5"
        screen2 = "different header\nline 1\nline 2\nline 3\nline 4\nline 5"
        self.assertEqual(fingerprint(screen1), fingerprint(screen2))

    def test_short_screen(self):
        screen = "only two\nlines"
        fp = fingerprint(screen)
        self.assertIsInstance(fp, str)
        self.assertEqual(len(fp), 32)  # MD5 hex digest
```

- [ ] **Step 6: Run all detection tests**

Run: `python -m unittest tests/test_detection.py -v`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add tests/test_detection.py
git commit -m "test: add unit tests for detection module (session detection, menus, fingerprint)"
```

---

## Task 9: Write storage tests

**Files:**
- Create: `tests/test_storage.py`

Test the pure functions in storage: `parse_session_cost`.

- [ ] **Step 1: Write tests for `parse_session_cost`**

```python
"""Tests for cmux_harness.storage module."""

import unittest
from cmux_harness.storage import parse_session_cost


class TestParseSessionCost(unittest.TestCase):
    def test_cost_line(self):
        screen = "Some output\nMore output\nCost: $1.23"
        self.assertEqual(parse_session_cost(screen), "$1.23")

    def test_money_bag_emoji(self):
        screen = "Output\n\U0001f4b0$0.45"
        self.assertEqual(parse_session_cost(screen), "$0.45")

    def test_block_format(self):
        screen = "Status line\n$2.50 block"
        self.assertEqual(parse_session_cost(screen), "$2.50")

    def test_bare_cost(self):
        screen = "Some line\n$0.00"
        self.assertEqual(parse_session_cost(screen), "$0.00")

    def test_no_cost(self):
        screen = "Just a normal terminal\nWith no cost info"
        self.assertIsNone(parse_session_cost(screen))

    def test_empty_input(self):
        self.assertIsNone(parse_session_cost(""))
        self.assertIsNone(parse_session_cost(None))

    def test_cost_in_last_5_lines(self):
        # Cost must be in the last 5 lines (where statusline renders)
        lines = ["line " + str(i) for i in range(20)]
        lines.append("Cost: $3.14")
        screen = "\n".join(lines)
        self.assertEqual(parse_session_cost(screen), "$3.14")

    def test_cost_too_far_up(self):
        # If cost is beyond the last 5 lines, it shouldn't be found
        lines = ["Cost: $3.14"]
        lines.extend(["regular line " + str(i) for i in range(10)])
        screen = "\n".join(lines)
        self.assertIsNone(parse_session_cost(screen))
```

- [ ] **Step 2: Run tests**

Run: `python -m unittest tests/test_storage.py -v`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_storage.py
git commit -m "test: add unit tests for storage module (session cost parsing)"
```

---

## Task 10: Write review tests

**Files:**
- Create: `tests/test_review.py`

Test `parse_review_json` and `build_review_prompt` (pure functions).

- [ ] **Step 1: Write tests for `parse_review_json`**

```python
"""Tests for cmux_harness.review module."""

import unittest
from cmux_harness.review import parse_review_json, build_review_prompt


class TestParseReviewJson(unittest.TestCase):
    def test_clean_json(self):
        raw = '{"summary": "Did stuff", "confidence": "high"}'
        result = parse_review_json(raw)
        self.assertEqual(result["summary"], "Did stuff")
        self.assertEqual(result["confidence"], "high")

    def test_json_in_markdown_fence(self):
        raw = '```json\n{"summary": "test"}\n```'
        result = parse_review_json(raw)
        self.assertEqual(result["summary"], "test")

    def test_json_with_leading_text(self):
        raw = 'Here is my review:\n{"summary": "test"}'
        result = parse_review_json(raw)
        self.assertEqual(result["summary"], "test")

    def test_empty_input(self):
        self.assertIsNone(parse_review_json(""))
        self.assertIsNone(parse_review_json(None))

    def test_no_json(self):
        self.assertIsNone(parse_review_json("just plain text"))

    def test_invalid_json(self):
        self.assertIsNone(parse_review_json("{not valid json}"))

    def test_non_dict_json(self):
        self.assertIsNone(parse_review_json("[1, 2, 3]"))


class TestBuildReviewPrompt(unittest.TestCase):
    def test_includes_workspace_name(self):
        data = {"workspaceName": "my-project", "approvalLog": []}
        prompt = build_review_prompt(data)
        self.assertIn("my-project", prompt)

    def test_includes_diff_when_present(self):
        data = {
            "workspaceName": "test",
            "gitDiff": "diff --git a/foo.py",
            "gitDiffStat": "1 file changed",
            "approvalLog": [],
        }
        prompt = build_review_prompt(data)
        self.assertIn("Git diff summary", prompt)
        self.assertIn("Full diff", prompt)

    def test_no_diff_section_when_empty(self):
        data = {"workspaceName": "test", "gitDiff": "", "approvalLog": []}
        prompt = build_review_prompt(data)
        self.assertIn("No uncommitted code changes detected", prompt)

    def test_counts_approvals_and_flags(self):
        data = {
            "workspaceName": "test",
            "approvalLog": [
                {"action": "sent Enter"},
                {"action": "sent y"},
                {"action": "⚠ needs human"},
            ],
        }
        prompt = build_review_prompt(data)
        self.assertIn("Actions auto-approved: 2", prompt)
        self.assertIn("Actions flagged for human: 1", prompt)
```

- [ ] **Step 2: Run tests**

Run: `python -m unittest tests/test_review.py -v`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_review.py
git commit -m "test: add unit tests for review module (JSON parsing, prompt builder)"
```

---

## Task 11: Update eval_models.py imports

**Files:**
- Modify: `eval_models.py` (if it imports from dashboard.py)

- [ ] **Step 1: Check if eval_models.py imports from dashboard.py**

Run: `grep -n "import.*dashboard\|from dashboard" eval_models.py`

If no imports found, skip this task. If imports are found, update them to use the new package paths.

- [ ] **Step 2: Commit if changes were made**

```bash
git add eval_models.py
git commit -m "refactor: update eval_models.py imports for new package structure"
```

---

## Task 12: Final integration test

- [ ] **Step 1: Run all unit tests**

Run: `python -m unittest discover tests -v`
Expected: All tests PASS

- [ ] **Step 2: Verify the dashboard starts without cmux**

Run: `python -c "from cmux_harness.engine import HarnessEngine; from cmux_harness.server import make_handler; print('All package imports OK')"`
Expected: `All package imports OK`

- [ ] **Step 3: Verify with cmux running (manual)**

Start the dashboard with `python dashboard.py` and confirm:
- Dashboard loads in browser
- Workspace cards appear
- Terminal preview renders
- Auto-approve toggle works
- Reviews tab loads

- [ ] **Step 4: Final commit with any integration fixes**

```bash
git add -A
git commit -m "refactor: complete dashboard.py monolith breakup into cmux_harness package"
```

---

## Summary

| Before | After |
|---|---|
| 1 file, 4,185 lines | 7 modules + HTML template + 3 test files |
| 0 unit tests | ~30 unit tests covering detection, storage, review |
| Global `_engine` coupling | Handler factory pattern, explicit parameters |
| HTML embedded in Python string | Separate `.html` file loaded at runtime |
| All logic in one class | Focused modules with clear boundaries |

The refactoring is purely structural. No behavior changes, no new features. Every function keeps its exact logic, just moves to its proper home.
