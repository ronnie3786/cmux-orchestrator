from __future__ import annotations

import json
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path

from .. import objectives
from .. import workspaces
from . import jira as jira_routes

def workflow_dir() -> Path:
    return objectives.OBJECTIVES_DIR.parent / "workflow"


def ideas_dir() -> Path:
    return workflow_dir() / "ideas"


def decisions_dir() -> Path:
    return workflow_dir() / "decisions"


def checkins_dir() -> Path:
    return workflow_dir() / "check-ins"


def preflights_dir() -> Path:
    return workflow_dir() / "preflights"

CONTEXT_DIMENSIONS = [
    ("open_questions", "Open Questions"),
    ("jira", "Jira Ticket"),
    ("design", "Design"),
    ("pm", "PM"),
    ("backend", "Backend"),
    ("blocked", "Blocked / Waiting"),
]

IDEA_STATUSES = {"inbox", "brainstorming", "researching", "ready_for_jira", "converted", "archived"}
PREFLIGHT_STATUSES = {"draft", "gathering_context", "ready_for_objective", "launched", "archived"}
DECISION_STATUSES = {"open", "approved", "rejected", "snoozed", "resolved"}
CONTEXT_STATES = {"unknown", "not_needed", "needed", "unresolved", "waiting", "resolved", "waived", "reopened"}
SEVERITIES = {"none", "info", "attention", "blocked"}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ensure_dirs():
    for directory in (workflow_dir(), ideas_dir(), decisions_dir(), checkins_dir(), preflights_dir()):
        directory.mkdir(parents=True, exist_ok=True)


def _read_json(path: Path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if data is not None else default
    except FileNotFoundError:
        return default
    except (json.JSONDecodeError, OSError):
        return default


def _write_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)


def _append_jsonl(path: Path, item):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(item, sort_keys=True) + "\n")


def _read_jsonl(path: Path, limit: int = 50):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []
    items = []
    for line in lines[-max(1, int(limit or 50)):]:
        try:
            items.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return items


def _safe_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def _idea_path(idea_id: str) -> Path:
    return ideas_dir() / idea_id / "idea.json"


def _decision_path(decision_id: str) -> Path:
    return decisions_dir() / decision_id / "decision.json"


def _checkin_path() -> Path:
    return checkins_dir() / "check-ins.jsonl"


def _preflight_path(preflight_id: str) -> Path:
    return preflights_dir() / preflight_id / "preflight.json"


def _context_path(objective_id: str) -> Path:
    return objectives.get_objective_dir(objective_id) / "context-health.json"


def _context_events_path(objective_id: str) -> Path:
    return objectives.get_objective_dir(objective_id) / "context-events.jsonl"


def _normalize_text(value, fallback="") -> str:
    return str(value if value is not None else fallback).strip()


def _normalize_status(value: str, allowed: set[str], default: str) -> str:
    status = _normalize_text(value).lower()
    return status if status in allowed else default


def _normalize_context_state(value: str) -> str:
    return _normalize_status(value, CONTEXT_STATES, "unknown")


def _severity_for_state(state: str, required: bool = False, explicit: str | None = None) -> str:
    explicit_value = _normalize_text(explicit).lower()
    if explicit_value in SEVERITIES:
        return explicit_value
    if state == "waiting":
        return "blocked"
    if state in {"unresolved", "reopened"}:
        return "attention" if required else "info"
    if state == "needed":
        return "attention" if required else "info"
    return "none"


def default_context_health(objective_id: str):
    now = _now_iso()
    dimensions = {}
    for dimension_id, label in CONTEXT_DIMENSIONS:
        dimensions[dimension_id] = {
            "id": dimension_id,
            "label": label,
            "state": "unknown",
            "required": dimension_id != "jira",
            "severity": "none",
            "reason": "Not checked yet.",
            "owner": "",
            "updatedAt": now,
            "resolvedAt": None,
            "reopenedAt": None,
            "history": [],
        }
    return {
        "objectiveId": objective_id,
        "updatedAt": now,
        "dimensions": dimensions,
    }


def read_context_health(objective_id: str):
    base = default_context_health(objective_id)
    current = _read_json(_context_path(objective_id), {})
    if isinstance(current, dict):
        dims = current.get("dimensions") if isinstance(current.get("dimensions"), dict) else {}
        for dim_id, value in dims.items():
            if dim_id in base["dimensions"] and isinstance(value, dict):
                base["dimensions"][dim_id].update(value)
        for key in ("objectiveId", "updatedAt"):
            if current.get(key):
                base[key] = current[key]
    return summarize_context_health(base)


def write_context_health(objective_id: str, health):
    health["objectiveId"] = objective_id
    health["updatedAt"] = _now_iso()
    health = summarize_context_health(health)
    _write_json(_context_path(objective_id), health)
    return health


def summarize_context_health(health):
    dimensions = health.get("dimensions") if isinstance(health.get("dimensions"), dict) else {}
    badges = []
    blocked = False
    attention = False
    unknown = False
    resolved_weight = 0
    total_weight = 0
    for dim_id, dim in dimensions.items():
        if not isinstance(dim, dict):
            continue
        state = _normalize_context_state(dim.get("state"))
        required = bool(dim.get("required"))
        severity = _severity_for_state(state, required, dim.get("severity"))
        dim["state"] = state
        dim["severity"] = severity
        if state == "unknown":
            unknown = True
        if severity == "blocked":
            blocked = True
        if severity == "attention":
            attention = True
        if required:
            total_weight += 1
            if state in {"resolved", "not_needed", "waived"}:
                resolved_weight += 1
        label = badge_label(dim)
        if label and severity != "none":
            badges.append({"label": label, "severity": severity, "dimension": dim_id})
    if blocked:
        state = "blocked"
    elif attention:
        state = "needs_attention"
    elif unknown:
        state = "unknown"
    else:
        state = "clear"
    score = int(round((resolved_weight / total_weight) * 100)) if total_weight else 100
    health["summary"] = {"score": score, "state": state, "badges": badges}
    return health


def badge_label(dim: dict) -> str:
    dim_id = dim.get("id")
    state = dim.get("state")
    if dim_id == "open_questions":
        count = dim.get("count")
        try:
            count = int(count)
        except (TypeError, ValueError):
            count = 1 if state in {"needed", "unresolved", "reopened", "waiting"} else 0
        return f"Questions {max(1, count)}" if count else ""
    if dim_id == "jira":
        return "No Jira" if state in {"needed", "unresolved", "reopened"} else "Jira"
    if dim_id == "blocked":
        owner = _normalize_text(dim.get("owner"))
        if state == "waiting" and owner:
            return f"Waiting on {owner}"
        return "Blocked" if state in {"waiting", "unresolved", "reopened"} else ""
    labels = {"design": "Design?", "pm": "PM?", "backend": "Backend?"}
    return labels.get(dim_id, _normalize_text(dim.get("label"))) if state in {"needed", "unresolved", "waiting", "reopened"} else ""


def update_context_dimension(objective_id: str, dimension_id: str, data: dict, *, action: str = "patch"):
    if dimension_id not in dict(CONTEXT_DIMENSIONS):
        raise ValueError("unknown context dimension")
    health = read_context_health(objective_id)
    dim = health["dimensions"][dimension_id]
    before = dict(dim)
    state = data.get("state")
    if action == "resolve":
        state = "resolved"
    elif action == "reopen":
        state = "reopened"
    elif action == "wait":
        state = "waiting"
    if state is not None:
        dim["state"] = _normalize_context_state(state)
    if "required" in data:
        dim["required"] = bool(data.get("required"))
    for key in ("reason", "owner", "count"):
        if key in data:
            dim[key] = data.get(key)
    dim["severity"] = _severity_for_state(dim.get("state"), bool(dim.get("required")), data.get("severity"))
    now = _now_iso()
    dim["updatedAt"] = now
    if dim["state"] == "resolved":
        dim["resolvedAt"] = now
    if dim["state"] == "reopened":
        dim["reopenedAt"] = now
    event = {
        "at": now,
        "actor": _normalize_text(data.get("actor"), "user") or "user",
        "action": action,
        "dimension": dimension_id,
        "from": before.get("state"),
        "to": dim.get("state"),
        "note": _normalize_text(data.get("note") or data.get("reason")),
    }
    dim.setdefault("history", []).append(event)
    health["dimensions"][dimension_id] = dim
    saved = write_context_health(objective_id, health)
    _append_jsonl(_context_events_path(objective_id), event)
    return saved


def list_ideas(include_archived: bool = False):
    _ensure_dirs()
    ideas = []
    for path in sorted(ideas_dir().glob("*/idea.json")):
        idea = _read_json(path, None)
        if not isinstance(idea, dict):
            continue
        if not include_archived and idea.get("status") == "archived":
            continue
        ideas.append(idea)
    return sorted(ideas, key=lambda item: item.get("updatedAt", ""), reverse=True)


def read_idea(idea_id: str):
    return _read_json(_idea_path(idea_id), None)


def create_idea(data: dict):
    _ensure_dirs()
    now = _now_iso()
    idea_id = _safe_id("idea")
    idea = {
        "id": idea_id,
        "title": _normalize_text(data.get("title"), "Untitled idea") or "Untitled idea",
        "summary": _normalize_text(data.get("summary") or data.get("notes")),
        "status": _normalize_status(data.get("status"), IDEA_STATUSES, "inbox"),
        "source": _normalize_text(data.get("source"), "manual"),
        "createdAt": now,
        "updatedAt": now,
        "links": data.get("links") if isinstance(data.get("links"), list) else [],
    }
    _write_json(_idea_path(idea_id), idea)
    return idea


def update_idea(idea_id: str, data: dict):
    idea = read_idea(idea_id)
    if not isinstance(idea, dict):
        return None
    for key in ("title", "summary", "source"):
        if key in data:
            idea[key] = _normalize_text(data.get(key))
    if "status" in data:
        idea["status"] = _normalize_status(data.get("status"), IDEA_STATUSES, idea.get("status", "inbox"))
    if isinstance(data.get("links"), list):
        idea["links"] = data.get("links")
    idea["updatedAt"] = _now_iso()
    _write_json(_idea_path(idea_id), idea)
    return idea


def delete_idea(idea_id: str) -> bool:
    path = ideas_dir() / idea_id
    if not path.exists():
        return False
    shutil.rmtree(path)
    return True



def list_preflights(include_archived: bool = False):
    _ensure_dirs()
    preflights = []
    for path in sorted(preflights_dir().glob("*/preflight.json")):
        item = _read_json(path, None)
        if not isinstance(item, dict):
            continue
        if not include_archived and item.get("status") == "archived":
            continue
        preflights.append(item)
    return sorted(preflights, key=lambda item: item.get("updatedAt", ""), reverse=True)


def preflight_missing_requirements(preflight: dict) -> list[dict]:
    missing = []
    for item in preflight.get("requiredContext", []):
        if not isinstance(item, dict):
            continue
        if bool(item.get("required")) and item.get("state") in {"needed", "unresolved", "unknown", "reopened", "waiting"}:
            missing.append({
                "id": item.get("id"),
                "label": item.get("label") or item.get("id") or "Context",
                "reason": item.get("reason") or item.get("state") or "missing",
            })
    if not _normalize_text(preflight.get("projectId")) and not _normalize_text(preflight.get("projectDir")):
        missing.append({"id": "project", "label": "Project / repo", "reason": "Choose a repo before launch."})
    if not _normalize_text(preflight.get("goal") or preflight.get("title")):
        missing.append({"id": "goal", "label": "Goal", "reason": "Give the objective a clear goal."})
    return missing


def sync_preflight_readiness(preflight: dict) -> dict:
    missing = preflight_missing_requirements(preflight)
    preflight["launchReady"] = len(missing) == 0
    preflight["missingRequirements"] = missing
    if preflight.get("objectiveId"):
        preflight["status"] = "launched"
    elif preflight["launchReady"]:
        preflight["status"] = "ready_for_objective"
    elif preflight.get("status") == "ready_for_objective":
        preflight["status"] = "gathering_context"
    return preflight


def read_preflight(preflight_id: str):
    preflight = _read_json(_preflight_path(preflight_id), None)
    return sync_preflight_readiness(preflight) if isinstance(preflight, dict) else preflight


def create_preflight(data: dict):
    _ensure_dirs()
    now = _now_iso()
    source_type = _normalize_status(data.get("sourceType"), {"idea", "jira", "manual"}, "manual")
    source_id = _normalize_text(data.get("sourceId"))
    source = {}
    if source_type == "idea" and source_id:
        idea = read_idea(source_id)
        if not isinstance(idea, dict):
            raise FileNotFoundError("idea not found")
        source = idea
    title = _normalize_text(data.get("title") or source.get("title"), "Untitled pre-flight") or "Untitled pre-flight"
    summary = _normalize_text(data.get("summary") or source.get("summary"))
    preflight_id = _safe_id("preflight")
    required_context = data.get("requiredContext") if isinstance(data.get("requiredContext"), list) else [
        {"id": "open_questions", "label": "Open questions", "state": "unresolved", "required": True},
        {"id": "jira", "label": "Jira ticket", "state": "needed" if source_type != "jira" else "resolved", "required": False},
        {"id": "design", "label": "Design discussion", "state": "unknown", "required": False},
        {"id": "pm", "label": "PM discussion", "state": "unknown", "required": False},
        {"id": "backend", "label": "Backend dependency", "state": "unknown", "required": False},
    ]
    preflight = {
        "id": preflight_id,
        "title": title,
        "summary": summary,
        "goal": _normalize_text(data.get("goal") or title),
        "status": _normalize_status(data.get("status"), PREFLIGHT_STATUSES, "gathering_context"),
        "sourceType": source_type,
        "sourceId": source_id,
        "sourceUrl": _normalize_text(data.get("sourceUrl") or source.get("url")),
        "projectId": _normalize_text(data.get("projectId")),
        "projectDir": _normalize_text(data.get("projectDir")),
        "baseBranch": _normalize_text(data.get("baseBranch")),
        "requiredContext": required_context,
        "createdAt": now,
        "updatedAt": now,
        "objectiveId": None,
    }
    preflight = sync_preflight_readiness(preflight)
    _write_json(_preflight_path(preflight_id), preflight)
    if source_type == "idea" and source_id:
        update_idea(source_id, {"status": "ready_for_jira"})
    return preflight


def update_preflight(preflight_id: str, data: dict):
    preflight = read_preflight(preflight_id)
    if not isinstance(preflight, dict):
        return None
    for key in ("title", "summary", "goal", "sourceUrl", "projectId", "projectDir", "baseBranch"):
        if key in data:
            preflight[key] = _normalize_text(data.get(key))
    if "status" in data:
        preflight["status"] = _normalize_status(data.get("status"), PREFLIGHT_STATUSES, preflight.get("status", "draft"))
    if isinstance(data.get("requiredContext"), list):
        preflight["requiredContext"] = data.get("requiredContext")
    preflight["updatedAt"] = _now_iso()
    preflight = sync_preflight_readiness(preflight)
    _write_json(_preflight_path(preflight_id), preflight)
    return preflight


def delete_preflight(preflight_id: str):
    path = preflights_dir() / preflight_id
    if not path.exists():
        return False
    shutil.rmtree(path)
    return True


def list_decisions(include_resolved: bool = False):
    _ensure_dirs()
    decisions = []
    for path in sorted(decisions_dir().glob("*/decision.json")):
        decision = _read_json(path, None)
        if not isinstance(decision, dict):
            continue
        if not include_resolved and decision.get("status") in {"approved", "rejected", "resolved"}:
            continue
        decisions.append(decision)
    return sorted(decisions, key=lambda item: item.get("updatedAt", ""), reverse=True)


def read_decision(decision_id: str):
    return _read_json(_decision_path(decision_id), None)


def create_decision(data: dict):
    _ensure_dirs()
    now = _now_iso()
    decision_id = _safe_id("decision")
    decision = {
        "id": decision_id,
        "status": _normalize_status(data.get("status"), DECISION_STATUSES, "open"),
        "kind": _normalize_text(data.get("kind"), "general"),
        "title": _normalize_text(data.get("title"), "Decision needed") or "Decision needed",
        "summary": _normalize_text(data.get("summary")),
        "recommendation": _normalize_text(data.get("recommendation")),
        "risk": _normalize_text(data.get("risk")),
        "options": data.get("options") if isinstance(data.get("options"), list) else [],
        "preview": data.get("preview") if isinstance(data.get("preview"), dict) else {},
        "target": data.get("target") if isinstance(data.get("target"), dict) else {},
        "createdAt": now,
        "updatedAt": now,
        "history": [],
    }
    _write_json(_decision_path(decision_id), decision)
    return decision


def update_decision(decision_id: str, data: dict, *, action: str = "patch"):
    decision = read_decision(decision_id)
    if not isinstance(decision, dict):
        return None
    before = decision.get("status")
    if action in {"approve", "reject", "snooze"}:
        decision["status"] = {"approve": "approved", "reject": "rejected", "snooze": "snoozed"}[action]
    elif "status" in data:
        decision["status"] = _normalize_status(data.get("status"), DECISION_STATUSES, decision.get("status", "open"))
    for key in ("title", "summary", "recommendation", "risk", "kind"):
        if key in data:
            decision[key] = _normalize_text(data.get(key))
    for key in ("options", "preview", "target"):
        if key in data:
            decision[key] = data.get(key)
    event = {
        "at": _now_iso(),
        "actor": _normalize_text(data.get("actor"), "user") or "user",
        "action": action,
        "from": before,
        "to": decision.get("status"),
        "note": _normalize_text(data.get("note")),
    }
    decision.setdefault("history", []).append(event)
    decision["updatedAt"] = event["at"]
    _write_json(_decision_path(decision_id), decision)
    return decision


def create_checkin(data: dict, *, engine=None):
    _ensure_dirs()
    target_type = _normalize_text(data.get("targetType"), "all") or "all"
    target_id = _normalize_text(data.get("targetId"))
    signals = data.get("signals") if isinstance(data.get("signals"), dict) else build_checkin_signals(target_type, target_id)
    summary = _normalize_text(data.get("summary"))
    health = _normalize_text(data.get("health"))
    recommended_action = _normalize_text(data.get("recommendedAction"))
    if not summary:
        summary = build_checkin_summary(target_type, target_id, signals=signals, engine=engine)
    if not health:
        health = infer_checkin_health(signals)
    if not recommended_action:
        recommended_action = infer_recommended_action(signals)
    item = {
        "id": _safe_id("checkin"),
        "targetType": target_type,
        "targetId": target_id,
        "createdAt": _now_iso(),
        "summary": summary,
        "health": health,
        "signals": signals,
        "recommendedAction": recommended_action,
    }
    _append_jsonl(_checkin_path(), item)
    return item


def list_checkins(limit: int = 50):
    _ensure_dirs()
    return list(reversed(_read_jsonl(_checkin_path(), limit=limit)))


def build_checkin_signals(target_type: str = "all", target_id: str = "") -> dict:
    if target_type == "objective" and target_id:
        objective = objectives.read_objective(target_id) or {}
        health = read_context_health(target_id).get("summary", {}) if objective else {}
        return {
            "objectives": 1 if objective else 0,
            "activeObjectives": 1 if str(objective.get("status") or "").lower() in {"running", "executing", "started", "active", "in_progress", "planning"} else 0,
            "contextState": health.get("state", "unknown"),
            "contextBadges": health.get("badges", []),
            "needsRonnie": 1 if health.get("state") in {"blocked", "needs_attention"} else 0,
        }

    objective_cards = [_objective_card(obj) for obj in objectives.list_objectives()]
    ideas = list_ideas()
    decisions = list_decisions()
    try:
        workspace_count = len(workspaces.list_workspace_sessions())
    except Exception:
        workspace_count = 0
    attention_cards = [card for card in objective_cards if card.get("contextHealth", {}).get("state") in {"blocked", "needs_attention"}]
    review_ready = [card for card in objective_cards if card.get("lane") == "review"]
    return {
        "objectives": len(objective_cards),
        "activeObjectives": len([card for card in objective_cards if card.get("lane") == "running"]),
        "workspaces": workspace_count,
        "ideas": len(ideas),
        "preflights": len(list_preflights()),
        "decisions": len(decisions),
        "attention": len(attention_cards),
        "reviewReady": len(review_ready),
        "needsRonnie": len(decisions) + len(attention_cards),
    }


def infer_checkin_health(signals: dict) -> str:
    if signals.get("needsRonnie") or signals.get("attention") or signals.get("contextState") in {"blocked", "needs_attention"}:
        return "attention"
    if signals.get("activeObjectives") or signals.get("workspaces"):
        return "green"
    return "quiet"


def infer_recommended_action(signals: dict) -> str:
    if signals.get("decisions"):
        return "review_decisions"
    if signals.get("attention") or signals.get("contextState") in {"blocked", "needs_attention"}:
        return "review_context"
    if signals.get("reviewReady"):
        return "review_finished_work"
    return "continue_watching"


def build_checkin_summary(target_type: str, target_id: str, *, signals: dict | None = None, engine=None) -> str:
    if target_type == "objective" and target_id:
        objective = objectives.read_objective(target_id)
        if objective:
            title = objective.get("title") or objective.get("goal") or target_id
            status = objective.get("status") or "unknown"
            health = read_context_health(target_id).get("summary", {})
            badges = ", ".join(b.get("label", "") for b in health.get("badges", []) if b.get("label"))
            return f"{title} is {status}. Context: {badges or health.get('state', 'clear')}."
    signals = signals if isinstance(signals, dict) else build_checkin_signals(target_type, target_id)
    pieces = [
        f"{signals.get('objectives', 0)} objectives watched",
        f"{signals.get('workspaces', 0)} active sessions",
        f"{signals.get('ideas', 0)} ideas",
    ]
    if signals.get("decisions"):
        pieces.append(f"{signals.get('decisions')} decisions need review")
    if signals.get("attention"):
        pieces.append(f"{signals.get('attention')} context items need attention")
    if signals.get("reviewReady"):
        pieces.append(f"{signals.get('reviewReady')} review-ready")
    return "Checked " + ", ".join(pieces) + "."


def _source_preflight_for_objective(objective_id: str) -> dict:
    for preflight in list_preflights(include_archived=True):
        if _normalize_text(preflight.get("objectiveId")) == objective_id:
            return preflight
    return {}


def _objective_card(objective: dict):
    objective_id = objective.get("id") or ""
    source_preflight = _source_preflight_for_objective(objective_id) if objective_id else {}
    health = read_context_health(objective_id) if objective_id else {"summary": {"badges": [], "state": "unknown"}}
    status = str(objective.get("status") or "intake").lower()
    context_state = health.get("summary", {}).get("state")
    if context_state in {"blocked", "needs_attention"}:
        lane = "context"
    elif status in {"review", "reviewing"}:
        lane = "review"
    elif status in {"completed", "done", "accepted"}:
        lane = "done"
    elif status in {"planning", "running", "executing", "started", "active", "in_progress"}:
        lane = "running"
    elif context_state == "unknown":
        lane = "context"
    else:
        lane = "intake"
    return {
        "id": objective_id,
        "type": "objective",
        "lane": lane,
        "title": objective.get("title") or objective.get("goal") or "Untitled objective",
        "summary": objective.get("summary") or objective.get("goal") or "",
        "status": objective.get("status") or "unknown",
        "sourcePreflightId": source_preflight.get("id") or "",
        "launchSummary": source_preflight.get("launchSummary") if isinstance(source_preflight.get("launchSummary"), dict) else {},
        "nextAction": (source_preflight.get("launchSummary") or {}).get("nextAction") if isinstance(source_preflight.get("launchSummary"), dict) else "",
        "contextHealth": health.get("summary", {}),
        "updatedAt": objective.get("updatedAt") or objective.get("createdAt"),
    }


def _idea_card(idea: dict):
    return {
        "id": idea.get("id"),
        "type": "idea",
        "lane": "ideas",
        "title": idea.get("title") or "Untitled idea",
        "summary": idea.get("summary") or "",
        "status": idea.get("status") or "inbox",
        "contextHealth": {"badges": [{"label": "Idea", "severity": "info", "dimension": "idea"}], "state": "idea", "score": 0},
        "updatedAt": idea.get("updatedAt"),
    }


def _preflight_card(preflight: dict):
    preflight = sync_preflight_readiness(preflight)
    missing = preflight.get("missingRequirements", [])
    severity = "attention" if missing else "info"
    objective_id = _normalize_text(preflight.get("objectiveId"))
    objective = objectives.read_objective(objective_id) if objective_id else None
    launch_summary = preflight.get("launchSummary") if isinstance(preflight.get("launchSummary"), dict) else {}
    if isinstance(objective, dict):
        launch_summary = {
            **launch_summary,
            "objectiveId": objective.get("id"),
            "status": objective.get("status"),
            "branchName": objective.get("branchName"),
            "baseBranch": objective.get("baseBranch"),
            "worktreePath": objective.get("worktreePath"),
            "projectDir": objective.get("projectDir"),
            "createdAt": objective.get("createdAt"),
            "nextAction": "Watch planner output",
            "detailUrl": f"/api/objectives/{objective.get('id')}",
        }
    return {
        "id": preflight.get("id"),
        "type": "preflight",
        "lane": "launched" if objective_id else ("context" if missing else "intake"),
        "title": preflight.get("title") or "Untitled pre-flight",
        "summary": preflight.get("summary") or preflight.get("goal") or "Context pre-flight",
        "status": preflight.get("status") or ("launched" if objective_id else "gathering_context"),
        "goal": preflight.get("goal") or preflight.get("title"),
        "projectDir": preflight.get("projectDir") or "",
        "baseBranch": preflight.get("baseBranch") or "",
        "sourceUrl": preflight.get("sourceUrl") or "",
        "objectiveId": objective_id,
        "launchSummary": launch_summary,
        "launchReady": bool(preflight.get("launchReady")),
        "missingRequirements": preflight.get("missingRequirements", []),
        "requiredContext": preflight.get("requiredContext", []),
        "launchPlan": preflight_launch_plan(preflight),
        "contextHealth": {
            "badges": [{"label": "Objective launched" if objective_id else f"Pre-flight {len(missing)}", "severity": "info" if objective_id else severity, "dimension": "preflight"}],
            "state": "running" if objective_id else ("needs_attention" if missing else "clear"),
            "score": max(0, 100 - (len(missing) * 20)),
        },
        "updatedAt": preflight.get("updatedAt"),
    }


def preflight_launch_plan(preflight: dict) -> dict:
    missing = preflight_missing_requirements(preflight)
    missing_ids = {item.get("id") for item in missing}
    context_items = []
    for item in preflight.get("requiredContext", []):
        if not isinstance(item, dict):
            continue
        state = _normalize_context_state(item.get("state"))
        required = bool(item.get("required"))
        context_items.append({
            "id": item.get("id"),
            "label": item.get("label") or item.get("id") or "Context",
            "state": state,
            "required": required,
            "ready": (not required) or state in {"resolved", "not_needed", "waived"},
            "reason": item.get("reason") or "",
        })
    steps = [
        {
            "id": "context",
            "label": "Clear required context",
            "state": "blocked" if any(item.get("id") != "project" and item.get("id") != "goal" for item in missing) else "done",
        },
        {
            "id": "project",
            "label": "Choose repo",
            "state": "blocked" if "project" in missing_ids else "done",
        },
        {
            "id": "goal",
            "label": "Confirm objective goal",
            "state": "blocked" if "goal" in missing_ids else "done",
        },
        {
            "id": "launch",
            "label": "Launch objective",
            "state": "ready" if not missing else "waiting",
        },
    ]
    return {
        "ready": len(missing) == 0,
        "steps": steps,
        "context": context_items,
        "missingCount": len(missing),
        "nextAction": "Launch objective" if not missing else f"Resolve {len(missing)} launch requirement(s)",
    }


def launch_preflight_objective(preflight_id: str, data: dict):
    preflight = read_preflight(preflight_id)
    if not isinstance(preflight, dict):
        return None, "preflight not found"
    if _normalize_text(preflight.get("objectiveId")):
        objective = objectives.read_objective(preflight.get("objectiveId"))
        return objective, None

    goal = _normalize_text(data.get("goal") or preflight.get("goal") or preflight.get("title"))
    project_dir = _normalize_text(data.get("projectDir") or preflight.get("projectDir"))
    project_id = _normalize_text(data.get("projectId") or preflight.get("projectId"))
    base_branch = _normalize_text(data.get("baseBranch") or preflight.get("baseBranch") or "main")
    branch_name = _normalize_text(data.get("branchName"))
    workflow_mode = _normalize_text(data.get("workflowMode") or "structured")
    launch_candidate = dict(preflight)
    launch_candidate.update({"goal": goal, "projectDir": project_dir, "projectId": project_id, "baseBranch": base_branch})
    missing = preflight_missing_requirements(launch_candidate)
    if missing:
        return None, "missing launch requirements: " + ", ".join(item.get("label") or item.get("id") for item in missing)
    try:
        objective = objectives.create_objective(
            goal,
            project_dir,
            base_branch=base_branch,
            branch_name=branch_name,
            project_id=project_id or None,
            workflow_mode=workflow_mode,
        )
    except FileNotFoundError:
        return None, "project not found"
    except (ValueError, OSError) as exc:
        return None, str(exc)
    preflight["objectiveId"] = objective.get("id")
    preflight["status"] = "launched"
    preflight["launchedAt"] = _now_iso()
    preflight["projectId"] = objective.get("projectId") or preflight.get("projectId") or ""
    preflight["projectDir"] = objective.get("projectDir") or project_dir
    preflight["baseBranch"] = objective.get("baseBranch") or base_branch
    preflight["launchSummary"] = {
        "objectiveId": objective.get("id"),
        "status": objective.get("status"),
        "branchName": objective.get("branchName"),
        "baseBranch": objective.get("baseBranch"),
        "worktreePath": objective.get("worktreePath"),
        "projectDir": objective.get("projectDir"),
        "createdAt": objective.get("createdAt"),
        "nextAction": "Watch planner output",
        "detailUrl": f"/api/objectives/{objective.get('id')}",
    }
    preflight["updatedAt"] = preflight["launchedAt"]
    _write_json(_preflight_path(preflight_id), preflight)
    create_checkin({
        "targetType": "objective",
        "targetId": objective.get("id"),
        "summary": f"Launched objective from pre-flight: {goal}.",
        "health": "green",
        "recommendedAction": "continue_watching",
        "signals": {
            "objectives": 1,
            "activeObjectives": 1,
            "preflightId": preflight_id,
            "sourceType": preflight.get("sourceType"),
            "sourceId": preflight.get("sourceId"),
            "needsRonnie": 0,
        },
    })
    return objective, None




def _status_is_done(status: str) -> bool:
    return str(status or "").lower() in {"completed", "done", "accepted"}

def _status_reached_review(status: str) -> bool:
    return str(status or "").lower() in {"review", "reviewing", "completed", "done", "accepted"}

def _status_reached_running(status: str) -> bool:
    return str(status or "").lower() in {"planning", "running", "executing", "started", "active", "in_progress", "review", "reviewing", "completed", "done", "accepted"}

def flow_proof_payload(idea_items: list[dict], preflight_items: list[dict], objective_items: list[dict], jira_items: list[dict]) -> dict:
    """Summarize the single web-first proof path for the UI.

    This keeps the product honest: the web app should always be able to show where
    a real objective flow is in intake -> context -> launch -> run -> review -> done.
    """
    objective_by_id = {item.get("id"): item for item in objective_items if item.get("id")}
    launched_preflights = [item for item in preflight_items if item.get("objectiveId")]
    candidate_preflight = launched_preflights[0] if launched_preflights else (preflight_items[0] if preflight_items else {})
    candidate_objective = objective_by_id.get(candidate_preflight.get("objectiveId")) if candidate_preflight else None
    if not candidate_objective and objective_items:
        candidate_objective = objective_items[0]
    source_item = candidate_preflight or candidate_objective or (idea_items[0] if idea_items else (jira_items[0] if jira_items else {}))

    if not source_item:
        return {
            "active": False,
            "title": "No proof flow started yet.",
            "summary": "Capture an idea or start a pre-flight from Jira to prove the web path.",
            "progressPercent": 0,
            "currentStage": "intake",
            "target": {},
            "steps": [
                {"id": "intake", "label": "Intake", "state": "current"},
                {"id": "context", "label": "Context", "state": "waiting"},
                {"id": "launch", "label": "Launch", "state": "waiting"},
                {"id": "running", "label": "Run", "state": "waiting"},
                {"id": "review", "label": "Review", "state": "waiting"},
                {"id": "done", "label": "Done", "state": "waiting"},
            ],
        }

    status = candidate_objective.get("status") if isinstance(candidate_objective, dict) else ""
    missing = candidate_preflight.get("missingRequirements", []) if isinstance(candidate_preflight, dict) else []
    context_missing = [item for item in missing if item.get("id") not in {"project", "goal"}]
    has_preflight = bool(candidate_preflight)
    has_objective = bool(candidate_objective)
    context_done = has_objective or (has_preflight and not context_missing)
    launch_done = has_objective
    running_done = has_objective and _status_reached_running(status)
    review_done = has_objective and _status_reached_review(status)
    done_done = has_objective and _status_is_done(status)
    step_defs = [
        ("intake", "Intake", True),
        ("context", "Context", context_done),
        ("launch", "Launch", launch_done),
        ("running", "Run", running_done),
        ("review", "Review", review_done),
        ("done", "Done", done_done),
    ]
    first_waiting = next((step_id for step_id, _label, done in step_defs if not done), "done")
    steps = []
    for step_id, label, done in step_defs:
        if done:
            state = "done"
        elif step_id == first_waiting:
            state = "current"
        else:
            state = "waiting"
        steps.append({"id": step_id, "label": label, "state": state})
    completed = len([step for step in steps if step["state"] == "done"])
    current = next((step for step in steps if step["state"] == "current"), steps[-1])
    title = (candidate_objective or candidate_preflight or source_item).get("title") or (candidate_objective or candidate_preflight or source_item).get("summary") or "Web objective flow"
    if done_done:
        summary = "Full web-first path proved through accepted completion."
    elif review_done:
        summary = "Objective is review-ready. The final handoff step is visible in the web UI."
    elif running_done:
        summary = "Objective launched and running from the web flow."
    elif context_done:
        summary = "Context is ready. Launch is the next proof step."
    else:
        summary = "Context needs to be cleared before launch."
    return {
        "active": True,
        "title": title,
        "summary": summary,
        "progressPercent": int(round((completed / len(steps)) * 100)),
        "currentStage": current["id"],
        "target": {
            "type": "objective" if has_objective else ("preflight" if has_preflight else source_item.get("type", "work")),
            "id": (candidate_objective or candidate_preflight or source_item).get("id"),
            "sourcePreflightId": candidate_preflight.get("id") if isinstance(candidate_preflight, dict) else "",
        },
        "steps": steps,
    }

def _jira_card(ticket: dict):
    return {
        "id": ticket.get("key"),
        "type": "jira",
        "lane": "intake",
        "title": f"{ticket.get('key', '')}: {ticket.get('title', '')}".strip(": "),
        "summary": ticket.get("status") or "Assigned Jira ticket",
        "status": ticket.get("priority") or ticket.get("issueType") or "Jira",
        "url": ticket.get("url"),
        "contextHealth": {"badges": [{"label": "Assigned", "severity": "info", "dimension": "jira"}], "state": "jira", "score": 0},
        "updatedAt": None,
    }


def fetch_assigned_jira(limit: int = 8):
    try:
        return {"ok": True, "tickets": jira_routes.fetch_assigned_tickets(limit=limit), "error": None}
    except Exception as exc:  # keep command center calm if Jira CLI/auth is unavailable
        return {"ok": False, "tickets": [], "error": str(exc)}


def command_center_payload(*, engine=None):
    _ensure_dirs()
    objective_items = [_objective_card(obj) for obj in objectives.list_objectives()]
    idea_items = [_idea_card(idea) for idea in list_ideas()]
    preflight_items = [_preflight_card(item) for item in list_preflights()]
    jira_result = fetch_assigned_jira(limit=8)
    jira_items = [_jira_card(ticket) for ticket in jira_result.get("tickets", [])]
    decision_items = list_decisions()
    checkins = list_checkins(limit=8)
    workspace_items = workspaces.list_workspace_sessions()
    active_preflight_items = [card for card in preflight_items if card.get("lane") != "launched"]
    cards = idea_items + active_preflight_items + jira_items + objective_items
    flow_proof = flow_proof_payload(idea_items, preflight_items, objective_items, jira_items)
    lanes = []
    lane_defs = [
        ("ideas", "Ideas / Pre-Jira"),
        ("intake", "Intake"),
        ("context", "Context"),
        ("running", "Running"),
        ("review", "Review / PR"),
        ("done", "Done"),
    ]
    for lane_id, title in lane_defs:
        lanes.append({"id": lane_id, "title": title, "cards": [card for card in cards if card.get("lane") == lane_id]})
    attention_cards = [card for card in cards if card.get("contextHealth", {}).get("state") in {"blocked", "needs_attention"}]
    if decision_items:
        top = {
            "title": decision_items[0].get("title") or "Decision needed",
            "summary": decision_items[0].get("recommendation") or decision_items[0].get("summary") or "Review the open decision.",
            "severity": "attention",
            "decisionId": decision_items[0].get("id"),
            "recommendedAction": "review_decision",
        }
    elif attention_cards:
        top_card = attention_cards[0]
        top = {
            "title": top_card.get("title"),
            "summary": "Context health needs attention before confidence is high.",
            "severity": top_card.get("contextHealth", {}).get("state"),
            "target": {"type": top_card.get("type"), "id": top_card.get("id")},
            "recommendedAction": "review_context",
        }
    else:
        top = {
            "title": "Nothing urgent needs Ronnie right now.",
            "summary": "The orchestrator is watching active work and assigned tickets.",
            "severity": "none",
            "recommendedAction": "continue_watching",
        }
    return {
        "ok": True,
        "generatedAt": _now_iso(),
        "topPriority": top,
        "summary": {
            "objectivesWatched": len(objective_items),
            "activeSessions": len(workspace_items),
            "needsRonnie": len(decision_items) + len(attention_cards),
            "reviewReady": len([c for c in cards if c.get("lane") == "review"]),
            "completed": len([c for c in cards if c.get("lane") == "done"]),
            "ideas": len(idea_items),
            "preflights": len(preflight_items),
            "assignedJira": len(jira_items),
        },
        "lanes": lanes,
        "ideas": idea_items,
        "preflights": preflight_items,
        "assignedJira": {**jira_result, "cards": jira_items},
        "decisions": decision_items[:6],
        "latestCheckIns": checkins,
        "flowProof": flow_proof,
    }


def briefing_payload(*, engine=None):
    command = command_center_payload(engine=engine)
    summary = command.get("summary", {})
    decisions = command.get("decisions", [])
    lanes = {lane.get("id"): lane for lane in command.get("lanes", [])}
    context_cards = lanes.get("context", {}).get("cards", [])
    review_cards = lanes.get("review", {}).get("cards", [])
    done_cards = lanes.get("done", {}).get("cards", [])
    running_cards = lanes.get("running", {}).get("cards", [])
    idea_cards = lanes.get("ideas", {}).get("cards", [])
    jira_tickets = command.get("assignedJira", {}).get("tickets", [])

    next_actions = []
    if decisions:
        first = decisions[0]
        next_actions.append({
            "kind": "decision",
            "label": "Review decision",
            "title": first.get("title") or "Decision needed",
            "target": {"type": "decision", "id": first.get("id")},
            "priority": "high",
        })
    if context_cards:
        first = context_cards[0]
        next_actions.append({
            "kind": "context",
            "label": "Clear context",
            "title": first.get("title") or "Context needed",
            "target": {"type": first.get("type"), "id": first.get("id")},
            "priority": "high",
        })
    if review_cards:
        first = review_cards[0]
        next_actions.append({
            "kind": "review",
            "label": "Review finished work",
            "title": first.get("title") or "Review ready",
            "target": {"type": first.get("type"), "id": first.get("id")},
            "priority": "medium",
        })
    if not next_actions and running_cards:
        first = running_cards[0]
        next_actions.append({
            "kind": "objective",
            "label": first.get("nextAction") or (first.get("launchSummary") or {}).get("nextAction") or "Watch objective",
            "title": first.get("title") or "Objective running",
            "target": {"type": first.get("type"), "id": first.get("id")},
            "priority": "medium",
        })
    if not next_actions and idea_cards:
        first = idea_cards[0]
        next_actions.append({
            "kind": "idea",
            "label": "Groom idea",
            "title": first.get("title") or "Idea captured",
            "target": {"type": "idea", "id": first.get("id")},
            "priority": "low",
        })

    if summary.get("needsRonnie", 0) > 0:
        headline = f"{summary.get('needsRonnie')} item(s) need Ronnie before confidence is high."
    elif running_cards:
        headline = f"{len(running_cards)} active objective(s) are running. No human decision is blocking them."
    elif review_cards:
        headline = f"{len(review_cards)} objective(s) are ready for review."
    else:
        headline = "No urgent handoff right now. The orchestrator is watching the board."

    watchlist = []
    for card in (context_cards + running_cards + review_cards + done_cards + idea_cards)[:6]:
        watchlist.append({
            "type": card.get("type"),
            "id": card.get("id"),
            "title": card.get("title"),
            "status": card.get("status"),
            "lane": card.get("lane"),
            "nextAction": card.get("nextAction") or (card.get("launchSummary") or {}).get("nextAction"),
            "sourcePreflightId": card.get("sourcePreflightId"),
            "badges": card.get("contextHealth", {}).get("badges", []),
        })

    return {
        "ok": True,
        "generatedAt": command.get("generatedAt") or _now_iso(),
        "headline": headline,
        "topPriority": command.get("topPriority", {}),
        "counts": {
            "needsRonnie": summary.get("needsRonnie", 0),
            "activeObjectives": len(running_cards),
            "reviewReady": len(review_cards),
            "completed": len(done_cards),
            "ideas": summary.get("ideas", 0),
            "assignedJira": len(jira_tickets),
            "decisions": len(decisions),
        },
        "nextActions": next_actions[:4],
        "watchlist": watchlist,
        "recentCheckIns": command.get("latestCheckIns", [])[:5],
        "flowProof": command.get("flowProof", {}),
    }


def handle_get_command_center(handler, parsed, *, engine=None):
    handler._json_response(command_center_payload(engine=engine))


def handle_get_briefing(handler, parsed, *, engine=None):
    handler._json_response(briefing_payload(engine=engine))


def handle_get_ideas(handler, parsed):
    params = handler.parse_qs(parsed.query)
    include_archived = str(params.get("includeArchived", [""])[0]).lower() in {"1", "true", "yes"}
    handler._json_response({"ok": True, "ideas": list_ideas(include_archived=include_archived)})


def handle_get_idea(handler, idea_id: str):
    idea = read_idea(idea_id)
    if not isinstance(idea, dict):
        handler._json_response({"ok": False, "error": "idea not found"}, 404)
        return
    handler._json_response({"ok": True, "idea": idea})


def handle_post_idea(handler, data):
    handler._json_response({"ok": True, "idea": create_idea(data)}, 201)


def handle_patch_idea(handler, idea_id: str, data):
    idea = update_idea(idea_id, data)
    if not isinstance(idea, dict):
        handler._json_response({"ok": False, "error": "idea not found"}, 404)
        return
    handler._json_response({"ok": True, "idea": idea})


def handle_delete_idea(handler, idea_id: str):
    if not delete_idea(idea_id):
        handler._json_response({"ok": False, "error": "idea not found"}, 404)
        return
    handler._json_response({"ok": True})


def handle_get_preflights(handler, parsed):
    params = handler.parse_qs(parsed.query)
    include_archived = str(params.get("includeArchived", [""])[0]).lower() in {"1", "true", "yes"}
    handler._json_response({"ok": True, "preflights": list_preflights(include_archived=include_archived)})


def handle_get_preflight(handler, preflight_id: str):
    preflight = read_preflight(preflight_id)
    if not isinstance(preflight, dict):
        handler._json_response({"ok": False, "error": "preflight not found"}, 404)
        return
    handler._json_response({"ok": True, "preflight": preflight})


def handle_post_preflight(handler, data):
    try:
        preflight = create_preflight(data)
    except FileNotFoundError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 404)
        return
    handler._json_response({"ok": True, "preflight": preflight}, 201)


def handle_patch_preflight(handler, preflight_id: str, data):
    preflight = update_preflight(preflight_id, data)
    if not isinstance(preflight, dict):
        handler._json_response({"ok": False, "error": "preflight not found"}, 404)
        return
    handler._json_response({"ok": True, "preflight": preflight})


def handle_launch_preflight_objective(handler, preflight_id: str, data):
    objective, error = launch_preflight_objective(preflight_id, data)
    if error == "preflight not found":
        handler._json_response({"ok": False, "error": error}, 404)
        return
    if error:
        handler._json_response({"ok": False, "error": error}, 400)
        return
    handler._json_response({"ok": True, "objective": objective, "preflight": read_preflight(preflight_id)}, 201)


def handle_delete_preflight(handler, preflight_id: str):
    if not delete_preflight(preflight_id):
        handler._json_response({"ok": False, "error": "preflight not found"}, 404)
        return
    handler._json_response({"ok": True})


def handle_get_decisions(handler, parsed):
    params = handler.parse_qs(parsed.query)
    include_resolved = str(params.get("includeResolved", [""])[0]).lower() in {"1", "true", "yes"}
    handler._json_response({"ok": True, "decisions": list_decisions(include_resolved=include_resolved)})


def handle_get_decision(handler, decision_id: str):
    decision = read_decision(decision_id)
    if not isinstance(decision, dict):
        handler._json_response({"ok": False, "error": "decision not found"}, 404)
        return
    handler._json_response({"ok": True, "decision": decision})


def handle_post_decision(handler, data):
    handler._json_response({"ok": True, "decision": create_decision(data)}, 201)


def handle_patch_decision(handler, decision_id: str, data, *, action: str = "patch"):
    decision = update_decision(decision_id, data, action=action)
    if not isinstance(decision, dict):
        handler._json_response({"ok": False, "error": "decision not found"}, 404)
        return
    handler._json_response({"ok": True, "decision": decision})


def handle_get_checkins(handler, parsed):
    params = handler.parse_qs(parsed.query)
    try:
        limit = int(params.get("limit", ["50"])[0])
    except (TypeError, ValueError):
        limit = 50
    handler._json_response({"ok": True, "checkIns": list_checkins(limit=max(1, min(limit, 200)))})


def handle_post_checkin(handler, data, *, engine=None):
    handler._json_response({"ok": True, "checkIn": create_checkin(data, engine=engine)}, 201)


def handle_get_context_health(handler, objective_id: str):
    if objectives.read_objective(objective_id) is None:
        handler._json_response({"ok": False, "error": "objective not found"}, 404)
        return
    handler._json_response({"ok": True, "contextHealth": read_context_health(objective_id)})


def handle_patch_context_health(handler, objective_id: str, dimension_id: str, data, *, action: str = "patch"):
    if objectives.read_objective(objective_id) is None:
        handler._json_response({"ok": False, "error": "objective not found"}, 404)
        return
    try:
        health = update_context_dimension(objective_id, dimension_id, data, action=action)
    except ValueError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 400)
        return
    handler._json_response({"ok": True, "contextHealth": health})


def handle_context_attention(handler):
    items = []
    for objective in objectives.list_objectives():
        objective_id = objective.get("id")
        if not objective_id:
            continue
        health = read_context_health(objective_id)
        state = health.get("summary", {}).get("state")
        if state in {"blocked", "needs_attention"}:
            items.append({"objective": _objective_card(objective), "contextHealth": health.get("summary", {})})
    handler._json_response({"ok": True, "items": items})
