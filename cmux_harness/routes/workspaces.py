from __future__ import annotations

import threading

from .. import cmux_api
from .. import workspaces


def handle_list_workspaces(handler):
    handler._json_response(workspaces.list_workspace_sessions())


def handle_get_workspace(handler, workspace):
    handler._json_response(workspace)


def handle_get_debug(handler, workspace_id, parsed):
    params = handler.parse_qs(parsed.query)
    try:
        limit = int(params.get("limit", ["200"])[0])
    except (TypeError, ValueError):
        limit = 200
    limit = max(1, min(limit, 500))
    level = params.get("level", [None])[0]
    entries = workspaces.get_debug_entries(workspace_id, limit=limit, level=level)
    handler._json_response(entries)


def handle_get_messages(handler, workspace_id, parsed, *, engine):
    params = handler.parse_qs(parsed.query)
    after = params.get("after", [None])[0]
    messages = engine.orchestrator.get_workspace_messages(workspace_id, after=after)
    handler._json_response(messages)


def handle_get_active_turn(handler, workspace_id):
    handler._json_response(workspaces.get_active_workspace_turn(workspace_id))


def handle_get_screen(handler, workspace, parsed):
    params = handler.parse_qs(parsed.query)
    lines_str = params.get("lines", ["200"])[0]
    try:
        lines = max(20, min(int(lines_str), 500))
    except (TypeError, ValueError):
        lines = 200
    workspace_uuid = str(workspace.get("cmuxWorkspaceId") or "").strip()
    if not workspace.get("sessionActive") or not workspace_uuid:
        handler._json_response({"ok": False, "error": "Workspace session is not active"}, 409)
        return
    screen = cmux_api.cmux_read_workspace(0, 0, lines=lines, workspace_uuid=workspace_uuid) or ""
    handler._json_response({"ok": True, "screen": screen, "lines": lines})


def handle_post_create_workspace(handler, data):
    project_id = data.get("projectId")
    root_path = data.get("rootPath")
    name = data.get("name")
    source = data.get("source", "manual-path")
    if not project_id or not root_path:
        handler._json_response({"ok": False, "error": "projectId and rootPath required"}, 400)
        return
    try:
        workspace = workspaces.create_workspace_session(project_id, root_path, name=name, source=source)
    except FileNotFoundError:
        handler._json_response({"ok": False, "error": "project not found"}, 404)
        return
    except ValueError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 400)
        return
    handler._json_response(workspace, 201)


def handle_post_start(handler, workspace_id, *, engine):
    workspace = workspaces.read_workspace_session(workspace_id)
    if workspace is None:
        handler._json_response({"ok": False, "error": "workspace not found"}, 404)
        return
    workspaces.update_workspace_session(workspace_id, {"status": "starting"})

    def _start_in_background():
        started = engine.orchestrator.start_workspace_session(workspace_id)
        if not started:
            try:
                workspaces.update_workspace_session(workspace_id, {"status": "error"})
            except FileNotFoundError:
                pass

    threading.Thread(target=_start_in_background, daemon=True).start()
    handler._json_response({"ok": True})


def handle_post_message(handler, workspace_id, data, *, engine, threading_module):
    message = data.get("message", "")
    threading_module.Thread(
        target=engine.orchestrator.handle_workspace_input,
        args=(workspace_id, message),
        daemon=True,
    ).start()
    handler._json_response({"ok": True})


def handle_post_finalize_turn(handler, workspace_id, turn_id, data, *, engine):
    token = data.get("token", "")
    content = data.get("content", "")
    source = data.get("source", "callback-helper")
    payload, status = engine.orchestrator.finalize_workspace_turn(
        workspace_id,
        turn_id,
        token,
        content,
        source=source,
    )
    handler._json_response(payload, status)


def handle_delete_workspace(handler, workspace_id, *, engine):
    engine.orchestrator.close_workspace_session(workspace_id, reason="delete")
    workspaces.delete_workspace_session(workspace_id)
    handler._json_response({"ok": True})


def handle_patch_workspace(handler, workspace_id, data):
    name = (data.get("name") or "").strip()
    if not name:
        handler._json_response({"ok": False, "error": "name is required"}, 400)
        return
    try:
        updated = workspaces.update_workspace_session(workspace_id, {"name": name})
    except FileNotFoundError:
        handler._json_response({"ok": False, "error": "workspace not found"}, 404)
        return
    handler._json_response(updated)
