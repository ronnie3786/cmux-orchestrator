"""Route handler for Claude Code PreToolUse hooks.

Receives hook payloads from Claude Code's HTTP hook system, classifies
severity via :mod:`cmux_harness.severity`, and returns allow/ask decisions
in the format Claude Code expects.

Below-threshold levels get ``permissionDecision: "allow"`` (auto-approved).
Above-threshold levels get ``permissionDecision: "ask"`` which pauses
Claude Code and shows the normal permission prompt to the user, waiting
for their manual approval or denial.
"""

from __future__ import annotations

import os

from .. import objectives
from .. import severity
from ..engine import AUTO_MODE_SUPER
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


def _build_super_auto_bypass_response(reason: str) -> dict:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": f"Super Auto: {reason}",
        }
    }


def _safe_realpath(path: str) -> str:
    value = str(path or "").strip()
    if not value:
        return ""
    try:
        return os.path.realpath(os.path.expanduser(value))
    except (OSError, TypeError, ValueError):
        return ""


def _cwd_matches_workspace(cwd: str, workspace_cwd: str) -> bool:
    cwd_real = _safe_realpath(cwd)
    workspace_real = _safe_realpath(workspace_cwd)
    if not cwd_real or not workspace_real:
        return False
    if cwd_real == workspace_real:
        return True
    try:
        common = os.path.commonpath([cwd_real, workspace_real])
        relative = os.path.relpath(cwd_real, workspace_real)
    except ValueError:
        return False
    if common != workspace_real:
        return False
    relative_parts = relative.split(os.sep)
    return relative_parts[:2] != [".claude", "worktrees"]


def _super_auto_workspace_for_cwd(engine, cwd: str) -> str | None:
    if not cwd:
        return None

    workspaces = getattr(engine, "workspaces", [])
    if not isinstance(workspaces, list):
        workspaces = []

    candidates = []
    for workspace in workspaces:
        if not isinstance(workspace, dict):
            continue
        workspace_id = workspace.get("uuid") or workspace.get("id")
        workspace_cwd = workspace.get("_cwd") or workspace.get("cwd") or workspace.get("current_directory")
        if workspace_id and workspace_cwd and _cwd_matches_workspace(cwd, workspace_cwd):
            candidates.append((len(_safe_realpath(workspace_cwd)), workspace_id))

    workspace_auto_mode = getattr(engine, "workspace_auto_mode", None)
    if not callable(workspace_auto_mode):
        return None

    for _, workspace_id in sorted(candidates, reverse=True):
        return workspace_id if workspace_auto_mode(workspace_id) == AUTO_MODE_SUPER else None
    return None


def _is_super_auto_workspace(engine, workspace_id: str | None) -> bool:
    if not workspace_id:
        return False
    workspace_auto_mode = getattr(engine, "workspace_auto_mode", None)
    return callable(workspace_auto_mode) and workspace_auto_mode(workspace_id) == AUTO_MODE_SUPER


def _allow_super_auto_bypass(
    handler,
    *,
    tool_name: str,
    session_id: str,
    cwd: str,
    workspace_id: str | None,
    source: str,
):
    debug_log({
        "event": "hook_super_auto_bypass",
        "tool_name": tool_name,
        "session_id": session_id,
        "cwd": cwd,
        "workspace_id": workspace_id,
        "source": source,
        "reason": "Super Auto enabled for this workspace.",
    })
    handler._json_response(_build_super_auto_bypass_response("enabled for this workspace"))


def handle_pre_tool_use(handler, data, *, engine):
    """Handle POST /api/hooks/pre-tool-use from Claude Code's PreToolUse hook.

    *data* is the JSON payload Claude Code sends to the hook endpoint.
    """
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    session_id = data.get("session_id", "")
    cwd = data.get("cwd", "")

    super_auto_workspace_id = _super_auto_workspace_for_cwd(engine, cwd)
    if super_auto_workspace_id:
        _allow_super_auto_bypass(
            handler,
            tool_name=tool_name,
            session_id=session_id,
            cwd=cwd,
            workspace_id=super_auto_workspace_id,
            source="cwd",
        )
        return

    # Resolve which objective/task this belongs to
    ctx = _resolve_context(engine, cwd)
    objective_id = ctx["objective_id"]
    task_id = ctx["task_id"]
    workspace_id = ctx["workspace_id"]
    spec_text = ctx["spec_text"]

    if _is_super_auto_workspace(engine, workspace_id):
        _allow_super_auto_bypass(
            handler,
            tool_name=tool_name,
            session_id=session_id,
            cwd=cwd,
            workspace_id=workspace_id,
            source="objective_context",
        )
        return

    if not objective_id:
        debug_log({
            "event": "hook_non_objective_ask",
            "tool_name": tool_name,
            "session_id": session_id,
            "cwd": cwd,
            "reason": "Non-objective sessions use /harness Haiku auto polling.",
        })
        handler._json_response(_build_ask_response(5, "Non-objective session uses /harness Auto polling"))
        return

    # Classify severity
    threshold = getattr(engine, "approval_threshold", 3)
    auto_mode = None
    workspace_auto_mode = getattr(engine, "workspace_auto_mode", None)
    if callable(workspace_auto_mode):
        auto_mode = workspace_auto_mode(workspace_id)
    classification = severity.classify_tool_severity(
        tool_name, tool_input, spec_text=spec_text,
    )
    level = classification["level"]
    reason = classification["reason"]

    debug_log({
        "event": "hook_pre_tool_use",
        "tool_name": tool_name,
        "session_id": session_id,
        "cwd": cwd,
        "objective_id": objective_id,
        "task_id": task_id,
        "level": level,
        "reason": reason,
        "auto_mode": auto_mode,
        "model": classification.get("model"),
        "latency_ms": classification.get("latency_ms"),
    })

    # Auto-approve if within threshold
    if severity.should_auto_approve_level(level, threshold):
        handler._json_response(_build_allow_response(level, reason))
        return

    # Escalate — pause Claude Code with "ask" and notify the dashboard.
    # "ask" makes Claude Code show the normal permission prompt, waiting
    # for the user to manually approve or deny in the terminal.
    response_sent = handler._json_response(_build_ask_response(level, reason))
    if response_sent is False:
        return

    if objective_id:
        if task_id:
            engine.orchestrator._pending_hook_approvals.add(task_id)
        tool_input_preview = str(tool_input)[:300]
        engine.orchestrator._append_message(
            objective_id,
            "approval",
            f"Task {task_id or 'N/A'}: needs your input — {reason}",
            metadata={
                "task_id": task_id,
                "workspace_id": workspace_id,
                "severity_level": level,
                "tool_name": tool_name,
                "tool_input_preview": tool_input_preview,
                "classification": classification,
            },
        )
        engine.orchestrator._log_event(
            objective_id,
            "warn",
            "hook_escalation",
            {
                "taskId": task_id,
                "tool_name": tool_name,
                "level": level,
                "reason": reason,
                "session_id": session_id,
            },
        )
