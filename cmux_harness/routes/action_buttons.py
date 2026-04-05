from __future__ import annotations

from datetime import timezone

from .. import objectives


DEFAULT_ACTION_BUTTONS = [
    {
        "id": "default-build-run",
        "label": "Build & Run",
        "icon": "▶",
        "color": "#34d399",
        "prompt": "/exp-project-run",
        "isDefault": True,
        "order": 0,
    }
]


def button_order(button, fallback=0):
    try:
        return int(button.get("order", fallback))
    except (TypeError, ValueError, AttributeError):
        return fallback


def action_buttons_for_objective(objective):
    buttons = objective.get("actionButtons")
    if isinstance(buttons, list):
        filtered = [button for button in buttons if isinstance(button, dict)]
        return sorted(filtered, key=lambda button: button_order(button, 0))
    return [dict(button) for button in DEFAULT_ACTION_BUTTONS]


def action_task_slug(label, *, re_module):
    slug = re_module.sub(r"[^a-z0-9]+", "-", str(label or "").strip().lower())
    slug = re_module.sub(r"-+", "-", slug).strip("-")
    return slug or "action"


def action_task_title(task):
    title = str(task.get("title") or "Action").strip() or "Action"
    if str(task.get("source") or "").lower() == "action-button":
        return f"Action: {title}"
    return title


def handle_get_action_buttons(handler, objective):
    handler._json_response({"buttons": action_buttons_for_objective(objective)})


def handle_post_action_buttons(handler, objective_id, objective, data, *, uuid_module):
    label = str(data.get("label") or "").strip()
    prompt = str(data.get("prompt") or "").strip()
    icon = str(data.get("icon") or "⚡").strip() or "⚡"
    color = str(data.get("color") or "#4f8ef7").strip() or "#4f8ef7"
    if not label or not prompt:
        handler._json_response({"ok": False, "error": "label and prompt required"}, 400)
        return
    buttons = objective.get("actionButtons")
    if not isinstance(buttons, list):
        buttons = []
    order = max(
        [button_order(button, index) for index, button in enumerate(buttons) if isinstance(button, dict)]
        + [-1]
    ) + 1
    button = {
        "id": str(uuid_module.uuid4()),
        "label": label,
        "icon": icon,
        "color": color,
        "prompt": prompt,
        "order": order,
    }
    buttons.append(button)
    objectives.set_action_buttons(objective_id, buttons)
    handler._json_response({"ok": True, "button": button})


def handle_post_action_inject(
    handler,
    objective_id,
    objective,
    data,
    *,
    engine,
    cmux_api,
    datetime_cls,
    time_module,
    re_module,
):
    worktree_path = str(objective.get("worktreePath") or "").strip()
    if not worktree_path:
        handler._json_response({"ok": False, "error": "objective worktreePath required"}, 400)
        return
    button_id = str(data.get("buttonId") or "").strip()
    prompt_override = str(data.get("prompt") or "").strip()
    button = None
    if button_id:
        button = next((item for item in action_buttons_for_objective(objective) if item.get("id") == button_id), None)
        if button is None:
            handler._json_response({"ok": False, "error": "action button not found"}, 404)
            return
    prompt = prompt_override or str((button or {}).get("prompt") or "").strip()
    if not prompt:
        handler._json_response({"ok": False, "error": "prompt required"}, 400)
        return
    button_label = str((button or {}).get("label") or "Ad Hoc Action").strip() or "Ad Hoc Action"
    workspace_title = action_task_title({"title": button_label, "source": "action-button"})
    workspace_uuid, created = engine.orchestrator._create_worker_workspace(
        workspace_title,
        worktree_path,
        objective_id=objective_id,
        purpose="action-button",
    )
    if not created or not workspace_uuid:
        handler._json_response({"ok": False, "error": "workspace creation failed"}, 500)
        return
    if not engine.orchestrator._wait_for_repl(
        workspace_uuid,
        objective_id=objective_id,
        purpose="action-button",
    ):
        engine.orchestrator._close_workspace(objective_id, workspace_uuid, "action-button_repl_timeout")
        handler._json_response({"ok": False, "error": "repl not ready"}, 500)
        return
    if not cmux_api.send_prompt_to_workspace(workspace_uuid, prompt):
        engine.orchestrator._close_workspace(objective_id, workspace_uuid, "action-button_prompt_failed")
        handler._json_response({"ok": False, "error": "prompt delivery failed"}, 500)
        return
    timestamp = int(time_module.time())
    task_id = f"action-{action_task_slug(button_label, re_module=re_module)}-{timestamp}"
    task = {
        "id": task_id,
        "title": button_label,
        "source": "action-button",
        "actionId": button.get("id") if button else None,
        "status": "executing",
        "workspaceId": workspace_uuid,
        "worktreePath": worktree_path,
        "startedAt": datetime_cls.now(timezone.utc).isoformat(),
        "prompt": prompt,
        "dependsOn": [],
        "files": [],
        "checkpoints": [],
    }
    objectives.append_task(objective_id, task)
    objectives.create_task_dir(objective_id, task_id)
    objectives.write_task_file(objective_id, task_id, "spec.md", prompt + "\n")
    handler._json_response({"ok": True, "taskId": task_id, "workspaceId": workspace_uuid})


def handle_delete_action_button(handler, objective_id, objective, button_id):
    buttons = objective.get("actionButtons")
    if not isinstance(buttons, list):
        handler._json_response({"ok": False, "error": "action button not found"}, 404)
        return
    remaining = [button for button in buttons if isinstance(button, dict) and button.get("id") != button_id]
    if len(remaining) == len(buttons):
        handler._json_response({"ok": False, "error": "action button not found"}, 404)
        return
    objectives.set_action_buttons(objective_id, remaining)
    handler._json_response({"ok": True})
