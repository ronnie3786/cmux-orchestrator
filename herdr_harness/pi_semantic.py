"""Semantic side channel for Pi sessions that continue to own their TUI.

The companion Pi extension owns one pane-specific Unix socket.  This module
connects to those sockets, durably journals forward-compatible Pi event
envelopes, and exposes ordered replay primitives to the HTTP layer.  Nothing in
this module reads from or writes to the terminal PTY.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import socket
import sqlite3
import stat
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Mapping, Optional

from .alerts import utc_now


PI_SEMANTIC_PROTOCOL = {"name": "herdr.pi.semantic", "version": 1}
PI_SEMANTIC_MAX_LINE_BYTES = 512 * 1024
PI_SEMANTIC_MAX_COMMAND_BYTES = 256 * 1024
PI_SEMANTIC_SOCKET_PATH_BYTES = 100


class PiSemanticError(RuntimeError):
    """A safe, user-facing Pi semantic bridge error."""

    def __init__(self, message: str, *, code: str, status: int) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


def _bounded_int(
    environ: Mapping[str, str],
    name: str,
    default: int,
    *,
    minimum: int,
    maximum: int,
) -> int:
    try:
        value = int(environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    return value if minimum <= value <= maximum else default


def pi_semantic_socket_path(herdr_socket_path: str, pane_id: str) -> str:
    """Return the extension socket path without risking Unix path truncation.

    A full SHA-256 of the pane ID prevents collisions between multiple Pi panes
    in one Herdr session. The socket always lives in a dedicated private
    directory. A short digest of the complete Herdr path keeps named Herdr
    sessions isolated without risking Unix socket path truncation.
    """

    source = os.path.abspath(os.path.expanduser(str(herdr_socket_path or "")))
    pane = str(pane_id or "")
    if not source or not pane or "\x00" in source or "\x00" in pane:
        raise ValueError("Herdr socket path and pane ID are required")
    pane_digest = hashlib.sha256(pane.encode("utf-8")).hexdigest()
    source_digest = hashlib.sha256(source.encode("utf-8")).hexdigest()[:8]
    uid = os.getuid() if hasattr(os, "getuid") else 0
    private_dir = f"/tmp/herdr-pi-{uid}"
    path = os.path.join(private_dir, f"{source_digest}-{pane_digest}.sock")
    if len(os.fsencode(path)) > PI_SEMANTIC_SOCKET_PATH_BYTES:
        private_dir = f"/tmp/hp-{uid}"
        path = os.path.join(private_dir, f"{source_digest}-{pane_digest}.sock")
    if len(os.fsencode(path)) > PI_SEMANTIC_SOCKET_PATH_BYTES:
        raise ValueError("Pi semantic socket path exceeds the platform limit")
    return path


def ensure_private_socket_directory(socket_path: str) -> None:
    """Validate or create the extension socket parent as a private directory."""

    parent = os.path.dirname(socket_path)
    uid = os.getuid() if hasattr(os, "getuid") else 0
    allowed = {f"/tmp/herdr-pi-{uid}", f"/tmp/hp-{uid}"}
    if parent not in allowed:
        raise PiSemanticError(
            "Pi semantic socket directory is not bridge-owned",
            code="pi_bridge_unsafe",
            status=503,
        )
    try:
        metadata = os.lstat(parent)
    except FileNotFoundError:
        try:
            os.mkdir(parent, mode=0o700)
        except FileExistsError:
            pass
        metadata = os.lstat(parent)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise PiSemanticError("Pi semantic socket directory is unsafe", code="pi_bridge_unsafe", status=503)
    if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
        raise PiSemanticError("Pi semantic socket directory belongs to another user", code="pi_bridge_unsafe", status=503)
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        try:
            os.chmod(parent, 0o700)
        except OSError as exc:
            raise PiSemanticError(
                "Pi semantic socket directory permissions are too broad",
                code="pi_bridge_unsafe",
                status=503,
            ) from exc
        metadata = os.lstat(parent)
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise PiSemanticError(
                "Pi semantic socket directory permissions are too broad",
                code="pi_bridge_unsafe",
                status=503,
            )


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _protocol_valid(record: dict) -> bool:
    protocol = record.get("protocol")
    return (
        isinstance(protocol, dict)
        and protocol.get("name") == PI_SEMANTIC_PROTOCOL["name"]
        and protocol.get("version") == PI_SEMANTIC_PROTOCOL["version"]
    )


def _record_pane_id(record: dict) -> str:
    return str(record.get("pane_id") or record.get("paneId") or "")


def _record_session_id(record: dict) -> Optional[str]:
    value = record.get("session_id") or record.get("sessionId")
    if value:
        return str(value)
    session = record.get("session")
    if isinstance(session, dict):
        value = session.get("id") or session.get("session_id") or session.get("sessionId")
        if value:
            return str(value)
    return None


class PiSemanticJournal:
    """Bounded SQLite journal with stable per-pane cursors across restarts."""

    def __init__(
        self,
        path: str,
        *,
        maximum_events_per_pane: int = 4096,
        maximum_bytes_per_pane: int = 32 * 1024 * 1024,
    ) -> None:
        self.path = path
        self.maximum_events_per_pane = max(64, int(maximum_events_per_pane))
        self.maximum_bytes_per_pane = max(1024 * 1024, int(maximum_bytes_per_pane))
        self._lock = threading.RLock()
        self._condition = threading.Condition(self._lock)
        if path != ":memory:":
            database_path = Path(os.path.abspath(os.path.expanduser(path)))
            parent = database_path.parent
            parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            parent_metadata = os.lstat(parent)
            if stat.S_ISLNK(parent_metadata.st_mode) or not stat.S_ISDIR(parent_metadata.st_mode):
                raise PiSemanticError("Pi journal directory is unsafe", code="pi_store_unsafe", status=500)
            if hasattr(os, "getuid") and parent_metadata.st_uid != os.getuid():
                raise PiSemanticError("Pi journal directory belongs to another user", code="pi_store_unsafe", status=500)
            try:
                database_metadata = os.lstat(database_path)
            except FileNotFoundError:
                pass
            else:
                if stat.S_ISLNK(database_metadata.st_mode) or not stat.S_ISREG(database_metadata.st_mode):
                    raise PiSemanticError("Pi journal path is unsafe", code="pi_store_unsafe", status=500)
                if hasattr(os, "getuid") and database_metadata.st_uid != os.getuid():
                    raise PiSemanticError("Pi journal belongs to another user", code="pi_store_unsafe", status=500)
            path = str(database_path)
        self._database = sqlite3.connect(path, check_same_thread=False, timeout=5.0)
        self._database.row_factory = sqlite3.Row
        if path != ":memory:":
            try:
                os.chmod(path, 0o600)
            except OSError as exc:
                self._database.close()
                raise PiSemanticError(
                    "Pi journal permissions could not be secured",
                    code="pi_store_unsafe",
                    status=500,
                ) from exc
        with self._database:
            self._database.execute("PRAGMA journal_mode=WAL")
            self._database.execute("PRAGMA synchronous=NORMAL")
            self._database.execute("PRAGMA foreign_keys=ON")
            self._database.execute(
                """
                CREATE TABLE IF NOT EXISTS pi_semantic_events (
                    pane_id TEXT NOT NULL,
                    cursor INTEGER NOT NULL,
                    session_id TEXT,
                    instance_id TEXT,
                    source_sequence INTEGER,
                    event_type TEXT NOT NULL,
                    envelope_json TEXT NOT NULL,
                    payload_bytes INTEGER NOT NULL,
                    generated_at TEXT NOT NULL,
                    PRIMARY KEY (pane_id, cursor)
                )
                """
            )
            self._database.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS pi_semantic_source_event
                ON pi_semantic_events (pane_id, instance_id, source_sequence)
                WHERE instance_id IS NOT NULL AND source_sequence IS NOT NULL
                """
            )
            self._database.execute(
                """
                CREATE TABLE IF NOT EXISTS pi_semantic_state (
                    pane_id TEXT PRIMARY KEY,
                    instance_id TEXT,
                    source_sequence INTEGER NOT NULL DEFAULT 0,
                    session_id TEXT,
                    snapshot_json TEXT,
                    snapshot_cursor INTEGER NOT NULL DEFAULT 0,
                    connected INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                )
                """
            )
        if path != ":memory:":
            for companion in (path, f"{path}-wal", f"{path}-shm"):
                try:
                    os.chmod(companion, 0o600)
                except FileNotFoundError:
                    continue
                metadata = os.lstat(companion)
                if stat.S_ISLNK(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) & 0o077:
                    self._database.close()
                    raise PiSemanticError(
                        "Pi journal permissions are unsafe",
                        code="pi_store_unsafe",
                        status=500,
                    )

    def close(self) -> None:
        with self._condition:
            self._database.close()

    def _ensure_state(self, pane_id: str) -> None:
        self._database.execute(
            """
            INSERT OR IGNORE INTO pi_semantic_state
            (pane_id, updated_at) VALUES (?, ?)
            """,
            (pane_id, utc_now()),
        )

    @staticmethod
    def _storage_pane_id(pane_id: str, namespace: str) -> str:
        """Scope a pane to one normalized Herdr socket identity.

        The composite remains in the existing pane_id columns, so databases
        upgrade without a destructive table rewrite. Legacy unscoped rows are
        deliberately invisible to scoped managers instead of risking history
        disclosure between named Herdr sessions.
        """

        if not namespace:
            return pane_id
        return f"{namespace}\x1f{pane_id}"

    def mark_connected(self, pane_id: str, connected: bool, *, namespace: str = "") -> Optional[dict]:
        storage_pane_id = self._storage_pane_id(pane_id, namespace)
        with self._condition, self._database:
            self._ensure_state(storage_pane_id)
            previous = self._database.execute(
                "SELECT connected, session_id FROM pi_semantic_state WHERE pane_id = ?",
                (storage_pane_id,),
            ).fetchone()
            previous_connected = bool(previous["connected"]) if previous is not None else False
            if previous_connected == bool(connected):
                return None
            self._database.execute(
                "UPDATE pi_semantic_state SET connected = ?, updated_at = ? WHERE pane_id = ?",
                (1 if connected else 0, utc_now(), storage_pane_id),
            )
            event = self._append_event_locked(
                storage_pane_id,
                {"type": "bridge.connection", "connected": bool(connected)},
                envelope_pane_id=pane_id,
                session_id=str(previous["session_id"]) if previous and previous["session_id"] else None,
                instance_id=None,
                source_sequence=None,
            )
            self._trim_locked(storage_pane_id)
            self._condition.notify_all()
            return event

    def source_position(self, pane_id: str, *, namespace: str = "") -> tuple[Optional[str], int]:
        storage_pane_id = self._storage_pane_id(pane_id, namespace)
        with self._lock:
            row = self._database.execute(
                "SELECT instance_id, source_sequence FROM pi_semantic_state WHERE pane_id = ?",
                (storage_pane_id,),
            ).fetchone()
            if row is None:
                return None, 0
            return row["instance_id"], int(row["source_sequence"] or 0)

    def ingest(self, pane_id: str, record: dict, *, namespace: str = "") -> list[dict]:
        """Validate and retain one extension record, returning new HTTP events."""

        if not isinstance(record, dict) or not _protocol_valid(record):
            raise PiSemanticError("Pi bridge sent an incompatible protocol record", code="pi_protocol_error", status=502)
        record_pane = _record_pane_id(record)
        if record_pane != pane_id:
            raise PiSemanticError("Pi bridge record targeted a different pane", code="pi_protocol_error", status=502)
        encoded = _json_bytes(record)
        if len(encoded) > PI_SEMANTIC_MAX_LINE_BYTES:
            raise PiSemanticError("Pi bridge record exceeded the size limit", code="pi_payload_too_large", status=502)

        kind = str(record.get("kind") or record.get("type") or "")
        instance_id = str(record.get("instance_id") or record.get("instanceId") or "") or None
        source_sequence_value = record.get("sequence")
        source_sequence = source_sequence_value if isinstance(source_sequence_value, int) else None
        session_id = _record_session_id(record)
        emitted: list[dict] = []
        storage_pane_id = self._storage_pane_id(pane_id, namespace)

        with self._condition, self._database:
            self._ensure_state(storage_pane_id)
            previous = self._database.execute(
                "SELECT instance_id, source_sequence, session_id FROM pi_semantic_state WHERE pane_id = ?",
                (storage_pane_id,),
            ).fetchone()
            previous_instance = str(previous["instance_id"]) if previous and previous["instance_id"] else None
            previous_session = str(previous["session_id"]) if previous and previous["session_id"] else None

            if instance_id and previous_instance and instance_id != previous_instance:
                self._database.execute(
                    """
                    UPDATE pi_semantic_state
                    SET instance_id = ?, source_sequence = 0, updated_at = ?
                    WHERE pane_id = ?
                    """,
                    (instance_id, utc_now(), storage_pane_id),
                )

            if kind in {"hello", "bridge.hello"}:
                resume_sequence = (
                    int(previous["source_sequence"] or 0)
                    if previous_instance == instance_id
                    else 0
                )
                self._database.execute(
                    """
                    UPDATE pi_semantic_state
                    SET instance_id = ?, source_sequence = ?, session_id = COALESCE(?, session_id),
                        connected = 1, updated_at = ?
                    WHERE pane_id = ?
                    """,
                    (instance_id, resume_sequence, session_id, utc_now(), storage_pane_id),
                )
                self._condition.notify_all()
                return emitted

            if kind in {"snapshot", "session.snapshot"}:
                payload = record.get("snapshot") or record.get("payload")
                if not isinstance(payload, dict):
                    raise PiSemanticError("Pi snapshot was not an object", code="pi_protocol_error", status=502)
                snapshot_session = _record_session_id(payload) or session_id
                if previous_session and snapshot_session and previous_session != snapshot_session:
                    reset = {
                        "type": "stream.reset",
                        "reason": "session_changed",
                        "previousSessionId": previous_session,
                        "sessionId": snapshot_session,
                    }
                    appended = self._append_event_locked(
                        storage_pane_id,
                        reset,
                        envelope_pane_id=pane_id,
                        session_id=snapshot_session,
                        instance_id=None,
                        source_sequence=None,
                    )
                    if appended is not None:
                        emitted.append(appended)
                snapshot_json = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
                if len(snapshot_json.encode("utf-8")) > 8 * 1024 * 1024:
                    raise PiSemanticError("Pi snapshot exceeded the size limit", code="pi_payload_too_large", status=502)
                latest = self._latest_cursor_locked(storage_pane_id)
                self._database.execute(
                    """
                    UPDATE pi_semantic_state
                    SET instance_id = COALESCE(?, instance_id),
                        source_sequence = MAX(source_sequence, ?),
                        session_id = COALESCE(?, session_id), snapshot_json = ?,
                        snapshot_cursor = ?, connected = 1, updated_at = ?
                    WHERE pane_id = ?
                    """,
                    (
                        instance_id,
                        source_sequence or 0,
                        snapshot_session,
                        snapshot_json,
                        latest,
                        utc_now(),
                        storage_pane_id,
                    ),
                )
                self._trim_locked(storage_pane_id)
                self._condition.notify_all()
                return emitted

            if kind in {"reset", "stream.reset"}:
                raw_event = record.get("event")
                if not isinstance(raw_event, dict):
                    raw_event = {"type": "stream.reset", "reason": str(record.get("reason") or "replay_gap")}
                recovery_snapshot = record.get("snapshot")
                if recovery_snapshot is not None and not isinstance(recovery_snapshot, dict):
                    raise PiSemanticError("Pi reset snapshot was malformed", code="pi_protocol_error", status=502)
            elif kind in {"event", "pi.event"}:
                raw_event = record.get("event")
                recovery_snapshot = None
                if not isinstance(raw_event, dict) or not isinstance(raw_event.get("type"), str):
                    raise PiSemanticError("Pi event was malformed", code="pi_protocol_error", status=502)
            else:
                # Responses are consumed by one-shot command connections, not by
                # the durable subscription. Unknown future record kinds are
                # ignored rather than corrupting the journal.
                return emitted

            appended = self._append_event_locked(
                storage_pane_id,
                raw_event,
                envelope_pane_id=pane_id,
                session_id=session_id or previous_session,
                instance_id=instance_id,
                source_sequence=source_sequence,
            )
            if appended is not None:
                emitted.append(appended)
            self._database.execute(
                """
                UPDATE pi_semantic_state
                SET instance_id = COALESCE(?, instance_id),
                    source_sequence = MAX(source_sequence, ?),
                    session_id = COALESCE(?, session_id), connected = 1, updated_at = ?
                WHERE pane_id = ?
                """,
                (instance_id, source_sequence or 0, session_id, utc_now(), storage_pane_id),
            )
            if isinstance(recovery_snapshot, dict):
                snapshot_json = json.dumps(recovery_snapshot, separators=(",", ":"), ensure_ascii=False)
                if len(snapshot_json.encode("utf-8")) > PI_SEMANTIC_MAX_LINE_BYTES:
                    raise PiSemanticError("Pi reset snapshot exceeded the size limit", code="pi_payload_too_large", status=502)
                recovery_session = _record_session_id(recovery_snapshot) or session_id or previous_session
                self._database.execute(
                    """
                    UPDATE pi_semantic_state
                    SET session_id = COALESCE(?, session_id), snapshot_json = ?,
                        snapshot_cursor = ?, updated_at = ?
                    WHERE pane_id = ?
                    """,
                    (
                        recovery_session,
                        snapshot_json,
                        self._latest_cursor_locked(storage_pane_id),
                        utc_now(),
                        storage_pane_id,
                    ),
                )
            self._trim_locked(storage_pane_id)
            self._condition.notify_all()
        return emitted

    def _latest_cursor_locked(self, pane_id: str) -> int:
        row = self._database.execute(
            "SELECT MAX(cursor) AS latest FROM pi_semantic_events WHERE pane_id = ?",
            (pane_id,),
        ).fetchone()
        return int(row["latest"] or 0)

    def _append_event_locked(
        self,
        storage_pane_id: str,
        event: dict,
        *,
        envelope_pane_id: str,
        session_id: Optional[str],
        instance_id: Optional[str],
        source_sequence: Optional[int],
    ) -> Optional[dict]:
        if instance_id is not None and source_sequence is not None:
            duplicate = self._database.execute(
                """
                SELECT 1 FROM pi_semantic_events
                WHERE pane_id = ? AND instance_id = ? AND source_sequence = ?
                """,
                (storage_pane_id, instance_id, source_sequence),
            ).fetchone()
            if duplicate is not None:
                return None
        cursor = self._latest_cursor_locked(storage_pane_id) + 1
        generated_at = utc_now()
        envelope = {
            "protocol": copy.deepcopy(PI_SEMANTIC_PROTOCOL),
            "pane_id": envelope_pane_id,
            "session_id": session_id,
            "cursor": cursor,
            "event": copy.deepcopy(event),
            "generated_at": generated_at,
        }
        envelope_json = json.dumps(envelope, separators=(",", ":"), ensure_ascii=False)
        payload_bytes = len(envelope_json.encode("utf-8"))
        if payload_bytes > PI_SEMANTIC_MAX_LINE_BYTES:
            event_type = str(event.get("type") or "unknown")
            envelope["event"] = {
                "type": "bridge.payload_omitted",
                "originalType": event_type,
                "reason": "payload_too_large",
                "payloadBytes": payload_bytes,
            }
            envelope_json = json.dumps(envelope, separators=(",", ":"), ensure_ascii=False)
            payload_bytes = len(envelope_json.encode("utf-8"))
        self._database.execute(
            """
            INSERT INTO pi_semantic_events
            (pane_id, cursor, session_id, instance_id, source_sequence, event_type,
             envelope_json, payload_bytes, generated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                storage_pane_id,
                cursor,
                session_id,
                instance_id,
                source_sequence,
                str(envelope["event"].get("type") or "unknown"),
                envelope_json,
                payload_bytes,
                generated_at,
            ),
        )
        return copy.deepcopy(envelope)

    def _trim_locked(self, pane_id: str) -> None:
        state = self._database.execute(
            "SELECT snapshot_cursor, snapshot_json FROM pi_semantic_state WHERE pane_id = ?",
            (pane_id,),
        ).fetchone()
        snapshot_cursor = int(state["snapshot_cursor"] or 0) if state is not None else 0
        rows = self._database.execute(
            """
            SELECT cursor, payload_bytes FROM pi_semantic_events
            WHERE pane_id = ? ORDER BY cursor DESC
            """,
            (pane_id,),
        ).fetchall()
        retained_bytes = 0
        keep: list[int] = []
        for row in rows:
            size = int(row["payload_bytes"])
            if len(keep) >= self.maximum_events_per_pane or retained_bytes + size > self.maximum_bytes_per_pane:
                break
            keep.append(int(row["cursor"]))
            retained_bytes += size
        if state is not None and state["snapshot_json"] is not None and keep:
            cutoff = min(keep)
            # A snapshot checkpoint must remain replayable. Temporarily exceed
            # configured retention during an unusually long active turn rather
            # than expose a cursor older than the retained suffix. The next Pi
            # checkpoint lets normal trimming resume.
            required_cutoff = snapshot_cursor + 1
            cutoff = min(cutoff, required_cutoff)
        else:
            cutoff = min(keep) if keep else self._latest_cursor_locked(pane_id) + 1
        if not rows or cutoff <= int(rows[-1]["cursor"]):
            return
        self._database.execute(
            "DELETE FROM pi_semantic_events WHERE pane_id = ? AND cursor < ?",
            (pane_id, cutoff),
        )

    def bounds(self, pane_id: str, *, namespace: str = "") -> tuple[int, int]:
        storage_pane_id = self._storage_pane_id(pane_id, namespace)
        with self._lock:
            row = self._database.execute(
                """
                SELECT MIN(cursor) AS oldest, MAX(cursor) AS latest
                FROM pi_semantic_events WHERE pane_id = ?
                """,
                (storage_pane_id,),
            ).fetchone()
            latest = int(row["latest"] or 0)
            oldest = int(row["oldest"] or (latest + 1))
            return oldest, latest

    def events_after(
        self,
        pane_id: str,
        cursor: int,
        *,
        limit: int = 256,
        namespace: str = "",
    ) -> list[dict]:
        storage_pane_id = self._storage_pane_id(pane_id, namespace)
        with self._lock:
            rows = self._database.execute(
                """
                SELECT envelope_json FROM pi_semantic_events
                WHERE pane_id = ? AND cursor > ? ORDER BY cursor LIMIT ?
                """,
                (storage_pane_id, int(cursor), max(1, min(int(limit), 1024))),
            ).fetchall()
            return [json.loads(row["envelope_json"]) for row in rows]

    def wait_after(
        self,
        pane_id: str,
        cursor: int,
        *,
        timeout: float = 15.0,
        namespace: str = "",
    ) -> list[dict]:
        with self._condition:
            values = self.events_after(pane_id, cursor, namespace=namespace)
            if values:
                return values
            self._condition.wait(max(0.0, float(timeout)))
            return self.events_after(pane_id, cursor, namespace=namespace)

    def snapshot(self, pane_id: str, *, namespace: str = "") -> dict:
        storage_pane_id = self._storage_pane_id(pane_id, namespace)
        with self._lock:
            row = self._database.execute(
                "SELECT * FROM pi_semantic_state WHERE pane_id = ?",
                (storage_pane_id,),
            ).fetchone()
            oldest, latest = self.bounds(pane_id, namespace=namespace)
            payload: dict = {}
            if row is not None and row["snapshot_json"]:
                value = json.loads(row["snapshot_json"])
                if isinstance(value, dict):
                    payload = value
            known = {
                "ok": True,
                "protocol": copy.deepcopy(PI_SEMANTIC_PROTOCOL),
                "pane_id": pane_id,
                "connected": bool(row["connected"]) if row is not None else False,
                "session": copy.deepcopy(payload.get("session")) if isinstance(payload.get("session"), dict) else None,
                "state": copy.deepcopy(payload.get("state")) if isinstance(payload.get("state"), dict) else {},
                "entries": copy.deepcopy(payload.get("entries")) if isinstance(payload.get("entries"), list) else [],
                "pending_interactions": (
                    copy.deepcopy(payload.get("pending_interactions") or payload.get("pendingInteractions"))
                    if isinstance(payload.get("pending_interactions") or payload.get("pendingInteractions"), list)
                    else []
                ),
                # Snapshot entries represent state through snapshot_cursor.
                # Clients replay later journal events from this checkpoint.
                "cursor": int(row["snapshot_cursor"] or 0) if row is not None else 0,
                "latest_cursor": latest,
                "oldest_cursor": oldest,
                "truncated": bool(payload.get("truncated", False)),
                "generated_at": str(payload.get("generated_at") or payload.get("generatedAt") or utc_now()),
            }
            # Unknown bridge fields survive round trips, but authoritative HTTP
            # transport fields above cannot be overridden by the extension.
            for key, value in payload.items():
                if key not in known and key not in {"pendingInteractions"}:
                    known[key] = copy.deepcopy(value)
            return known


def _pi_pane_ids(snapshot: dict) -> set[str]:
    result: set[str] = set()
    for record in snapshot.get("panes", []):
        if not isinstance(record, dict) or not record.get("pane_id"):
            continue
        values = [record.get("agent"), record.get("display_agent")]
        if any(str(value or "").strip().lower() == "pi" for value in values):
            result.add(str(record["pane_id"]))
    for record in snapshot.get("agents", []):
        if not isinstance(record, dict) or not record.get("pane_id"):
            continue
        values = [record.get("agent"), record.get("display_agent"), record.get("kind")]
        if any(str(value or "").strip().lower() == "pi" for value in values):
            result.add(str(record["pane_id"]))
    return result


class PiSemanticManager:
    """Supervise pane-specific extension connections and command requests."""

    def __init__(
        self,
        herdr_socket_path: str,
        *,
        environ: Optional[Mapping[str, str]] = None,
        journal: Optional[PiSemanticJournal] = None,
        on_event: Optional[Callable[[dict], None]] = None,
    ) -> None:
        production_environment = environ is None
        self.environ = dict(os.environ if production_environment else environ)
        self.herdr_socket_path = os.path.abspath(os.path.expanduser(herdr_socket_path))
        self.namespace = hashlib.sha256(self.herdr_socket_path.encode("utf-8")).hexdigest()
        store_path = self.environ.get("HERDR_HARNESS_PI_STORE_PATH")
        if not store_path:
            store_path = (
                os.path.expanduser("~/.config/herdr-harness/pi-semantic.sqlite3")
                if production_environment
                else ":memory:"
            )
        self.journal = journal or PiSemanticJournal(
            store_path,
            maximum_events_per_pane=_bounded_int(
                self.environ,
                "HERDR_HARNESS_PI_MAX_EVENTS_PER_PANE",
                4096,
                minimum=64,
                maximum=65536,
            ),
            maximum_bytes_per_pane=_bounded_int(
                self.environ,
                "HERDR_HARNESS_PI_MAX_BYTES_PER_PANE",
                32 * 1024 * 1024,
                minimum=1024 * 1024,
                maximum=512 * 1024 * 1024,
            ),
        )
        self._on_event = on_event
        self._lock = threading.RLock()
        self._started = False
        self._known_pi_panes: set[str] = set()
        self._bridge_capabilities: dict[str, dict] = {}
        self._watchers: dict[str, tuple[threading.Event, threading.Thread]] = {}

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            self._started = True
            panes = set(self._known_pi_panes)
        for pane_id in panes:
            self._start_watcher(pane_id)

    def stop(self) -> None:
        with self._lock:
            self._started = False
            values = list(self._watchers.values())
            self._watchers.clear()
        for stop, _thread in values:
            stop.set()
        for _stop, thread in values:
            if thread.is_alive():
                thread.join(timeout=2.0)

    def close(self) -> None:
        self.stop()
        self.journal.close()

    def sync_snapshot(self, snapshot: dict) -> None:
        panes = _pi_pane_ids(snapshot)
        with self._lock:
            self._known_pi_panes = panes
            started = self._started
            removed = [pane for pane in self._watchers if pane not in panes]
            removed_values = [self._watchers.pop(pane) for pane in removed]
            missing = panes.difference(self._watchers)
        for stop, _thread in removed_values:
            stop.set()
        if started:
            for pane_id in missing:
                self._start_watcher(pane_id)

    def _start_watcher(self, pane_id: str) -> None:
        with self._lock:
            if not self._started or pane_id in self._watchers:
                return
            stop = threading.Event()
            thread = threading.Thread(
                target=self._watch,
                args=(pane_id, stop),
                name=f"pi-semantic-{hashlib.sha256(pane_id.encode()).hexdigest()[:8]}",
                daemon=True,
            )
            self._watchers[pane_id] = (stop, thread)
            thread.start()

    def _verified_socket_path(self, pane_id: str) -> str:
        path = pi_semantic_socket_path(self.herdr_socket_path, pane_id)
        ensure_private_socket_directory(path)
        try:
            metadata = os.lstat(path)
        except FileNotFoundError as exc:
            raise PiSemanticError("Pi semantic extension is not connected", code="pi_bridge_unavailable", status=503) from exc
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISSOCK(metadata.st_mode):
            raise PiSemanticError("Pi semantic socket is not a safe Unix socket", code="pi_bridge_unsafe", status=503)
        if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
            raise PiSemanticError("Pi semantic socket belongs to another user", code="pi_bridge_unsafe", status=503)
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise PiSemanticError("Pi semantic socket permissions are too broad", code="pi_bridge_unsafe", status=503)
        return path

    def _connect(self, pane_id: str, *, timeout: float) -> socket.socket:
        path = self._verified_socket_path(pane_id)
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(timeout)
        try:
            connection.connect(path)
        except OSError as exc:
            connection.close()
            raise PiSemanticError("Could not connect to the Pi semantic extension", code="pi_bridge_unavailable", status=503) from exc
        return connection

    def _watch(self, pane_id: str, stop: threading.Event) -> None:
        delay = 0.25
        while not stop.is_set():
            connection: Optional[socket.socket] = None
            try:
                connection = self._connect(pane_id, timeout=2.0)
                instance_id, sequence = self.journal.source_position(pane_id, namespace=self.namespace)
                request = {
                    "protocol": copy.deepcopy(PI_SEMANTIC_PROTOCOL),
                    "id": f"subscribe:{uuid.uuid4().hex}",
                    "type": "subscribe",
                    "pane_id": pane_id,
                    "instance_id": instance_id,
                    "after": sequence,
                }
                connection.sendall(_json_bytes(request) + b"\n")
                connection.settimeout(1.0)
                delay = 0.25
                buffer = bytearray()
                authenticated = False
                while not stop.is_set():
                    try:
                        chunk = connection.recv(65536)
                    except socket.timeout:
                        continue
                    if not chunk:
                        raise PiSemanticError("Pi semantic extension disconnected", code="pi_bridge_disconnected", status=503)
                    buffer.extend(chunk)
                    if len(buffer) > PI_SEMANTIC_MAX_LINE_BYTES:
                        raise PiSemanticError("Pi semantic record exceeded the size limit", code="pi_payload_too_large", status=502)
                    while b"\n" in buffer:
                        raw, _, remainder = buffer.partition(b"\n")
                        buffer = bytearray(remainder)
                        if not raw.strip():
                            continue
                        try:
                            record = json.loads(raw.decode("utf-8"))
                        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                            raise PiSemanticError("Pi semantic record was invalid JSON", code="pi_protocol_error", status=502) from exc
                        if not isinstance(record, dict) or not _protocol_valid(record) or _record_pane_id(record) != pane_id:
                            raise PiSemanticError(
                                "Pi semantic record failed bridge authentication",
                                code="pi_protocol_error",
                                status=502,
                            )
                        if record.get("kind") in ("hello", "bridge.hello"):
                            observed_capabilities = record.get("capabilities")
                            if isinstance(observed_capabilities, dict):
                                with self._lock:
                                    self._bridge_capabilities[pane_id] = dict(observed_capabilities)
                        if not authenticated:
                            changed = self.journal.mark_connected(pane_id, True, namespace=self.namespace)
                            if changed is not None and self._on_event is not None:
                                self._on_event(copy.deepcopy(changed))
                            authenticated = True
                        for event in self.journal.ingest(pane_id, record, namespace=self.namespace):
                            if self._on_event is not None:
                                self._on_event(copy.deepcopy(event))
            except (PiSemanticError, OSError):
                changed = self.journal.mark_connected(pane_id, False, namespace=self.namespace)
                if changed is not None and self._on_event is not None:
                    self._on_event(copy.deepcopy(changed))
            finally:
                if connection is not None:
                    try:
                        connection.close()
                    except OSError:
                        pass
            if stop.wait(delay):
                break
            delay = min(delay * 1.7, 10.0)
        changed = self.journal.mark_connected(pane_id, False, namespace=self.namespace)
        if changed is not None and self._on_event is not None:
            self._on_event(copy.deepcopy(changed))

    def command(self, pane_id: str, command: str, payload: Optional[dict] = None) -> dict:
        if pane_id not in self._known_pi_panes:
            raise PiSemanticError("Pane is not a detected Pi session", code="pi_pane_not_found", status=404)
        request_id = f"harness:{uuid.uuid4().hex}"
        request = {
            "protocol": copy.deepcopy(PI_SEMANTIC_PROTOCOL),
            "id": request_id,
            "type": "command",
            "pane_id": pane_id,
            "command": command,
            "payload": copy.deepcopy(payload or {}),
        }
        encoded = _json_bytes(request) + b"\n"
        if len(encoded) > PI_SEMANTIC_MAX_COMMAND_BYTES:
            raise PiSemanticError("Pi command exceeded the size limit", code="pi_command_too_large", status=413)
        timeout = _bounded_int(
            self.environ,
            "HERDR_HARNESS_PI_COMMAND_TIMEOUT_MS",
            3000,
            minimum=250,
            maximum=30000,
        ) / 1000.0
        with self._connect(pane_id, timeout=timeout) as connection:
            connection.sendall(encoded)
            buffer = bytearray()
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                connection.settimeout(max(0.05, deadline - time.monotonic()))
                try:
                    chunk = connection.recv(65536)
                except socket.timeout as exc:
                    raise PiSemanticError("Pi command timed out", code="pi_bridge_timeout", status=504) from exc
                if not chunk:
                    break
                buffer.extend(chunk)
                if len(buffer) > PI_SEMANTIC_MAX_LINE_BYTES:
                    raise PiSemanticError("Pi command response exceeded the size limit", code="pi_payload_too_large", status=502)
                while b"\n" in buffer:
                    raw, _, remainder = buffer.partition(b"\n")
                    buffer = bytearray(remainder)
                    if not raw.strip():
                        continue
                    try:
                        response = json.loads(raw.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        raise PiSemanticError("Pi command response was invalid JSON", code="pi_protocol_error", status=502) from exc
                    response_id = response.get("request_id") or response.get("requestId") or response.get("id")
                    if response_id != request_id:
                        continue
                    success = bool(response.get("success", False))
                    if not success:
                        error = response.get("error") if isinstance(response.get("error"), dict) else {}
                        code = str(error.get("code") or "pi_command_rejected")
                        message = str(error.get("message") or "Pi rejected the command")
                        status = 501 if code == "unsupported" else 409
                        raise PiSemanticError(message, code=code, status=status)
                    return response
        raise PiSemanticError("Pi command connection ended without a response", code="pi_bridge_disconnected", status=503)

    def capability(self, pane_id: str) -> dict:
        default_capabilities = {
            "prompt": True,
            "steer": True,
            "followUp": True,
            "abort": True,
            "listModels": True,
            "setModel": True,
            "interactionResponse": False,
        }
        with self._lock:
            observed = self._bridge_capabilities.get(pane_id)
        if observed is None:
            capabilities = dict(default_capabilities)
        else:
            capabilities = {key: bool(observed.get(key, False)) for key in default_capabilities}
        snapshot = self.journal.snapshot(pane_id, namespace=self.namespace)
        available = bool(snapshot.get("entries")) or snapshot.get("session") is not None
        try:
            self._verified_socket_path(pane_id)
            available = True
        except PiSemanticError:
            pass
        session = snapshot.get("session") if isinstance(snapshot.get("session"), dict) else {}
        return {
            "available": available,
            "connected": bool(snapshot.get("connected")),
            "protocol_version": PI_SEMANTIC_PROTOCOL["version"],
            "session_id": session.get("id") if isinstance(session, dict) else None,
            "cursor": snapshot.get("cursor", 0),
            "oldest_cursor": snapshot.get("oldest_cursor", 1),
            "capabilities": capabilities,
            "generated_at": utc_now(),
        }

    def snapshot_response(self, pane_id: str) -> dict:
        if pane_id not in self._known_pi_panes:
            raise PiSemanticError("Pane is not a detected Pi session", code="pi_pane_not_found", status=404)
        response = self.journal.snapshot(pane_id, namespace=self.namespace)
        capability = self.capability(pane_id)
        response["available"] = capability["available"]
        response["connected"] = capability["connected"]
        response["capabilities"] = copy.deepcopy(capability["capabilities"])
        return response

    def bounds(self, pane_id: str) -> tuple[int, int]:
        return self.journal.bounds(pane_id, namespace=self.namespace)

    def wait_after(self, pane_id: str, cursor: int, *, timeout: float = 15.0) -> list[dict]:
        return self.journal.wait_after(pane_id, cursor, timeout=timeout, namespace=self.namespace)

    def enrich_snapshot(self, snapshot: dict) -> dict:
        result = copy.deepcopy(snapshot)
        pi_panes = _pi_pane_ids(result)
        for pane in result.get("panes", []):
            if isinstance(pane, dict) and str(pane.get("pane_id") or "") in pi_panes:
                pane["pi_semantic"] = self.capability(str(pane["pane_id"]))
        return result

    def enrich_workspaces(self, snapshot: dict, workspaces: list[dict]) -> list[dict]:
        result = copy.deepcopy(workspaces)
        pi_panes = _pi_pane_ids(snapshot)
        for workspace in result:
            for pane in workspace.get("panes", []):
                pane_id = str(pane.get("pane_id") or "") if isinstance(pane, dict) else ""
                if pane_id in pi_panes:
                    pane["pi_semantic"] = self.capability(pane_id)
        return result
