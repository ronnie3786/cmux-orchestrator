from __future__ import annotations

import json
import os
import re
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import storage


DATA_DIR = storage.LOG_DIR / "orchestrator-v2"
DB_FILENAME = "orchestrator-v2.sqlite3"
GOALS_DIRNAME = "goals"

TASK_STATUSES = {
    "Backlog",
    "Investigating",
    "To Do",
    "Running",
    "In Progress",
    "Blocked",
    "In Review",
    "Done",
    "Archived",
}
ACTIVE_TASK_STATUSES = TASK_STATUSES - {"Done", "Archived"}
TASK_PRIORITIES = {"Low", "Medium", "High"}
SESSION_LAUNCH_TYPES = {"Empty shell", "Codex", "Claude Code", "OpenCode"}


class V2StorageError(ValueError):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def safe_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def data_dir() -> Path:
    return Path(os.environ.get("CMUX_ORCHESTRATOR_V2_DIR") or DATA_DIR).expanduser()


def default_db_path() -> Path:
    return data_dir() / DB_FILENAME


def default_goals_dir() -> Path:
    return data_dir() / GOALS_DIRNAME


def _json_dumps(value: Any) -> str:
    return json.dumps(value if value is not None else {}, sort_keys=True)


def _json_loads(value: str | None, default: Any):
    if not value:
        return default
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return default


def _normalize_text(value: Any, *, field: str, required: bool = False) -> str:
    text = str(value or "").strip()
    if required and not text:
        raise V2StorageError(f"{field} required", 400)
    return text


def normalize_status(value: Any, default: str = "To Do") -> str:
    status = str(value or default).strip()
    if status not in TASK_STATUSES:
        raise V2StorageError(f"invalid task status: {status}", 400)
    return status


def normalize_priority(value: Any, default: str = "Medium") -> str:
    priority = str(value or default).strip()
    if priority not in TASK_PRIORITIES:
        raise V2StorageError(f"invalid task priority: {priority}", 400)
    return priority


def normalize_launch_type(value: Any, default: str = "Empty shell") -> str:
    launch_type = str(value or default).strip()
    if launch_type not in SESSION_LAUNCH_TYPES:
        raise V2StorageError(f"invalid session launch type: {launch_type}", 400)
    return launch_type


def sanitize_goal_filename(task_id: str, title: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "-", title.strip().lower()).strip("-")
    if not slug:
        slug = "task"
    return f"{task_id}-{slug[:48]}.md"


def goal_template(task: dict[str, Any]) -> str:
    title = task.get("title") or "Untitled Task"
    workspace_dir = task.get("workspaceDir") or ""
    status = task.get("status") or "To Do"
    priority = task.get("priority") or "Medium"
    created_at = task.get("createdAt") or now_iso()
    return (
        f"# {title}\n\n"
        "## Goal\n\n"
        "Describe the concrete outcome Ronnie wants from this task.\n\n"
        "## Context\n\n"
        f"- Workspace: `{workspace_dir}`\n"
        f"- Status: {status}\n"
        f"- Priority: {priority}\n"
        f"- Created: {created_at}\n\n"
        "## Acceptance Criteria\n\n"
        "- [ ] Define the finished behavior.\n"
        "- [ ] Confirm tests or checks needed before handoff.\n\n"
        "## Discussion Notes\n\n"
        "Use this section for the future Discuss Goal flow.\n"
    )


SCHEMA = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    status TEXT NOT NULL,
    workspace_dir TEXT NOT NULL,
    priority TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    feature_branch TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_jira_links (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT '',
    project_key TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT '',
    issue_type TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL DEFAULT '',
    raw_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(task_id, key)
);

CREATE TABLE IF NOT EXISTS task_pr_links (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    owner TEXT NOT NULL DEFAULT '',
    repo TEXT NOT NULL DEFAULT '',
    number INTEGER NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL DEFAULT '',
    branch TEXT NOT NULL DEFAULT '',
    is_draft INTEGER NOT NULL DEFAULT 0,
    is_primary INTEGER NOT NULL DEFAULT 0,
    raw_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(task_id, owner, repo, number)
);

CREATE TABLE IF NOT EXISTS task_cmux_session_links (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    session_key TEXT NOT NULL UNIQUE,
    workspace_id TEXT NOT NULL,
    surface_id TEXT NOT NULL DEFAULT '',
    pane_id TEXT NOT NULL DEFAULT '',
    session_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    cwd TEXT NOT NULL DEFAULT '',
    launch_type TEXT NOT NULL DEFAULT 'Empty shell',
    active INTEGER NOT NULL DEFAULT 1,
    raw_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_seen_at TEXT
);

CREATE TABLE IF NOT EXISTS task_tags (
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    PRIMARY KEY(task_id, tag)
);

CREATE TABLE IF NOT EXISTS task_goal_documents (
    task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_session_summaries (
    task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
    summary TEXT NOT NULL DEFAULT '',
    source_fingerprint TEXT NOT NULL DEFAULT '',
    refreshed_at TEXT NOT NULL,
    stale_after TEXT
);

CREATE TABLE IF NOT EXISTS cmux_session_snapshots (
    session_key TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    surface_id TEXT NOT NULL DEFAULT '',
    pane_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    cwd TEXT NOT NULL DEFAULT '',
    active INTEGER NOT NULL DEFAULT 1,
    running_kind TEXT NOT NULL DEFAULT '',
    raw_json TEXT NOT NULL DEFAULT '{}',
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS orphan_session_candidates (
    session_key TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    surface_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    cwd TEXT NOT NULL DEFAULT '',
    raw_json TEXT NOT NULL DEFAULT '{}',
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS global_chat_messages (
    id TEXT PRIMARY KEY,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS agent_tool_runs (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    input_json TEXT NOT NULL DEFAULT '{}',
    output_json TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'completed',
    requires_approval INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE TABLE IF NOT EXISTS approval_requests (
    id TEXT PRIMARY KEY,
    task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    summary TEXT NOT NULL DEFAULT '',
    impact TEXT NOT NULL DEFAULT 'Medium',
    payload_json TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    decided_at TEXT
);

CREATE TABLE IF NOT EXISTS audit_events (
    id TEXT PRIMARY KEY,
    actor TEXT NOT NULL,
    action TEXT NOT NULL,
    target_type TEXT NOT NULL DEFAULT '',
    target_id TEXT NOT NULL DEFAULT '',
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS activity_events (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    summary TEXT NOT NULL DEFAULT '',
    target_type TEXT NOT NULL DEFAULT '',
    target_id TEXT NOT NULL DEFAULT '',
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
);
"""


class V2Repository:
    def __init__(self, db_path: str | Path | None = None, goals_dir: str | Path | None = None):
        self.db_path = Path(db_path) if db_path is not None else default_db_path()
        self.goals_dir = Path(goals_dir) if goals_dir is not None else default_goals_dir()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.goals_dir.mkdir(parents=True, exist_ok=True)
        self.initialize()

    @contextmanager
    def connect(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def initialize(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(self.db_path) as conn:
            conn.executescript(SCHEMA)

    def create_task(
        self,
        data: dict[str, Any],
        *,
        cmux_session: dict[str, Any] | None = None,
        actor: str = "local",
    ) -> dict[str, Any]:
        title = _normalize_text(data.get("title"), field="title", required=True)
        workspace_dir = _normalize_text(data.get("workspaceDir") or data.get("workspace_dir"), field="workspaceDir", required=True)
        status = normalize_status(data.get("status"))
        priority = normalize_priority(data.get("priority"))
        launch_type = normalize_launch_type(data.get("sessionLaunchType") or data.get("launchType"))
        created_at = now_iso()
        task_id = str(data.get("id") or safe_id("task"))
        description = _normalize_text(data.get("description"), field="description")
        feature_branch = _normalize_text(data.get("featureBranch") or data.get("feature_branch"), field="featureBranch")

        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO tasks (id, title, status, workspace_dir, priority, description, feature_branch, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (task_id, title, status, workspace_dir, priority, description, feature_branch, created_at, created_at),
            )
            task = {
                "id": task_id,
                "title": title,
                "status": status,
                "workspaceDir": workspace_dir,
                "priority": priority,
                "description": description,
                "featureBranch": feature_branch,
                "createdAt": created_at,
                "updatedAt": created_at,
            }
            goal_path = self._create_goal_document_file(task)
            conn.execute(
                """
                INSERT INTO task_goal_documents (task_id, path, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """,
                (task_id, str(goal_path), created_at, created_at),
            )
            for tag in data.get("tags") or []:
                self._upsert_tag(conn, task_id, tag)
            if cmux_session:
                self._attach_cmux_session(conn, task_id, cmux_session, launch_type=launch_type)
            jira = data.get("jiraTicket") or data.get("jira")
            if jira:
                self._attach_jira(conn, task_id, jira)
            pr = data.get("pullRequest") or data.get("pr")
            if pr:
                self._attach_pr(conn, task_id, pr)
            self._audit(conn, actor, "create_task", "task", task_id, {"title": title, "launchType": launch_type})
            self._activity(conn, "task_created", title, f"Created task with {launch_type}", "task", task_id)
        return self.get_task(task_id) or {}

    def _create_goal_document_file(self, task: dict[str, Any]) -> Path:
        path = self.goals_dir / sanitize_goal_filename(task["id"], task["title"])
        if not path.exists():
            path.write_text(goal_template(task), encoding="utf-8")
        return path

    def list_tasks(self, *, include_history: bool = False, query: str = "") -> list[dict[str, Any]]:
        where = []
        args: list[Any] = []
        if not include_history:
            where.append("status NOT IN ('Done', 'Archived')")
        query = str(query or "").strip()
        if query:
            needle = f"%{query.casefold()}%"
            where.append(
                """
                (
                    lower(title) LIKE ?
                    OR lower(description) LIKE ?
                    OR id IN (SELECT task_id FROM task_jira_links WHERE lower(key) LIKE ? OR lower(title) LIKE ?)
                    OR id IN (SELECT task_id FROM task_pr_links WHERE lower(title) LIKE ? OR CAST(number AS TEXT) LIKE ?)
                    OR id IN (SELECT task_id FROM task_cmux_session_links WHERE lower(workspace_id) LIKE ? OR lower(surface_id) LIKE ? OR lower(title) LIKE ?)
                )
                """
            )
            args.extend([needle, needle, needle, needle, needle, needle, needle, needle, needle])
        clause = f"WHERE {' AND '.join(where)}" if where else ""
        with self.connect() as conn:
            rows = conn.execute(
                f"SELECT * FROM tasks {clause} ORDER BY updated_at DESC, created_at DESC",
                args,
            ).fetchall()
            return [self._hydrate_task(conn, row) for row in rows]

    def get_task(self, task_id: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
            if row is None:
                return None
            return self._hydrate_task(conn, row)

    def update_task(self, task_id: str, data: dict[str, Any], *, actor: str = "local") -> dict[str, Any]:
        allowed = {
            "title": ("title", lambda value: _normalize_text(value, field="title", required=True)),
            "status": ("status", normalize_status),
            "workspaceDir": ("workspace_dir", lambda value: _normalize_text(value, field="workspaceDir", required=True)),
            "priority": ("priority", normalize_priority),
            "description": ("description", lambda value: _normalize_text(value, field="description")),
            "featureBranch": ("feature_branch", lambda value: _normalize_text(value, field="featureBranch")),
        }
        updates = []
        args = []
        for json_key, (column, normalizer) in allowed.items():
            if json_key in data:
                updates.append(f"{column} = ?")
                args.append(normalizer(data[json_key]))
        if "tags" in data:
            tags = data.get("tags") or []
        else:
            tags = None
        if not updates and tags is None:
            task = self.get_task(task_id)
            if task is None:
                raise V2StorageError("task not found", 404)
            return task
        updated_at = now_iso()
        with self.connect() as conn:
            if updates:
                args.extend([updated_at, task_id])
                cursor = conn.execute(
                    f"UPDATE tasks SET {', '.join(updates)}, updated_at = ? WHERE id = ?",
                    args,
                )
                if cursor.rowcount == 0:
                    raise V2StorageError("task not found", 404)
            if tags is not None:
                conn.execute("DELETE FROM task_tags WHERE task_id = ?", (task_id,))
                for tag in tags:
                    self._upsert_tag(conn, task_id, tag)
            self._audit(conn, actor, "update_task", "task", task_id, data)
            self._activity(conn, "task_updated", "Task updated", task_id, "task", task_id)
        task = self.get_task(task_id)
        if task is None:
            raise V2StorageError("task not found", 404)
        return task

    def delete_task(self, task_id: str, *, actor: str = "local") -> None:
        with self.connect() as conn:
            cursor = conn.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
            if cursor.rowcount == 0:
                raise V2StorageError("task not found", 404)
            self._audit(conn, actor, "delete_task", "task", task_id, {})
            self._activity(conn, "task_deleted", "Task deleted", task_id, "task", task_id)

    def attach_jira(self, task_id: str, ticket: dict[str, Any], *, actor: str = "local") -> dict[str, Any]:
        with self.connect() as conn:
            self._require_task(conn, task_id)
            link = self._attach_jira(conn, task_id, ticket)
            self._touch_task(conn, task_id)
            self._audit(conn, actor, "attach_jira_to_task", "task", task_id, ticket)
            self._activity(conn, "jira_attached", f"Attached {link['key']}", link.get("title", ""), "task", task_id)
            return link

    def resync_jira_link(self, task_id: str, link_id_or_key: str, ticket: dict[str, Any], *, actor: str = "local") -> dict[str, Any]:
        lookup = str(link_id_or_key or "").strip()
        if not lookup:
            raise V2StorageError("Jira link id required", 400)
        with self.connect() as conn:
            self._require_task(conn, task_id)
            existing = conn.execute(
                "SELECT * FROM task_jira_links WHERE task_id = ? AND (id = ? OR key = ?)",
                (task_id, lookup, lookup.upper()),
            ).fetchone()
            if existing is None:
                raise V2StorageError("Jira link not found", 404)
            payload = dict(ticket or {})
            payload["key"] = str(payload.get("key") or existing["key"]).upper()
            link = self._attach_jira(conn, task_id, payload)
            self._touch_task(conn, task_id)
            self._audit(conn, actor, "resync_jira_metadata", "task", task_id, {"linkId": existing["id"], "key": existing["key"]})
            self._activity(conn, "jira_resynced", f"Resynced {link['key']}", link.get("status", ""), "task", task_id)
            return link

    def attach_pr(self, task_id: str, pr: dict[str, Any], *, actor: str = "local") -> dict[str, Any]:
        with self.connect() as conn:
            self._require_task(conn, task_id)
            link = self._attach_pr(conn, task_id, pr)
            self._touch_task(conn, task_id)
            self._audit(conn, actor, "attach_pr_to_task", "task", task_id, pr)
            self._activity(conn, "pr_attached", f"Attached PR #{link['number']}", link.get("title", ""), "task", task_id)
            return link

    def attach_cmux_session(
        self,
        task_id: str,
        session: dict[str, Any],
        *,
        launch_type: str = "Empty shell",
        actor: str = "local",
    ) -> dict[str, Any]:
        with self.connect() as conn:
            self._require_task(conn, task_id)
            link = self._attach_cmux_session(conn, task_id, session, launch_type=launch_type)
            self._touch_task(conn, task_id)
            self._audit(conn, actor, "attach_cmux_session_to_task", "task", task_id, session)
            self._activity(conn, "cmux_attached", "Attached cmux session", link.get("title", ""), "task", task_id)
            return link

    def detach_cmux_session(self, task_id: str, link_id: str, *, actor: str = "local") -> None:
        with self.connect() as conn:
            cursor = conn.execute(
                "DELETE FROM task_cmux_session_links WHERE id = ? AND task_id = ?",
                (link_id, task_id),
            )
            if cursor.rowcount == 0:
                raise V2StorageError("cmux session link not found", 404)
            self._touch_task(conn, task_id)
            self._audit(conn, actor, "detach_cmux_session_from_task", "task", task_id, {"linkId": link_id})
            self._activity(conn, "cmux_detached", "Detached cmux session", link_id, "task", task_id)

    def read_goal(self, task_id: str) -> dict[str, Any]:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM task_goal_documents WHERE task_id = ?", (task_id,)).fetchone()
            if row is None:
                raise V2StorageError("goal document not found", 404)
            path = Path(row["path"])
            try:
                content = path.read_text(encoding="utf-8")
            except OSError as exc:
                raise V2StorageError(f"goal document unreadable: {exc}", 500) from exc
            return {
                "taskId": task_id,
                "path": str(path),
                "content": content,
                "createdAt": row["created_at"],
                "updatedAt": row["updated_at"],
            }

    def update_goal(self, task_id: str, content: str, *, actor: str = "local") -> dict[str, Any]:
        content = str(content or "")
        updated_at = now_iso()
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM task_goal_documents WHERE task_id = ?", (task_id,)).fetchone()
            if row is None:
                raise V2StorageError("goal document not found", 404)
            path = Path(row["path"])
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            conn.execute("UPDATE task_goal_documents SET updated_at = ? WHERE task_id = ?", (updated_at, task_id))
            self._touch_task(conn, task_id)
            self._audit(conn, actor, "update_goal_markdown", "task", task_id, {"path": str(path)})
            self._activity(conn, "goal_updated", "Goal updated", path.name, "task", task_id)
        return self.read_goal(task_id)

    def record_cmux_snapshots(self, sessions: list[dict[str, Any]]) -> list[dict[str, Any]]:
        now = now_iso()
        active_keys = {session_key(item) for item in sessions if session_key(item)}
        orphans: list[dict[str, Any]] = []
        with self.connect() as conn:
            for item in sessions:
                key = session_key(item)
                if not key:
                    continue
                existing = conn.execute("SELECT first_seen_at FROM cmux_session_snapshots WHERE session_key = ?", (key,)).fetchone()
                first_seen = existing["first_seen_at"] if existing else now
                conn.execute(
                    """
                    INSERT INTO cmux_session_snapshots (
                        session_key, workspace_id, surface_id, pane_id, title, cwd, active,
                        running_kind, raw_json, first_seen_at, last_seen_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(session_key) DO UPDATE SET
                        workspace_id = excluded.workspace_id,
                        surface_id = excluded.surface_id,
                        pane_id = excluded.pane_id,
                        title = excluded.title,
                        cwd = excluded.cwd,
                        active = excluded.active,
                        running_kind = excluded.running_kind,
                        raw_json = excluded.raw_json,
                        last_seen_at = excluded.last_seen_at
                    """,
                    (
                        key,
                        str(item.get("workspaceId") or item.get("workspace_id") or ""),
                        str(item.get("surfaceId") or item.get("surface_id") or ""),
                        str(item.get("paneId") or item.get("pane_id") or ""),
                        str(item.get("title") or ""),
                        str(item.get("cwd") or item.get("currentDirectory") or ""),
                        1 if item.get("active", True) else 0,
                        str(item.get("runningKind") or item.get("running_kind") or ""),
                        _json_dumps(item),
                        first_seen,
                        now,
                    ),
                )
                if not self._is_session_linked(conn, key):
                    orphan = self._upsert_orphan(conn, key, item, first_seen=first_seen, now=now)
                    orphans.append(orphan)
                else:
                    conn.execute("DELETE FROM orphan_session_candidates WHERE session_key = ?", (key,))
            if active_keys:
                placeholders = ",".join("?" for _ in active_keys)
                conn.execute(
                    f"UPDATE cmux_session_snapshots SET active = 0 WHERE session_key NOT IN ({placeholders})",
                    list(active_keys),
                )
                conn.execute(
                    f"DELETE FROM orphan_session_candidates WHERE session_key NOT IN ({placeholders})",
                    list(active_keys),
                )
            else:
                conn.execute("UPDATE cmux_session_snapshots SET active = 0")
                conn.execute("DELETE FROM orphan_session_candidates")
        return orphans

    def list_orphans(self) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute("SELECT * FROM orphan_session_candidates ORDER BY last_seen_at DESC").fetchall()
            return [self._orphan_from_row(row) for row in rows]

    def create_approval_request(self, data: dict[str, Any], *, actor: str = "agent") -> dict[str, Any]:
        request_id = str(data.get("id") or safe_id("approval"))
        created_at = now_iso()
        task_id = str(data.get("taskId") or data.get("task_id") or "").strip() or None
        kind = _normalize_text(data.get("kind"), field="kind", required=True)
        title = _normalize_text(data.get("title"), field="title", required=True)
        summary = _normalize_text(data.get("summary"), field="summary")
        impact = _normalize_text(data.get("impact"), field="impact") or "Medium"
        payload = data.get("payload") if isinstance(data.get("payload"), dict) else {}
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO approval_requests (
                    id, task_id, kind, title, summary, impact, payload_json, status, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                """,
                (request_id, task_id, kind, title, summary, impact, _json_dumps(payload), created_at, created_at),
            )
            self._audit(conn, actor, "create_approval_request", "approval", request_id, data)
            self._activity(conn, "approval_required", title, summary, "approval", request_id, run_id=str(data.get("runId") or ""))
        return self.get_approval_request(request_id) or {}

    def list_approval_requests(self, *, status: str | None = None) -> list[dict[str, Any]]:
        with self.connect() as conn:
            if status:
                rows = conn.execute(
                    "SELECT * FROM approval_requests WHERE status = ? ORDER BY created_at DESC",
                    (status,),
                ).fetchall()
            else:
                rows = conn.execute("SELECT * FROM approval_requests ORDER BY created_at DESC").fetchall()
            return [self._approval_from_row(row) for row in rows]

    def get_approval_request(self, request_id: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM approval_requests WHERE id = ?", (request_id,)).fetchone()
            return self._approval_from_row(row) if row else None

    def decide_approval_request(self, request_id: str, status: str, *, actor: str = "local") -> dict[str, Any]:
        status = str(status or "").strip().lower()
        if status not in {"approved", "denied", "cancelled"}:
            raise V2StorageError("invalid approval status", 400)
        updated_at = now_iso()
        with self.connect() as conn:
            cursor = conn.execute(
                "UPDATE approval_requests SET status = ?, updated_at = ?, decided_at = ? WHERE id = ?",
                (status, updated_at, updated_at, request_id),
            )
            if cursor.rowcount == 0:
                raise V2StorageError("approval request not found", 404)
            self._audit(conn, actor, f"{status}_approval_request", "approval", request_id, {})
            self._activity(conn, f"approval_{status}", f"Approval {status}", request_id, "approval", request_id)
        approval = self.get_approval_request(request_id)
        if approval is None:
            raise V2StorageError("approval request not found", 404)
        return approval

    def list_activity_events(self, *, limit: int = 100) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 100), 500))
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM activity_events ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
            return [self._activity_from_row(row) for row in rows]

    def list_audit_events(self, *, limit: int = 100) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 100), 500))
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM audit_events ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
            return [self._audit_from_row(row) for row in rows]

    def append_chat_message(self, role: str, content: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
        message_id = safe_id("chat")
        created_at = now_iso()
        with self.connect() as conn:
            conn.execute(
                "INSERT INTO global_chat_messages (id, role, content, metadata_json, created_at) VALUES (?, ?, ?, ?, ?)",
                (message_id, str(role or "user"), str(content or ""), _json_dumps(metadata or {}), created_at),
            )
        return {"id": message_id, "role": role, "content": content, "metadata": metadata or {}, "createdAt": created_at}

    def list_chat_messages(self, *, limit: int = 100) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 100), 500))
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM global_chat_messages ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
            messages = []
            for row in reversed(rows):
                messages.append({
                    "id": row["id"],
                    "role": row["role"],
                    "content": row["content"],
                    "metadata": _json_loads(row["metadata_json"], {}),
                    "createdAt": row["created_at"],
                })
            return messages

    def record_tool_run(
        self,
        run_id: str,
        tool_name: str,
        input_payload: dict[str, Any],
        output_payload: dict[str, Any],
        *,
        status: str = "completed",
        requires_approval: bool = False,
        actor: str = "agent",
    ) -> dict[str, Any]:
        run_item_id = safe_id("tool")
        created_at = now_iso()
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO agent_tool_runs (
                    id, run_id, tool_name, input_json, output_json, status, requires_approval, created_at, completed_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    run_item_id,
                    str(run_id or ""),
                    tool_name,
                    _json_dumps(input_payload),
                    _json_dumps(output_payload),
                    status,
                    1 if requires_approval else 0,
                    created_at,
                    created_at,
                ),
            )
            self._audit(conn, actor, f"tool:{tool_name}", "agent_tool_run", run_item_id, {
                "input": input_payload,
                "output": output_payload,
                "status": status,
            })
            self._activity(conn, "tool_call", tool_name, status, "agent_tool_run", run_item_id, run_id=run_id)
        return {
            "id": run_item_id,
            "runId": run_id,
            "toolName": tool_name,
            "input": input_payload,
            "output": output_payload,
            "status": status,
            "requiresApproval": requires_approval,
            "createdAt": created_at,
            "completedAt": created_at,
        }

    def summarize_task_sessions(self, task_id: str, session_texts: list[str]) -> dict[str, Any]:
        joined = "\n".join(text.strip() for text in session_texts if text and text.strip())
        if not joined:
            summary = "No cmux session output is available yet."
        else:
            lines = [line.strip() for line in joined.splitlines() if line.strip()]
            tail = lines[-12:]
            summary = "\n".join(tail)
        fingerprint = str(hash(joined))
        refreshed_at = now_iso()
        with self.connect() as conn:
            self._require_task(conn, task_id)
            conn.execute(
                """
                INSERT INTO task_session_summaries (task_id, summary, source_fingerprint, refreshed_at, stale_after)
                VALUES (?, ?, ?, ?, NULL)
                ON CONFLICT(task_id) DO UPDATE SET
                    summary = excluded.summary,
                    source_fingerprint = excluded.source_fingerprint,
                    refreshed_at = excluded.refreshed_at,
                    stale_after = excluded.stale_after
                """,
                (task_id, summary, fingerprint, refreshed_at),
            )
            self._audit(conn, "agent", "summarize_task_sessions", "task", task_id, {"textCount": len(session_texts)})
            self._activity(conn, "session_summary", "Session summary refreshed", summary[:160], "task", task_id)
        return {"taskId": task_id, "summary": summary, "sourceFingerprint": fingerprint, "refreshedAt": refreshed_at}

    def _hydrate_task(self, conn: sqlite3.Connection, row: sqlite3.Row) -> dict[str, Any]:
        task_id = row["id"]
        task = {
            "id": task_id,
            "title": row["title"],
            "status": row["status"],
            "workspaceDir": row["workspace_dir"],
            "priority": row["priority"],
            "description": row["description"],
            "featureBranch": row["feature_branch"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }
        task["tags"] = [
            {"tag": tag["tag"], "color": tag["color"], "createdAt": tag["created_at"]}
            for tag in conn.execute("SELECT * FROM task_tags WHERE task_id = ? ORDER BY created_at, tag", (task_id,)).fetchall()
        ]
        task["jiraLinks"] = [
            self._jira_from_row(link)
            for link in conn.execute("SELECT * FROM task_jira_links WHERE task_id = ? ORDER BY created_at", (task_id,)).fetchall()
        ]
        task["pullRequestLinks"] = [
            self._pr_from_row(link)
            for link in conn.execute("SELECT * FROM task_pr_links WHERE task_id = ? ORDER BY is_primary DESC, created_at", (task_id,)).fetchall()
        ]
        task["cmuxSessionLinks"] = [
            self._cmux_link_from_row(link)
            for link in conn.execute("SELECT * FROM task_cmux_session_links WHERE task_id = ? ORDER BY created_at", (task_id,)).fetchall()
        ]
        goal = conn.execute("SELECT * FROM task_goal_documents WHERE task_id = ?", (task_id,)).fetchone()
        task["goalDocument"] = {
            "taskId": task_id,
            "path": goal["path"],
            "createdAt": goal["created_at"],
            "updatedAt": goal["updated_at"],
        } if goal else None
        summary = conn.execute("SELECT * FROM task_session_summaries WHERE task_id = ?", (task_id,)).fetchone()
        task["sessionSummary"] = {
            "taskId": task_id,
            "summary": summary["summary"],
            "sourceFingerprint": summary["source_fingerprint"],
            "refreshedAt": summary["refreshed_at"],
            "staleAfter": summary["stale_after"],
        } if summary else None
        approvals = conn.execute(
            "SELECT * FROM approval_requests WHERE task_id = ? AND status = 'pending' ORDER BY created_at DESC",
            (task_id,),
        ).fetchall()
        task["pendingApprovals"] = [self._approval_from_row(item) for item in approvals]
        return task

    def _require_task(self, conn: sqlite3.Connection, task_id: str) -> None:
        row = conn.execute("SELECT id FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if row is None:
            raise V2StorageError("task not found", 404)

    def _touch_task(self, conn: sqlite3.Connection, task_id: str) -> None:
        conn.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", (now_iso(), task_id))

    def _upsert_tag(self, conn: sqlite3.Connection, task_id: str, value: Any) -> None:
        if isinstance(value, dict):
            tag = _normalize_text(value.get("tag") or value.get("name"), field="tag", required=True)
            color = _normalize_text(value.get("color"), field="color")
        else:
            tag = _normalize_text(value, field="tag", required=True)
            color = ""
        conn.execute(
            """
            INSERT INTO task_tags (task_id, tag, color, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(task_id, tag) DO UPDATE SET color = excluded.color
            """,
            (task_id, tag, color, now_iso()),
        )

    def _attach_jira(self, conn: sqlite3.Connection, task_id: str, ticket: dict[str, Any]) -> dict[str, Any]:
        key = _normalize_text(ticket.get("key"), field="Jira key", required=True).upper()
        link_id = str(ticket.get("id") or safe_id("jira"))
        current = conn.execute(
            "SELECT id FROM task_jira_links WHERE task_id = ? AND key = ?",
            (task_id, key),
        ).fetchone()
        if current:
            link_id = current["id"]
        updated_at = now_iso()
        values = (
            link_id,
            task_id,
            key,
            _normalize_text(ticket.get("title"), field="Jira title"),
            _normalize_text(ticket.get("status"), field="Jira status"),
            _normalize_text(ticket.get("projectKey") or ticket.get("project_key"), field="projectKey"),
            _normalize_text(ticket.get("priority"), field="Jira priority"),
            _normalize_text(ticket.get("issueType") or ticket.get("issue_type"), field="issueType"),
            _normalize_text(ticket.get("url"), field="Jira url"),
            _json_dumps(ticket),
            updated_at,
            updated_at,
        )
        conn.execute(
            """
            INSERT INTO task_jira_links (
                id, task_id, key, title, status, project_key, priority, issue_type, url,
                raw_json, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(task_id, key) DO UPDATE SET
                title = excluded.title,
                status = excluded.status,
                project_key = excluded.project_key,
                priority = excluded.priority,
                issue_type = excluded.issue_type,
                url = excluded.url,
                raw_json = excluded.raw_json,
                updated_at = excluded.updated_at
            """,
            values,
        )
        row = conn.execute("SELECT * FROM task_jira_links WHERE task_id = ? AND key = ?", (task_id, key)).fetchone()
        return self._jira_from_row(row)

    def _attach_pr(self, conn: sqlite3.Connection, task_id: str, pr: dict[str, Any]) -> dict[str, Any]:
        number = pr.get("number")
        try:
            number_int = int(number)
        except (TypeError, ValueError) as exc:
            raise V2StorageError("PR number required", 400) from exc
        owner = _normalize_text(pr.get("owner"), field="owner")
        repo = _normalize_text(pr.get("repo") or pr.get("repository"), field="repo")
        if not owner or not repo:
            owner, repo = parse_github_repo_from_url(pr.get("url"))
        link_id = str(pr.get("id") or safe_id("pr"))
        current = conn.execute(
            "SELECT id FROM task_pr_links WHERE task_id = ? AND owner = ? AND repo = ? AND number = ?",
            (task_id, owner, repo, number_int),
        ).fetchone()
        if current:
            link_id = current["id"]
        is_primary = 1 if pr.get("isPrimary") or pr.get("is_primary") else 0
        if is_primary:
            conn.execute("UPDATE task_pr_links SET is_primary = 0 WHERE task_id = ?", (task_id,))
        updated_at = now_iso()
        conn.execute(
            """
            INSERT INTO task_pr_links (
                id, task_id, owner, repo, number, title, state, url, branch, is_draft,
                is_primary, raw_json, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(task_id, owner, repo, number) DO UPDATE SET
                title = excluded.title,
                state = excluded.state,
                url = excluded.url,
                branch = excluded.branch,
                is_draft = excluded.is_draft,
                is_primary = CASE WHEN excluded.is_primary = 1 THEN 1 ELSE task_pr_links.is_primary END,
                raw_json = excluded.raw_json,
                updated_at = excluded.updated_at
            """,
            (
                link_id,
                task_id,
                owner,
                repo,
                number_int,
                _normalize_text(pr.get("title"), field="PR title"),
                _normalize_text(pr.get("state"), field="PR state"),
                _normalize_text(pr.get("url"), field="PR url"),
                _normalize_text(pr.get("branch") or pr.get("headRefName"), field="PR branch"),
                1 if pr.get("isDraft") or pr.get("is_draft") else 0,
                is_primary,
                _json_dumps(pr),
                updated_at,
                updated_at,
            ),
        )
        row = conn.execute(
            "SELECT * FROM task_pr_links WHERE task_id = ? AND owner = ? AND repo = ? AND number = ?",
            (task_id, owner, repo, number_int),
        ).fetchone()
        return self._pr_from_row(row)

    def _attach_cmux_session(
        self,
        conn: sqlite3.Connection,
        task_id: str,
        session: dict[str, Any],
        *,
        launch_type: str = "Empty shell",
    ) -> dict[str, Any]:
        launch_type = normalize_launch_type(launch_type)
        key = session_key(session)
        if not key:
            raise V2StorageError("cmux workspaceId required", 400)
        existing = conn.execute("SELECT task_id FROM task_cmux_session_links WHERE session_key = ?", (key,)).fetchone()
        if existing and existing["task_id"] != task_id:
            raise V2StorageError("cmux session is already attached to another task", 409)
        link_id = str(session.get("id") or safe_id("cmux"))
        current = conn.execute(
            "SELECT id FROM task_cmux_session_links WHERE task_id = ? AND session_key = ?",
            (task_id, key),
        ).fetchone()
        if current:
            link_id = current["id"]
        updated_at = now_iso()
        conn.execute(
            """
            INSERT INTO task_cmux_session_links (
                id, task_id, session_key, workspace_id, surface_id, pane_id, session_id,
                title, cwd, launch_type, active, raw_json, created_at, updated_at, last_seen_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_key) DO UPDATE SET
                title = excluded.title,
                cwd = excluded.cwd,
                launch_type = excluded.launch_type,
                active = excluded.active,
                raw_json = excluded.raw_json,
                updated_at = excluded.updated_at,
                last_seen_at = excluded.last_seen_at
            """,
            (
                link_id,
                task_id,
                key,
                str(session.get("workspaceId") or session.get("workspace_id") or ""),
                str(session.get("surfaceId") or session.get("surface_id") or ""),
                str(session.get("paneId") or session.get("pane_id") or ""),
                str(session.get("sessionId") or session.get("session_id") or ""),
                str(session.get("title") or ""),
                str(session.get("cwd") or session.get("currentDirectory") or ""),
                launch_type,
                1 if session.get("active", True) else 0,
                _json_dumps(session),
                updated_at,
                updated_at,
                updated_at,
            ),
        )
        conn.execute("DELETE FROM orphan_session_candidates WHERE session_key = ?", (key,))
        row = conn.execute("SELECT * FROM task_cmux_session_links WHERE session_key = ?", (key,)).fetchone()
        return self._cmux_link_from_row(row)

    def _is_session_linked(self, conn: sqlite3.Connection, key: str) -> bool:
        return conn.execute("SELECT 1 FROM task_cmux_session_links WHERE session_key = ?", (key,)).fetchone() is not None

    def _upsert_orphan(self, conn: sqlite3.Connection, key: str, session: dict[str, Any], *, first_seen: str, now: str) -> dict[str, Any]:
        current = conn.execute("SELECT first_seen_at FROM orphan_session_candidates WHERE session_key = ?", (key,)).fetchone()
        first_seen_at = current["first_seen_at"] if current else first_seen
        conn.execute(
            """
            INSERT INTO orphan_session_candidates (
                session_key, workspace_id, surface_id, title, cwd, raw_json, first_seen_at, last_seen_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_key) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                surface_id = excluded.surface_id,
                title = excluded.title,
                cwd = excluded.cwd,
                raw_json = excluded.raw_json,
                last_seen_at = excluded.last_seen_at
            """,
            (
                key,
                str(session.get("workspaceId") or session.get("workspace_id") or ""),
                str(session.get("surfaceId") or session.get("surface_id") or ""),
                str(session.get("title") or ""),
                str(session.get("cwd") or session.get("currentDirectory") or ""),
                _json_dumps(session),
                first_seen_at,
                now,
            ),
        )
        row = conn.execute("SELECT * FROM orphan_session_candidates WHERE session_key = ?", (key,)).fetchone()
        return self._orphan_from_row(row)

    def _audit(
        self,
        conn: sqlite3.Connection,
        actor: str,
        action: str,
        target_type: str,
        target_id: str,
        payload: dict[str, Any],
    ) -> None:
        conn.execute(
            """
            INSERT INTO audit_events (id, actor, action, target_type, target_id, payload_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (safe_id("audit"), actor, action, target_type, target_id, _json_dumps(payload), now_iso()),
        )

    def _activity(
        self,
        conn: sqlite3.Connection,
        kind: str,
        title: str,
        summary: str,
        target_type: str,
        target_id: str,
        *,
        run_id: str = "",
        payload: dict[str, Any] | None = None,
    ) -> None:
        conn.execute(
            """
            INSERT INTO activity_events (
                id, run_id, kind, title, summary, target_type, target_id, payload_json, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (safe_id("activity"), run_id, kind, title, summary, target_type, target_id, _json_dumps(payload or {}), now_iso()),
        )

    def _jira_from_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "taskId": row["task_id"],
            "key": row["key"],
            "title": row["title"],
            "status": row["status"],
            "projectKey": row["project_key"],
            "priority": row["priority"],
            "issueType": row["issue_type"],
            "url": row["url"],
            "raw": _json_loads(row["raw_json"], {}),
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }

    def _pr_from_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "taskId": row["task_id"],
            "owner": row["owner"],
            "repo": row["repo"],
            "number": row["number"],
            "title": row["title"],
            "state": row["state"],
            "url": row["url"],
            "branch": row["branch"],
            "isDraft": bool(row["is_draft"]),
            "isPrimary": bool(row["is_primary"]),
            "raw": _json_loads(row["raw_json"], {}),
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }

    def _cmux_link_from_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "taskId": row["task_id"],
            "sessionKey": row["session_key"],
            "workspaceId": row["workspace_id"],
            "surfaceId": row["surface_id"],
            "paneId": row["pane_id"],
            "sessionId": row["session_id"],
            "title": row["title"],
            "cwd": row["cwd"],
            "launchType": row["launch_type"],
            "active": bool(row["active"]),
            "raw": _json_loads(row["raw_json"], {}),
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "lastSeenAt": row["last_seen_at"],
        }

    def _orphan_from_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "sessionKey": row["session_key"],
            "workspaceId": row["workspace_id"],
            "surfaceId": row["surface_id"],
            "title": row["title"],
            "cwd": row["cwd"],
            "raw": _json_loads(row["raw_json"], {}),
            "firstSeenAt": row["first_seen_at"],
            "lastSeenAt": row["last_seen_at"],
        }

    def _approval_from_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "taskId": row["task_id"],
            "kind": row["kind"],
            "title": row["title"],
            "summary": row["summary"],
            "impact": row["impact"],
            "payload": _json_loads(row["payload_json"], {}),
            "status": row["status"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "decidedAt": row["decided_at"],
        }

    def _activity_from_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "runId": row["run_id"],
            "kind": row["kind"],
            "title": row["title"],
            "summary": row["summary"],
            "targetType": row["target_type"],
            "targetId": row["target_id"],
            "payload": _json_loads(row["payload_json"], {}),
            "createdAt": row["created_at"],
        }

    def _audit_from_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "actor": row["actor"],
            "action": row["action"],
            "targetType": row["target_type"],
            "targetId": row["target_id"],
            "payload": _json_loads(row["payload_json"], {}),
            "createdAt": row["created_at"],
        }


def session_key(session: dict[str, Any]) -> str:
    workspace_id = str(session.get("workspaceId") or session.get("workspace_id") or "").strip()
    surface_id = str(session.get("surfaceId") or session.get("surface_id") or "").strip()
    if not workspace_id:
        return ""
    return f"{workspace_id}:{surface_id}" if surface_id else workspace_id


def parse_github_repo_from_url(url: Any) -> tuple[str, str]:
    value = str(url or "").strip()
    match = re.search(r"github\.com/([^/]+)/([^/]+)/pull/\d+", value)
    if not match:
        return "", ""
    return match.group(1), match.group(2)


_default_repo: V2Repository | None = None


def get_repository() -> V2Repository:
    global _default_repo
    path = default_db_path()
    goals = default_goals_dir()
    if _default_repo is None or _default_repo.db_path != path or _default_repo.goals_dir != goals:
        _default_repo = V2Repository(path, goals)
    return _default_repo
