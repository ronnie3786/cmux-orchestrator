from __future__ import annotations

import json
import subprocess
from datetime import datetime, timezone
from typing import Any

from .. import claude_cli
from .. import objectives


_STAGE_LABELS = {
    "planning": "Planning",
    "plan_review": "Plan review",
    "negotiating_contracts": "Negotiating contracts",
    "contract_review": "Contract review",
    "executing": "Executing",
    "reviewing": "Reviewing",
    "rework": "Rework",
    "completed": "Completed",
    "failed": "Needs attention",
}


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_iso(value: Any) -> datetime | None:
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _message_time(message: dict) -> float:
    parsed = _parse_iso(message.get("timestamp"))
    return parsed.timestamp() if parsed else 0.0


def _status_label(status: str) -> str:
    value = str(status or "").strip().lower()
    return _STAGE_LABELS.get(value, value.replace("_", " ").title() or "Unknown")


def _task_counts(tasks: list[dict]) -> dict[str, Any]:
    counts = {
        "total": len(tasks),
        "completed": 0,
        "queued": 0,
        "active": 0,
        "failed": 0,
        "reviewing": 0,
        "rework": 0,
        "activeTitles": [],
    }
    for task in tasks:
        status = str(task.get("status") or "").lower()
        title = str(task.get("title") or task.get("id") or "Untitled task")
        if status == "completed":
            counts["completed"] += 1
        elif status == "queued":
            counts["queued"] += 1
        elif status == "failed":
            counts["failed"] += 1
        elif status == "reviewing":
            counts["active"] += 1
            counts["reviewing"] += 1
            counts["activeTitles"].append(title)
        elif status == "rework":
            counts["active"] += 1
            counts["rework"] += 1
            counts["activeTitles"].append(title)
        elif status in {"executing", "planning", "plan_review", "negotiating_contracts", "contract_review"}:
            counts["active"] += 1
            counts["activeTitles"].append(title)
    return counts


def _read_review(objective_id: str, task_id: str) -> dict[str, Any]:
    raw = objectives.read_task_file(objective_id, task_id, "review.json")
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _review_summary(objective_id: str, tasks: list[dict]) -> dict[str, Any]:
    passed = 0
    failed = 0
    latest: dict[str, Any] | None = None
    for task in tasks:
        task_id = str(task.get("id") or "")
        if not task_id:
            continue
        review = _read_review(objective_id, task_id)
        if not review:
            continue
        verdict = str(review.get("verdict") or "").lower()
        if verdict == "pass":
            passed += 1
        elif verdict == "fail":
            failed += 1
        candidate = {
            "taskId": task_id,
            "taskTitle": task.get("title") or task_id,
            "verdict": verdict or "unknown",
            "issues": review.get("issues") or [],
            "recommendation": review.get("recommendation") or review.get("summary") or "",
            "reviewCycles": task.get("reviewCycles") or 0,
            "timestamp": task.get("completedAt") or task.get("updatedAt") or "",
        }
        if latest is None or str(candidate.get("timestamp") or "") >= str(latest.get("timestamp") or ""):
            latest = candidate
    return {"passed": passed, "failed": failed, "latest": latest}


def _latest_interesting_message(messages: list[dict]) -> dict | None:
    interesting = [
        message
        for message in messages
        if str(message.get("type") or "") in {"progress", "review", "alert", "approval", "completion", "plan_review", "system", "assistant"}
    ]
    if not interesting:
        return None
    interesting.sort(key=_message_time)
    return interesting[-1]


def _latest_approval_state(messages: list[dict], tasks: list[dict]) -> dict[str, Any]:
    pending: dict[str, dict] = {}
    for message in sorted(messages, key=_message_time):
        msg_type = str(message.get("type") or "")
        metadata = message.get("metadata") if isinstance(message.get("metadata"), dict) else {}
        task_id = metadata.get("task_id")
        content = str(message.get("content") or "")
        if not task_id and "Task " in content:
            marker = content.split("Task ", 1)[1].split(":", 1)[0].split()[0]
            task_id = marker.strip()
        if msg_type == "approval" and task_id:
            pending[str(task_id)] = message
        elif task_id and (msg_type in {"progress", "review", "completion"} or content.startswith("Sent '")):
            pending.pop(str(task_id), None)
    active_by_id = {str(task.get("id") or ""): task for task in tasks if isinstance(task, dict)}
    unresolved = []
    for task_id, message in pending.items():
        task = active_by_id.get(task_id)
        if task and str(task.get("status") or "").lower() in {"completed", "failed", "reviewing"}:
            continue
        unresolved.append({
            "taskId": task_id,
            "taskTitle": (task or {}).get("title") or task_id,
            "content": message.get("content") or "",
            "timestamp": message.get("timestamp"),
        })
    unresolved.sort(key=lambda item: str(item.get("timestamp") or ""), reverse=True)
    return {
        "waiting": len(unresolved),
        "latest": unresolved[0] if unresolved else None,
    }


def _run_git_command(worktree_path: str, *args: str) -> str:
    if not worktree_path:
        return ""
    try:
        result = subprocess.run(
            ["git", "-C", worktree_path, *args],
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )
    except Exception:
        return ""
    if result.returncode != 0:
        return ""
    return (result.stdout or "").strip()


def _git_summary(worktree_path: str) -> dict[str, Any]:
    status_output = _run_git_command(worktree_path, "status", "--short", "--branch")
    branch = ""
    staged = 0
    unstaged = 0
    untracked = 0
    if status_output:
        lines = status_output.splitlines()
        if lines and lines[0].startswith("## "):
            branch = lines[0][3:].strip()
            lines = lines[1:]
        for line in lines:
            if line.startswith("??"):
                untracked += 1
                continue
            if line[:1] not in {" ", "?"}:
                staged += 1
            if len(line) > 1 and line[1] not in {" ", "?"}:
                unstaged += 1
    diff_stat = _run_git_command(worktree_path, "diff", "--stat", "--")
    cached_diff_stat = _run_git_command(worktree_path, "diff", "--stat", "--cached", "--")
    latest_commit = _run_git_command(worktree_path, "log", "-1", "--pretty=%h %s")
    changed_files = staged + unstaged + untracked
    return {
        "branch": branch,
        "staged": staged,
        "unstaged": unstaged,
        "untracked": untracked,
        "changedFiles": changed_files,
        "latestCommit": latest_commit,
        "diffStat": diff_stat,
        "cachedDiffStat": cached_diff_stat,
    }


def _clean_message_text(message: dict | None) -> str:
    if not message:
        return ""
    content = str(message.get("content") or "").strip()
    if content:
        return content
    msg_type = str(message.get("type") or "").replace("_", " ")
    return msg_type.title() or "No recent activity yet"


def _blockers_for_summary(objective: dict, tasks: list[dict], approvals: dict, review_summary: dict, recent_message: dict | None) -> list[str]:
    blockers: list[str] = []
    status = str(objective.get("status") or "").lower()
    if approvals.get("latest"):
        latest = approvals["latest"]
        blockers.append(f"Waiting on approval for {latest.get('taskTitle') or latest.get('taskId')}")
    if status == "plan_review":
        blockers.append("Plan needs human approval or feedback before execution can start")
    if status == "contract_review":
        blockers.append("Sprint contracts need human approval before tasks can start")
    for task in tasks:
        if str(task.get("status") or "").lower() != "failed":
            continue
        review = _read_review(objective["id"], str(task.get("id") or ""))
        issues = review.get("issues") if isinstance(review.get("issues"), list) else []
        if issues:
            blockers.append(f"{task.get('title') or task.get('id')}: {issues[0]}")
        else:
            blockers.append(f"{task.get('title') or task.get('id')} failed and needs attention")
    if recent_message and str(recent_message.get("type") or "") == "alert":
        blockers.append(_clean_message_text(recent_message))
    latest_review = review_summary.get("latest") or {}
    if str(latest_review.get("verdict") or "") == "fail" and latest_review.get("issues"):
        blockers.append(str(latest_review["issues"][0]))
    deduped: list[str] = []
    seen = set()
    for blocker in blockers:
        value = str(blocker or "").strip()
        key = value.lower()
        if not value or key in seen:
            continue
        seen.add(key)
        deduped.append(value)
    return deduped[:4]


def _now_line(objective: dict, task_counts: dict, approvals: dict) -> str:
    status = str(objective.get("status") or "").lower()
    active_titles = task_counts.get("activeTitles") or []
    if approvals.get("latest"):
        latest = approvals["latest"]
        return f"Waiting on approval for {latest.get('taskTitle') or latest.get('taskId')}."
    if status == "planning":
        return "The planner is breaking the objective into executable tasks."
    if status == "plan_review":
        return "The plan is ready and waiting for human review."
    if status == "negotiating_contracts":
        return "The orchestrator is generating sprint contracts for each planned task."
    if status == "contract_review":
        return "Contracts are ready and waiting for human approval."
    if status in {"executing", "reviewing", "rework"} and active_titles:
        titles = ", ".join(active_titles[:2])
        if len(active_titles) > 2:
            titles += f" +{len(active_titles) - 2} more"
        return f"Active work is in flight on {titles}."
    if status == "completed":
        return "All planned tasks are complete on the objective branch."
    if status == "failed":
        return "At least one task failed and the objective needs intervention."
    return "The orchestrator is holding the current objective state."


def _next_line(objective: dict, task_counts: dict, approvals: dict, blockers: list[str]) -> str:
    status = str(objective.get("status") or "").lower()
    if approvals.get("latest"):
        return "Approve the pending task or take over manually to unblock progress."
    if status == "plan_review":
        return "Approve the plan or send feedback in chat to revise it."
    if status == "contract_review":
        return "Approve the contracts so execution can start."
    if status == "planning":
        return "Wait for the plan review card, then approve or revise it."
    if status == "negotiating_contracts":
        return "Wait for the contract review step, then approve it."
    if status in {"executing", "reviewing", "rework"}:
        queued = int(task_counts.get("queued") or 0)
        if queued > 0:
            return f"Finish the current work so {queued} queued task{'s' if queued != 1 else ''} can continue."
        if blockers:
            return "Resolve the current blocker, then continue the objective."
        return "Let the active task finish and review the next update when it lands."
    if status == "completed":
        branch = str(objective.get("branchName") or "").strip()
        return f"Review the finished branch{f' {branch}' if branch else ''} and decide whether to merge or continue iterating."
    if status == "failed":
        return "Inspect the latest failed task, address the issue, or retry the objective."
    return "Check the latest objective messages for the next manual action."


def _tldr(objective: dict, stage_label: str, task_counts: dict, blockers: list[str], git_summary: dict) -> str:
    total = int(task_counts.get("total") or 0)
    completed = int(task_counts.get("completed") or 0)
    active = int(task_counts.get("active") or 0)
    changed_files = int(git_summary.get("changedFiles") or 0)
    pieces = [
        f"{stage_label}: {completed}/{total} tasks complete" if total else f"{stage_label}: no tasks planned yet",
    ]
    if active:
        pieces.append(f"{active} active")
    if changed_files:
        pieces.append(f"{changed_files} changed file{'s' if changed_files != 1 else ''} in the worktree")
    if blockers:
        pieces.append(f"blocker: {blockers[0]}")
    return ". ".join(pieces) + "."


def _summary_source(kind: str, *, fallback_reason: str = "") -> dict[str, Any]:
    display = "Haiku" if kind == "haiku" else "Deterministic"
    return {
        "kind": kind,
        "display": display,
        "fallbackReason": fallback_reason,
    }


def _recent_events(messages: list[dict], limit: int = 4) -> list[dict[str, str]]:
    interesting = [
        message
        for message in messages
        if str(message.get("type") or "") in {"progress", "review", "alert", "approval", "completion", "plan_review", "system", "assistant"}
    ]
    interesting.sort(key=_message_time)
    events: list[dict[str, str]] = []
    for message in interesting[-limit:]:
        events.append(
            {
                "type": str(message.get("type") or ""),
                "timestamp": str(message.get("timestamp") or ""),
                "content": _clean_message_text(message),
            }
        )
    return events


def _task_summary_payload(tasks: list[dict], limit: int = 6) -> list[dict[str, Any]]:
    payload = []
    for task in tasks[:limit]:
        payload.append(
            {
                "id": str(task.get("id") or ""),
                "title": str(task.get("title") or task.get("id") or "Untitled task"),
                "status": str(task.get("status") or ""),
                "reviewCycles": int(task.get("reviewCycles") or 0),
            }
        )
    return payload


def _build_haiku_prompt(summary: dict[str, Any], objective: dict, messages: list[dict]) -> str:
    payload = {
        "objective": {
            "goal": str(objective.get("goal") or ""),
            "status": str(objective.get("status") or ""),
            "branchName": str(objective.get("branchName") or ""),
        },
        "deterministicDraft": {
            "tldr": summary.get("tldr") or "",
            "justHappened": summary.get("justHappened") or "",
            "now": summary.get("now") or "",
            "next": summary.get("next") or "",
            "blockers": summary.get("blockers") or [],
        },
        "signals": {
            "tasks": summary.get("signals", {}).get("tasks") or {},
            "approvals": summary.get("signals", {}).get("approvals") or {},
            "reviews": summary.get("signals", {}).get("reviews") or {},
            "git": summary.get("signals", {}).get("git") or {},
        },
        "tasks": _task_summary_payload(objective.get("tasks") or []),
        "recentEvents": _recent_events(messages),
    }
    return "\n".join(
        [
            "You turn deterministic orchestration signals into a compact, human-useful objective status summary.",
            "Stay faithful to the facts in the payload. Do not invent work, progress, blockers, or certainty.",
            "Write short, plain-English updates for a busy human checking progress.",
            "If there is no blocker, return an empty blockers array.",
            "Return JSON only with exactly these keys:",
            '{"tldr":"...","justHappened":"...","now":"...","next":"...","blockers":["..."]}',
            "Keep tldr to one sentence. Keep the other strings under 140 characters each.",
            "",
            "Payload:",
            json.dumps(payload, separators=(",", ":")),
        ]
    )


def _normalize_enriched_fields(result: Any) -> dict[str, Any] | None:
    if not isinstance(result, dict) or result.get("error"):
        return None
    text_fields = {}
    for key in ("tldr", "justHappened", "now", "next"):
        value = result.get(key)
        if not isinstance(value, str) or not value.strip():
            return None
        text_fields[key] = value.strip()
    blockers = result.get("blockers")
    if blockers is None:
        blockers = []
    if not isinstance(blockers, list):
        return None
    clean_blockers = []
    for item in blockers:
        if not isinstance(item, str):
            return None
        value = item.strip()
        if value:
            clean_blockers.append(value)
    text_fields["blockers"] = clean_blockers[:4]
    return text_fields


def maybe_enrich_status_summary(
    summary: dict[str, Any],
    objective: dict,
    messages: list[dict],
    *,
    enrich: str | None = None,
    timeout: int = 12,
) -> dict[str, Any]:
    enriched = dict(summary)
    if str(enrich or "").lower() != "haiku":
        enriched["summarySource"] = _summary_source("deterministic")
        return enriched

    result = claude_cli.run_haiku(_build_haiku_prompt(summary, objective, messages), timeout=timeout)
    fields = _normalize_enriched_fields(result)
    if not fields:
        fallback_reason = "Haiku unavailable or returned invalid output"
        if isinstance(result, dict) and result.get("error"):
            fallback_reason = str(result.get("error") or fallback_reason)
        enriched["summarySource"] = _summary_source("deterministic", fallback_reason=fallback_reason)
        return enriched

    enriched.update(fields)
    enriched["summarySource"] = _summary_source("haiku")
    return enriched


def build_status_summary(objective_id: str, objective: dict, messages: list[dict]) -> dict[str, Any]:
    tasks = [task for task in (objective.get("tasks") or []) if isinstance(task, dict)]
    stage = str(objective.get("status") or "unknown").lower()
    stage_label = _status_label(stage)
    task_counts = _task_counts(tasks)
    review_summary = _review_summary(objective_id, tasks)
    approvals = _latest_approval_state(messages, tasks)
    recent_message = _latest_interesting_message(messages)
    git_summary = _git_summary(str(objective.get("worktreePath") or ""))
    blockers = _blockers_for_summary(objective, tasks, approvals, review_summary, recent_message)
    summary = {
        "objectiveId": objective_id,
        "generatedAt": _utc_now_iso(),
        "objective": str(objective.get("goal") or ""),
        "stage": {"code": stage, "label": stage_label},
        "tldr": _tldr(objective, stage_label, task_counts, blockers, git_summary),
        "justHappened": _clean_message_text(recent_message),
        "now": _now_line(objective, task_counts, approvals),
        "next": _next_line(objective, task_counts, approvals, blockers),
        "blockers": blockers,
        "signals": {
            "tasks": task_counts,
            "approvals": approvals,
            "reviews": review_summary,
            "git": git_summary,
        },
        "summarySource": _summary_source("deterministic"),
    }
    return summary


def handle_get_status_summary(handler, objective_id: str, objective: dict, *, engine, parsed=None):
    orchestrator = getattr(engine, "orchestrator", None)
    get_messages = getattr(orchestrator, "get_messages", None)
    messages = get_messages(objective_id) if callable(get_messages) else []
    enrich = None
    if parsed is not None:
        query = getattr(handler, "parse_qs", None)
        params = query(parsed.query) if callable(query) else {}
        enrich = (params.get("enrich", [None])[0] or "").strip().lower() or None
    summary = build_status_summary(objective_id, objective, messages)
    handler._json_response(maybe_enrich_status_summary(summary, objective, messages, enrich=enrich))
