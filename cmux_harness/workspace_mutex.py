from __future__ import annotations

import contextlib
import threading
import time


class WorkspaceMutex:
    def __init__(self):
        self._locks = {}
        self._cooldowns = {}
        self._state_lock = threading.Lock()

    def _get_lock(self, workspace_id: str) -> threading.Lock:
        with self._state_lock:
            lock = self._locks.get(workspace_id)
            if lock is None:
                lock = threading.Lock()
                self._locks[workspace_id] = lock
            return lock

    def acquire(self, workspace_id: str, blocking: bool = True, timeout: float = -1) -> bool:
        lock = self._get_lock(workspace_id)
        if timeout is not None and timeout >= 0:
            return lock.acquire(blocking=blocking, timeout=timeout)
        return lock.acquire(blocking=blocking)

    def release(self, workspace_id: str):
        lock = self._get_lock(workspace_id)
        lock.release()

    def set_cooldown(self, workspace_id: str, seconds: float):
        with self._state_lock:
            self._cooldowns[workspace_id] = time.monotonic() + seconds

    def is_in_cooldown(self, workspace_id: str) -> bool:
        now = time.monotonic()
        with self._state_lock:
            cooldown_ends_at = self._cooldowns.get(workspace_id)
            if cooldown_ends_at is None:
                return False
            if cooldown_ends_at <= now:
                self._cooldowns.pop(workspace_id, None)
                return False
            return True

    @contextlib.contextmanager
    def context(self, workspace_id: str):
        acquired = self.acquire(workspace_id)
        if not acquired:
            raise RuntimeError(f"Failed to acquire mutex for workspace {workspace_id}")
        try:
            yield
        finally:
            self.release(workspace_id)
