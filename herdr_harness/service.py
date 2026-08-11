"""Stateful Herdr adapter used by the HTTP API."""

from __future__ import annotations

import copy
import os
import threading
from typing import Mapping, Optional

from .alerts import AlertStore, utc_now
from .client import DEFAULT_SUBSCRIPTIONS, HerdrClient, HerdrClientError
from .events import EventBroker
from .network import network_payload
from .normalization import composite_workspaces, pane_index
from .push_notifications import APNsManager
from .terminal import TerminalObserver, TerminalObserverError


def _bounded_environment_int(
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


class HerdrService:
    """Maintain a cached snapshot and a reconnecting native event stream."""

    def __init__(
        self,
        client: Optional[HerdrClient] = None,
        *,
        alerts: Optional[AlertStore] = None,
        broker: Optional[EventBroker] = None,
        push: Optional[APNsManager] = None,
        environ: Optional[Mapping[str, str]] = None,
    ) -> None:
        self.environ = dict(os.environ if environ is None else environ)
        self.client = client or HerdrClient(environ=self.environ)
        alert_store_path = self.environ.get("HERDR_HARNESS_ALERT_STORE_PATH") or None
        self.alerts = alerts or AlertStore(store_path=alert_store_path)
        self.broker = broker or EventBroker()
        self.push = push or APNsManager(environ=self.environ)
        self._lock = threading.RLock()
        self._snapshot: Optional[dict] = None
        self._generated_at: Optional[str] = None
        self._last_error: Optional[str] = None
        self._request_connected = False
        self._events_connected = False
        self._started = False
        self._stop_event = threading.Event()
        self._refresh_event = threading.Event()
        self._restart_subscription = threading.Event()
        self._event_thread: Optional[threading.Thread] = None
        self._refresh_thread: Optional[threading.Thread] = None
        self._terminal_limit = _bounded_environment_int(
            self.environ,
            "HERDR_HARNESS_TERMINAL_MAX_STREAMS",
            8,
            minimum=1,
            maximum=64,
        )
        self.terminal_max_seconds = _bounded_environment_int(
            self.environ,
            "HERDR_HARNESS_TERMINAL_MAX_SECONDS",
            3600,
            minimum=60,
            maximum=86400,
        )
        self._terminal_slots = threading.BoundedSemaphore(self._terminal_limit)

    @property
    def generated_at(self) -> Optional[str]:
        with self._lock:
            return self._generated_at

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            self._started = True
        try:
            self.refresh_snapshot()
        except HerdrClientError:
            pass
        self._event_thread = threading.Thread(
            target=self._event_loop,
            name="herdr-events",
            daemon=True,
        )
        self._refresh_thread = threading.Thread(
            target=self._refresh_loop,
            name="herdr-snapshot-refresh",
            daemon=True,
        )
        self._event_thread.start()
        self._refresh_thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        self._refresh_event.set()
        self._restart_subscription.set()
        for thread in (self._event_thread, self._refresh_thread):
            if thread is not None and thread.is_alive():
                thread.join(timeout=2.0)
        with self._lock:
            self._started = False

    def refresh_snapshot(self) -> dict:
        try:
            snapshot = self.client.snapshot()
        except HerdrClientError as exc:
            with self._lock:
                self._request_connected = False
                self._last_error = str(exc)
            raise
        if not isinstance(snapshot, dict):
            raise HerdrClientError("Herdr returned an invalid snapshot", code="invalid_herdr_response")
        generated_at = utc_now()
        with self._lock:
            had_snapshot = self._snapshot is not None
            previous_pane_ids = {
                str(item.get("pane_id"))
                for item in (self._snapshot or {}).get("panes", [])
                if isinstance(item, dict) and item.get("pane_id")
            }
            current_pane_ids = {
                str(item.get("pane_id"))
                for item in snapshot.get("panes", [])
                if isinstance(item, dict) and item.get("pane_id")
            }
            self._snapshot = copy.deepcopy(snapshot)
            self._generated_at = generated_at
            self._request_connected = True
            if self._events_connected:
                self._last_error = None
        if had_snapshot and previous_pane_ids != current_pane_ids:
            # Rebuild pane-specific status subscriptions only after the cache
            # contains the new topology.
            self._restart_subscription.set()
        emitted = self.alerts.observe_snapshot(snapshot, emit_initial=False)
        for alert in emitted:
            self._publish_alert(alert)
        self.broker.publish(
            "snapshot.updated",
            {
                "generatedAt": generated_at,
                "initial": not had_snapshot,
                "focusedWorkspaceId": snapshot.get("focused_workspace_id"),
                "focusedTabId": snapshot.get("focused_tab_id"),
                "focusedPaneId": snapshot.get("focused_pane_id"),
                "paneRevisions": {
                    str(item.get("pane_id")): item.get("revision")
                    for item in snapshot.get("panes", [])
                    if isinstance(item, dict) and item.get("pane_id")
                },
            },
        )
        return copy.deepcopy(snapshot)

    def _refresh_loop(self) -> None:
        while not self._stop_event.is_set():
            self._refresh_event.wait(1.0)
            if self._stop_event.is_set():
                return
            if not self._refresh_event.is_set():
                continue
            self._refresh_event.clear()
            if self._stop_event.wait(0.05):
                return
            try:
                self.refresh_snapshot()
            except HerdrClientError:
                continue

    def _subscriptions(self) -> list[dict]:
        values = [{"type": item} for item in DEFAULT_SUBSCRIPTIONS]
        with self._lock:
            snapshot = copy.deepcopy(self._snapshot or {})
        for pane in snapshot.get("panes", []):
            if isinstance(pane, dict) and pane.get("pane_id"):
                values.append(
                    {"type": "pane.agent_status_changed", "pane_id": str(pane["pane_id"])}
                )
        return values

    def _event_loop(self) -> None:
        self.client.subscribe_forever(
            self._handle_event,
            subscription_provider=self._subscriptions,
            stop_event=self._stop_event,
            restart_event=self._restart_subscription,
            on_state=self._handle_stream_state,
        )

    def _handle_stream_state(self, state: str, error: Optional[BaseException]) -> None:
        with self._lock:
            self._events_connected = state == "connected"
            if error is not None:
                self._last_error = str(error)
            elif state == "connected" and self._request_connected:
                self._last_error = None
        self.broker.publish(
            "connection.changed",
            {"state": state, "error": str(error) if error is not None else None},
        )

    def _lookup_pane(self, pane_id: str) -> Optional[dict]:
        with self._lock:
            snapshot = copy.deepcopy(self._snapshot or {})
        return pane_index(snapshot).get(pane_id)

    def _handle_event(self, envelope: dict) -> None:
        event_name = str(envelope.get("event") or "herdr.event")
        alert = self.alerts.observe_event(envelope, lookup=self._lookup_pane)
        self.broker.publish(event_name, envelope)
        if alert:
            self._publish_alert(alert)
        self._refresh_event.set()

    def _cached_snapshot(self) -> tuple[dict, str]:
        with self._lock:
            snapshot = copy.deepcopy(self._snapshot)
            generated_at = self._generated_at
        if snapshot is None or generated_at is None:
            snapshot = self.refresh_snapshot()
            generated_at = self.generated_at or utc_now()
        return snapshot, generated_at

    def snapshot_response(self) -> dict:
        snapshot, generated_at = self._cached_snapshot()
        return {"ok": True, "snapshot": snapshot, "generatedAt": generated_at}

    def workspaces_response(self) -> dict:
        snapshot, generated_at = self._cached_snapshot()
        return {
            "ok": True,
            "workspaces": composite_workspaces(snapshot),
            "alerts": self.alerts.list(limit=100),
            "generatedAt": generated_at,
        }

    def workspace_response(self, workspace_id: str) -> Optional[dict]:
        response = self.workspaces_response()
        workspace = next(
            (item for item in response["workspaces"] if item.get("workspace_id") == workspace_id),
            None,
        )
        if workspace is None:
            return None
        return {
            "ok": True,
            "workspace": workspace,
            "alerts": [
                item
                for item in response["alerts"]
                if item.get("workspaceId") == workspace_id
            ],
            "generatedAt": response["generatedAt"],
        }

    def health_response(self) -> dict:
        with self._lock:
            cached = self._snapshot is not None
            generated_at = self._generated_at
            request_connected = self._request_connected
            events_connected = self._events_connected
            error = self._last_error
            snapshot = copy.deepcopy(self._snapshot or {})
        connected = request_connected and events_connected
        return {
            "ok": bool(connected or cached),
            "service": "herdr-harness",
            "session": self.client.session,
            "herdr": {
                "connected": connected,
                "requestConnected": request_connected,
                "eventsConnected": events_connected,
                "socketFound": os.path.exists(self.client.socket_path),
                "version": snapshot.get("version"),
                "protocol": snapshot.get("protocol"),
                "lastError": error,
            },
            "cache": {
                "available": cached,
                "stale": cached and not connected,
                "generatedAt": generated_at,
            },
            "alerts": {"unread": self.alerts.unread_count()},
            "generatedAt": utc_now(),
        }

    def network_response(self, port: int, *, host_header: str = "") -> dict:
        payload = network_payload(port, environ=self.environ, host_header=host_header)
        payload["apiBasePath"] = "/api/v1"
        payload["session"] = self.client.session
        payload["authRequired"] = bool(self.environ.get("HERDR_HARNESS_API_TOKEN"))
        return payload

    def invoke(self, method: str, params: dict) -> dict:
        try:
            result = self.client.request(method, params)
        except HerdrClientError as exc:
            self._record_request_error(exc)
            raise
        self._record_request_success()
        try:
            self.refresh_snapshot()
        except HerdrClientError:
            pass
        return {"ok": True, "result": result}

    def read_pane(
        self,
        pane_id: str,
        *,
        source: str = "recent_unwrapped",
        lines: int = 200,
        format_name: str = "text",
        strip_ansi: bool = True,
    ) -> dict:
        try:
            result = self.client.request(
                "pane.read",
                {
                    "pane_id": pane_id,
                    "source": source,
                    "lines": lines,
                    "format": format_name,
                    "strip_ansi": strip_ansi,
                },
            )
        except HerdrClientError as exc:
            self._record_request_error(exc)
            raise
        self._record_request_success()
        read = result.get("read") if isinstance(result.get("read"), dict) else result
        return {"ok": True, "output": read, "result": result, "generatedAt": utc_now()}

    def list_alerts(self, *, unread_only: bool, status: Optional[str], limit: int) -> dict:
        return {
            "ok": True,
            "alerts": self.alerts.list(unread_only=unread_only, status=status, limit=limit),
            "unreadCount": self.alerts.unread_count(),
            "generatedAt": utc_now(),
        }

    def mark_alert_read(self, alert_id: str) -> Optional[dict]:
        alert = self.alerts.mark_read(alert_id)
        if alert:
            self.broker.publish("alert.updated", alert)
            return {"ok": True, "alert": alert, "unreadCount": self.alerts.unread_count()}
        return None

    def mark_all_alerts_read(self) -> dict:
        changed = self.alerts.mark_all_read()
        for alert in changed:
            self.broker.publish("alert.updated", alert)
        return {"ok": True, "alerts": changed, "unreadCount": self.alerts.unread_count()}

    def _publish_alert(self, alert: dict) -> None:
        self.broker.publish("alert.created", alert)
        self.push.notify_alert_async(
            alert,
            unread_count=self.alerts.unread_count(),
            callback=lambda result: self.broker.publish("push.delivery", result),
        )

    def push_status(self) -> dict:
        return {"ok": True, "apns": self.push.configuration(), "generatedAt": utc_now()}

    def register_push_device(self, device_token: str, *, bundle_id: str, environment: str) -> dict:
        return self.push.register(device_token, bundle_id=bundle_id, environment=environment)

    def unregister_push_device(self, device_token: str) -> dict:
        return self.push.unregister(device_token)

    def terminal_observer(self, pane_id: str, *, cols: int, rows: int) -> TerminalObserver:
        if not self._terminal_slots.acquire(blocking=False):
            raise TerminalObserverError(
                f"Terminal stream limit reached ({self._terminal_limit}); close another live pane and retry"
            )
        try:
            return TerminalObserver(
                pane_id,
                cols=cols,
                rows=rows,
                socket_path=self.client.socket_path,
                session=self.client.session,
                environ=self.environ,
            )
        except Exception:
            self._terminal_slots.release()
            raise

    def release_terminal_observer(self) -> None:
        self._terminal_slots.release()

    def _record_request_error(self, exc: HerdrClientError) -> None:
        code = str(getattr(exc, "code", ""))
        if code in {"herdr_unavailable", "herdr_disconnected"} or "timeout" in code:
            with self._lock:
                self._request_connected = False
                self._last_error = str(exc)

    def _record_request_success(self) -> None:
        with self._lock:
            self._request_connected = True
            if self._events_connected:
                self._last_error = None
