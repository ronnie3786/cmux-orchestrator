"""Bounded event broker shared by Herdr events and HTTP SSE clients."""

from __future__ import annotations

import copy
import threading
from collections import deque
from typing import Any

from .alerts import utc_now


class EventBroker:
    def __init__(self, *, maximum: int = 1024) -> None:
        self._condition = threading.Condition()
        self._events: deque[dict] = deque(maxlen=max(32, int(maximum)))
        self._sequence = 0

    @property
    def latest_id(self) -> int:
        with self._condition:
            return self._sequence

    @property
    def oldest_id(self) -> int:
        with self._condition:
            return int(self._events[0]["id"]) if self._events else self._sequence + 1

    def publish(self, event: str, data: Any) -> dict:
        with self._condition:
            self._sequence += 1
            item = {
                "id": self._sequence,
                "event": str(event or "message"),
                "data": copy.deepcopy(data),
                "generatedAt": utc_now(),
            }
            self._events.append(item)
            self._condition.notify_all()
            return copy.deepcopy(item)

    def after(self, event_id: int) -> list[dict]:
        with self._condition:
            return [copy.deepcopy(item) for item in self._events if item["id"] > event_id]

    def wait_after(self, event_id: int, timeout: float = 15.0) -> list[dict]:
        with self._condition:
            if not any(item["id"] > event_id for item in self._events):
                self._condition.wait(max(0.0, float(timeout)))
            return [copy.deepcopy(item) for item in self._events if item["id"] > event_id]
