"""Low-level cmux socket and CLI helpers."""

import json
import os
import socket
import subprocess

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


# Virtual index scheme: workspace idx 0 with 3 surfaces becomes idx 0, 10000, 10001.
# Real index stays at position 0; additional surfaces start at VIRTUAL_BASE + real_idx * STRIDE.
VIRTUAL_BASE = 10000
VIRTUAL_STRIDE = 100

SURFACE_MAP_TTL = 15  # seconds between cmux tree --all --json refreshes


def cmux_tree():
    """Fetch the full workspace/pane/surface hierarchy via cmux CLI.
    Returns {workspace_index: [{"ref": "surface:N", "title": "...", "pane_ref": "..."}]} or None on failure."""
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
