"""Server-side starred-pane store for Herdr Harness."""

from __future__ import annotations

import json
import os
import tempfile
import threading
from pathlib import Path
from typing import Optional

from .alerts import utc_now


class StarStore:
    """Keep starred pane IDs in their starred-at insertion order."""

    STORE_VERSION = 1
    MAX_STORE_BYTES = 64 * 1024

    def __init__(self, *, maximum: int = 500, store_path: Optional[Path] = None) -> None:
        self.maximum = max(10, int(maximum))
        self.store_path = Path(store_path).expanduser() if store_path is not None else None
        self._lock = threading.RLock()
        self._starred: dict[str, str] = {}
        self._dirty = False
        self._load()

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
        if not isinstance(payload, dict) or payload.get("version") != self.STORE_VERSION:
            return

        raw_starred = payload.get("starred")
        if isinstance(raw_starred, dict):
            for pane_id, starred_at in raw_starred.items():
                if len(self._starred) >= self.maximum:
                    break
                if (
                    isinstance(pane_id, str)
                    and pane_id
                    and isinstance(starred_at, str)
                    and starred_at
                ):
                    self._starred[pane_id] = starred_at

    def _mark_dirty_locked(self) -> None:
        if self.store_path is not None:
            self._dirty = True

    def _payload_locked(self) -> dict:
        return {"version": self.STORE_VERSION, "starred": self._starred}

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

    def list(self) -> list[str]:
        with self._lock:
            return list(self._starred.keys())

    def set(self, pane_id: str, starred: bool) -> bool:
        with self._lock:
            if starred:
                if pane_id in self._starred:
                    return False
                if len(self._starred) >= self.maximum:
                    del self._starred[next(iter(self._starred))]
                self._starred[pane_id] = utc_now()
            else:
                if pane_id not in self._starred:
                    return False
                del self._starred[pane_id]
            self._mark_dirty_locked()
            self._persist_locked()
            return True

    def prune(self, live_pane_ids: set[str]) -> bool:
        with self._lock:
            changed = False
            for pane_id in list(self._starred):
                if pane_id not in live_pane_ids:
                    del self._starred[pane_id]
                    changed = True
            if changed:
                self._mark_dirty_locked()
                self._persist_locked()
            return changed
