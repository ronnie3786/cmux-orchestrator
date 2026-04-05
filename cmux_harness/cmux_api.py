"""Low-level cmux socket and CLI helpers."""

import json
import logging
import os
import socket
import subprocess
import time as _time

log = logging.getLogger(__name__)

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


def cmux_send_to_workspace(ws_index, surface_index, text=None, key=None, workspace_uuid=None, surface_id=None):
    """Send text or a key to a surface WITHOUT switching workspaces.
    Uses the v2 JSON-RPC API with workspace_id parameter.
    When surface_id is provided (e.g. 'surface:2'), targets that specific surface."""
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
    # Attempt 1: tmux paste-buffer (atomic, handles long text)
    pane_ref = _find_pane_ref_for_workspace(workspace_uuid)
    if pane_ref:
        if _try_tmux_paste(pane_ref, text):
            return True

    # Attempt 2: cmux v2 send_text + send_key("enter") — always separate calls
    params = {"workspace_id": workspace_uuid, "text": text}
    if surface_id:
        params["surface_id"] = surface_id
    _v2_request("surface.send_text", params)
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
