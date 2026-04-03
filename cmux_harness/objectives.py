from __future__ import annotations

import json
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path


OBJECTIVES_DIR = Path.home() / ".cmux-harness" / "objectives"


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _objective_path(objective_id):
    return get_objective_dir(objective_id) / "objective.json"


def get_objective_dir(objective_id: str) -> Path:
    return OBJECTIVES_DIR / objective_id


def create_objective(goal: str, project_dir: str, base_branch: str = "main") -> dict:
    OBJECTIVES_DIR.mkdir(parents=True, exist_ok=True)
    objective_id = str(uuid.uuid4())
    now = _now_iso()
    objective = {
        "id": objective_id,
        "goal": goal,
        "status": "planning",
        "projectDir": project_dir,
        "baseBranch": base_branch,
        "createdAt": now,
        "updatedAt": now,
        "tasks": [],
    }
    objective_dir = get_objective_dir(objective_id)
    objective_dir.mkdir(parents=True, exist_ok=False)
    with open(objective_dir / "objective.json", "w", encoding="utf-8") as f:
        json.dump(objective, f, indent=2)
    return objective


def read_objective(objective_id: str) -> dict | None:
    try:
        with open(_objective_path(objective_id), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


_objective_locks: dict = {}
_objective_locks_lock = __import__("threading").Lock()


def _get_objective_lock(objective_id: str):
    with _objective_locks_lock:
        if objective_id not in _objective_locks:
            _objective_locks[objective_id] = __import__("threading").Lock()
        return _objective_locks[objective_id]


def update_objective(objective_id: str, updates: dict) -> dict:
    lock = _get_objective_lock(objective_id)
    with lock:
        objective = read_objective(objective_id)
        if objective is None:
            raise FileNotFoundError(f"objective not found: {objective_id}")
        objective.update(updates)
        objective["updatedAt"] = _now_iso()
        with open(_objective_path(objective_id), "w", encoding="utf-8") as f:
            json.dump(objective, f, indent=2)
        return objective


def update_task(objective_id: str, task_id: str, task_updates: dict) -> dict:
    """Atomically update a single task within an objective.

    Reads the latest objective from disk, finds the task, applies updates,
    and writes back — all under a lock. This prevents lost-update races
    when multiple threads modify different tasks concurrently.
    """
    lock = _get_objective_lock(objective_id)
    with lock:
        objective = read_objective(objective_id)
        if objective is None:
            raise FileNotFoundError(f"objective not found: {objective_id}")
        tasks = objective.get("tasks", [])
        task = next((t for t in tasks if t.get("id") == task_id), None)
        if task is None:
            raise KeyError(f"task not found: {task_id}")
        task.update(task_updates)
        objective["updatedAt"] = _now_iso()
        with open(_objective_path(objective_id), "w", encoding="utf-8") as f:
            json.dump(objective, f, indent=2)
        return task


def list_objectives() -> list[dict]:
    try:
        OBJECTIVES_DIR.mkdir(parents=True, exist_ok=True)
        objective_dirs = sorted((p for p in OBJECTIVES_DIR.iterdir() if p.is_dir()), key=lambda p: p.name)
    except OSError:
        return []
    objectives = []
    for objective_dir in objective_dirs:
        objective = read_objective(objective_dir.name)
        if objective is not None:
            objectives.append(objective)
    return objectives


def create_task_dir(objective_id: str, task_id: str) -> Path:
    task_dir = get_objective_dir(objective_id) / "tasks" / task_id
    task_dir.mkdir(parents=True, exist_ok=True)
    for filename in ("spec.md", "context.md", "progress.md"):
        path = task_dir / filename
        if not path.exists():
            path.write_text("", encoding="utf-8")
    return task_dir


def read_task_file(objective_id: str, task_id: str, filename: str) -> str | None:
    path = get_objective_dir(objective_id) / "tasks" / task_id / filename
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def write_task_file(objective_id: str, task_id: str, filename: str, content: str):
    task_dir = get_objective_dir(objective_id) / "tasks" / task_id
    task_dir.mkdir(parents=True, exist_ok=True)
    (task_dir / filename).write_text(content, encoding="utf-8")


def delete_objective(objective_id: str) -> bool:
    objective_dir = get_objective_dir(objective_id)
    if not objective_dir.exists():
        return False
    shutil.rmtree(objective_dir)
    return True
