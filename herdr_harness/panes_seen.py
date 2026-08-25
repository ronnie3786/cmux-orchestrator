"""Persistent lifecycle timestamps for Herdr panes."""

from __future__ import annotations

import json
import os
import tempfile
import threading
from pathlib import Path
from typing import Callable, Iterable, Optional

from .alerts import utc_now


class PaneFirstSeenStore:
    """Persist pane lifecycle state while retaining the original public name.

    Version 1 stored only ``firstSeen``. Version 2 keeps enough observation
    state to preserve activity and working durations across harness restarts.
    """

    STORE_VERSION = 2
    MAX_STORE_BYTES = 256 * 1024

    def __init__(
        self,
        *,
        maximum: int = 500,
        store_path: Optional[Path] = None,
        now: Callable[[], str] = utc_now,
    ) -> None:
        self.maximum = max(10, int(maximum))
        self.store_path = Path(store_path).expanduser() if store_path is not None else None
        self._now = now
        self._lock = threading.RLock()
        self._panes: dict[str, dict] = {}
        self._dirty = False
        self._load()

    @staticmethod
    def _valid_timestamp(value: object) -> Optional[str]:
        return value if isinstance(value, str) and bool(value) else None

    def _load(self) -> None:
        if self.store_path is None:
            return
        try:
            if self.store_path.stat().st_size > self.MAX_STORE_BYTES:
                return
            os.chmod(self.store_path, 0o600)
            with self.store_path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (
            FileNotFoundError,
            OSError,
            json.JSONDecodeError,
            UnicodeError,
            RecursionError,
        ):
            return
        if not isinstance(payload, dict):
            return

        version = payload.get("version")
        if version == 1:
            raw_first_seen = payload.get("firstSeen")
            if isinstance(raw_first_seen, dict):
                for pane_id, first_seen_at in raw_first_seen.items():
                    if len(self._panes) >= self.maximum:
                        break
                    timestamp = self._valid_timestamp(first_seen_at)
                    if isinstance(pane_id, str) and pane_id and timestamp:
                        self._panes[pane_id] = {
                            "firstSeenAt": timestamp,
                            "lastActivityAt": timestamp,
                            "statusSinceAt": timestamp,
                            "workingSince": None,
                            "revision": None,
                            "status": None,
                        }
            self._dirty = True
            self._persist_locked()
            return
        if version != self.STORE_VERSION:
            return

        raw_panes = payload.get("panes")
        if not isinstance(raw_panes, dict):
            return
        for pane_id, raw in raw_panes.items():
            if len(self._panes) >= self.maximum:
                break
            if not isinstance(pane_id, str) or not pane_id or not isinstance(raw, dict):
                continue
            first_seen_at = self._valid_timestamp(raw.get("firstSeenAt"))
            if not first_seen_at:
                continue
            status = raw.get("status")
            revision = raw.get("revision")
            self._panes[pane_id] = {
                "firstSeenAt": first_seen_at,
                "lastActivityAt": self._valid_timestamp(raw.get("lastActivityAt")) or first_seen_at,
                "statusSinceAt": self._valid_timestamp(raw.get("statusSinceAt")) or first_seen_at,
                "workingSince": self._valid_timestamp(raw.get("workingSince")),
                "revision": (
                    revision
                    if isinstance(revision, (str, int, float))
                    and not isinstance(revision, bool)
                    else None
                ),
                "status": status if isinstance(status, str) and status else None,
            }

    def _mark_dirty_locked(self) -> None:
        if self.store_path is not None:
            self._dirty = True

    def _payload_locked(self) -> dict:
        return {"version": self.STORE_VERSION, "panes": self._panes}

    def _write(self, payload: dict) -> None:
        assert self.store_path is not None
        self.store_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path: Optional[Path] = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=str(self.store_path.parent),
                prefix=f".{self.store_path.name}.",
                suffix=".tmp",
                delete=False,
            ) as handle:
                temporary_path = Path(handle.name)
                json.dump(payload, handle, separators=(",", ":"), ensure_ascii=False)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_path, 0o600)
            os.replace(temporary_path, self.store_path)
            os.chmod(self.store_path, 0o600)
        finally:
            if temporary_path is not None and temporary_path.exists():
                try:
                    temporary_path.unlink()
                except OSError:
                    pass

    def _persist_locked(self) -> None:
        if self.store_path is None or not self._dirty:
            return
        try:
            self._write(self._payload_locked())
        except (OSError, TypeError, ValueError):
            return
        self._dirty = False

    def observe(self, panes: Iterable[dict]) -> bool:
        """Record one authoritative snapshot of pane revisions and statuses."""

        with self._lock:
            changed = False
            timestamp: Optional[str] = None
            for pane in panes:
                if not isinstance(pane, dict):
                    continue
                pane_id = pane.get("pane_id")
                if not isinstance(pane_id, (str, int)) or not str(pane_id):
                    continue
                pane_id = str(pane_id)
                status_value = pane.get("agent_status")
                status = (
                    str(status_value)
                    if isinstance(status_value, (str, int)) and str(status_value)
                    else None
                )
                revision_value = pane.get("revision")
                revision = (
                    revision_value
                    if isinstance(revision_value, (str, int, float))
                    and not isinstance(revision_value, bool)
                    else None
                )
                if timestamp is None:
                    timestamp = self._now()
                current = self._panes.get(pane_id)
                if current is None:
                    if len(self._panes) >= self.maximum:
                        del self._panes[next(iter(self._panes))]
                    self._panes[pane_id] = {
                        "firstSeenAt": timestamp,
                        "lastActivityAt": timestamp,
                        "statusSinceAt": timestamp,
                        "workingSince": timestamp if status == "working" else None,
                        "revision": revision,
                        "status": status,
                    }
                    changed = True
                    continue

                previous_status = current.get("status")
                status_changed = status != previous_status
                revision_changed = revision != current.get("revision")
                working_changed = False
                if status_changed or revision_changed:
                    current["lastActivityAt"] = timestamp
                if status_changed:
                    current["statusSinceAt"] = timestamp
                if status == "working":
                    if previous_status != "working" or not current.get("workingSince"):
                        current["workingSince"] = timestamp
                        working_changed = True
                elif current.get("workingSince") is not None:
                    current["workingSince"] = None
                    working_changed = True
                if status_changed or revision_changed:
                    current["status"] = status
                    current["revision"] = revision
                if status_changed or revision_changed or working_changed:
                    changed = True

            if changed:
                self._mark_dirty_locked()
                self._persist_locked()
            return changed

    def record_first_seen(self, pane_ids: Iterable[str]) -> bool:
        """Compatibility shim for callers that only have pane IDs."""

        with self._lock:
            changed = False
            timestamp: Optional[str] = None
            for raw_pane_id in pane_ids:
                pane_id = str(raw_pane_id or "")
                if not pane_id or pane_id in self._panes:
                    continue
                if timestamp is None:
                    timestamp = self._now()
                if len(self._panes) >= self.maximum:
                    del self._panes[next(iter(self._panes))]
                self._panes[pane_id] = {
                    "firstSeenAt": timestamp,
                    "lastActivityAt": timestamp,
                    "statusSinceAt": timestamp,
                    "workingSince": None,
                    "revision": None,
                    "status": None,
                }
                changed = True
            if changed:
                self._mark_dirty_locked()
                self._persist_locked()
            return changed

    def lifecycle_map(self) -> dict[str, dict]:
        with self._lock:
            return {pane_id: dict(value) for pane_id, value in self._panes.items()}

    def first_seen_map(self) -> dict[str, str]:
        with self._lock:
            return {
                pane_id: str(value["firstSeenAt"])
                for pane_id, value in self._panes.items()
                if value.get("firstSeenAt")
            }

    def prune(self, live_pane_ids: set[str]) -> bool:
        with self._lock:
            changed = False
            for pane_id in list(self._panes):
                if pane_id not in live_pane_ids:
                    del self._panes[pane_id]
                    changed = True
            if changed:
                self._mark_dirty_locked()
                self._persist_locked()
            return changed
