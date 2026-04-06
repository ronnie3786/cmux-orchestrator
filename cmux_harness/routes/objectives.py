from __future__ import annotations

from .. import cmux_api
from .. import objectives


def handle_list_objectives(handler):
    handler._json_response(objectives.list_objectives())


def handle_get_objective(handler, objective):
    handler._json_response(objective)


def handle_get_task_screen(handler, objective, task_id):
    task = next((t for t in objective.get("tasks", []) if t.get("id") == task_id), None)
    if not task or not task.get("workspaceId"):
        handler._json_response({"ok": False, "error": "Task not found"}, 404)
        return
    try:
        screen = cmux_api.cmux_read_workspace(
            0, 0, lines=200, workspace_uuid=task["workspaceId"]
        ) or ""
    except Exception:
        screen = ""
    handler._json_response({"ok": True, "screen": screen, "lines": 200})


def handle_get_messages(handler, objective_id, parsed, *, engine):
    params = handler.parse_qs(parsed.query)
    after = params.get("after", [None])[0]
    messages = engine.orchestrator.get_messages(objective_id, after=after)
    handler._json_response(messages)


def handle_get_debug(handler, objective_id, parsed, *, engine):
    params = handler.parse_qs(parsed.query)
    try:
        limit = int(params.get("limit", ["200"])[0])
    except (TypeError, ValueError):
        limit = 200
    limit = max(1, min(limit, 500))
    level = params.get("level", [None])[0]
    entries = engine.orchestrator.get_debug_entries(objective_id, limit=limit, level=level)
    handler._json_response(entries)


def handle_post_start(handler, objective_id, *, engine):
    started = engine.orchestrator.start_objective(objective_id)
    if started:
        handler._json_response({"ok": True, "status": "planning"})
    else:
        handler._json_response({"ok": False, "error": "Could not start objective"}, 400)


def handle_post_task_approve(handler, objective_id, task_id, data, *, engine):
    action = data.get("action", "y\n")
    engine.orchestrator.handle_human_input(
        objective_id,
        f"Approved: {action}",
        context={"task_id": task_id, "approval_action": action},
    )
    handler._json_response({"ok": True})


def handle_post_approve_plan(handler, objective_id, *, engine):
    approved = engine.orchestrator.approve_plan(objective_id)
    if approved:
        handler._json_response({"ok": True})
    else:
        handler._json_response({"ok": False, "error": "Could not approve plan"}, 400)


def handle_approve_contracts(handler, objective_id, engine):
    approved = engine.orchestrator.approve_contracts(objective_id)
    handler._json_response({"ok": approved})


def handle_post_message(handler, objective_id, data, *, engine, threading_module):
    message = data.get("message", "")
    context = data.get("context")
    threading_module.Thread(
        target=engine.orchestrator.handle_human_input,
        args=(objective_id, message, context),
        daemon=True,
    ).start()
    handler._json_response({"ok": True})


def handle_post_create_objective(handler, data, *, engine):
    goal = data.get("goal", "")
    project_dir = data.get("projectDir", "")
    base_branch = data.get("baseBranch")
    branch_name = data.get("branchName")
    if not project_dir:
        with engine._lock:
            project_dir = engine.default_project_dir
    if not base_branch:
        with engine._lock:
            base_branch = engine.default_base_branch
    if not goal or not project_dir:
        handler._json_response({"ok": False, "error": "goal and projectDir required"}, 400)
        return
    try:
        objective = objectives.create_objective(
            goal,
            project_dir,
            base_branch=base_branch,
            branch_name=branch_name,
        )
    except OSError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 500)
        return
    handler._json_response(objective, 201)


def handle_delete_objective(handler, objective_id, *, engine):
    engine.orchestrator.stop_and_cleanup(objective_id)
    objectives.delete_objective(objective_id)
    handler._json_response({"ok": True})
