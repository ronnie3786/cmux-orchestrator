"""Low-level cmux socket and CLI helpers."""

import json
import logging
import os
import socket
import subprocess
import time as _time

log = logging.getLogger(__name__)

CMUX_APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/cmux")
CMUX_LAST_SOCKET_PATH_FILE = os.path.join(CMUX_APP_SUPPORT_DIR, "last-socket-path")
CMUX_DEFAULT_SOCKET_PATH = os.path.join(CMUX_APP_SUPPORT_DIR, "cmux.sock")
CMUX_STATE_DIR = os.path.expanduser("~/.local/state/cmux")
CMUX_STATE_LAST_SOCKET_PATH_FILE = os.path.join(CMUX_STATE_DIR, "last-socket-path")
CMUX_STATE_SOCKET_PATH = os.path.join(CMUX_STATE_DIR, "cmux.sock")
_LAST_WORKING_SOCKET_PATH = None

_TERMINAL_KEY_ALIASES = {
    "arrowleft": "left",
    "arrow-left": "left",
    "arrowright": "right",
    "arrow-right": "right",
    "esc": "escape",
    "bckspc": "backspace",
    "del": "backspace",
    "delete": "backspace",
}

def _normalize_terminal_key(key):
    value = str(key or "").strip().lower()
    return _TERMINAL_KEY_ALIASES.get(value, value)


def _send_v2_text(workspace_uuid, text, surface_id=None):
    params = {"workspace_id": workspace_uuid, "text": text}
    if surface_id:
        params["surface_id"] = surface_id
    return _v2_request("surface.send_text", params) is not None


def _send_v2_key(workspace_uuid, key, surface_id=None):
    params = {"workspace_id": workspace_uuid, "key": key}
    if surface_id:
        params["surface_id"] = surface_id
    return _v2_request("surface.send_key", params) is not None

# ---------------------------------------------------------------------------
# cmux socket helpers
# ---------------------------------------------------------------------------

def _normalize_socket_path(path):
    value = os.path.expanduser(str(path or "").strip())
    return value or None


def _add_socket_candidate(candidates, seen, path):
    normalized = _normalize_socket_path(path)
    if not normalized or normalized in seen or not os.path.exists(normalized):
        return
    candidates.append(normalized)
    seen.add(normalized)


def _read_socket_path_file(path):
    try:
        with open(path, encoding="utf-8") as file:
            return file.read().strip()
    except OSError:
        return None


def _read_last_socket_path():
    return _read_socket_path_file(CMUX_LAST_SOCKET_PATH_FILE)


def _add_tagged_sockets(candidates, seen, directory):
    tagged_sockets = []
    try:
        for name in os.listdir(directory):
            if not name.startswith("cmux") or not name.endswith(".sock"):
                continue
            path = os.path.join(directory, name)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                mtime = 0
            tagged_sockets.append((mtime, path))
    except OSError:
        return

    for _, path in sorted(tagged_sockets, key=lambda item: item[0], reverse=True):
        _add_socket_candidate(candidates, seen, path)


def _socket_candidate_paths():
    candidates = []
    seen = set()
    _add_socket_candidate(candidates, seen, os.environ.get("CMUX_SOCKET_PATH"))

    _add_socket_candidate(candidates, seen, _read_socket_path_file(CMUX_STATE_LAST_SOCKET_PATH_FILE))
    _add_socket_candidate(candidates, seen, _read_last_socket_path())

    _add_tagged_sockets(candidates, seen, CMUX_STATE_DIR)
    _add_tagged_sockets(candidates, seen, CMUX_APP_SUPPORT_DIR)

    _add_socket_candidate(candidates, seen, CMUX_STATE_SOCKET_PATH)
    _add_socket_candidate(candidates, seen, CMUX_DEFAULT_SOCKET_PATH)
    _add_socket_candidate(candidates, seen, "/tmp/cmux.sock")
    return candidates


def _cmux_send(sock, command, timeout=3):
    """Send a command string to a cmux Unix socket and return the response."""
    sock.sendall((command + "\n").encode())
    chunks = []
    sock.settimeout(timeout)
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


def _socket_responds_to_ping(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
        req = json.dumps({"id": "harness-socket-probe", "method": "system.ping", "params": {}})
        raw = _cmux_send(sock, req, timeout=0.75)
        if not raw:
            return False
        if raw.strip() == "PONG":
            return True
        parsed = json.loads(raw)
        return bool(parsed.get("ok"))
    except (OSError, json.JSONDecodeError):
        return False
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


def _find_socket_path():
    global _LAST_WORKING_SOCKET_PATH
    candidates = []
    seen = set()
    _add_socket_candidate(candidates, seen, _LAST_WORKING_SOCKET_PATH)
    for candidate in _socket_candidate_paths():
        _add_socket_candidate(candidates, seen, candidate)
    for candidate in candidates:
        if _socket_responds_to_ping(candidate):
            _LAST_WORKING_SOCKET_PATH = candidate
            return candidate
    _LAST_WORKING_SOCKET_PATH = None
    return None


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
        err = parsed.get("error", raw[:200])
        if method == "surface.read_text" and "not a terminal" in str(err).lower():
            return None
        log.warning("cmux v2 %s failed: %s", method, err)
        return None
    except (OSError, json.JSONDecodeError) as exc:
        log.warning("cmux v2 %s error: %s", method, exc)
        return None
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


def cmux_read_workspace(ws_index, surface_index=0, lines=40, workspace_uuid=None, surface_id=None):
    """Read terminal text from a workspace WITHOUT switching to it.
    Uses the v2 JSON-RPC API with workspace_id parameter.
    When surface_id is provided (e.g. 'surface:2'), reads that specific surface."""
    if workspace_uuid:
        params = {"workspace_id": workspace_uuid, "lines": lines}
        if surface_id:
            params["surface_id"] = surface_id
        result = _v2_request("surface.read_text", params)
        if result:
            text = result.get("text", "")
            if text:
                return text
            # Fallback: decode base64 if text field is empty
            import base64 as _b64
            b64 = result.get("base64", "")
            if b64:
                return _b64.b64decode(b64).decode(errors="replace")
            return ""
        # v2 failed — return None instead of falling back to v1
        # (v1 uses select_workspace which visibly switches the active tab)
        return None
    return None


def ensure_workspace_terminal_ready(workspace_uuid=None, surface_id=None):
    """Ask cmux to materialize/focus a terminal surface before read/write.

    Some cmux workspaces lazily start the underlying TTY when the workspace or
    surface is first focused. The harness needs the same warm-up behavior when
    it reads/sends from the dashboard without the user manually opening cmux.
    """
    if not workspace_uuid and not surface_id:
        return False

    focus_params = {}
    focus_surface_id = surface_id
    if workspace_uuid:
        data = _v2_request("system.tree", {"all": True})
        if isinstance(data, dict):
            for win in data.get("windows", []):
                for ws in win.get("workspaces", []):
                    if ws.get("uuid") != workspace_uuid and ws.get("id") != workspace_uuid:
                        continue
                    for pane in ws.get("panes", []):
                        for surf in pane.get("surfaces", []):
                            if surf.get("type") != "terminal":
                                continue
                            if not focus_surface_id or focus_surface_id in {surf.get("ref"), surf.get("id")}:
                                focus_surface_id = surf.get("id") or surf.get("ref") or focus_surface_id
                                break
                        if focus_surface_id:
                            break
                    break
                if focus_surface_id:
                    break

    focused = False
    if workspace_uuid:
        focus_params["workspace_id"] = workspace_uuid
    if focus_surface_id:
        focus_params["surface_id"] = focus_surface_id

    if focus_params and _v2_request("surface.focus", focus_params) is not None:
        focused = True
    if workspace_uuid and _v2_request("workspace.select", {"workspace_id": workspace_uuid}) is not None:
        focused = True

    if focused:
        _v2_request("surface.refresh", {})
    return focused


def cmux_read_workspace_warm(ws_index, surface_index=0, lines=40, workspace_uuid=None, surface_id=None):
    """Read a workspace, warming the target terminal if the first read is empty."""
    screen = cmux_read_workspace(
        ws_index,
        surface_index=surface_index,
        lines=lines,
        workspace_uuid=workspace_uuid,
        surface_id=surface_id,
    )
    if screen:
        return screen
    if not ensure_workspace_terminal_ready(workspace_uuid=workspace_uuid, surface_id=surface_id):
        return screen
    _time.sleep(0.15)
    return cmux_read_workspace(
        ws_index,
        surface_index=surface_index,
        lines=lines,
        workspace_uuid=workspace_uuid,
        surface_id=surface_id,
    )


def cmux_send_to_workspace(ws_index, surface_index, text=None, key=None, workspace_uuid=None, surface_id=None):
    """Send text or a key to a surface WITHOUT switching workspaces.
    Uses the v2 JSON-RPC API with workspace_id parameter.
    When surface_id is provided (e.g. 'surface:2'), targets that specific surface."""
    if workspace_uuid:
        if text is not None:
            return _send_v2_text(workspace_uuid, text, surface_id=surface_id)
        if key is not None:
            normalized_key = _normalize_terminal_key(key)
            return _send_v2_key(workspace_uuid, normalized_key, surface_id=surface_id)
    # No workspace_uuid provided and no v1 fallback — v1 used select_workspace
    # which visibly switches the active tab, causing UI flickering.
    return False


def _try_tmux_paste(pane_ref, text):
    """Inject text via tmux load-buffer + paste-buffer + Enter.
    This is more reliable than send-keys -l for long or multi-line text.
    Returns True on success, False on any failure."""
    buf_name = f"harness-{int(_time.time() * 1000)}"
    try:
        r = subprocess.run(
            ["tmux", "load-buffer", "-b", buf_name, "-"],
            input=text.encode(),
            capture_output=True,
            timeout=5,
        )
        if r.returncode != 0:
            return False
        r = subprocess.run(
            ["tmux", "paste-buffer", "-b", buf_name, "-t", pane_ref, "-d"],
            capture_output=True,
            timeout=5,
        )
        if r.returncode != 0:
            # Clean up buffer if paste failed
            subprocess.run(["tmux", "delete-buffer", "-b", buf_name], capture_output=True, timeout=3)
            return False
        r = subprocess.run(
            ["tmux", "send-keys", "-t", pane_ref, "Enter"],
            capture_output=True,
            timeout=5,
        )
        return r.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def _find_pane_ref_for_workspace(workspace_uuid):
    """Look up the first pane ref for a workspace UUID.
    Returns a pane ref string if found, or None."""
    data = _v2_request("system.tree", {"all": True})
    if not data:
        return None
    for win in data.get("windows", []):
        for ws in win.get("workspaces", []):
            if ws.get("uuid") == workspace_uuid or ws.get("id") == workspace_uuid:
                panes = ws.get("panes", [])
                if panes:
                    return panes[0].get("ref")
    return None


def send_prompt_to_workspace(workspace_uuid, text, surface_id=None):
    """Send a prompt to a workspace and submit it.

    Mirrors WebMux's sendPrompt() approach: try tmux paste-buffer for atomic,
    reliable delivery of long/multi-line text; fall back to surface.send_text +
    surface.send_key("enter") as separate calls. Never embeds newline in send_text
    (cmux does not interpret \\n as Enter).

    Returns True if the submit key was sent successfully.
    """
    # Validate workspace exists in the system tree before sending anything.
    # Without this check, a stale UUID can cause the v2 API fallback to
    # route the command to the wrong panel (e.g. the currently active one).
    data = _v2_request("system.tree", {"all": True})
    pane_ref = None
    workspace_found = False
    if data:
        for win in data.get("windows", []):
            for ws in win.get("workspaces", []):
                if ws.get("uuid") == workspace_uuid or ws.get("id") == workspace_uuid:
                    workspace_found = True
                    panes = ws.get("panes", [])
                    if panes:
                        pane_ref = panes[0].get("ref")
                    break
            if workspace_found:
                break

    if data is not None and not workspace_found:
        log.warning(
            "send_prompt_to_workspace: workspace %s not in system tree — "
            "aborting to avoid misrouted command",
            workspace_uuid,
        )
        return False

    # Attempt 1: tmux paste-buffer (atomic, handles long text)
    if pane_ref:
        if _try_tmux_paste(pane_ref, text):
            return True

    # Attempt 2: cmux v2 send_text + send_key("enter") — always separate calls
    params = {"workspace_id": workspace_uuid, "text": text}
    if surface_id:
        params["surface_id"] = surface_id
    send_result = _v2_request("surface.send_text", params)
    if send_result is None:
        log.warning(
            "send_prompt_to_workspace: send_text failed for workspace %s — "
            "not sending enter key",
            workspace_uuid,
        )
        return False
    _time.sleep(0.15)
    key_params = {"workspace_id": workspace_uuid, "key": "enter"}
    if surface_id:
        key_params["surface_id"] = surface_id
    result = _v2_request("surface.send_key", key_params)
    return result is not None


# Virtual index scheme: workspace idx 0 with 3 surfaces becomes idx 0, 10000, 10001.
# Real index stays at position 0; additional surfaces start at VIRTUAL_BASE + real_idx * STRIDE.
VIRTUAL_BASE = 10000
VIRTUAL_STRIDE = 100

SURFACE_MAP_TTL = 15  # seconds between cmux tree --all --json refreshes


def _parse_tree_data(data):
    """Parse a cmux tree JSON structure into a surface map.
    Returns {workspace_index: [{"ref", "title", "pane_ref", "selected_in_pane", "id"}]}
    or {} if the data is invalid."""
    if not data or not isinstance(data, dict):
        return {}
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
                        "id": surf.get("id", ""),
                        "title": surf.get("title", ""),
                        "pane_ref": pane_ref,
                        "selected_in_pane": surf.get("selected_in_pane", False),
                    })
            if surfaces:
                result[ws_idx] = surfaces
    return result


def cmux_tree():
    """Fetch the full workspace/pane/surface hierarchy.
    Prefers v2 socket API; falls back to CLI subprocess.
    Returns {workspace_index: [{"ref", "title", "pane_ref", ...}]} or None on failure."""
    # Try v2 socket API first (no subprocess overhead)
    data = _v2_request("system.tree", {"all": True})
    if data is not None:
        result = _parse_tree_data(data)
        if result:
            return result
    # Fallback to CLI subprocess
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
    return _parse_tree_data(data) or None


def _parse_notifications(result):
    """Parse a notification.list v2 response into a list of notification dicts.
    Each dict has: id, workspace_id, surface_id, title, subtitle, body, is_read."""
    if result is None:
        return []
    if isinstance(result, list):
        notifications = result
    elif isinstance(result, dict):
        notifications = result.get("notifications", [])
    else:
        return []
    return [n for n in notifications if isinstance(n, dict)]


def cmux_notifications():
    """Fetch notifications via v2 API.
    Returns a list of notification dicts or None on failure."""
    result = _v2_request("notification.list", {})
    if result is None:
        return None
    return _parse_notifications(result)


def cmux_mark_notifications_read(workspace_id=None, surface_id=None):
    """Mark notifications as read for a workspace or surface via v2 API.

    Tries ``notification.mark_read`` first (not all cmux versions support it).
    Then focuses the target surface so the native cmux app marks its
    notifications as read — the same thing that happens when a user clicks
    into a pane in the desktop app.

    Returns True if either approach succeeded, False if both failed.
    """
    params = {}
    if workspace_id:
        params["workspace_id"] = workspace_id
    if surface_id:
        params["surface_id"] = surface_id

    marked = False
    if params:
        result = _v2_request("notification.mark_read", params)
        if result is not None:
            marked = True

    focused = ensure_workspace_terminal_ready(
        workspace_uuid=workspace_id,
        surface_id=surface_id,
    )
    return marked or focused


def _first_present(item, keys, default=""):
    for key in keys:
        value = item.get(key)
        if value is not None and value != "":
            return value
    return default


def _feed_sources(item):
    """Return the Feed envelope followed by its optional hook event."""
    if not isinstance(item, dict):
        return []
    sources = [item]
    event = item.get("event")
    if isinstance(event, dict):
        sources.append(event)
    return sources


def _first_feed_present(item, keys, default=""):
    for source in _feed_sources(item):
        value = _first_present(source, keys, None)
        if value is not None and value != "":
            return value
    return default


def _infer_feed_kind(item):
    hook_event_name = str(_first_feed_present(item, ["hook_event_name", "hookEventName"], "")).strip()
    hook_kind = hook_event_name.lower().replace("-", "_").replace(" ", "_")
    if hook_kind == "permissionrequest":
        return "permission"
    if hook_kind == "exitplanmode":
        return "plan"
    if hook_kind == "askuserquestion":
        return "question"

    raw_kind = str(_first_feed_present(
        item,
        ["kind", "type", "request_type", "requestType", "category"],
        "",
    )).strip()
    normalized = raw_kind.lower().replace("-", "_").replace(" ", "_")
    if "permission" in normalized:
        return "permission"
    if "exit_plan" in normalized or "plan" in normalized:
        return "plan"
    if "question" in normalized or "select" in normalized:
        return "question"
    return normalized or "item"


def _is_actionable_feed_item(item):
    """Return True for feed entries that can currently be replied to.

    ``feed.list`` includes historical telemetry such as toolUse, toolResult,
    sessionStart, and expired requests. The harness UI should only surface
    unresolved requests supported by the feed reply methods.
    """
    if not isinstance(item, dict):
        return False

    kind = _infer_feed_kind(item)
    if kind not in {"permission", "plan", "question"}:
        return False

    request_id = str(_first_feed_present(item, [
        "request_id", "requestId", "requestID", "_opencode_request_id",
    ], "") or "").strip()
    if not request_id:
        return False

    if _first_feed_present(item, ["resolved_at", "resolvedAt"], None):
        return False

    status = str(_first_feed_present(item, ["status", "state"], "") or "").strip().lower()
    if status in {"telemetry", "expired", "resolved", "approved", "denied", "rejected", "completed"}:
        return False

    return True


def _string_option(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        candidate = _first_present(value, ["label", "title", "name", "value", "id"], "")
        return str(candidate) if candidate is not None else ""
    if value is None:
        return ""
    return str(value)


def _normalize_string_options(value):
    if not isinstance(value, list):
        return []
    return [option for option in (_string_option(item) for item in value) if option]


def _normalize_feed_questions(value):
    if not isinstance(value, list):
        return []

    questions = []
    for question_index, raw_question in enumerate(value):
        if not isinstance(raw_question, dict):
            continue
        raw_options = raw_question.get("options")
        options = []
        if isinstance(raw_options, list):
            for option_index, raw_option in enumerate(raw_options):
                if isinstance(raw_option, dict):
                    option_id = _first_present(raw_option, ["id", "value"], f"opt{option_index}")
                    label = _first_present(raw_option, ["label", "title", "name", "value"], "")
                    description = _first_present(raw_option, ["description", "detail", "subtitle"], "")
                else:
                    option_id = f"opt{option_index}"
                    label = raw_option
                    description = ""
                options.append({
                    "id": str(option_id or f"opt{option_index}"),
                    "label": str(label or ""),
                    "description": str(description or ""),
                })

        question_id = _first_present(raw_question, ["id", "questionID", "question_id"], f"q{question_index}")
        header = _first_present(raw_question, ["header", "title"], "")
        prompt = _first_present(raw_question, ["question", "prompt", "message"], "")
        multi_select = _first_present(raw_question, ["multiSelect", "multi_select", "multiple"], False)
        questions.append({
            "id": str(question_id or f"q{question_index}"),
            "header": str(header or ""),
            "question": str(prompt or ""),
            "multiSelect": multi_select is True,
            "options": options,
        })
    return questions


def _normalize_feed_item(item):
    """Normalize a cmux Feed item while preserving the raw payload.

    cmux Feed was added after the harness, and its payload may grow over time.
    The harness keeps stable top-level fields for UI clients but includes raw so
    new fields are still available without a server deploy.
    """
    if not isinstance(item, dict):
        return None
    request_id = str(_first_feed_present(item, [
        "request_id", "requestId", "requestID", "_opencode_request_id",
    ], "") or "")
    workspace_id = str(_first_feed_present(item, [
        "workspace_id", "workspaceId", "workspace_uuid", "workspaceUUID",
    ], "") or "")
    surface_id = str(_first_feed_present(item, [
        "surface_id", "surfaceId", "tab_id", "tabId",
    ], "") or "")
    title = str(_first_feed_present(item, [
        "title", "label", "summary", "tool_name", "toolName",
    ], "") or "")
    message = str(_first_feed_present(item, [
        "message", "body", "prompt", "question", "description", "text", "content",
    ], "") or "")
    command = str(_first_feed_present(item, [
        "command", "toolPreview", "tool_preview",
    ], "") or "")
    raw_tool_input = _first_feed_present(item, ["tool_input", "toolInput"], {})
    if not command and isinstance(raw_tool_input, str):
        command = raw_tool_input
    tool_input = raw_tool_input if isinstance(raw_tool_input, dict) else {}

    raw_questions = _first_feed_present(item, ["questions"], None)
    if raw_questions is None:
        raw_questions = tool_input.get("questions")
    questions = _normalize_feed_questions(raw_questions)

    raw_options = _first_feed_present(item, ["options", "choices", "selections"], None)
    options = _normalize_string_options(raw_options)
    if not options and questions:
        options = [
            option["label"]
            for question in questions
            for option in question["options"]
            if option["label"]
        ]

    permission_type = _first_feed_present(
        item,
        ["permissionType", "permission_type", "permission"],
        None,
    )
    if permission_type is None:
        permission_type = _first_present(tool_input, ["permissionType", "permission_type", "permission"], "")
    raw_patterns = _first_feed_present(item, ["patterns"], None)
    if raw_patterns is None:
        raw_patterns = tool_input.get("patterns")
    patterns = _normalize_string_options(raw_patterns)

    if not message and questions:
        message = questions[0]["question"]
    if not message:
        message = str(_first_present(tool_input, ["message", "prompt", "question", "description"], "") or "")

    return {
        "requestID": request_id,
        "kind": _infer_feed_kind(item),
        "title": title,
        "message": message,
        "command": command,
        "workspaceID": workspace_id,
        "surfaceID": surface_id,
        "agent": str(_first_feed_present(item, ["agent", "source", "app", "_source"], "") or ""),
        "status": str(_first_feed_present(item, ["status", "state"], "") or ""),
        "createdAt": str(_first_feed_present(item, ["created_at", "createdAt", "timestamp", "time"], "") or ""),
        "options": options,
        "permissionType": str(permission_type or ""),
        "patterns": patterns,
        "questions": questions,
        "raw": item,
    }


def _parse_feed_items(result):
    """Return normalized Feed items from feed.list result."""
    if result is None:
        return []
    if isinstance(result, list):
        items = result
    elif isinstance(result, dict):
        items = result.get("items") or result.get("feed") or result.get("requests")
        if items is None and isinstance(result.get("event"), dict):
            items = [result]
        if items is None:
            items = []
    else:
        return []
    parsed = []
    for item in items:
        if not _is_actionable_feed_item(item):
            continue
        normalized = _normalize_feed_item(item)
        if normalized is not None:
            parsed.append(normalized)
    return parsed


def cmux_feed_items():
    """Fetch cmux Feed items via v2 API."""
    result = _v2_request("feed.list", {})
    if result is None:
        return None
    return _parse_feed_items(result)


def cmux_feed_reply(kind, request_id, action=None, mode=None, selections=None):
    """Reply to a cmux Feed item.

    Supported cmux methods:
    - feed.permission.reply: request_id + mode once|always|all|bypass|deny
    - feed.exit_plan.reply: request_id + mode ultraplan|bypassPermissions|autoAccept|manual|deny
    - feed.question.reply: request_id + selections: [string]
    """
    kind = str(kind or "").strip().lower().replace("-", "_")
    request_id = str(request_id or "").strip()
    if not request_id:
        return {"ok": False, "error": "requestID required"}

    action = str(action or "").strip().lower()
    mode = str(mode or "").strip()
    if kind == "permission":
        action_modes = {
            "approve": "once",
            "allow": "once",
            "once": "once",
            "always": "always",
            "all": "all",
            "bypass": "bypass",
            "deny": "deny",
            "reject": "deny",
        }
        allowed_modes = {"once", "always", "all", "bypass", "deny"}
        permission_mode = mode or action_modes.get(action)
        if permission_mode not in allowed_modes:
            return {"ok": False, "error": "unsupported permission reply"}
        result = _v2_request("feed.permission.reply", {
            "request_id": request_id,
            "mode": permission_mode,
        })
    elif kind in {"plan", "exit_plan", "exitplan"}:
        action_modes = {
            "approve": "autoAccept",
            "accept": "autoAccept",
            "auto": "autoAccept",
            "manual": "manual",
            "ultraplan": "ultraplan",
            "bypass": "bypassPermissions",
            "deny": "deny",
            "reject": "deny",
        }
        allowed_modes = {"ultraplan", "bypassPermissions", "autoAccept", "manual", "deny"}
        plan_mode = mode or action_modes.get(action)
        if plan_mode not in allowed_modes:
            return {"ok": False, "error": "unsupported plan reply"}
        result = _v2_request("feed.exit_plan.reply", {
            "request_id": request_id,
            "mode": plan_mode,
        })
    elif kind == "question":
        selected = selections if isinstance(selections, list) else []
        selected = [str(item).strip() for item in selected if str(item).strip()]
        if not selected:
            return {"ok": False, "error": "question selections required"}
        result = _v2_request("feed.question.reply", {
            "request_id": request_id,
            "selections": selected,
        })
    else:
        return {"ok": False, "error": f"unsupported feed kind: {kind or 'unknown'}"}

    if result is None:
        return {"ok": False, "error": "cmux feed reply failed"}
    return {"ok": True, "result": result}


def _parse_debug_terminals(result):
    """Parse a debug.terminals v2 response into a dict indexed by surface UUID.
    Returns {surface_uuid: {surface_title, git_dirty, surface_created_at,
    runtime_surface_age_seconds, current_directory, workspace_ref}}."""
    if result is None:
        return {}
    if isinstance(result, list):
        terminals = result
    elif isinstance(result, dict):
        terminals = result.get("terminals", [])
    else:
        return {}
    indexed = {}
    for t in terminals:
        if not isinstance(t, dict):
            continue
        sid = t.get("surface_id", "")
        if not sid:
            continue
        indexed[sid] = {
            "surface_title": t.get("surface_title", ""),
            "git_dirty": t.get("git_dirty", False),
            "surface_created_at": t.get("surface_created_at", ""),
            "runtime_surface_age_seconds": t.get("runtime_surface_age_seconds", 0),
            "current_directory": t.get("current_directory", ""),
            "workspace_ref": t.get("workspace_ref", ""),
        }
    return indexed


def cmux_debug_terminals():
    """Fetch terminal metadata via debug.terminals v2 API.
    Returns {surface_uuid: {...metadata...}} or None on failure."""
    result = _v2_request("debug.terminals", {})
    if result is None:
        return None
    return _parse_debug_terminals(result)
