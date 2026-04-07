from __future__ import annotations

from .. import workspaces


def handle_list_workspaces(handler):
    handler._json_response(workspaces.list_workspace_sessions())


def handle_get_workspace(handler, workspace):
    handler._json_response(workspace)


def handle_get_messages(handler, workspace_id, parsed, *, engine):
    params = handler.parse_qs(parsed.query)
    after = params.get("after", [None])[0]
    messages = engine.orchestrator.get_workspace_messages(workspace_id, after=after)
    handler._json_response(messages)


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
    started = engine.orchestrator.start_workspace_session(workspace_id)
    if started:
        handler._json_response({"ok": True})
    else:
        handler._json_response({"ok": False, "error": "Could not start workspace session"}, 400)


def handle_post_message(handler, workspace_id, data, *, engine, threading_module):
    message = data.get("message", "")
    threading_module.Thread(
        target=engine.orchestrator.handle_workspace_input,
        args=(workspace_id, message),
        daemon=True,
    ).start()
    handler._json_response({"ok": True})


def handle_delete_workspace(handler, workspace_id, *, engine):
    engine.orchestrator.close_workspace_session(workspace_id, reason="delete")
    workspaces.delete_workspace_session(workspace_id)
    handler._json_response({"ok": True})
