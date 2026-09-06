"""Deliver durable, delayed APNs alerts only while a session is still unread."""

from __future__ import annotations

import threading
import time
from typing import Callable, Optional

from .alerts import AlertStore, utc_now


class UnreadNotificationManager:
    def __init__(self, alerts: AlertStore, push, *, callback: Optional[Callable[[dict], None]] = None,
                 delay: float = 60.0, clock: Callable[[], float] = time.time) -> None:
        self.alerts = alerts
        self.push = push
        self.callback = callback
        self.delay = delay
        self.clock = clock
        self._stop = threading.Event()
        self._processing = threading.Lock()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="herdr-unread-push", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)

    def _run(self) -> None:
        while not self._stop.wait(1.0):
            self.process_due()

    def process_due(self) -> None:
        # One delivery owner prevents overlapping polls from notifying twice.
        if not self._processing.acquire(blocking=False):
            return
        try:
            for alert in self.alerts.unread_push_candidates(now=self.clock(), delay=self.delay):
                if self._stop.is_set():
                    break
                alert_id = str(alert["id"])
                pending = lambda: not self._stop.is_set() and self.alerts.is_push_pending(alert_id)
                if not pending():
                    continue
                receipts = alert.get("pushDeliveredDeviceIds")
                try:
                    result = self.push.notify_alert(
                        alert,
                        unread_count=self.alerts.unread_count(),
                        excluding_device_ids={value for value in receipts if isinstance(value, str)} if isinstance(receipts, list) else set(),
                        should_deliver=pending,
                    )
                except Exception:
                    # Provider failures must not stop the worker or include credentials.
                    result = {"configured": False, "sent": 0, "errors": ["Push delivery failed; retry scheduled."]}
                self.alerts.record_push_attempt(
                    alert_id, now=self.clock(),
                    delivered_device_ids=result.get("deliveredDeviceIds", []),
                    complete=bool(result.get("complete", False)),
                )
                # Cancellation is silent. A retry without a new result must
                # not repeatedly trigger the app's local-notification fallback.
                meaningful = result.get("sent", 0) > 0 or (result.get("errors") and not alert.get("pushAttempts"))
                if self.callback and meaningful and not result.get("cancelled"):
                    try:
                        self.callback({key: value for key, value in result.items() if key != "deliveredDeviceIds"}
                                      | {"alertId": alert_id, "generatedAt": utc_now()})
                    except Exception:
                        pass
        finally:
            self._processing.release()
