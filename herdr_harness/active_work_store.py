"""Durable SQLite repository for Herdr Active Work.

The repository is deliberately independent of Buzz and Jira clients. External
systems merge observations into already-tracked work, while Jira setup is an
explicit, idempotent user action.
"""

from __future__ import annotations

import copy
import os
import sqlite3
import stat
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Mapping, Optional

from .active_work import (
    ActiveWorkError,
    AGENT_LINK_STATES,
    AGENT_STATUSES,
    ATTENTION_STATES,
    CHECKPOINT_STATES,
    CURRENT_SCHEMA_VERSION,
    DEFAULT_PIPELINE_ID,
    DEFAULT_PIPELINE_SLUG,
    DEFAULT_PIPELINE_STAGES,
    DEFAULT_PIPELINE_VERSION,
    SESSION_STATUSES,
    STAGE_KEYS,
    STAGE_STATES,
    THREAD_STATUSES,
    WORK_KINDS,
    WORK_LIFECYCLES,
    bounded_json,
    choice,
    external_id,
    internal_id,
    jira_key,
    json_dump,
    json_load,
    link_url,
    payload_hash,
    reject_unknown,
    require_list,
    require_mapping,
    safe_id,
    site_from_ticket,
    source,
    text,
    timestamp,
    timestamp_value,
    url,
    utc_now,
)


DEFAULT_STORE_PATH = "~/.config/herdr-harness/active-work.sqlite3"


SCHEMA_V1 = """
CREATE TABLE IF NOT EXISTS active_work_schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS pipeline_templates (
    id TEXT PRIMARY KEY,
    slug TEXT NOT NULL,
    version INTEGER NOT NULL CHECK(version > 0),
    title TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(slug, version)
);

CREATE TABLE IF NOT EXISTS pipeline_stage_definitions (
    id TEXT PRIMARY KEY,
    template_id TEXT NOT NULL REFERENCES pipeline_templates(id) ON DELETE CASCADE,
    stage_key TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK(sequence > 0),
    phase_key TEXT NOT NULL,
    title TEXT NOT NULL,
    skill_name TEXT NOT NULL,
    checkpoint_kind TEXT NOT NULL CHECK(checkpoint_kind IN ('none', 'human')),
    created_at TEXT NOT NULL,
    UNIQUE(template_id, stage_key),
    UNIQUE(template_id, sequence)
);

CREATE TABLE IF NOT EXISTS work_items (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK(kind IN ('feature', 'task', 'idea')),
    title TEXT NOT NULL,
    summary TEXT NOT NULL DEFAULT '',
    lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'blocked', 'done', 'archived')),
    template_id TEXT NOT NULL REFERENCES pipeline_templates(id),
    current_stage_id TEXT REFERENCES pipeline_stage_definitions(id),
    next_action TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 1 CHECK(revision > 0),
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    archived_at TEXT
);

CREATE TABLE IF NOT EXISTS work_stage_states (
    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
    stage_id TEXT NOT NULL REFERENCES pipeline_stage_definitions(id),
    state TEXT NOT NULL CHECK(state IN ('pending', 'ready', 'active', 'blocked', 'complete', 'skipped')),
    attention TEXT NOT NULL DEFAULT 'none' CHECK(attention IN ('none', 'agent', 'human')),
    checkpoint_state TEXT NOT NULL DEFAULT 'none' CHECK(checkpoint_state IN ('none', 'pending', 'approved', 'changes_requested')),
    summary TEXT NOT NULL DEFAULT '',
    content_json TEXT NOT NULL DEFAULT '{}',
    source_observed_at TEXT,
    started_at TEXT,
    completed_at TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(work_item_id, stage_id)
);

CREATE TABLE IF NOT EXISTS jira_links (
    id TEXT PRIMARY KEY,
    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
    site TEXT NOT NULL,
    issue_key TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT '',
    issue_type TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL DEFAULT '',
    metadata_json TEXT NOT NULL DEFAULT '{}',
    observed_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(site, issue_key)
);

CREATE TABLE IF NOT EXISTS agent_profiles (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'agent',
    role_label TEXT NOT NULL DEFAULT '',
    avatar_key TEXT NOT NULL DEFAULT '',
    avatar_url TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'unknown' CHECK(status IN ('unknown', 'queued', 'idle', 'working', 'waiting', 'blocked', 'done', 'offline')),
    metadata_json TEXT NOT NULL DEFAULT '{}',
    last_seen_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(source, external_id)
);

CREATE TABLE IF NOT EXISTS stage_agent_links (
    work_item_id TEXT NOT NULL,
    stage_id TEXT NOT NULL,
    agent_id TEXT NOT NULL REFERENCES agent_profiles(id),
    role TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('queued', 'active', 'waiting', 'done')),
    attached_at TEXT NOT NULL,
    detached_at TEXT,
    source_observed_at TEXT,
    PRIMARY KEY(work_item_id, stage_id, agent_id),
    FOREIGN KEY(work_item_id, stage_id) REFERENCES work_stage_states(work_item_id, stage_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS pi_sessions (
    id TEXT PRIMARY KEY,
    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    agent_id TEXT REFERENCES agent_profiles(id),
    title TEXT NOT NULL DEFAULT '',
    provider TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'unknown' CHECK(status IN ('unknown', 'queued', 'running', 'blocked', 'completed', 'failed', 'ended')),
    machine_id TEXT NOT NULL DEFAULT '',
    workspace_id TEXT NOT NULL DEFAULT '',
    pane_id TEXT NOT NULL DEFAULT '',
    native_session_id TEXT NOT NULL DEFAULT '',
    started_at TEXT,
    last_seen_at TEXT,
    ended_at TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(source, external_id),
    UNIQUE(id, work_item_id)
);

CREATE TABLE IF NOT EXISTS stage_session_links (
    work_item_id TEXT NOT NULL,
    stage_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT '',
    attached_at TEXT NOT NULL,
    detached_at TEXT,
    PRIMARY KEY(work_item_id, stage_id, session_id),
    FOREIGN KEY(work_item_id, stage_id) REFERENCES work_stage_states(work_item_id, stage_id) ON DELETE CASCADE,
    FOREIGN KEY(session_id, work_item_id) REFERENCES pi_sessions(id, work_item_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS buzz_channels (
    id TEXT PRIMARY KEY,
    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'archived')),
    last_activity_at TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(source, external_id)
);

CREATE TABLE IF NOT EXISTS buzz_threads (
    id TEXT PRIMARY KEY,
    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
    channel_id TEXT REFERENCES buzz_channels(id) ON DELETE SET NULL,
    stage_id TEXT REFERENCES pipeline_stage_definitions(id),
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL DEFAULT '',
    snippet TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'archived')),
    last_activity_at TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(source, external_id)
);

CREATE TABLE IF NOT EXISTS work_activity_events (
    id TEXT PRIMARY KEY,
    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
    stage_id TEXT REFERENCES pipeline_stage_definitions(id),
    kind TEXT NOT NULL,
    actor_kind TEXT NOT NULL DEFAULT 'system',
    actor_id TEXT NOT NULL DEFAULT '',
    message TEXT NOT NULL,
    details_json TEXT NOT NULL DEFAULT '{}',
    source TEXT NOT NULL DEFAULT 'herdr',
    source_event_id TEXT,
    occurred_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS work_activity_source_event
ON work_activity_events(source, source_event_id)
WHERE source_event_id IS NOT NULL AND source_event_id != '';

CREATE TABLE IF NOT EXISTS work_source_state (
    work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(work_item_id, source)
);

CREATE TABLE IF NOT EXISTS ingestion_receipts (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    changed_items_json TEXT NOT NULL DEFAULT '[]',
    received_at TEXT NOT NULL,
    applied_at TEXT,
    UNIQUE(source, idempotency_key)
);

CREATE TABLE IF NOT EXISTS active_work_audit_events (
    id TEXT PRIMARY KEY,
    actor TEXT NOT NULL,
    action TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    patch_json TEXT NOT NULL DEFAULT '{}',
    request_id TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS work_items_updated ON work_items(lifecycle, updated_at DESC);
CREATE INDEX IF NOT EXISTS work_stage_states_item ON work_stage_states(work_item_id);
CREATE INDEX IF NOT EXISTS stage_agent_links_agent ON stage_agent_links(agent_id);
CREATE INDEX IF NOT EXISTS stage_session_links_session ON stage_session_links(session_id);
CREATE INDEX IF NOT EXISTS buzz_threads_item_stage ON buzz_threads(work_item_id, stage_id, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS work_activity_item_time ON work_activity_events(work_item_id, occurred_at DESC);
"""


def _merge_json_objects(existing: Any, incoming: Any) -> dict[str, Any]:
    """Recursively merge source metadata without deleting omitted fields."""

    base = copy.deepcopy(existing) if isinstance(existing, dict) else {}
    if not isinstance(incoming, dict):
        return base
    for key, value in incoming.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            base[key] = _merge_json_objects(base[key], value)
        else:
            base[key] = copy.deepcopy(value)
    return base


class ActiveWorkRepository:
    """Thread-safe durable repository used by the Herdr HTTP service."""

    def __init__(
        self,
        db_path: str | Path = DEFAULT_STORE_PATH,
        *,
        now: Callable[[], str] = utc_now,
    ) -> None:
        self._now = now
        self._lock = threading.RLock()
        self.path = self._prepare_path(db_path)
        self._database = sqlite3.connect(
            self.path,
            check_same_thread=False,
            timeout=5.0,
        )
        self._database.row_factory = sqlite3.Row
        with self._lock:
            self._database.execute("PRAGMA foreign_keys=ON")
            self._database.execute("PRAGMA busy_timeout=5000")
            if self.path != ":memory:":
                self._database.execute("PRAGMA journal_mode=WAL")
                self._database.execute("PRAGMA synchronous=NORMAL")
            self._migrate_locked()
            self._seed_pipeline_locked()
            self._secure_database_files()

    @staticmethod
    def _prepare_path(db_path: str | Path) -> str:
        if str(db_path) == ":memory:":
            return ":memory:"
        path = Path(os.path.abspath(os.path.expanduser(str(db_path))))
        parent = path.parent
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(parent, 0o700)
        except OSError as exc:
            raise ActiveWorkError(
                "Active Work database directory could not be secured",
                code="active_work_store_unsafe",
                status=500,
            ) from exc
        parent_metadata = os.lstat(parent)
        if stat.S_ISLNK(parent_metadata.st_mode) or not stat.S_ISDIR(parent_metadata.st_mode):
            raise ActiveWorkError(
                "Active Work database directory is unsafe",
                code="active_work_store_unsafe",
                status=500,
            )
        if hasattr(os, "getuid") and parent_metadata.st_uid != os.getuid():
            raise ActiveWorkError(
                "Active Work database directory belongs to another user",
                code="active_work_store_unsafe",
                status=500,
            )
        try:
            metadata = os.lstat(path)
        except FileNotFoundError:
            pass
        else:
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise ActiveWorkError(
                    "Active Work database path is unsafe",
                    code="active_work_store_unsafe",
                    status=500,
                )
            if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
                raise ActiveWorkError(
                    "Active Work database belongs to another user",
                    code="active_work_store_unsafe",
                    status=500,
                )
        return str(path)

    def _secure_database_files(self) -> None:
        if self.path == ":memory:":
            return
        for candidate in (self.path, f"{self.path}-wal", f"{self.path}-shm"):
            try:
                os.chmod(candidate, 0o600)
                metadata = os.lstat(candidate)
            except FileNotFoundError:
                continue
            if stat.S_ISLNK(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) & 0o077:
                raise ActiveWorkError(
                    "Active Work database permissions are unsafe",
                    code="active_work_store_unsafe",
                    status=500,
                )

    def close(self) -> None:
        with self._lock:
            self._database.close()

    @contextmanager
    def _transaction(self):
        with self._lock:
            self._database.execute("BEGIN IMMEDIATE")
            try:
                yield self._database
                self._database.commit()
                self._secure_database_files()
            except Exception:
                self._database.rollback()
                raise

    def _migrate_locked(self) -> None:
        version = int(self._database.execute("PRAGMA user_version").fetchone()[0])
        if version > CURRENT_SCHEMA_VERSION:
            raise ActiveWorkError(
                "Active Work database was created by a newer Herdr version",
                code="active_work_schema_newer",
                status=500,
            )
        if version == 0:
            applied_at = self._now().replace("'", "''")
            script = (
                "BEGIN IMMEDIATE;\n"
                + SCHEMA_V1
                + f"\nINSERT OR REPLACE INTO active_work_schema_migrations(version, applied_at) VALUES (1, '{applied_at}');\n"
                + "PRAGMA user_version=1;\nCOMMIT;"
            )
            try:
                self._database.executescript(script)
            except Exception:
                try:
                    self._database.rollback()
                except sqlite3.Error:
                    pass
                raise

    def _seed_pipeline_locked(self) -> None:
        created_at = self._now()
        with self._database:
            self._database.execute(
                """
                INSERT OR IGNORE INTO pipeline_templates(id, slug, version, title, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    DEFAULT_PIPELINE_ID,
                    DEFAULT_PIPELINE_SLUG,
                    DEFAULT_PIPELINE_VERSION,
                    "Buzz Feature Work",
                    created_at,
                ),
            )
            for stage in DEFAULT_PIPELINE_STAGES:
                self._database.execute(
                    """
                    INSERT OR IGNORE INTO pipeline_stage_definitions(
                        id, template_id, stage_key, sequence, phase_key, title,
                        skill_name, checkpoint_kind, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        stage["id"],
                        DEFAULT_PIPELINE_ID,
                        stage["stage_key"],
                        stage["sequence"],
                        stage["phase_key"],
                        stage["title"],
                        stage["skill_name"],
                        stage["checkpoint_kind"],
                        created_at,
                    ),
                )

    def schema_version(self) -> int:
        with self._lock:
            return int(self._database.execute("PRAGMA user_version").fetchone()[0])

    def board_projection(self, jira_candidates: Optional[list[dict]] = None) -> dict:
        """Return the complete durable board plus caller-supplied Jira candidates."""

        with self._lock:
            rows = self._database.execute(
                """
                SELECT id FROM work_items
                WHERE lifecycle != 'archived'
                ORDER BY CASE lifecycle WHEN 'blocked' THEN 0 WHEN 'active' THEN 1 ELSE 2 END,
                         updated_at DESC, created_at DESC
                """
            ).fetchall()
            items = [self._item_projection_locked(str(row["id"])) for row in rows]
            candidates = [self._candidate_projection_locked(item) for item in (jira_candidates or [])]
            return {
                "ok": True,
                "schema_version": CURRENT_SCHEMA_VERSION,
                "pipeline": self._pipeline_projection_locked(DEFAULT_PIPELINE_ID),
                "items": [item for item in items if item is not None],
                "jira_candidates": candidates,
                "generated_at": self._now(),
            }

    def item_projection(self, item_id: str) -> Optional[dict]:
        with self._lock:
            return self._item_projection_locked(internal_id(item_id, "work item ID"))

    def create_item(self, payload: dict, *, actor: str = "user") -> dict:
        """Create a Feature, Task, or Idea and initialize its whole route."""

        body = require_mapping(payload, "work item")
        reject_unknown(
            body,
            {
                "id",
                "kind",
                "title",
                "summary",
                "lifecycle",
                "current_stage_key",
                "next_action",
                "metadata",
            },
            "work item",
        )
        with self._transaction() as conn:
            item_id = self._insert_item_locked(conn, body, actor=actor)
        result = self.item_projection(item_id)
        assert result is not None
        return result

    def setup_jira(self, ticket: dict, *, actor: str = "user") -> dict:
        """Idempotently create one tracked item from an explicitly chosen Jira ticket."""

        item = require_mapping(ticket, "Jira ticket")
        key = jira_key(item.get("key") or item.get("issue_key"))
        site = site_from_ticket(item)
        with self._transaction() as conn:
            existing = conn.execute(
                "SELECT work_item_id FROM jira_links WHERE site = ? AND issue_key = ?",
                (site, key),
            ).fetchone()
            if existing is not None:
                item_id = str(existing["work_item_id"])
                created = False
                self._refresh_jira_link_locked(conn, item_id, item, site=site, key=key)
            else:
                issue_type = text(
                    item.get("issue_type") or item.get("issueType"),
                    "issue_type",
                    maximum=120,
                )
                normalized_type = issue_type.casefold()
                if "idea" in normalized_type:
                    kind = "idea"
                elif "epic" in normalized_type or "feature" in normalized_type:
                    kind = "feature"
                else:
                    kind = "task"
                title_value = text(item.get("title"), "title", maximum=500) or key
                item_id = self._insert_item_locked(
                    conn,
                    {
                        "kind": kind,
                        "title": title_value,
                        "summary": "",
                        "lifecycle": "active",
                        "current_stage_key": "start-ticket",
                        "next_action": "Set up the Buzz channel and confirm the current pipeline stage.",
                        "metadata": {"created_from": "jira"},
                    },
                    actor=actor,
                    record_created_activity=False,
                )
                self._refresh_jira_link_locked(conn, item_id, item, site=site, key=key)
                self._activity_locked(
                    conn,
                    item_id,
                    kind="jira_setup",
                    message=f"Set up {key} for Active Work.",
                    actor_kind="user" if actor == "user" else "agent",
                    actor_id=actor,
                    source_name="herdr",
                )
                self._audit_locked(
                    conn,
                    actor,
                    "setup_jira",
                    "work_item",
                    item_id,
                    {"site": site, "issue_key": key},
                )
                created = True
        projection = self.item_projection(item_id)
        assert projection is not None
        return {"created": created, "item": projection}

    def refresh_tracked_jira(self, ticket: dict) -> Optional[dict]:
        """Refresh an existing Jira link without ever creating board work."""

        item = require_mapping(ticket, "Jira ticket")
        key = jira_key(item.get("key") or item.get("issue_key"))
        site = site_from_ticket(item)
        with self._transaction() as conn:
            existing = conn.execute(
                "SELECT work_item_id, site FROM jira_links WHERE site = ? AND issue_key = ?",
                (site, key),
            ).fetchone()
            if existing is None and site == "default":
                matches = conn.execute(
                    "SELECT work_item_id, site FROM jira_links WHERE issue_key = ?",
                    (key,),
                ).fetchall()
                existing = matches[0] if len(matches) == 1 else None
            if existing is None:
                return None
            item_id = str(existing["work_item_id"])
            site = str(existing["site"])
            self._refresh_jira_link_locked(conn, item_id, item, site=site, key=key)
        return self.item_projection(item_id)

    def patch_item(
        self,
        item_id: str,
        payload: dict,
        *,
        expected_revision: Optional[int] = None,
        actor: str = "user",
    ) -> dict:
        """Patch user-owned item fields using optimistic revision matching."""

        normalized_id = internal_id(item_id, "work item ID")
        body = require_mapping(payload, "work item patch")
        reject_unknown(
            body,
            {"title", "summary", "kind", "lifecycle", "next_action", "metadata", "expected_revision"},
            "work item patch",
        )
        revision = self._expected_revision(body, expected_revision)
        requested: dict[str, Any] = {}
        if "title" in body:
            requested["title"] = text(body["title"], "title", maximum=500, required=True)
        if "summary" in body:
            requested["summary"] = text(body["summary"], "summary", maximum=32768)
        if "kind" in body:
            requested["kind"] = choice(body["kind"], "kind", WORK_KINDS)
        if "lifecycle" in body:
            requested["lifecycle"] = choice(body["lifecycle"], "lifecycle", WORK_LIFECYCLES)
        if "next_action" in body:
            requested["next_action"] = text(body["next_action"], "next_action", maximum=8192)
        incoming_metadata = (
            bounded_json(body["metadata"], "metadata", maximum_bytes=128 * 1024)
            if "metadata" in body
            else None
        )
        with self._transaction() as conn:
            row = self._require_item_locked(conn, normalized_id)
            if int(row["revision"]) != revision:
                raise ActiveWorkError(
                    "Work item was changed by another client",
                    code="active_work_revision_conflict",
                    status=409,
                )
            if requested.get("lifecycle") == "done":
                current_stage = conn.execute(
                    "SELECT stage_key FROM pipeline_stage_definitions WHERE id = ?",
                    (row["current_stage_id"],),
                ).fetchone()
                if current_stage is None or current_stage["stage_key"] != "pr-triage":
                    raise ActiveWorkError(
                        "Work can only be marked done at the final pipeline stage",
                        code="active_work_invalid_terminal_state",
                        status=409,
                    )
            updates = {
                column: value
                for column, value in requested.items()
                if row[column] != value
            }
            if incoming_metadata is not None:
                merged_metadata = bounded_json(
                    _merge_json_objects(json_load(row["metadata_json"], {}), incoming_metadata),
                    "metadata",
                    maximum_bytes=128 * 1024,
                )
                encoded_metadata = json_dump(merged_metadata)
                if encoded_metadata != row["metadata_json"]:
                    updates["metadata_json"] = encoded_metadata
            if not updates:
                return self._item_projection_locked(normalized_id) or {}
            now = self._now()
            if updates.get("lifecycle") == "archived":
                updates["archived_at"] = now
            elif "lifecycle" in updates:
                updates["archived_at"] = None
            assignments = ", ".join(f"{column} = ?" for column in updates)
            conn.execute(
                f"UPDATE work_items SET {assignments}, revision = revision + 1, updated_at = ? WHERE id = ?",
                [*updates.values(), now, normalized_id],
            )
            if updates.get("lifecycle") == "done" and row["current_stage_id"]:
                conn.execute(
                    """
                    UPDATE work_stage_states SET state = 'complete', attention = 'none',
                        checkpoint_state = CASE WHEN checkpoint_state = 'none' THEN 'none' ELSE 'approved' END,
                        completed_at = COALESCE(completed_at, ?), updated_at = ?
                    WHERE work_item_id = ? AND stage_id = ?
                    """,
                    (now, now, normalized_id, row["current_stage_id"]),
                )
            elif updates.get("lifecycle") in {"active", "blocked"} and row["current_stage_id"]:
                conn.execute(
                    """
                    UPDATE work_stage_states SET state = ?, completed_at = NULL, updated_at = ?
                    WHERE work_item_id = ? AND stage_id = ?
                    """,
                    (
                        "blocked" if updates["lifecycle"] == "blocked" else "active",
                        now,
                        normalized_id,
                        row["current_stage_id"],
                    ),
                )
            self._audit_locked(conn, actor, "patch_item", "work_item", normalized_id, body)
            self._activity_locked(
                conn,
                normalized_id,
                kind="work_item_updated",
                message="Updated Active Work fields.",
                actor_kind="user" if actor == "user" else "agent",
                actor_id=actor,
            )
        result = self.item_projection(normalized_id)
        assert result is not None
        return result

    def transition(self, item_id: str, payload: dict, *, actor: str = "user") -> dict:
        """Move an item forward through its pipeline, or update its current stage."""

        normalized_id = internal_id(item_id, "work item ID")
        body = require_mapping(payload, "transition")
        reject_unknown(
            body,
            {"to_stage_key", "expected_revision", "note", "attention", "checkpoint_state", "state"},
            "transition",
        )
        revision = self._expected_revision(body, None)
        target_key = choice(body.get("to_stage_key"), "to_stage_key", STAGE_KEYS)
        target_state = choice(body.get("state"), "state", {"active", "blocked"}, default="active")
        attention = choice(body.get("attention"), "attention", ATTENTION_STATES, default="none")
        note = text(body.get("note"), "note", maximum=32768)
        with self._transaction() as conn:
            item = self._require_item_locked(conn, normalized_id)
            if int(item["revision"]) != revision:
                raise ActiveWorkError(
                    "Work item was changed by another client",
                    code="active_work_revision_conflict",
                    status=409,
                )
            target = self._require_stage_locked(conn, str(item["template_id"]), target_key)
            current = None
            if item["current_stage_id"]:
                current = conn.execute(
                    "SELECT * FROM pipeline_stage_definitions WHERE id = ?",
                    (item["current_stage_id"],),
                ).fetchone()
            if current is not None and int(target["sequence"]) < int(current["sequence"]):
                raise ActiveWorkError(
                    "Pipeline transitions cannot move backward",
                    code="active_work_invalid_transition",
                    status=409,
                )
            checkpoint = body.get("checkpoint_state")
            if checkpoint is None:
                checkpoint = "pending" if target["checkpoint_kind"] == "human" else "none"
            checkpoint_state = choice(checkpoint, "checkpoint_state", CHECKPOINT_STATES)
            self._set_current_stage_locked(
                conn,
                normalized_id,
                target,
                state=target_state,
                attention=attention,
                checkpoint_state=checkpoint_state,
                summary=note or None,
                observed_at=None,
                reset_future=False,
            )
            now = self._now()
            conn.execute(
                "UPDATE work_items SET lifecycle = ?, revision = revision + 1, updated_at = ? WHERE id = ?",
                ("blocked" if target_state == "blocked" else "active", now, normalized_id),
            )
            self._activity_locked(
                conn,
                normalized_id,
                stage_id=str(target["id"]),
                kind="stage_transition",
                message=note or f"Moved to {target['title']}.",
                actor_kind="user" if actor == "user" else "agent",
                actor_id=actor,
            )
            self._audit_locked(conn, actor, "transition", "work_item", normalized_id, body)
        result = self.item_projection(normalized_id)
        assert result is not None
        return result

    def ingest(self, payload: dict, *, actor: str = "ingest") -> dict:
        """Merge an idempotent, stale-safe observation into an existing item.

        This method never creates a work item. A Jira candidate must first be
        set up through :meth:`setup_jira`.
        """

        body = require_mapping(payload, "ingestion")
        reject_unknown(
            body,
            {
                "source",
                "idempotency_key",
                "observed_at",
                "selector",
                "item",
                "current_stage_key",
                "channel",
                "stages",
                "threads",
                "activity",
            },
            "ingestion",
        )
        source_name = source(body.get("source"))
        idempotency_key = external_id(body.get("idempotency_key"), "idempotency_key")
        observed_at = timestamp(body.get("observed_at"), "observed_at", required=True)
        assert observed_at is not None
        digest = payload_hash(body)
        selector = require_mapping(body.get("selector"), "selector")
        reject_unknown(selector, {"work_item_id", "jira_key", "jira_site", "buzz_channel_id"}, "selector")
        with self._transaction() as conn:
            receipt = conn.execute(
                "SELECT * FROM ingestion_receipts WHERE source = ? AND idempotency_key = ?",
                (source_name, idempotency_key),
            ).fetchone()
            if receipt is not None:
                if receipt["payload_hash"] != digest:
                    raise ActiveWorkError(
                        "Idempotency key was already used with a different payload",
                        code="active_work_idempotency_conflict",
                        status=409,
                    )
                changed = json_load(receipt["changed_items_json"], [])
                item_id = str(changed[0]) if changed else self._resolve_selector_locked(conn, selector)
                projection = self._item_projection_locked(item_id) if item_id else None
                return {
                    "applied": False,
                    "replayed": True,
                    "stale": receipt["applied_at"] is None,
                    "receipt_id": receipt["id"],
                    "item": projection,
                }

            item_id = self._resolve_selector_locked(conn, selector)
            if not item_id:
                raise ActiveWorkError(
                    "Active Work item must be set up before ingestion",
                    code="active_work_item_not_found",
                    status=404,
                )
            item = self._require_item_locked(conn, item_id)
            source_state = conn.execute(
                "SELECT observed_at FROM work_source_state WHERE work_item_id = ? AND source = ?",
                (item_id, source_name),
            ).fetchone()
            stale = bool(
                source_state
                and timestamp_value(observed_at) < timestamp_value(str(source_state["observed_at"]))
            )
            receipt_id = safe_id("ingest")
            if stale:
                conn.execute(
                    """
                    INSERT INTO ingestion_receipts(
                        id, source, idempotency_key, payload_hash, changed_items_json,
                        received_at, applied_at
                    ) VALUES (?, ?, ?, ?, '[]', ?, NULL)
                    """,
                    (receipt_id, source_name, idempotency_key, digest, self._now()),
                )
                return {
                    "applied": False,
                    "replayed": False,
                    "stale": True,
                    "receipt_id": receipt_id,
                    "item": self._item_projection_locked(item_id),
                }

            current_definition = None
            if item["current_stage_id"]:
                current_definition = conn.execute(
                    "SELECT * FROM pipeline_stage_definitions WHERE id = ?",
                    (item["current_stage_id"],),
                ).fetchone()
            target = None
            target_key = body.get("current_stage_key")
            if target_key is not None:
                normalized_target = choice(target_key, "current_stage_key", STAGE_KEYS)
                candidate_target = self._require_stage_locked(
                    conn, str(item["template_id"]), normalized_target
                )
                # Source observations are monotonic. A newer but sparse or
                # inconsistent snapshot may enrich an older phase, but it may
                # not move the durable route backward.
                if (
                    current_definition is None
                    or int(candidate_target["sequence"]) >= int(current_definition["sequence"])
                ):
                    target = candidate_target
            terminal_definition = target or current_definition
            terminal_stage_key = (
                str(terminal_definition["stage_key"]) if terminal_definition is not None else None
            )

            changed = False
            item_patch = body.get("item")
            if item_patch is not None:
                changed |= self._merge_item_fields_locked(
                    conn,
                    item_id,
                    require_mapping(item_patch, "item"),
                    terminal_stage_key=terminal_stage_key,
                )

            channel_id = None
            if body.get("channel") is not None:
                channel_id, channel_changed = self._upsert_channel_locked(
                    conn,
                    item_id,
                    source_name,
                    require_mapping(body["channel"], "channel"),
                    observed_at,
                )
                changed |= channel_changed

            if target is not None:
                current_lifecycle = str(
                    conn.execute("SELECT lifecycle FROM work_items WHERE id = ?", (item_id,)).fetchone()[
                        "lifecycle"
                    ]
                )
                terminal = current_lifecycle in {"done", "archived"} and target["stage_key"] == "pr-triage"
                advancing = (
                    current_definition is None
                    or int(target["sequence"]) > int(current_definition["sequence"])
                )
                if advancing:
                    prepared_state = conn.execute(
                        "SELECT attention, checkpoint_state FROM work_stage_states WHERE work_item_id = ? AND stage_id = ?",
                        (item_id, target["id"]),
                    ).fetchone()
                    prepared_attention = str(prepared_state["attention"])
                    prepared_checkpoint = str(prepared_state["checkpoint_state"])
                    self._set_current_stage_locked(
                        conn,
                        item_id,
                        target,
                        state=(
                            "complete"
                            if terminal
                            else "blocked" if current_lifecycle == "blocked" else "active"
                        ),
                        attention="none" if terminal else prepared_attention,
                        checkpoint_state=(
                            "approved"
                            if terminal and target["checkpoint_kind"] == "human"
                            else prepared_checkpoint
                            if prepared_checkpoint != "none"
                            else "pending" if target["checkpoint_kind"] == "human" else "none"
                        ),
                        summary=None,
                        observed_at=observed_at,
                        reset_future=False,
                    )
                else:
                    # Re-observing the same phase is a sparse heartbeat, not a
                    # command to clear manual attention/checkpoint state.
                    conn.execute(
                        """
                        UPDATE work_stage_states SET source_observed_at = ?, updated_at = ?
                        WHERE work_item_id = ? AND stage_id = ?
                        """,
                        (observed_at, self._now(), item_id, target["id"]),
                    )
                changed = True

            for raw_stage in require_list(body.get("stages"), "stages", maximum=64):
                stage_payload = require_mapping(raw_stage, "stage")
                stage_changed = self._ingest_stage_locked(
                    conn,
                    item_id,
                    str(item["template_id"]),
                    source_name,
                    observed_at,
                    stage_payload,
                    default_channel_id=channel_id,
                )
                changed |= stage_changed

            terminal_item = conn.execute(
                "SELECT lifecycle, current_stage_id FROM work_items WHERE id = ?",
                (item_id,),
            ).fetchone()
            if terminal_item["lifecycle"] == "done":
                final_stage = self._require_stage_locked(conn, str(item["template_id"]), "pr-triage")
                if terminal_item["current_stage_id"] != final_stage["id"]:
                    raise ActiveWorkError(
                        "Done work must remain at the final pipeline stage",
                        code="active_work_invalid_terminal_state",
                        status=409,
                    )
                now = self._now()
                conn.execute(
                    """
                    UPDATE work_stage_states SET state = 'complete', attention = 'none',
                        checkpoint_state = CASE WHEN checkpoint_state = 'none' THEN 'none' ELSE 'approved' END,
                        started_at = COALESCE(started_at, ?),
                        completed_at = COALESCE(completed_at, ?), updated_at = ?
                    WHERE work_item_id = ? AND stage_id = ?
                    """,
                    (now, now, now, item_id, final_stage["id"]),
                )

            for raw_thread in require_list(body.get("threads"), "threads", maximum=500):
                _, thread_changed = self._upsert_thread_locked(
                    conn,
                    item_id,
                    None,
                    source_name,
                    require_mapping(raw_thread, "thread"),
                    observed_at,
                    default_channel_id=channel_id,
                )
                changed |= thread_changed

            for raw_event in require_list(body.get("activity"), "activity", maximum=500):
                changed |= self._ingest_activity_locked(
                    conn,
                    item_id,
                    str(item["template_id"]),
                    source_name,
                    observed_at,
                    require_mapping(raw_event, "activity event"),
                )

            now = self._now()
            conn.execute(
                """
                INSERT INTO work_source_state(work_item_id, source, observed_at, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(work_item_id, source) DO UPDATE SET
                    observed_at = excluded.observed_at,
                    updated_at = excluded.updated_at
                """,
                (item_id, source_name, observed_at, now),
            )
            if changed:
                conn.execute(
                    "UPDATE work_items SET revision = revision + 1, updated_at = ? WHERE id = ?",
                    (now, item_id),
                )
            conn.execute(
                """
                INSERT INTO ingestion_receipts(
                    id, source, idempotency_key, payload_hash, changed_items_json,
                    received_at, applied_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    receipt_id,
                    source_name,
                    idempotency_key,
                    digest,
                    json_dump([item_id] if changed else []),
                    now,
                    now,
                ),
            )
            self._audit_locked(
                conn,
                actor,
                "ingest",
                "work_item",
                item_id,
                {
                    "source": source_name,
                    "idempotency_key": idempotency_key,
                    "observed_at": observed_at,
                },
                request_id=idempotency_key,
            )
        projection = self.item_projection(item_id)
        assert projection is not None
        return {
            "applied": changed,
            "replayed": False,
            "stale": False,
            "receipt_id": receipt_id,
            "item": projection,
        }

    def sync_targets(self) -> dict:
        """Return the minimum stable identifiers required by an external scraper."""

        with self._lock:
            rows = self._database.execute(
                "SELECT id, kind, title, lifecycle, revision FROM work_items WHERE lifecycle != 'archived' ORDER BY updated_at DESC"
            ).fetchall()
            targets = []
            for row in rows:
                item_id = str(row["id"])
                jira = self._database.execute(
                    "SELECT site, issue_key FROM jira_links WHERE work_item_id = ? ORDER BY created_at",
                    (item_id,),
                ).fetchall()
                channels = self._database.execute(
                    "SELECT source, external_id FROM buzz_channels WHERE work_item_id = ? AND status = 'active' ORDER BY created_at",
                    (item_id,),
                ).fetchall()
                targets.append(
                    {
                        "work_item_id": item_id,
                        "kind": row["kind"],
                        "title": row["title"],
                        "lifecycle": row["lifecycle"],
                        "revision": int(row["revision"]),
                        "jira": [dict(item) for item in jira],
                        "buzz_channels": [dict(item) for item in channels],
                    }
                )
            return {"ok": True, "items": targets, "generated_at": self._now()}

    def _insert_item_locked(
        self,
        conn: sqlite3.Connection,
        body: Mapping[str, Any],
        *,
        actor: str,
        record_created_activity: bool = True,
    ) -> str:
        kind = choice(body.get("kind"), "kind", WORK_KINDS, default="task")
        title_value = text(body.get("title"), "title", maximum=500, required=True)
        summary = text(body.get("summary"), "summary", maximum=32768)
        lifecycle = choice(body.get("lifecycle"), "lifecycle", WORK_LIFECYCLES, default="active")
        next_action = text(body.get("next_action"), "next_action", maximum=8192)
        metadata = bounded_json(body.get("metadata"), "metadata", maximum_bytes=128 * 1024)
        item_id = internal_id(body["id"], "work item ID") if body.get("id") else safe_id("work")
        current_raw = body.get("current_stage_key", "__missing__")
        current_key: Optional[str]
        if current_raw == "__missing__":
            if lifecycle == "done":
                current_key = "pr-triage"
            else:
                current_key = None if kind == "idea" else "start-ticket"
        elif current_raw is None:
            current_key = None
        else:
            current_key = choice(current_raw, "current_stage_key", STAGE_KEYS)
        if lifecycle == "done" and current_key != "pr-triage":
            raise ActiveWorkError(
                "Work can only be marked done at the final pipeline stage",
                code="active_work_invalid_terminal_state",
                status=409,
            )
        stages = conn.execute(
            "SELECT * FROM pipeline_stage_definitions WHERE template_id = ? ORDER BY sequence",
            (DEFAULT_PIPELINE_ID,),
        ).fetchall()
        current = next((stage for stage in stages if stage["stage_key"] == current_key), None)
        now = self._now()
        conn.execute(
            """
            INSERT INTO work_items(
                id, kind, title, summary, lifecycle, template_id, current_stage_id,
                next_action, revision, metadata_json, created_at, updated_at, archived_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
            """,
            (
                item_id,
                kind,
                title_value,
                summary,
                lifecycle,
                DEFAULT_PIPELINE_ID,
                current["id"] if current else None,
                next_action,
                json_dump(metadata),
                now,
                now,
                now if lifecycle == "archived" else None,
            ),
        )
        current_sequence = int(current["sequence"]) if current else None
        for stage in stages:
            sequence = int(stage["sequence"])
            if current_sequence is None:
                state = "pending"
                checkpoint_state = "none"
                started_at = None
                completed_at = None
            elif sequence < current_sequence:
                state = "complete"
                checkpoint_state = "approved" if stage["checkpoint_kind"] == "human" else "none"
                started_at = now
                completed_at = now
            elif sequence == current_sequence:
                if lifecycle == "done":
                    state = "complete"
                    checkpoint_state = "approved" if stage["checkpoint_kind"] == "human" else "none"
                else:
                    state = "blocked" if lifecycle == "blocked" else "active"
                    checkpoint_state = "pending" if stage["checkpoint_kind"] == "human" else "none"
                started_at = now
                completed_at = now if lifecycle == "done" else None
            else:
                state = "pending"
                checkpoint_state = "none"
                started_at = None
                completed_at = None
            conn.execute(
                """
                INSERT INTO work_stage_states(
                    work_item_id, stage_id, state, attention, checkpoint_state,
                    summary, content_json, source_observed_at, started_at,
                    completed_at, updated_at
                ) VALUES (?, ?, ?, 'none', ?, '', '{}', NULL, ?, ?, ?)
                """,
                (item_id, stage["id"], state, checkpoint_state, started_at, completed_at, now),
            )
        if record_created_activity:
            self._activity_locked(
                conn,
                item_id,
                kind="work_item_created",
                message=f"Created {kind} {title_value}.",
                actor_kind="user" if actor == "user" else "agent",
                actor_id=actor,
            )
            self._audit_locked(conn, actor, "create_item", "work_item", item_id, dict(body))
        return item_id

    def _refresh_jira_link_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        ticket: Mapping[str, Any],
        *,
        site: str,
        key: str,
    ) -> None:
        now = self._now()
        observed_at = timestamp(ticket.get("observed_at"), "observed_at") or now
        existing = conn.execute(
            "SELECT * FROM jira_links WHERE site = ? AND issue_key = ?",
            (site, key),
        ).fetchone()
        try:
            candidate_url = url(ticket.get("url"), "Jira URL") if ticket.get("url") else ""
        except ActiveWorkError:
            # A malformed optional browse link must not take the durable board
            # down during live Jira enrichment. Keep the last safe link.
            candidate_url = str(existing["url"] or "") if existing else ""
        existing_metadata = json_load(existing["metadata_json"], {}) if existing else {}
        metadata = existing_metadata
        if "metadata" in ticket:
            metadata = bounded_json(
                _merge_json_objects(
                    existing_metadata,
                    bounded_json(ticket.get("metadata"), "Jira metadata", maximum_bytes=128 * 1024),
                ),
                "Jira metadata",
                maximum_bytes=128 * 1024,
            )
        link_id = str(existing["id"]) if existing else safe_id("jira")
        created_at = str(existing["created_at"]) if existing else now
        conn.execute(
            """
            INSERT INTO jira_links(
                id, work_item_id, site, issue_key, title, status, priority,
                issue_type, url, metadata_json, observed_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(site, issue_key) DO UPDATE SET
                title = excluded.title,
                status = excluded.status,
                priority = excluded.priority,
                issue_type = excluded.issue_type,
                url = excluded.url,
                metadata_json = excluded.metadata_json,
                observed_at = excluded.observed_at,
                updated_at = excluded.updated_at
            """,
            (
                link_id,
                item_id,
                site,
                key,
                text(ticket.get("title"), "Jira title", maximum=500),
                text(ticket.get("status"), "Jira status", maximum=120),
                text(ticket.get("priority"), "Jira priority", maximum=120),
                text(ticket.get("issue_type") or ticket.get("issueType"), "Jira issue_type", maximum=120),
                candidate_url,
                json_dump(metadata),
                observed_at,
                created_at,
                now,
            ),
        )

    def _expected_revision(self, body: Mapping[str, Any], explicit: Optional[int]) -> int:
        raw = explicit if explicit is not None else body.get("expected_revision")
        if isinstance(raw, bool):
            raise ActiveWorkError("expected_revision must be a positive integer")
        try:
            revision = int(raw)
        except (TypeError, ValueError) as exc:
            raise ActiveWorkError("expected_revision is required") from exc
        if revision < 1:
            raise ActiveWorkError("expected_revision must be a positive integer")
        return revision

    def _require_item_locked(self, conn: sqlite3.Connection, item_id: str) -> sqlite3.Row:
        row = conn.execute("SELECT * FROM work_items WHERE id = ?", (item_id,)).fetchone()
        if row is None:
            raise ActiveWorkError(
                "Active Work item not found",
                code="active_work_item_not_found",
                status=404,
            )
        return row

    def _require_stage_locked(
        self,
        conn: sqlite3.Connection,
        template_id: str,
        stage_key: str,
    ) -> sqlite3.Row:
        row = conn.execute(
            "SELECT * FROM pipeline_stage_definitions WHERE template_id = ? AND stage_key = ?",
            (template_id, stage_key),
        ).fetchone()
        if row is None:
            raise ActiveWorkError("Pipeline stage is invalid")
        return row

    def _set_current_stage_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        target: sqlite3.Row,
        *,
        state: str,
        attention: str,
        checkpoint_state: str,
        summary: Optional[str],
        observed_at: Optional[str],
        reset_future: bool,
    ) -> None:
        now = self._now()
        stages = conn.execute(
            """
            SELECT definition.*, state.state AS current_state
            FROM pipeline_stage_definitions definition
            JOIN work_stage_states state ON state.stage_id = definition.id
            WHERE state.work_item_id = ? AND definition.template_id = ?
            ORDER BY definition.sequence
            """,
            (item_id, target["template_id"]),
        ).fetchall()
        target_sequence = int(target["sequence"])
        for stage in stages:
            sequence = int(stage["sequence"])
            if sequence < target_sequence:
                next_state = "skipped" if stage["current_state"] == "skipped" else "complete"
                next_checkpoint = "approved" if stage["checkpoint_kind"] == "human" else "none"
                conn.execute(
                    """
                    UPDATE work_stage_states SET state = ?, attention = 'none',
                        checkpoint_state = ?, started_at = COALESCE(started_at, ?),
                        completed_at = COALESCE(completed_at, ?), updated_at = ?
                    WHERE work_item_id = ? AND stage_id = ?
                    """,
                    (next_state, next_checkpoint, now, now, now, item_id, stage["id"]),
                )
            elif sequence == target_sequence:
                fields = [
                    "state = ?",
                    "attention = ?",
                    "checkpoint_state = ?",
                    "started_at = COALESCE(started_at, ?)",
                    "updated_at = ?",
                ]
                values: list[Any] = [state, attention, checkpoint_state, now, now]
                if state in {"complete", "skipped"}:
                    fields.append("completed_at = COALESCE(completed_at, ?)")
                    values.append(now)
                else:
                    fields.append("completed_at = NULL")
                if summary is not None:
                    fields.append("summary = ?")
                    values.append(summary)
                if observed_at is not None:
                    fields.append("source_observed_at = ?")
                    values.append(observed_at)
                values.extend([item_id, stage["id"]])
                conn.execute(
                    f"UPDATE work_stage_states SET {', '.join(fields)} WHERE work_item_id = ? AND stage_id = ?",
                    values,
                )
            elif reset_future:
                conn.execute(
                    """
                    UPDATE work_stage_states SET state = 'pending', attention = 'none',
                        checkpoint_state = 'none', started_at = NULL, completed_at = NULL,
                        updated_at = ? WHERE work_item_id = ? AND stage_id = ?
                    """,
                    (now, item_id, stage["id"]),
                )
        conn.execute(
            "UPDATE work_items SET current_stage_id = ? WHERE id = ?",
            (target["id"], item_id),
        )

    def _merge_item_fields_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        body: Mapping[str, Any],
        *,
        terminal_stage_key: Optional[str] = None,
    ) -> bool:
        reject_unknown(body, {"title", "summary", "lifecycle", "next_action", "metadata"}, "ingested item")
        current = self._require_item_locked(conn, item_id)
        updates: dict[str, Any] = {}
        if "title" in body:
            updates["title"] = text(body["title"], "title", maximum=500, required=True)
        if "summary" in body:
            updates["summary"] = text(body["summary"], "summary", maximum=32768)
        if "lifecycle" in body:
            updates["lifecycle"] = choice(body["lifecycle"], "lifecycle", WORK_LIFECYCLES)
        if "next_action" in body:
            updates["next_action"] = text(body["next_action"], "next_action", maximum=8192)
        if "metadata" in body:
            merged_metadata = bounded_json(
                _merge_json_objects(
                    json_load(current["metadata_json"], {}),
                    bounded_json(body["metadata"], "metadata", maximum_bytes=128 * 1024),
                ),
                "metadata",
                maximum_bytes=128 * 1024,
            )
            updates["metadata_json"] = json_dump(merged_metadata)
        if updates.get("lifecycle") == "done" and terminal_stage_key != "pr-triage":
            raise ActiveWorkError(
                "Work can only be marked done at the final pipeline stage",
                code="active_work_invalid_terminal_state",
                status=409,
            )
        incoming_lifecycle = updates.get("lifecycle")
        source_would_reopen_terminal = "lifecycle" in updates and (
            (current["lifecycle"] == "archived" and incoming_lifecycle != "archived")
            or (
                current["lifecycle"] == "done"
                and incoming_lifecycle in {"active", "blocked"}
            )
        )
        if source_would_reopen_terminal:
            # External observations may enrich terminal work, but reopening is
            # an explicit owner action through the revisioned PATCH endpoint.
            updates.pop("lifecycle", None)
        updates = {
            column: value
            for column, value in updates.items()
            if current[column] != value
        }
        if not updates:
            return False
        if updates.get("lifecycle") == "archived":
            updates["archived_at"] = self._now()
        elif "lifecycle" in updates:
            updates["archived_at"] = None
        assignments = ", ".join(f"{column} = ?" for column in updates)
        conn.execute(
            f"UPDATE work_items SET {assignments} WHERE id = ?",
            [*updates.values(), item_id],
        )
        return True

    def _upsert_channel_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        source_name: str,
        body: Mapping[str, Any],
        observed_at: str,
    ) -> tuple[str, bool]:
        reject_unknown(body, {"external_id", "name", "url", "status", "last_activity_at", "metadata"}, "channel")
        external = external_id(body.get("external_id"), "channel external_id")
        existing = conn.execute(
            "SELECT * FROM buzz_channels WHERE source = ? AND external_id = ?",
            (source_name, external),
        ).fetchone()
        if existing is not None and existing["work_item_id"] != item_id:
            raise ActiveWorkError(
                "Buzz channel is already attached to another work item",
                code="active_work_association_conflict",
                status=409,
            )
        now = self._now()
        channel_id = str(existing["id"]) if existing else safe_id("channel")
        created_at = str(existing["created_at"]) if existing else now
        channel_name = (
            text(body.get("name"), "channel name", maximum=500)
            if "name" in body
            else str(existing["name"] or "") if existing else ""
        )
        channel_url = (
            link_url(body.get("url"), "channel URL")
            if "url" in body and body.get("url")
            else "" if "url" in body
            else str(existing["url"] or "") if existing else ""
        )
        channel_status = (
            choice(body.get("status"), "channel status", THREAD_STATUSES)
            if "status" in body
            else str(existing["status"]) if existing else "active"
        )
        channel_activity = (
            timestamp(body.get("last_activity_at"), "channel last_activity_at")
            if "last_activity_at" in body
            else str(existing["last_activity_at"] or "") if existing else observed_at
        ) or observed_at
        existing_metadata = json_load(existing["metadata_json"], {}) if existing else {}
        channel_metadata = existing_metadata
        if "metadata" in body:
            incoming_metadata = bounded_json(body.get("metadata"), "channel metadata")
            channel_metadata = bounded_json(
                _merge_json_objects(existing_metadata, incoming_metadata),
                "channel metadata",
            )
        conn.execute(
            """
            INSERT INTO buzz_channels(
                id, work_item_id, source, external_id, name, url, status,
                last_activity_at, metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, external_id) DO UPDATE SET
                name = excluded.name, url = excluded.url, status = excluded.status,
                last_activity_at = excluded.last_activity_at,
                metadata_json = excluded.metadata_json, updated_at = excluded.updated_at
            """,
            (
                channel_id,
                item_id,
                source_name,
                external,
                channel_name,
                channel_url,
                channel_status,
                channel_activity,
                json_dump(channel_metadata),
                created_at,
                now,
            ),
        )
        return channel_id, True

    def _ingest_stage_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        template_id: str,
        source_name: str,
        observed_at: str,
        body: Mapping[str, Any],
        *,
        default_channel_id: Optional[str],
    ) -> bool:
        reject_unknown(
            body,
            {
                "stage_key",
                "state",
                "attention",
                "checkpoint_state",
                "summary",
                "content",
                "agents",
                "pi_sessions",
                "threads",
            },
            "stage",
        )
        stage_key = choice(body.get("stage_key"), "stage_key", STAGE_KEYS)
        stage = self._require_stage_locked(conn, template_id, stage_key)
        stage_state = conn.execute(
            "SELECT * FROM work_stage_states WHERE work_item_id = ? AND stage_id = ?",
            (item_id, stage["id"]),
        ).fetchone()
        current_stage = conn.execute(
            """
            SELECT definition.sequence
            FROM work_items item
            LEFT JOIN pipeline_stage_definitions definition ON definition.id = item.current_stage_id
            WHERE item.id = ?
            """,
            (item_id,),
        ).fetchone()
        current_sequence = (
            int(current_stage["sequence"])
            if current_stage is not None and current_stage["sequence"] is not None
            else None
        )
        updates: dict[str, Any] = {"source_observed_at": observed_at, "updated_at": self._now()}
        if "state" in body:
            incoming_state = choice(body["state"], "stage state", STAGE_STATES)
            stage_sequence = int(stage["sequence"])
            existing_state = str(stage_state["state"])
            state_rank = {
                "pending": 0,
                "ready": 1,
                "active": 2,
                "blocked": 2,
                "complete": 3,
                "skipped": 3,
            }
            allow_state = True
            if current_sequence is not None and stage_sequence < current_sequence:
                allow_state = incoming_state in {"complete", "skipped"}
            elif current_sequence is not None and stage_sequence > current_sequence:
                allow_state = (
                    incoming_state in {"pending", "ready"}
                    and state_rank[incoming_state] >= state_rank[existing_state]
                )
            if allow_state:
                updates["state"] = incoming_state
        if "attention" in body:
            updates["attention"] = choice(body["attention"], "stage attention", ATTENTION_STATES)
        if "checkpoint_state" in body:
            updates["checkpoint_state"] = choice(
                body["checkpoint_state"], "checkpoint_state", CHECKPOINT_STATES
            )
        if "summary" in body:
            updates["summary"] = text(body["summary"], "stage summary", maximum=32768)
        if "content" in body:
            merged_content = _merge_json_objects(
                json_load(stage_state["content_json"], {}),
                bounded_json(body["content"], "stage content", maximum_bytes=256 * 1024),
            )
            updates["content_json"] = json_dump(
                bounded_json(merged_content, "stage content", maximum_bytes=256 * 1024)
            )
        assignments = ", ".join(f"{key} = ?" for key in updates)
        conn.execute(
            f"UPDATE work_stage_states SET {assignments} WHERE work_item_id = ? AND stage_id = ?",
            [*updates.values(), item_id, stage["id"]],
        )
        changed = bool(updates)
        for raw_agent in require_list(body.get("agents"), "stage agents", maximum=200):
            changed |= self._upsert_stage_agent_locked(
                conn,
                item_id,
                str(stage["id"]),
                source_name,
                observed_at,
                require_mapping(raw_agent, "agent"),
            )
        for raw_session in require_list(body.get("pi_sessions"), "stage pi_sessions", maximum=500):
            changed |= self._upsert_stage_session_locked(
                conn,
                item_id,
                str(stage["id"]),
                source_name,
                observed_at,
                require_mapping(raw_session, "Pi session"),
            )
        for raw_thread in require_list(body.get("threads"), "stage threads", maximum=500):
            _, thread_changed = self._upsert_thread_locked(
                conn,
                item_id,
                str(stage["id"]),
                source_name,
                require_mapping(raw_thread, "thread"),
                observed_at,
                default_channel_id=default_channel_id,
            )
            changed |= thread_changed
        return changed

    def _upsert_agent_profile_locked(
        self,
        conn: sqlite3.Connection,
        source_name: str,
        body: Mapping[str, Any],
        observed_at: str,
    ) -> str:
        reject_unknown(
            body,
            {
                "external_id",
                "display_name",
                "kind",
                "role_label",
                "avatar_key",
                "avatar_url",
                "status",
                "metadata",
                "role",
                "link_state",
                "removed",
            },
            "agent",
        )
        external = external_id(body.get("external_id"), "agent external_id")
        existing = conn.execute(
            "SELECT * FROM agent_profiles WHERE source = ? AND external_id = ?",
            (source_name, external),
        ).fetchone()
        now = self._now()
        agent_id = str(existing["id"]) if existing else safe_id("agent")
        display_name = text(body.get("display_name"), "agent display_name", maximum=200)
        if not display_name:
            display_name = str(existing["display_name"]) if existing else external[:200]
        created_at = str(existing["created_at"]) if existing else now
        agent_kind = (
            text(body.get("kind"), "agent kind", maximum=120)
            if "kind" in body
            else str(existing["kind"] or "") if existing else "agent"
        ) or "agent"
        role_label = (
            text(body.get("role_label"), "agent role_label", maximum=200)
            if "role_label" in body
            else str(existing["role_label"] or "") if existing else ""
        )
        avatar_key = (
            text(body.get("avatar_key"), "agent avatar_key", maximum=200)
            if "avatar_key" in body
            else str(existing["avatar_key"] or "") if existing else ""
        )
        avatar_url = (
            url(body.get("avatar_url"), "agent avatar_url")
            if "avatar_url" in body and body.get("avatar_url")
            else "" if "avatar_url" in body
            else str(existing["avatar_url"] or "") if existing else ""
        )
        agent_status = (
            choice(body.get("status"), "agent status", AGENT_STATUSES)
            if "status" in body
            else str(existing["status"]) if existing else "unknown"
        )
        existing_metadata = json_load(existing["metadata_json"], {}) if existing else {}
        agent_metadata = existing_metadata
        if "metadata" in body:
            agent_metadata = bounded_json(
                _merge_json_objects(
                    existing_metadata,
                    bounded_json(body.get("metadata"), "agent metadata"),
                ),
                "agent metadata",
            )
        conn.execute(
            """
            INSERT INTO agent_profiles(
                id, source, external_id, display_name, kind, role_label,
                avatar_key, avatar_url, status, metadata_json, last_seen_at,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, external_id) DO UPDATE SET
                display_name = excluded.display_name, kind = excluded.kind,
                role_label = excluded.role_label, avatar_key = excluded.avatar_key,
                avatar_url = excluded.avatar_url, status = excluded.status,
                metadata_json = excluded.metadata_json,
                last_seen_at = excluded.last_seen_at, updated_at = excluded.updated_at
            """,
            (
                agent_id,
                source_name,
                external,
                display_name,
                agent_kind,
                role_label,
                avatar_key,
                avatar_url,
                agent_status,
                json_dump(agent_metadata),
                observed_at,
                created_at,
                now,
            ),
        )
        return agent_id

    def _upsert_stage_agent_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        stage_id: str,
        source_name: str,
        observed_at: str,
        body: Mapping[str, Any],
    ) -> bool:
        agent_id = self._upsert_agent_profile_locked(conn, source_name, body, observed_at)
        now = self._now()
        existing = conn.execute(
            "SELECT * FROM stage_agent_links WHERE work_item_id = ? AND stage_id = ? AND agent_id = ?",
            (item_id, stage_id, agent_id),
        ).fetchone()
        attached_at = str(existing["attached_at"]) if existing else now
        removed = body.get("removed") is True
        link_role = (
            text(body.get("role"), "agent role", maximum=200)
            if "role" in body
            else str(existing["role"] or "") if existing else ""
        )
        link_state = (
            choice(body.get("link_state"), "agent link_state", AGENT_LINK_STATES)
            if "link_state" in body
            else str(existing["state"]) if existing else "active"
        )
        conn.execute(
            """
            INSERT INTO stage_agent_links(
                work_item_id, stage_id, agent_id, role, state, attached_at,
                detached_at, source_observed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(work_item_id, stage_id, agent_id) DO UPDATE SET
                role = excluded.role, state = excluded.state,
                detached_at = excluded.detached_at,
                source_observed_at = excluded.source_observed_at
            """,
            (
                item_id,
                stage_id,
                agent_id,
                link_role,
                link_state,
                attached_at,
                now if removed else None,
                observed_at,
            ),
        )
        return True

    def _upsert_stage_session_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        stage_id: str,
        source_name: str,
        observed_at: str,
        body: Mapping[str, Any],
    ) -> bool:
        reject_unknown(
            body,
            {
                "external_id",
                "agent_external_id",
                "title",
                "provider",
                "model",
                "status",
                "machine_id",
                "workspace_id",
                "pane_id",
                "native_session_id",
                "started_at",
                "last_seen_at",
                "ended_at",
                "metadata",
                "role",
                "removed",
            },
            "Pi session",
        )
        external = external_id(body.get("external_id"), "Pi session external_id")
        existing = conn.execute(
            "SELECT * FROM pi_sessions WHERE source = ? AND external_id = ?",
            (source_name, external),
        ).fetchone()
        if existing is not None and existing["work_item_id"] != item_id:
            raise ActiveWorkError(
                "Pi session is already attached to another work item",
                code="active_work_association_conflict",
                status=409,
            )
        agent_id = None
        if body.get("agent_external_id"):
            agent_external = external_id(body["agent_external_id"], "agent_external_id")
            agent = conn.execute(
                "SELECT id FROM agent_profiles WHERE source = ? AND external_id = ?",
                (source_name, agent_external),
            ).fetchone()
            if agent is None:
                agent_id = self._upsert_agent_profile_locked(
                    conn,
                    source_name,
                    {"external_id": agent_external, "display_name": agent_external},
                    observed_at,
                )
            else:
                agent_id = str(agent["id"])
        elif existing is not None:
            agent_id = existing["agent_id"]
        now = self._now()
        session_id = str(existing["id"]) if existing else safe_id("session")
        created_at = str(existing["created_at"]) if existing else now
        def session_text(field: str, column: str, maximum: int) -> str:
            if field in body:
                return text(body.get(field), f"Pi session {field}", maximum=maximum)
            return str(existing[column] or "") if existing else ""

        session_status = (
            choice(body.get("status"), "Pi session status", SESSION_STATUSES)
            if "status" in body
            else str(existing["status"]) if existing else "unknown"
        )
        existing_metadata = json_load(existing["metadata_json"], {}) if existing else {}
        session_metadata = existing_metadata
        if "metadata" in body:
            session_metadata = bounded_json(
                _merge_json_objects(
                    existing_metadata,
                    bounded_json(body.get("metadata"), "Pi session metadata"),
                ),
                "Pi session metadata",
            )
        ended_at = (
            timestamp(body.get("ended_at"), "Pi session ended_at")
            if "ended_at" in body
            else str(existing["ended_at"] or "") if existing else None
        ) or None
        conn.execute(
            """
            INSERT INTO pi_sessions(
                id, work_item_id, source, external_id, agent_id, title, provider,
                model, status, machine_id, workspace_id, pane_id, native_session_id,
                started_at, last_seen_at, ended_at, metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, external_id) DO UPDATE SET
                agent_id = excluded.agent_id, title = excluded.title,
                provider = excluded.provider, model = excluded.model,
                status = excluded.status, machine_id = excluded.machine_id,
                workspace_id = excluded.workspace_id, pane_id = excluded.pane_id,
                native_session_id = excluded.native_session_id,
                started_at = COALESCE(excluded.started_at, pi_sessions.started_at),
                last_seen_at = excluded.last_seen_at,
                ended_at = excluded.ended_at,
                metadata_json = excluded.metadata_json, updated_at = excluded.updated_at
            """,
            (
                session_id,
                item_id,
                source_name,
                external,
                agent_id,
                session_text("title", "title", 500),
                session_text("provider", "provider", 120),
                session_text("model", "model", 200),
                session_status,
                session_text("machine_id", "machine_id", 256),
                session_text("workspace_id", "workspace_id", 256),
                session_text("pane_id", "pane_id", 256),
                session_text("native_session_id", "native_session_id", 512),
                timestamp(body.get("started_at"), "Pi session started_at"),
                timestamp(body.get("last_seen_at"), "Pi session last_seen_at") or observed_at,
                ended_at,
                json_dump(session_metadata),
                created_at,
                now,
            ),
        )
        link = conn.execute(
            "SELECT * FROM stage_session_links WHERE work_item_id = ? AND stage_id = ? AND session_id = ?",
            (item_id, stage_id, session_id),
        ).fetchone()
        attached_at = str(link["attached_at"]) if link else now
        session_role = (
            text(body.get("role"), "Pi session role", maximum=200)
            if "role" in body
            else str(link["role"] or "") if link else ""
        )
        conn.execute(
            """
            INSERT INTO stage_session_links(
                work_item_id, stage_id, session_id, role, attached_at, detached_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(work_item_id, stage_id, session_id) DO UPDATE SET
                role = excluded.role, detached_at = excluded.detached_at
            """,
            (
                item_id,
                stage_id,
                session_id,
                session_role,
                attached_at,
                now if body.get("removed") is True else None,
            ),
        )
        return True

    def _upsert_thread_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        stage_id: Optional[str],
        source_name: str,
        body: Mapping[str, Any],
        observed_at: str,
        *,
        default_channel_id: Optional[str],
    ) -> tuple[str, bool]:
        reject_unknown(
            body,
            {
                "external_id",
                "channel_external_id",
                "title",
                "url",
                "snippet",
                "status",
                "last_activity_at",
                "metadata",
                "removed",
            },
            "thread",
        )
        external = external_id(body.get("external_id"), "thread external_id")
        existing = conn.execute(
            "SELECT * FROM buzz_threads WHERE source = ? AND external_id = ?",
            (source_name, external),
        ).fetchone()
        if existing is not None and existing["work_item_id"] != item_id:
            raise ActiveWorkError(
                "Buzz thread is already attached to another work item",
                code="active_work_association_conflict",
                status=409,
            )
        channel_id = default_channel_id
        if body.get("channel_external_id"):
            channel = conn.execute(
                "SELECT id, work_item_id FROM buzz_channels WHERE source = ? AND external_id = ?",
                (source_name, external_id(body["channel_external_id"], "channel_external_id")),
            ).fetchone()
            if channel is None or channel["work_item_id"] != item_id:
                raise ActiveWorkError("Thread channel is not attached to this work item")
            channel_id = str(channel["id"])
        now = self._now()
        thread_id = str(existing["id"]) if existing else safe_id("thread")
        created_at = str(existing["created_at"]) if existing else now
        if body.get("removed") is True:
            status = "archived"
        elif "status" in body:
            status = choice(body.get("status"), "thread status", THREAD_STATUSES)
        else:
            status = str(existing["status"]) if existing else "active"
        thread_title = (
            text(body.get("title"), "thread title", maximum=500)
            if "title" in body
            else str(existing["title"] or "") if existing else ""
        )
        thread_url = (
            link_url(body.get("url"), "thread URL")
            if "url" in body and body.get("url")
            else "" if "url" in body
            else str(existing["url"] or "") if existing else ""
        )
        thread_snippet = (
            text(body.get("snippet"), "thread snippet", maximum=4096)
            if "snippet" in body
            else str(existing["snippet"] or "") if existing else ""
        )
        thread_activity = (
            timestamp(body.get("last_activity_at"), "thread last_activity_at")
            if "last_activity_at" in body
            else str(existing["last_activity_at"] or "") if existing else observed_at
        ) or observed_at
        existing_metadata = json_load(existing["metadata_json"], {}) if existing else {}
        thread_metadata = existing_metadata
        if "metadata" in body:
            thread_metadata = bounded_json(
                _merge_json_objects(
                    existing_metadata,
                    bounded_json(body.get("metadata"), "thread metadata"),
                ),
                "thread metadata",
            )
        conn.execute(
            """
            INSERT INTO buzz_threads(
                id, work_item_id, channel_id, stage_id, source, external_id,
                title, url, snippet, status, last_activity_at, metadata_json,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, external_id) DO UPDATE SET
                channel_id = COALESCE(excluded.channel_id, buzz_threads.channel_id),
                stage_id = COALESCE(excluded.stage_id, buzz_threads.stage_id),
                title = excluded.title,
                url = excluded.url, snippet = excluded.snippet,
                status = excluded.status, last_activity_at = excluded.last_activity_at,
                metadata_json = excluded.metadata_json, updated_at = excluded.updated_at
            """,
            (
                thread_id,
                item_id,
                channel_id,
                stage_id,
                source_name,
                external,
                thread_title,
                thread_url,
                thread_snippet,
                status,
                thread_activity,
                json_dump(thread_metadata),
                created_at,
                now,
            ),
        )
        return thread_id, True

    def _ingest_activity_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        template_id: str,
        source_name: str,
        observed_at: str,
        body: Mapping[str, Any],
    ) -> bool:
        reject_unknown(
            body,
            {"external_id", "stage_key", "kind", "actor_kind", "actor_id", "message", "details", "occurred_at"},
            "activity event",
        )
        event_external = external_id(body.get("external_id"), "activity external_id")
        if conn.execute(
            "SELECT 1 FROM work_activity_events WHERE source = ? AND source_event_id = ?",
            (source_name, event_external),
        ).fetchone():
            return False
        stage_id = None
        if body.get("stage_key"):
            stage_id = str(
                self._require_stage_locked(
                    conn,
                    template_id,
                    choice(body["stage_key"], "activity stage_key", STAGE_KEYS),
                )["id"]
            )
        self._activity_locked(
            conn,
            item_id,
            stage_id=stage_id,
            kind=text(body.get("kind"), "activity kind", maximum=120) or "buzz_activity",
            actor_kind=text(body.get("actor_kind"), "activity actor_kind", maximum=120) or "agent",
            actor_id=text(body.get("actor_id"), "activity actor_id", maximum=512),
            message=text(body.get("message"), "activity message", maximum=32768, required=True),
            details=bounded_json(body.get("details"), "activity details"),
            source_name=source_name,
            source_event_id=event_external,
            occurred_at=timestamp(body.get("occurred_at"), "activity occurred_at") or observed_at,
        )
        return True

    def _resolve_selector_locked(
        self,
        conn: sqlite3.Connection,
        selector: Mapping[str, Any],
    ) -> Optional[str]:
        resolved: list[tuple[str, Optional[str]]] = []
        if selector.get("work_item_id"):
            item_id = internal_id(selector["work_item_id"], "work_item_id")
            resolved.append((
                "work_item",
                item_id
                if conn.execute("SELECT 1 FROM work_items WHERE id = ?", (item_id,)).fetchone()
                else None,
            ))
        if selector.get("jira_key"):
            key = jira_key(selector["jira_key"])
            if selector.get("jira_site"):
                site = text(selector["jira_site"], "jira_site", maximum=255, required=True).lower()
                row = conn.execute(
                    "SELECT work_item_id FROM jira_links WHERE site = ? AND issue_key = ?",
                    (site, key),
                ).fetchone()
                resolved.append(("jira", str(row["work_item_id"]) if row else None))
            else:
                rows = conn.execute(
                    "SELECT work_item_id FROM jira_links WHERE issue_key = ?",
                    (key,),
                ).fetchall()
                if len(rows) > 1:
                    raise ActiveWorkError(
                        "Jira selector is ambiguous without jira_site",
                        code="active_work_selector_ambiguous",
                        status=409,
                    )
                resolved.append(("jira", str(rows[0]["work_item_id"]) if rows else None))
        if selector.get("buzz_channel_id"):
            external = external_id(selector["buzz_channel_id"], "buzz_channel_id")
            rows = conn.execute(
                "SELECT work_item_id FROM buzz_channels WHERE external_id = ?",
                (external,),
            ).fetchall()
            if len(rows) > 1:
                raise ActiveWorkError(
                    "Buzz channel selector is ambiguous",
                    code="active_work_selector_ambiguous",
                    status=409,
                )
            resolved.append(("buzz_channel", str(rows[0]["work_item_id"]) if rows else None))
        if not resolved:
            raise ActiveWorkError("selector must contain a stable work identifier")
        identities = {item_id for _, item_id in resolved if item_id is not None}
        missing_stable = [kind for kind, item_id in resolved if item_id is None and kind != "buzz_channel"]
        if missing_stable:
            if identities:
                raise ActiveWorkError(
                    "selector identifiers do not resolve to the same work item",
                    code="active_work_selector_conflict",
                    status=409,
                )
            return None
        if not identities:
            return None
        if len(identities) != 1:
            raise ActiveWorkError(
                "selector identifiers resolve to different work items",
                code="active_work_selector_conflict",
                status=409,
            )
        return next(iter(identities))

    def _activity_locked(
        self,
        conn: sqlite3.Connection,
        item_id: str,
        *,
        kind: str,
        message: str,
        stage_id: Optional[str] = None,
        actor_kind: str = "system",
        actor_id: str = "",
        details: Optional[dict] = None,
        source_name: str = "herdr",
        source_event_id: Optional[str] = None,
        occurred_at: Optional[str] = None,
    ) -> None:
        now = self._now()
        conn.execute(
            """
            INSERT INTO work_activity_events(
                id, work_item_id, stage_id, kind, actor_kind, actor_id,
                message, details_json, source, source_event_id, occurred_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                safe_id("activity"),
                item_id,
                stage_id,
                kind,
                actor_kind,
                actor_id,
                message,
                json_dump(details or {}),
                source_name,
                source_event_id,
                occurred_at or now,
                now,
            ),
        )

    def _audit_locked(
        self,
        conn: sqlite3.Connection,
        actor: str,
        action: str,
        entity_type: str,
        entity_id: str,
        patch: Mapping[str, Any],
        *,
        request_id: str = "",
    ) -> None:
        conn.execute(
            """
            INSERT INTO active_work_audit_events(
                id, actor, action, entity_type, entity_id, patch_json,
                request_id, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                safe_id("audit"),
                text(actor, "actor", maximum=200) or "unknown",
                action,
                entity_type,
                entity_id,
                json_dump(bounded_json(dict(patch), "audit patch", maximum_bytes=256 * 1024)),
                text(request_id, "request_id", maximum=512),
                self._now(),
            ),
        )

    def _pipeline_projection_locked(self, template_id: str) -> dict:
        template = self._database.execute(
            "SELECT * FROM pipeline_templates WHERE id = ?",
            (template_id,),
        ).fetchone()
        if template is None:
            raise ActiveWorkError("Pipeline template not found", status=500)
        stages = self._database.execute(
            "SELECT * FROM pipeline_stage_definitions WHERE template_id = ? ORDER BY sequence",
            (template_id,),
        ).fetchall()
        return {
            "id": template["id"],
            "slug": template["slug"],
            "version": int(template["version"]),
            "title": template["title"],
            "stages": [self._stage_definition_from_row(row) for row in stages],
        }

    def _item_projection_locked(self, item_id: str) -> Optional[dict]:
        row = self._database.execute("SELECT * FROM work_items WHERE id = ?", (item_id,)).fetchone()
        if row is None:
            return None
        template_id = str(row["template_id"])
        stage_rows = self._database.execute(
            """
            SELECT definition.*, state.state, state.attention, state.checkpoint_state,
                   state.summary, state.content_json, state.source_observed_at,
                   state.started_at, state.completed_at, state.updated_at
            FROM pipeline_stage_definitions definition
            JOIN work_stage_states state ON state.stage_id = definition.id
            WHERE state.work_item_id = ? AND definition.template_id = ?
            ORDER BY definition.sequence
            """,
            (item_id, template_id),
        ).fetchall()
        stages = []
        for stage in stage_rows:
            stage_id = str(stage["id"])
            projected = self._stage_definition_from_row(stage)
            projected.update(
                {
                    "state": stage["state"],
                    "attention": stage["attention"],
                    "checkpoint_state": stage["checkpoint_state"],
                    "summary": stage["summary"],
                    "content": json_load(stage["content_json"], {}),
                    "source_observed_at": stage["source_observed_at"],
                    "started_at": stage["started_at"],
                    "completed_at": stage["completed_at"],
                    "updated_at": stage["updated_at"],
                    "agents": self._stage_agents_locked(item_id, stage_id),
                    "pi_sessions": self._stage_sessions_locked(item_id, stage_id),
                    "buzz_threads": self._threads_locked(item_id, stage_id),
                }
            )
            stages.append(projected)
        jira_links = [
            self._jira_from_row(link)
            for link in self._database.execute(
                "SELECT * FROM jira_links WHERE work_item_id = ? ORDER BY created_at",
                (item_id,),
            ).fetchall()
        ]
        channels = [
            self._channel_from_row(channel)
            for channel in self._database.execute(
                "SELECT * FROM buzz_channels WHERE work_item_id = ? ORDER BY created_at",
                (item_id,),
            ).fetchall()
        ]
        setup_state = self._setup_state_locked(item_id)
        agents = []
        for agent_row in self._database.execute(
                """
                SELECT DISTINCT profile.* FROM agent_profiles profile
                JOIN stage_agent_links link ON link.agent_id = profile.id
                WHERE link.work_item_id = ? AND link.detached_at IS NULL
                ORDER BY profile.display_name COLLATE NOCASE
                """,
                (item_id,),
            ).fetchall():
            agent = self._agent_from_row(agent_row)
            agent["stage_links"] = [
                {
                    "stage_key": link["stage_key"],
                    "link_role": link["link_role"],
                    "link_state": link["link_state"],
                    "attached_at": link["attached_at"],
                    "detached_at": link["detached_at"],
                }
                for link in self._database.execute(
                    """
                    SELECT definition.stage_key, association.role AS link_role,
                           association.state AS link_state, association.attached_at,
                           association.detached_at
                    FROM stage_agent_links association
                    JOIN pipeline_stage_definitions definition ON definition.id = association.stage_id
                    WHERE association.work_item_id = ? AND association.agent_id = ?
                    ORDER BY definition.sequence
                    """,
                    (item_id, agent["id"]),
                ).fetchall()
            ]
            agents.append(agent)
        sessions = []
        for session_row in self._database.execute(
                "SELECT * FROM pi_sessions WHERE work_item_id = ? ORDER BY COALESCE(last_seen_at, created_at) DESC",
                (item_id,),
            ).fetchall():
            session = self._session_from_row(session_row)
            session["stage_links"] = [
                {
                    "stage_key": link["stage_key"],
                    "link_role": link["link_role"],
                    "attached_at": link["attached_at"],
                    "detached_at": link["detached_at"],
                }
                for link in self._database.execute(
                    """
                    SELECT definition.stage_key, association.role AS link_role,
                           association.attached_at, association.detached_at
                    FROM stage_session_links association
                    JOIN pipeline_stage_definitions definition ON definition.id = association.stage_id
                    WHERE association.work_item_id = ? AND association.session_id = ?
                    ORDER BY definition.sequence
                    """,
                    (item_id, session["id"]),
                ).fetchall()
            ]
            sessions.append(session)
        activity = [
            self._activity_from_row(event)
            for event in self._database.execute(
                "SELECT * FROM work_activity_events WHERE work_item_id = ? ORDER BY occurred_at DESC, created_at DESC LIMIT 500",
                (item_id,),
            ).fetchall()
        ]
        current_stage_key = None
        current_stage = None
        for stage in stages:
            if stage["id"] == row["current_stage_id"]:
                current_stage_key = stage["stage_key"]
                current_stage = stage
                break
        completed = sum(stage["state"] in {"complete", "skipped"} for stage in stages)
        needs_attention = bool(
            row["lifecycle"] == "blocked"
            or (
                current_stage
                and (
                    current_stage["state"] == "blocked"
                    or current_stage["attention"] == "human"
                    or current_stage["checkpoint_state"] in {"pending", "changes_requested"}
                )
            )
        )
        attention_reason = None
        if row["lifecycle"] == "blocked":
            attention_reason = "Work item is blocked"
        elif current_stage and current_stage["attention"] == "human":
            attention_reason = f"Human attention at {current_stage['title']}"
        elif current_stage and current_stage["attention"] == "agent":
            attention_reason = f"Agent attention at {current_stage['title']}"
        elif current_stage and current_stage["checkpoint_state"] == "changes_requested":
            attention_reason = f"Changes requested at {current_stage['title']}"
        elif current_stage and current_stage["checkpoint_state"] == "pending":
            attention_reason = f"Checkpoint pending at {current_stage['title']}"
        return {
            "id": row["id"],
            "kind": row["kind"],
            "title": row["title"],
            "summary": row["summary"],
            "lifecycle": row["lifecycle"],
            "current_stage_key": current_stage_key,
            "next_action": row["next_action"],
            "revision": int(row["revision"]),
            "metadata": json_load(row["metadata_json"], {}),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "archived_at": row["archived_at"],
            "needs_attention": needs_attention,
            "attention_reason": attention_reason,
            "setup_state": setup_state,
            "progress": {
                "completed": completed,
                "total": len(stages),
                "current_sequence": current_stage["sequence"] if current_stage else None,
            },
            "pipeline": {
                **self._pipeline_projection_locked(template_id),
                "stages": stages,
            },
            "stages": stages,
            "jira_links": jira_links,
            "agents": agents,
            "pi_sessions": sessions,
            "buzz_channels": channels,
            "unscoped_threads": self._threads_locked(item_id, None),
            "activity": activity,
        }

    def _candidate_projection_locked(self, candidate: Mapping[str, Any]) -> dict:
        result = copy.deepcopy(dict(candidate))
        try:
            key = jira_key(candidate.get("key") or candidate.get("issue_key"))
            site = site_from_ticket(candidate)
        except ActiveWorkError:
            result.update({"setup_state": "available", "work_item_id": None})
            return result
        link = self._database.execute(
            "SELECT work_item_id FROM jira_links WHERE site = ? AND issue_key = ?",
            (site, key),
        ).fetchone()
        if link is None and site == "default":
            matches = self._database.execute(
                "SELECT work_item_id FROM jira_links WHERE issue_key = ?",
                (key,),
            ).fetchall()
            link = matches[0] if len(matches) == 1 else None
        result.update(
            {
                "setup_state": self._setup_state_locked(str(link["work_item_id"])) if link else "available",
                "work_item_id": str(link["work_item_id"]) if link else None,
            }
        )
        return result

    def _setup_state_locked(self, item_id: str) -> str:
        has_active_channel = self._database.execute(
            "SELECT 1 FROM buzz_channels WHERE work_item_id = ? AND status = 'active' LIMIT 1",
            (item_id,),
        ).fetchone() is not None
        if not has_active_channel:
            return "board_created"
        has_driver = self._database.execute(
            """
            SELECT 1 FROM stage_agent_links
            WHERE work_item_id = ? AND lower(role) = 'driver' AND detached_at IS NULL
            LIMIT 1
            """,
            (item_id,),
        ).fetchone() is not None
        return "ready" if has_driver else "channel_linked"

    @staticmethod
    def _stage_definition_from_row(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "stage_key": row["stage_key"],
            "sequence": int(row["sequence"]),
            "phase_key": row["phase_key"],
            "title": row["title"],
            "skill_name": row["skill_name"],
            "checkpoint_kind": row["checkpoint_kind"],
        }

    def _stage_agents_locked(self, item_id: str, stage_id: str) -> list[dict]:
        rows = self._database.execute(
            """
            SELECT profile.*, definition.stage_key, link.role AS link_role, link.state AS link_state,
                   link.attached_at, link.detached_at, link.source_observed_at AS link_source_observed_at
            FROM stage_agent_links link
            JOIN agent_profiles profile ON profile.id = link.agent_id
            JOIN pipeline_stage_definitions definition ON definition.id = link.stage_id
            WHERE link.work_item_id = ? AND link.stage_id = ?
            ORDER BY link.detached_at IS NOT NULL, link.attached_at, profile.display_name COLLATE NOCASE
            """,
            (item_id, stage_id),
        ).fetchall()
        result = []
        for row in rows:
            agent = self._agent_from_row(row)
            agent.update(
                {
                    "link_role": row["link_role"],
                    "link_state": row["link_state"],
                    "stage_key": row["stage_key"],
                    "attached_at": row["attached_at"],
                    "detached_at": row["detached_at"],
                    "link_source_observed_at": row["link_source_observed_at"],
                }
            )
            result.append(agent)
        return result

    def _stage_sessions_locked(self, item_id: str, stage_id: str) -> list[dict]:
        rows = self._database.execute(
            """
            SELECT session.*, definition.stage_key, link.role AS link_role, link.attached_at, link.detached_at
            FROM stage_session_links link
            JOIN pi_sessions session ON session.id = link.session_id
            JOIN pipeline_stage_definitions definition ON definition.id = link.stage_id
            WHERE link.work_item_id = ? AND link.stage_id = ?
            ORDER BY link.detached_at IS NOT NULL, COALESCE(session.last_seen_at, link.attached_at) DESC
            """,
            (item_id, stage_id),
        ).fetchall()
        result = []
        for row in rows:
            session = self._session_from_row(row)
            session.update(
                {
                    "link_role": row["link_role"],
                    "stage_key": row["stage_key"],
                    "attached_at": row["attached_at"],
                    "detached_at": row["detached_at"],
                }
            )
            result.append(session)
        return result

    def _threads_locked(self, item_id: str, stage_id: Optional[str]) -> list[dict]:
        if stage_id is None:
            rows = self._database.execute(
                "SELECT * FROM buzz_threads WHERE work_item_id = ? AND stage_id IS NULL ORDER BY COALESCE(last_activity_at, created_at) DESC",
                (item_id,),
            ).fetchall()
        else:
            rows = self._database.execute(
                "SELECT * FROM buzz_threads WHERE work_item_id = ? AND stage_id = ? ORDER BY COALESCE(last_activity_at, created_at) DESC",
                (item_id, stage_id),
            ).fetchall()
        return [self._thread_from_row(row) for row in rows]

    @staticmethod
    def _jira_from_row(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "site": row["site"],
            "issue_key": row["issue_key"],
            "title": row["title"],
            "status": row["status"],
            "priority": row["priority"],
            "issue_type": row["issue_type"],
            "url": row["url"],
            "metadata": json_load(row["metadata_json"], {}),
            "observed_at": row["observed_at"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    @staticmethod
    def _agent_from_row(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "source": row["source"],
            "external_id": row["external_id"],
            "display_name": row["display_name"],
            "kind": row["kind"],
            "role_label": row["role_label"],
            "avatar_key": row["avatar_key"],
            "avatar_url": row["avatar_url"],
            "status": row["status"],
            "metadata": json_load(row["metadata_json"], {}),
            "last_seen_at": row["last_seen_at"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    @staticmethod
    def _session_from_row(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "source": row["source"],
            "external_id": row["external_id"],
            "agent_id": row["agent_id"],
            "title": row["title"],
            "provider": row["provider"],
            "model": row["model"],
            "status": row["status"],
            "machine_id": row["machine_id"],
            "workspace_id": row["workspace_id"],
            "pane_id": row["pane_id"],
            "native_session_id": row["native_session_id"],
            "started_at": row["started_at"],
            "last_seen_at": row["last_seen_at"],
            "ended_at": row["ended_at"],
            "metadata": json_load(row["metadata_json"], {}),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    @staticmethod
    def _channel_from_row(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "source": row["source"],
            "external_id": row["external_id"],
            "name": row["name"],
            "url": row["url"],
            "status": row["status"],
            "last_activity_at": row["last_activity_at"],
            "metadata": json_load(row["metadata_json"], {}),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    @staticmethod
    def _thread_from_row(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "channel_id": row["channel_id"],
            "stage_id": row["stage_id"],
            "source": row["source"],
            "external_id": row["external_id"],
            "title": row["title"],
            "url": row["url"],
            "snippet": row["snippet"],
            "status": row["status"],
            "last_activity_at": row["last_activity_at"],
            "metadata": json_load(row["metadata_json"], {}),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    @staticmethod
    def _activity_from_row(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "stage_id": row["stage_id"],
            "kind": row["kind"],
            "actor_kind": row["actor_kind"],
            "actor_id": row["actor_id"],
            "message": row["message"],
            "details": json_load(row["details_json"], {}),
            "source": row["source"],
            "source_event_id": row["source_event_id"],
            "occurred_at": row["occurred_at"],
            "created_at": row["created_at"],
        }
