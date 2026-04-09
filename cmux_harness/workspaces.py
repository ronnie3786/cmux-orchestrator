from __future__ import annotations

import json
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

from . import objectives


WORKSPACES_DIR = objectives.OBJECTIVES_DIR.parent / "workspaces"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _coerce_timestamp(value) -> float:
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value).timestamp()
        except ValueError:
            return 0.0
    return 0.0


def _normalize_path(path_value: str | Path | None) -> str:
    raw = str(path_value or "").strip()
    if not raw:
        return ""
    return str(Path(raw).expanduser().absolute())


def _workspace_dir(workspace_id: str) -> Path:
    return WORKSPACES_DIR / workspace_id


def _workspace_path(workspace_id: str) -> Path:
    return _workspace_dir(workspace_id) / "workspace.json"


def _messages_path(workspace_id: str) -> Path:
    return _workspace_dir(workspace_id) / "messages.jsonl"


def _debug_path(workspace_id: str) -> Path:
    return _workspace_dir(workspace_id) / "debug.jsonl"


def _conversation_context_path(workspace_id: str) -> Path:
    return _workspace_dir(workspace_id) / "conversation-context.md"


def _turns_dir(workspace_id: str) -> Path:
    return _workspace_dir(workspace_id) / "turns"


def _turn_path(workspace_id: str, turn_id: str) -> Path:
    return _turns_dir(workspace_id) / f"{turn_id}.json"


def _validate_root(root_path: str) -> str:
    normalized = _normalize_path(root_path)
    if not normalized:
        raise ValueError("rootPath required")
    path = Path(normalized)
    if not path.exists():
        raise ValueError("rootPath does not exist")
    if not path.is_dir():
        raise ValueError("rootPath must be a directory")
    try:
        result = subprocess.run(
            ["git", "-C", normalized, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        message = stderr or stdout or "rootPath must be inside a git repository"
        raise ValueError(message) from exc
    except OSError as exc:
        raise ValueError(str(exc)) from exc
    return _normalize_path(normalized)


def _infer_name(root_path: str) -> str:
    value = Path(root_path).name.strip()
    return value or "Workspace"


def create_workspace_session(project_id: str, root_path: str, name: str | None = None, source: str = "manual-path") -> dict:
    project = objectives.read_project(project_id)
    if project is None:
        raise FileNotFoundError(f"project not found: {project_id}")
    canonical_root = _validate_root(root_path)
    workspace_id = str(uuid.uuid4())
    now = _now_iso()
    workspace = {
        "id": workspace_id,
        "projectId": project_id,
        "name": str(name or "").strip() or _infer_name(canonical_root),
        "rootPath": canonical_root,
        "source": str(source or "manual-path").strip() or "manual-path",
        "status": "idle",
        "cmuxWorkspaceId": "",
        "sessionActive": False,
        "lastActivityAt": now,
        "createdAt": now,
        "updatedAt": now,
    }
    directory = _workspace_dir(workspace_id)
    directory.mkdir(parents=True, exist_ok=False)
    with open(_workspace_path(workspace_id), "w", encoding="utf-8") as f:
        json.dump(workspace, f, indent=2)
    return workspace


def read_workspace_session(workspace_id: str) -> dict | None:
    try:
        with open(_workspace_path(workspace_id), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def list_workspace_sessions() -> list[dict]:
    try:
        WORKSPACES_DIR.mkdir(parents=True, exist_ok=True)
        items = sorted((p for p in WORKSPACES_DIR.iterdir() if p.is_dir()), key=lambda p: p.name)
    except OSError:
        return []
    output = []
    for item in items:
        workspace = read_workspace_session(item.name)
        if workspace is not None:
            output.append(workspace)
    return output


def list_workspace_sessions_for_project(project_id: str) -> list[dict]:
    return [item for item in list_workspace_sessions() if item.get("projectId") == project_id]


def update_workspace_session(workspace_id: str, updates: dict) -> dict:
    workspace = read_workspace_session(workspace_id)
    if workspace is None:
        raise FileNotFoundError(f"workspace not found: {workspace_id}")
    next_updates = dict(updates or {})
    if "rootPath" in next_updates:
        next_updates["rootPath"] = _validate_root(str(next_updates.get("rootPath") or ""))
    workspace.update(next_updates)
    workspace["updatedAt"] = _now_iso()
    with open(_workspace_path(workspace_id), "w", encoding="utf-8") as f:
        json.dump(workspace, f, indent=2)
    return workspace


def append_workspace_message(workspace_id: str, msg: dict) -> dict:
    path = _messages_path(workspace_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(msg) + "\n")
    return msg


def load_workspace_messages(workspace_id: str) -> list[dict]:
    path = _messages_path(workspace_id)
    messages = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(msg, dict):
                    messages.append(msg)
    except OSError:
        return []
    return messages


def set_action_buttons(workspace_id: str, buttons: list[dict]) -> list[dict]:
    workspace = read_workspace_session(workspace_id)
    if workspace is None:
        raise FileNotFoundError(f"workspace not found: {workspace_id}")
    workspace["actionButtons"] = buttons
    workspace["updatedAt"] = _now_iso()
    with open(_workspace_path(workspace_id), "w", encoding="utf-8") as f:
        json.dump(workspace, f, indent=2)
    return buttons


def get_debug_entries(workspace_id: str, limit: int = 200, level: str | None = None) -> list[dict]:
    entries = []
    path = _debug_path(workspace_id)
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(entry, dict):
                    continue
                if level and str(entry.get("level") or "").lower() != level.lower():
                    continue
                entries.append(entry)
    except OSError:
        return []
    if len(entries) > limit:
        entries = entries[-limit:]
    return entries


def append_workspace_debug(workspace_id: str, entry: dict) -> dict:
    path = _debug_path(workspace_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")
    return entry


def workspace_conversation_context_path(workspace_id: str) -> Path:
    return _conversation_context_path(workspace_id)


def sync_workspace_conversation_context(
    workspace_id: str,
    *,
    max_turns: int = 30,
    max_chars: int = 24000,
) -> Path:
    workspace = read_workspace_session(workspace_id)
    if workspace is None:
        raise FileNotFoundError(f"workspace not found: {workspace_id}")
    messages = load_workspace_messages(workspace_id)
    turns = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        msg_type = str(message.get("type") or "").strip().lower()
        if msg_type not in {"user", "assistant"}:
            continue
        content = str(message.get("content") or "").strip()
        if not content:
            continue
        role = "User" if msg_type == "user" else "Assistant"
        timestamp = str(message.get("timestamp") or "").strip()
        turns.append(
            {
                "role": role,
                "timestamp": timestamp,
                "content": content,
            }
        )
    if len(turns) > max_turns:
        turns = turns[-max_turns:]

    kept = []
    total_chars = 0
    for turn in reversed(turns):
        content = turn["content"]
        if len(content) > 4000:
            content = content[:4000].rstrip() + "\n...[truncated]"
        heading = f"## {turn['role']}"
        if turn["timestamp"]:
            heading += f" ({turn['timestamp']})"
        block = f"{heading}\n\n{content}"
        projected = total_chars + len(block) + (2 if kept else 0)
        if kept and projected > max_chars:
            break
        kept.append(block)
        total_chars = projected
    kept.reverse()

    body = [
        "# Workspace Conversation Context",
        "",
        f"- Workspace: {workspace.get('name') or workspace.get('rootPath') or workspace_id}",
        f"- Root Path: {workspace.get('rootPath') or ''}",
        "",
        "This file contains recent user and assistant turns for continuity when a workspace session is re-opened.",
        "It is generated by the harness and should be treated as read-only session context.",
        "",
        "## Recent Turns",
    ]
    if kept:
        body.extend([""] + kept)
    else:
        body.extend(["", "_No user/assistant turns yet._"])

    path = _conversation_context_path(workspace_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(body).rstrip() + "\n")
    return path


def create_workspace_turn(workspace_id: str, user_message: str = "") -> dict:
    workspace = read_workspace_session(workspace_id)
    if workspace is None:
        raise FileNotFoundError(f"workspace not found: {workspace_id}")
    turn_id = str(uuid.uuid4())
    now = _now_iso()
    turn = {
        "id": turn_id,
        "workspaceId": workspace_id,
        "userMessage": str(user_message or ""),
        "token": uuid.uuid4().hex,
        "status": "pending",
        "assistantMessageId": "",
        "contentPreview": "",
        "callbackSource": "",
        "lastError": "",
        "progressSummary": "",
        "progressState": "",
        "progressUpdatedAt": "",
        "progressSequence": 0,
        "lastScreenHash": "",
        "createdAt": now,
        "updatedAt": now,
        "completedAt": "",
    }
    path = _turn_path(workspace_id, turn_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(turn, f, indent=2)
    return turn


def read_workspace_turn(workspace_id: str, turn_id: str) -> dict | None:
    try:
        with open(_turn_path(workspace_id, turn_id), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def update_workspace_turn(workspace_id: str, turn_id: str, updates: dict) -> dict:
    turn = read_workspace_turn(workspace_id, turn_id)
    if turn is None:
        raise FileNotFoundError(f"workspace turn not found: {workspace_id}/{turn_id}")
    next_updates = dict(updates or {})
    turn.update(next_updates)
    turn["updatedAt"] = _now_iso()
    with open(_turn_path(workspace_id, turn_id), "w", encoding="utf-8") as f:
        json.dump(turn, f, indent=2)
    return turn


def list_workspace_turns(workspace_id: str) -> list[dict]:
    directory = _turns_dir(workspace_id)
    try:
        items = sorted((p for p in directory.iterdir() if p.is_file() and p.suffix == ".json"), key=lambda p: p.name)
    except OSError:
        return []
    output = []
    for item in items:
        turn = read_workspace_turn(workspace_id, item.stem)
        if turn is not None:
            output.append(turn)
    return output


def get_active_workspace_turn(workspace_id: str) -> dict | None:
    candidates = [
        turn for turn in list_workspace_turns(workspace_id)
        if str(turn.get("status") or "").lower() in {"pending", "timed_out"}
    ]
    if not candidates:
        return None
    candidates.sort(key=lambda turn: (_coerce_timestamp(turn.get("createdAt")), str(turn.get("id") or "")))
    return candidates[-1]


def delete_workspace_session(workspace_id: str) -> bool:
    directory = _workspace_dir(workspace_id)
    if not directory.exists():
        return False
    for path in sorted(directory.glob("**/*"), reverse=True):
        if path.is_file() or path.is_symlink():
            path.unlink(missing_ok=True)
        elif path.is_dir():
            try:
                path.rmdir()
            except OSError:
                pass
    try:
        directory.rmdir()
    except OSError:
        return False
    return True
