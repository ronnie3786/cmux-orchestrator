from __future__ import annotations

import json
import re
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path


OBJECTIVES_DIR = Path.home() / ".cmux-harness" / "objectives"


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _projects_dir() -> Path:
    return OBJECTIVES_DIR.parent / "projects"


def _project_path(project_id: str) -> Path:
    return _projects_dir() / project_id / "project.json"


def _objective_path(objective_id):
    return get_objective_dir(objective_id) / "objective.json"


def get_objective_dir(objective_id: str) -> Path:
    return OBJECTIVES_DIR / objective_id


def get_project_dir(project_id: str) -> Path:
    return _projects_dir() / project_id


def _default_branch_name(objective_id: str) -> str:
    return f"orchestrator/{objective_id[:8]}"


def _slugify_branch_name(branch_name: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", str(branch_name or "").strip())
    slug = re.sub(r"-+", "-", slug).strip("-")
    return slug or "worktree"


def _objective_worktree_path(project_dir: str, branch_name: str) -> Path:
    return Path(project_dir) / ".cmux-harness" / "worktrees" / _slugify_branch_name(branch_name)


def _normalize_path(path_value: str | Path | None) -> str:
    raw = str(path_value or "").strip()
    if not raw:
        return ""
    return str(Path(raw).expanduser().absolute())


def _normalize_workflow_mode(workflow_mode: str | None) -> str:
    value = str(workflow_mode or "structured").strip().lower()
    return value if value in {"structured", "direct"} else "structured"


def _infer_project_name(root_path: str) -> str:
    name = Path(root_path).name.strip()
    return name or "Project"


def _validate_project_root(root_path: str) -> str:
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
    resolved = (result.stdout or "").strip()
    return _normalize_path(resolved or normalized)


def _safe_legacy_root(root_path: str | None) -> str:
    candidate = _normalize_path(root_path)
    if candidate:
        return candidate
    cwd = _normalize_path(Path.cwd())
    return cwd or str(OBJECTIVES_DIR.parent)


def _find_project_by_root_path(root_path: str) -> dict | None:
    normalized = _normalize_path(root_path)
    if not normalized:
        return None
    for project in list_projects():
        if _normalize_path(project.get("rootPath")) == normalized:
            return project
    return None


def create_project(name: str, root_path: str, default_base_branch: str = "main") -> dict:
    canonical_root = _validate_project_root(root_path)
    duplicate = _find_project_by_root_path(canonical_root)
    if duplicate is not None:
        raise ValueError("project already exists for rootPath")
    project_id = str(uuid.uuid4())
    now = _now_iso()
    project = {
        "id": project_id,
        "name": str(name or "").strip() or _infer_project_name(canonical_root),
        "rootPath": canonical_root,
        "defaultBaseBranch": str(default_base_branch or "main").strip() or "main",
        "createdAt": now,
        "updatedAt": now,
    }
    project_dir = get_project_dir(project_id)
    project_dir.mkdir(parents=True, exist_ok=False)
    try:
        with open(project_dir / "project.json", "w", encoding="utf-8") as f:
            json.dump(project, f, indent=2)
    except Exception:
        shutil.rmtree(project_dir, ignore_errors=True)
        raise
    return project


def _create_legacy_project(root_path: str, default_base_branch: str = "main", name: str | None = None) -> dict:
    normalized = _safe_legacy_root(root_path)
    duplicate = _find_project_by_root_path(normalized)
    if duplicate is not None:
        return duplicate
    project_id = str(uuid.uuid4())
    now = _now_iso()
    project = {
        "id": project_id,
        "name": str(name or "").strip() or _infer_project_name(normalized),
        "rootPath": normalized,
        "defaultBaseBranch": str(default_base_branch or "main").strip() or "main",
        "createdAt": now,
        "updatedAt": now,
    }
    project_dir = get_project_dir(project_id)
    project_dir.mkdir(parents=True, exist_ok=False)
    try:
        with open(project_dir / "project.json", "w", encoding="utf-8") as f:
            json.dump(project, f, indent=2)
    except Exception:
        shutil.rmtree(project_dir, ignore_errors=True)
        raise
    return project


def get_or_create_project_for_root_path(
    root_path: str,
    *,
    default_base_branch: str = "main",
    name: str | None = None,
    strict: bool = True,
) -> dict:
    if strict:
        canonical_root = _validate_project_root(root_path)
        duplicate = _find_project_by_root_path(canonical_root)
        if duplicate is not None:
            return duplicate
        return create_project(name or _infer_project_name(canonical_root), canonical_root, default_base_branch)
    normalized = _normalize_path(root_path)
    duplicate = _find_project_by_root_path(normalized or root_path)
    if duplicate is not None:
        return duplicate
    try:
        return get_or_create_project_for_root_path(
            root_path,
            default_base_branch=default_base_branch,
            name=name,
            strict=True,
        )
    except ValueError:
        return _create_legacy_project(
            root_path,
            default_base_branch=default_base_branch,
            name=name,
        )


def read_project(project_id: str) -> dict | None:
    try:
        with open(_project_path(project_id), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def list_projects() -> list[dict]:
    try:
        _projects_dir().mkdir(parents=True, exist_ok=True)
        project_dirs = sorted((p for p in _projects_dir().iterdir() if p.is_dir()), key=lambda p: p.name)
    except OSError:
        return []
    projects = []
    for project_dir in project_dirs:
        project = read_project(project_dir.name)
        if project is not None:
            projects.append(project)
    return projects


def update_project(project_id: str, updates: dict) -> dict:
    project = read_project(project_id)
    if project is None:
        raise FileNotFoundError(f"project not found: {project_id}")
    next_name = project.get("name")
    next_root_path = project.get("rootPath")
    next_default_base_branch = project.get("defaultBaseBranch")
    if "name" in updates:
        next_name = str(updates.get("name") or "").strip() or next_name
    if "defaultBaseBranch" in updates:
        next_default_base_branch = str(updates.get("defaultBaseBranch") or "").strip() or "main"
    if "rootPath" in updates:
        next_root_path = _validate_project_root(str(updates.get("rootPath") or ""))
        duplicate = _find_project_by_root_path(next_root_path)
        if duplicate is not None and duplicate.get("id") != project_id:
            raise ValueError("project already exists for rootPath")
    project["name"] = next_name
    project["rootPath"] = next_root_path
    project["defaultBaseBranch"] = next_default_base_branch
    project["updatedAt"] = _now_iso()
    with open(_project_path(project_id), "w", encoding="utf-8") as f:
        json.dump(project, f, indent=2)
    return project


def delete_project(project_id: str) -> bool:
    project_dir = get_project_dir(project_id)
    if not project_dir.exists():
        return False
    linked_objectives = [item for item in list_objectives() if item.get("projectId") == project_id]
    if linked_objectives:
        raise ValueError("cannot delete project with existing objectives")
    shutil.rmtree(project_dir)
    return True


_objective_locks: dict = {}
_objective_locks_lock = __import__("threading").Lock()


def _get_objective_lock(objective_id: str):
    with _objective_locks_lock:
        if objective_id not in _objective_locks:
            _objective_locks[objective_id] = __import__("threading").Lock()
        return _objective_locks[objective_id]


def _persist_objective(objective_id: str, objective: dict) -> dict:
    with open(_objective_path(objective_id), "w", encoding="utf-8") as f:
        json.dump(objective, f, indent=2)
    return objective


def _ensure_objective_project(objective_id: str, objective: dict) -> tuple[dict, bool]:
    changed = False
    project = None
    project_id = str(objective.get("projectId") or "").strip()
    if project_id:
        project = read_project(project_id)
    if project is None:
        legacy_root = str(objective.get("projectDir") or "").strip() or str(objective.get("worktreePath") or "").strip()
        legacy_base_branch = str(objective.get("baseBranch") or "main").strip() or "main"
        project = get_or_create_project_for_root_path(
            legacy_root,
            default_base_branch=legacy_base_branch,
            name=_infer_project_name(legacy_root or _safe_legacy_root(None)),
            strict=False,
        )
        objective["projectId"] = project["id"]
        changed = True
    if not objective.get("projectDir"):
        objective["projectDir"] = project["rootPath"]
        changed = True
    if not objective.get("baseBranch"):
        objective["baseBranch"] = project.get("defaultBaseBranch") or "main"
        changed = True
    workflow_mode = _normalize_workflow_mode(objective.get("workflowMode"))
    if objective.get("workflowMode") != workflow_mode:
        objective["workflowMode"] = workflow_mode
        changed = True
    tasks = objective.get("tasks")
    if not isinstance(tasks, list):
        objective["tasks"] = []
        changed = True
    return objective, changed


def _create_objective_worktree(project_dir: str, worktree_path: Path, branch_name: str, base_branch: str):
    worktree_path.parent.mkdir(parents=True, exist_ok=True)
    add_new_branch_cmd = [
        "git",
        "-C",
        project_dir,
        "worktree",
        "add",
        str(worktree_path),
        "-b",
        branch_name,
        base_branch,
    ]
    try:
        subprocess.run(
            add_new_branch_cmd,
            capture_output=True,
            text=True,
            check=True,
        )
        return
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        message = stderr or stdout or f"git worktree add failed with exit code {exc.returncode}"
        if "already exists" not in message.lower():
            raise OSError(message) from exc
    except OSError as exc:
        raise OSError(str(exc)) from exc

    reuse_branch_cmd = [
        "git",
        "-C",
        project_dir,
        "worktree",
        "add",
        str(worktree_path),
        branch_name,
    ]
    try:
        subprocess.run(
            reuse_branch_cmd,
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        message = stderr or stdout or f"git worktree add failed with exit code {exc.returncode}"
        raise OSError(message) from exc
    except OSError as exc:
        raise OSError(str(exc)) from exc


def _remove_objective_worktree(project_dir: str, worktree_path: str | None):
    if not project_dir or not worktree_path:
        return
    try:
        subprocess.run(
            ["git", "-C", project_dir, "worktree", "remove", str(worktree_path), "--force"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, OSError):
        return


def create_objective(
    goal: str,
    project_dir: str | None = None,
    base_branch: str | None = None,
    branch_name: str | None = None,
    *,
    project_id: str | None = None,
    workflow_mode: str = "structured",
) -> dict:
    OBJECTIVES_DIR.mkdir(parents=True, exist_ok=True)
    if project_id:
        project = read_project(project_id)
        if project is None:
            raise FileNotFoundError(f"project not found: {project_id}")
    else:
        if not project_dir:
            raise ValueError("projectDir or projectId required")
        project = get_or_create_project_for_root_path(
            project_dir,
            default_base_branch=str(base_branch or "main").strip() or "main",
            name=_infer_project_name(project_dir),
            strict=False,
        )
    objective_id = str(uuid.uuid4())
    now = _now_iso()
    resolved_branch_name = (branch_name or "").strip() or _default_branch_name(objective_id)
    resolved_base_branch = str(base_branch or project.get("defaultBaseBranch") or "main").strip() or "main"
    resolved_project_dir = str(project.get("rootPath") or project_dir or "").strip()
    worktree_path = _objective_worktree_path(resolved_project_dir, resolved_branch_name)
    objective = {
        "id": objective_id,
        "goal": goal,
        "status": "planning",
        "projectId": project["id"],
        "projectDir": resolved_project_dir,
        "baseBranch": resolved_base_branch,
        "branchName": resolved_branch_name,
        "worktreePath": str(worktree_path),
        "workflowMode": _normalize_workflow_mode(workflow_mode),
        "createdAt": now,
        "updatedAt": now,
        "tasks": [],
    }
    objective_dir = get_objective_dir(objective_id)
    objective_dir.mkdir(parents=True, exist_ok=False)
    try:
        with open(objective_dir / "objective.json", "w", encoding="utf-8") as f:
            json.dump(objective, f, indent=2)
        _create_objective_worktree(resolved_project_dir, worktree_path, resolved_branch_name, resolved_base_branch)
    except Exception:
        shutil.rmtree(objective_dir, ignore_errors=True)
        raise
    return objective


def read_objective(objective_id: str) -> dict | None:
    try:
        with open(_objective_path(objective_id), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    data, changed = _ensure_objective_project(objective_id, data)
    if changed:
        data["updatedAt"] = _now_iso()
        _persist_objective(objective_id, data)
    return data


def update_objective(objective_id: str, updates: dict) -> dict:
    lock = _get_objective_lock(objective_id)
    with lock:
        objective = read_objective(objective_id)
        if objective is None:
            raise FileNotFoundError(f"objective not found: {objective_id}")
        if "workflowMode" in updates:
            updates = dict(updates)
            updates["workflowMode"] = _normalize_workflow_mode(updates.get("workflowMode"))
        objective.update(updates)
        objective, _ = _ensure_objective_project(objective_id, objective)
        objective["updatedAt"] = _now_iso()
        _persist_objective(objective_id, objective)
        return objective


def update_task(objective_id: str, task_id: str, task_updates: dict) -> dict:
    """Atomically update a single task within an objective.

    Reads the latest objective from disk, finds the task, applies updates,
    and writes back, all under a lock. This prevents lost-update races
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
        _persist_objective(objective_id, objective)
        return task


def append_task(objective_id: str, task: dict) -> dict:
    lock = _get_objective_lock(objective_id)
    with lock:
        objective = read_objective(objective_id)
        if objective is None:
            raise FileNotFoundError(f"objective not found: {objective_id}")
        tasks = objective.setdefault("tasks", [])
        if not isinstance(tasks, list):
            tasks = []
            objective["tasks"] = tasks
        tasks.append(task)
        objective["updatedAt"] = _now_iso()
        _persist_objective(objective_id, objective)
        return task


def set_action_buttons(objective_id: str, buttons: list[dict]) -> list[dict]:
    lock = _get_objective_lock(objective_id)
    with lock:
        objective = read_objective(objective_id)
        if objective is None:
            raise FileNotFoundError(f"objective not found: {objective_id}")
        objective["actionButtons"] = buttons
        objective["updatedAt"] = _now_iso()
        _persist_objective(objective_id, objective)
        return buttons


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


def get_objective_worktree_path(objective_id: str) -> str | None:
    objective = read_objective(objective_id)
    if objective is None:
        return None
    worktree_path = objective.get("worktreePath")
    return str(worktree_path) if worktree_path else None


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
    objective = read_objective(objective_id) or {}
    _remove_objective_worktree(objective.get("projectDir", ""), objective.get("worktreePath"))
    shutil.rmtree(objective_dir)
    return True
