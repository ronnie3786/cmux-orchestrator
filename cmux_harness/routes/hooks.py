"""Compatibility route handler for Claude Code PreToolUse hooks.

Auto/Super Auto approval decisions are owned by terminal polling in
``cmux_harness.engine``. If a Claude Code hook still points at this endpoint,
the route deliberately returns ``permissionDecision: "ask"`` so the normal
terminal prompt appears and can be evaluated by the polling policy.
"""

from __future__ import annotations

import os

from .. import objectives
from ..storage import debug_log


def _resolve_context(engine, cwd: str) -> dict:
    """Map a working directory back to an active objective + task.

    Returns ``{"objective_id", "task_id", "spec_text"}`` when found,
    or ``{"objective_id": None, "task_id": None, "spec_text": None}``
    when the cwd doesn't match any known workspace.
    """
    if not cwd:
        return {"objective_id": None, "task_id": None, "spec_text": None}

    real_cwd = os.path.realpath(cwd)

    for obj in objectives.list_objectives():
        obj_id = obj.get("id")
        if not obj_id:
            continue
        full_obj = objectives.read_objective(obj_id)
        if not full_obj:
            continue

        obj_wt = full_obj.get("worktreePath", "")

        # Check each task's worktree path first (more specific match)
        for task in full_obj.get("tasks", []):
            task_wt = task.get("worktreePath") or obj_wt
            if task_wt and os.path.realpath(task_wt) == real_cwd:
                task_id = task.get("id")
                spec_text = objectives.read_task_file(obj_id, task_id, "spec.md") if task_id else None
                return {
                    "objective_id": obj_id,
                    "task_id": task_id,
                    "workspace_id": task.get("workspaceId"),
                    "spec_text": spec_text,
                }

        # Fall back to objective-level worktree (e.g. planner session)
        if obj_wt and os.path.realpath(obj_wt) == real_cwd:
            return {
                "objective_id": obj_id,
                "task_id": None,
                "workspace_id": full_obj.get("plannerWorkspaceId"),
                "spec_text": None,
            }

    return {"objective_id": None, "task_id": None, "workspace_id": None, "spec_text": None}


def _build_allow_response(level: int, reason: str) -> dict:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": f"Level {level}: {reason}",
        }
    }


def _build_ask_response(level: int, reason: str) -> dict:
    """Return ``permissionDecision: "ask"`` so Claude Code pauses and shows
    the normal permission prompt to the user, waiting for manual approval."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": f"Level {level}: {reason}",
        }
    }


def handle_pre_tool_use(handler, data, *, engine):
    """Handle POST /api/hooks/pre-tool-use from Claude Code's PreToolUse hook.

    *data* is the JSON payload Claude Code sends to the hook endpoint.
    """
    tool_name = data.get("tool_name", "")
    session_id = data.get("session_id", "")
    cwd = data.get("cwd", "")

    debug_log({
        "event": "hook_deferred_to_polling",
        "tool_name": tool_name,
        "session_id": session_id,
        "cwd": cwd,
        "reason": "Auto/Super Auto approval is handled by terminal polling.",
    })
    handler._json_response(_build_ask_response(4, "Auto policy deferred to /harness terminal polling"))
