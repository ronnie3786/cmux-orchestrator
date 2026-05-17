from __future__ import annotations

import threading
import time

from . import orchestrator_v2_storage as v2
from .routes import orchestrator_v2


class OrchestratorV2Watcher:
    def __init__(self, *, interval_seconds: int = 600):
        self.interval_seconds = max(60, int(interval_seconds or 600))
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> bool:
        if self._thread and self._thread.is_alive():
            return False
        self._thread = threading.Thread(target=self._run, name="orchestrator-v2-watcher", daemon=True)
        self._thread.start()
        return True

    def stop(self) -> None:
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.5)

    def run_once(self):
        return orchestrator_v2.run_watcher_once(repo=v2.get_repository())

    def _run(self) -> None:
        while not self._stop.wait(self.interval_seconds):
            try:
                self.run_once()
            except Exception:
                continue

