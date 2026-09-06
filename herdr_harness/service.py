"""Stateful Herdr adapter used by the HTTP API."""

from __future__ import annotations

import base64
import binascii
import copy
import hashlib
import json
import os
import socket
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, TypeVar

from .alerts import AlertStore, utc_now
from . import attachments, cmux_tools, response_audio, result_artifacts, voice, workspace_tools
from .active_work import ActiveWorkError
from .active_work_store import ActiveWorkRepository, DEFAULT_STORE_PATH as DEFAULT_ACTIVE_WORK_STORE_PATH
from .agent_activity import AgentActivityManager
from .agent_runs import ACT_CHARTER, ASK_CHARTER, THINKING_LEVELS, AgentRunError, AgentRunManager
from .client import DEFAULT_SUBSCRIPTIONS, HerdrClient, HerdrClientError
from .cleanup import DEFAULT_JUDGE_CHARTER, CleanupManager, _parse_time
from .events import EventBroker
from .network import network_payload
from .normalization import composite_workspaces, pane_index
from .pi_semantic import PiSemanticError, PiSemanticManager
from .panes_seen import PaneFirstSeenStore
from .push_notifications import APNsManager
from .quick_voice import QuickVoiceManager
from .remote_activity import RemoteActivityPoller
from .stars import StarStore
from .terminal import TerminalObserver, TerminalObserverError
from .workflows import parse_workflow_config


_ToolResult = TypeVar("_ToolResult")

SNAPSHOT_DEBOUNCE_SECONDS = 0.25
SNAPSHOT_MAX_DELAY_SECONDS = 1.0
GLOBAL_PI_EVENT_TYPES = frozenset(
    {
        "bridge.connection",
        "session_start",
        "session_shutdown",
        "session_info_changed",
        "session_tree",
        "session_compact",
        "stream.reset",
        "agent_settled",
    }
)
_VOLATILE_SNAPSHOT_KEYS = frozenset({"generated_at", "generatedAt", "updated_at", "updatedAt"})
_STATUS_ROLLUP_PRECEDENCE = ("blocked", "done", "working", "idle", "unknown")
QUICK_PI_WORKSPACE_LABEL = "Random"
QUICK_PI_TAB_LABEL = "One-off Tasks"
QUICK_SESSION_IDEMPOTENCY_TTL_SECONDS = 10 * 60
QUICK_SESSION_READY_TIMEOUT_MS = 15_000
QUICK_SESSION_AGENT_BUSY_TIMEOUT_SECONDS = 2.0
QUICK_SESSION_AGENT_BUSY_RETRY_SECONDS = 0.05
QUICK_SESSION_AGENT_BUSY_RETRIES = int(
    QUICK_SESSION_AGENT_BUSY_TIMEOUT_SECONDS / QUICK_SESSION_AGENT_BUSY_RETRY_SECONDS
)


def _find_pane_id(value: Any) -> Optional[str]:
    if isinstance(value, dict):
        pane_id = value.get("pane_id")
        if isinstance(pane_id, (str, int)) and str(pane_id):
            return str(pane_id)
        for item in value.values():
            found = _find_pane_id(item)
            if found:
                return found
    elif isinstance(value, list):
        for item in value:
            found = _find_pane_id(item)
            if found:
                return found
    return None


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
        stars: Optional[StarStore] = None,
        panes_seen: Optional[PaneFirstSeenStore] = None,
        broker: Optional[EventBroker] = None,
        push: Optional[APNsManager] = None,
        environ: Optional[Mapping[str, str]] = None,
        tools: Optional[cmux_tools.CmuxToolsClient] = None,
        pi_semantic: Optional[PiSemanticManager] = None,
        response_audio_service: Optional[response_audio.ResponseAudioService] = None,
        cleanup: Optional[CleanupManager] = None,
        agent_runs: Optional[AgentRunManager] = None,
        active_work: Optional[ActiveWorkRepository] = None,
        agent_activity: Optional[AgentActivityManager] = None,
        remote_activity: Optional[RemoteActivityPoller] = None,
        result_artifact_store: Optional[result_artifacts.ResultArtifactStore] = None,
    ) -> None:
        production_environment = environ is None
        self.environ = dict(os.environ if production_environment else environ)
        self.client = client or HerdrClient(environ=self.environ)
        self.cmux_tools = tools or cmux_tools.CmuxToolsClient(environ=self.environ)
        alert_store_path = self.environ.get("HERDR_HARNESS_ALERT_STORE_PATH") or None
        self.alerts = alerts or AlertStore(store_path=alert_store_path)
        star_store_path = self.environ.get("HERDR_HARNESS_STAR_STORE_PATH") or None
        self.stars = stars or StarStore(store_path=star_store_path)
        pane_seen_store_path = self.environ.get("HERDR_HARNESS_PANE_SEEN_STORE_PATH") or None
        if pane_seen_store_path is None:
            home = self.environ.get("HOME")
            if home:
                pane_seen_store_path = str(
                    Path(home) / ".config" / "herdr-harness" / "pane-first-seen.json"
                )
        self.panes_seen = panes_seen or PaneFirstSeenStore(store_path=pane_seen_store_path)
        self.broker = broker or EventBroker()
        self._result_artifact_store = result_artifact_store
        self._result_artifact_store_lock = threading.Lock()
        self.push = push or APNsManager(environ=self.environ)
        self.pi_semantic = pi_semantic or PiSemanticManager(
            self.client.socket_path,
            environ=None if production_environment else self.environ,
            on_event=self._dispatch_pi_event,
        )
        self.response_audio = response_audio_service or response_audio.ResponseAudioService(self.environ)
        self.cleanup = cleanup or CleanupManager(self, environ=self.environ)
        active_work_store_path = self.environ.get("HERDR_HARNESS_ACTIVE_WORK_STORE_PATH")
        if not active_work_store_path:
            active_work_store_path = DEFAULT_ACTIVE_WORK_STORE_PATH if production_environment else ":memory:"
        self.active_work = active_work or ActiveWorkRepository(active_work_store_path, environ=self.environ)
        self._owns_active_work = active_work is None
        self.agent_activity = agent_activity or AgentActivityManager(
            self.active_work,
            self.broker,
            environ=None if production_environment else self.environ,
        )
        self.remote_activity = remote_activity or RemoteActivityPoller(
            lambda: set(self.active_work.active_pane_ids()),
            self.agent_activity.handle_event,
            environ=None if production_environment else self.environ,
        )
        # Agent runs are initialized lazily. Most harness requests do not need
        # a subprocess manager, and delaying creation avoids touching its
        # private persistence directory until the feature is actually used.
        self._agent_runs = agent_runs
        self._quick_voice = None
        self._quick_voice_recovery_enabled = production_environment or "HERDR_QUICK_VOICE_STORE_PATH" in self.environ
        self._quick_voice_lock = threading.Lock()
        self._lock = threading.RLock()
        self._quick_session_lock = threading.Lock()
        self._quick_session_results: dict[str, tuple[float, str, dict]] = {}
        self._quick_session_idempotency_ttl = _bounded_environment_int(
            self.environ,
            "HERDR_HARNESS_QUICK_SESSION_IDEMPOTENCY_TTL_SECONDS",
            QUICK_SESSION_IDEMPOTENCY_TTL_SECONDS,
            minimum=30,
            maximum=24 * 60 * 60,
        )
        self._quick_session_ready_timeout = _bounded_environment_int(
            self.environ,
            "HERDR_HARNESS_QUICK_SESSION_READY_TIMEOUT_MS",
            QUICK_SESSION_READY_TIMEOUT_MS,
            minimum=100,
            maximum=60_000,
        ) / 1000.0
        self._agent_promotion_lock = threading.Lock()
        self._snapshot: Optional[dict] = None
        self._snapshot_fingerprint: Optional[str] = None
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
        self._snapshot_debounce_seconds = _bounded_environment_int(
            self.environ,
            "HERDR_HARNESS_SNAPSHOT_DEBOUNCE_MS",
            int(SNAPSHOT_DEBOUNCE_SECONDS * 1000),
            minimum=0,
            maximum=2000,
        ) / 1000.0
        self._terminal_limit = _bounded_environment_int(
            self.environ,
            "HERDR_HARNESS_TERMINAL_MAX_STREAMS",
            16,
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
    def result_artifact_store(self) -> result_artifacts.ResultArtifactStore:
        """Lazily open private result storage only when the feature is used."""

        if self._result_artifact_store is None:
            with self._result_artifact_store_lock:
                if self._result_artifact_store is None:
                    self._result_artifact_store = result_artifacts.ResultArtifactStore(
                        environ=self.environ
                    )
        return self._result_artifact_store

    def create_result_artifact(
        self,
        *,
        origin_type: str,
        origin_id: str,
        session_id: Optional[str],
        kind: str,
        location: str,
        title: Optional[str],
        idempotency_key: Optional[str] = None,
    ) -> dict:
        artifact, created = self.result_artifact_store.create_with_status(
            origin_type=origin_type,
            origin_id=origin_id,
            session_id=session_id,
            kind=kind,
            location=location,
            title=title,
            idempotency_key=idempotency_key,
        )
        if created:
            self.broker.publish("result_artifact.created", artifact)
        return {"ok": True, "artifact": artifact}

    def list_result_artifacts(self) -> dict:
        return {"ok": True, "artifacts": self.result_artifact_store.list()}

    def open_result_artifact_content(
        self, artifact_id: str
    ) -> result_artifacts.ResultArtifactContent:
        return self.result_artifact_store.open_content(artifact_id)

    @staticmethod
    def _herd_pulse_state(
        snapshot: dict,
        *,
        connected: bool,
        acked_done_panes: frozenset[str] = frozenset(),
        lifecycle_by_pane: Optional[dict] = None,
        limit: int = 6,
    ) -> dict:
        workspaces = [item for item in snapshot.get("workspaces", []) if isinstance(item, dict)]
        panes = [item for item in snapshot.get("panes", []) if isinstance(item, dict)]
        working = sum(item.get("agent_status") == "working" for item in panes)
        attention = sum(item.get("agent_status") == "blocked" for item in panes)
        ready = sum(
            item.get("agent_status") == "done"
            and str(item.get("pane_id")) not in acked_done_panes
            for item in panes
        )
        lifecycle_by_pane = lifecycle_by_pane or {}
        candidates = []
        for pane in panes:
            pane_id = str(pane.get("pane_id"))
            status = pane.get("agent_status")
            if status not in {"blocked", "working"} and not (
                status == "done" and pane_id not in acked_done_panes
            ):
                continue
            lifecycle = lifecycle_by_pane.get(pane_id)
            lifecycle = lifecycle if isinstance(lifecycle, dict) else {}
            timestamp = lifecycle.get("workingSince" if status == "working" else "statusSinceAt")
            since = int(_parse_time(timestamp) or 0)
            agent_info = pane.get("agent_info") if isinstance(pane.get("agent_info"), dict) else {}
            agent = (
                agent_info.get("name")
                or agent_info.get("display_agent")
                or pane.get("display_agent")
                or agent_info.get("agent")
                or pane.get("agent")
                or "Agent"
            )
            title = (
                agent_info.get("title")
                or pane.get("title")
                or pane.get("label")
                or pane.get("terminal_title_stripped")
            )
            revision = pane.get("revision")
            try:
                revision_sort = float(revision) if not isinstance(revision, bool) else 0
            except (TypeError, ValueError):
                revision_sort = 0
            candidates.append(
                {
                    "id": pane_id,
                    "title": str(title or "")[:40],
                    "agent": str(agent)[:16],
                    "state": status,
                    "since": since,
                    "_revision": revision_sort,
                }
            )
        # Missing lifecycle data sorts as oldest (epoch 0), then stable pane ID.
        candidates.sort(
            key=lambda item: (
                {"blocked": 0, "done": 1, "working": 2}[item["state"]],
                item["since"] if item["state"] == "working" else -item["since"],
                -item["_revision"],
                item["id"],
            )
        )
        session_limit = max(0, int(limit))
        sessions = [
            {key: value for key, value in item.items() if key != "_revision"}
            for item in candidates[:session_limit]
        ]
        if not connected:
            phase = "offline"
            connection = "offline"
        elif attention:
            phase = "attention"
            connection = "live"
        elif ready:
            phase = "ready"
            connection = "live"
        elif working:
            phase = "working"
            connection = "live"
        else:
            phase = "resting"
            connection = "live"
        return {
            "workspaceCount": len(workspaces),
            "paneCount": len(panes),
            "workingCount": working,
            "attentionCount": attention,
            "readyCount": ready,
            "sessions": sessions,
            "sessionOverflow": max(0, len(candidates) - session_limit),
            "connection": connection,
            "phase": phase,
            "updatedAt": int(time.time()),
        }

    def _publish_herd_pulse(self, *, force: bool = False, activity_id: Optional[str] = None) -> bool:
        with self._lock:
            snapshot = copy.deepcopy(self._snapshot or {})
            connected = self._request_connected and self._events_connected
        content_state = self._herd_pulse_state(
            snapshot,
            connected=connected,
            acked_done_panes=self.alerts.acked_done_panes(),
            lifecycle_by_pane=self.panes_seen.lifecycle_map(),
        )
        return self.push.notify_herd_pulse_async(
            content_state,
            force=force,
            activity_id=activity_id,
            callback=lambda result: self.broker.publish("push.live_activity", result),
        )

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
            self.refresh_snapshot(force=True)
        except HerdrClientError:
            pass
        try:
            self.pi_semantic.start()
        except Exception as exc:
            try:
                self.pi_semantic.stop()
            except Exception:
                pass
            with self._lock:
                self._started = False
            raise HerdrClientError(
                "The Pi semantic bridge could not start",
                code="quick_session_not_ready",
            ) from exc
        try:
            self.agent_activity.start()
        except Exception:
            pass
        try:
            self.remote_activity.start()
        except Exception:
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
        if self._quick_voice_recovery_enabled:
            self.quick_voice.recover()

    def stop(self) -> None:
        if self._quick_voice is not None:
            self._quick_voice.stop()
        self._stop_event.set()
        self._refresh_event.set()
        self._restart_subscription.set()
        self.pi_semantic.stop()
        try:
            self.agent_activity.stop()
        except Exception:
            pass
        try:
            self.remote_activity.stop()
        except Exception:
            pass
        for thread in (
            self._event_thread,
            self._refresh_thread,
        ):
            if thread is not None and thread.is_alive():
                thread.join(timeout=2.0)
        with self._lock:
            self._started = False
        close_pi = getattr(self.pi_semantic, "close", None)
        if callable(close_pi):
            close_pi()
        if self._agent_runs is not None:
            stop_agent_runs = getattr(self._agent_runs, "stop", None)
            if callable(stop_agent_runs):
                stop_agent_runs()
        if self._owns_active_work:
            self.active_work.close()

    @property
    def agent_runs(self) -> AgentRunManager:
        with self._lock:
            if self._agent_runs is None:
                self._agent_runs = AgentRunManager(
                    environ=self.environ,
                    herdr_socket_path=self.client.socket_path,
                    herdr_session=self.client.session,
                )
            return self._agent_runs

    def _dispatch_pi_event(self, envelope: dict) -> None:
        self._publish_pi_event(envelope)
        try:
            self.agent_activity.handle_event(envelope)
        except Exception:
            pass

    def _publish_pi_event(self, envelope: dict) -> None:
        event = envelope.get("event") if isinstance(envelope, dict) else None
        event_type = str(event.get("type") or "event") if isinstance(event, dict) else "event"
        if event_type in GLOBAL_PI_EVENT_TYPES:
            self.broker.publish(f"pi.{event_type}", envelope)

    @staticmethod
    def _snapshot_fingerprint_for(snapshot: dict) -> str:
        """Fingerprint stable native state while ignoring transport timestamps."""

        stable = {key: value for key, value in snapshot.items() if key not in _VOLATILE_SNAPSHOT_KEYS}
        encoded = json.dumps(stable, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")
        return hashlib.sha1(encoded).hexdigest()

    def refresh_snapshot(self, *, force: bool = False) -> dict:
        try:
            snapshot = self.client.snapshot()
        except HerdrClientError as exc:
            with self._lock:
                self._request_connected = False
                self._last_error = str(exc)
            self._publish_herd_pulse()
            raise
        if not isinstance(snapshot, dict):
            raise HerdrClientError("Herdr returned an invalid snapshot", code="invalid_herdr_response")
        generated_at = utc_now()
        fingerprint = self._snapshot_fingerprint_for(snapshot)
        with self._lock:
            had_snapshot = self._snapshot is not None
            connection_recovered = not self._request_connected
            changed = force or not had_snapshot or fingerprint != self._snapshot_fingerprint
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
            self._snapshot_fingerprint = fingerprint
            self._generated_at = generated_at
            self._request_connected = True
            if self._events_connected:
                self._last_error = None
        self.pi_semantic.sync_snapshot(snapshot)
        if had_snapshot and previous_pane_ids != current_pane_ids:
            # Rebuild pane-specific status subscriptions only after the cache
            # contains the new topology.
            self._restart_subscription.set()
        emitted, resolved = self.alerts.observe_snapshot(snapshot, emit_initial=False)
        for alert in emitted:
            self._publish_alert(alert)
        if resolved:
            self._publish_read_state_changed()
        self.panes_seen.observe(snapshot.get("panes", []))
        if self.stars.prune(current_pane_ids):
            self.broker.publish(
                "stars.changed",
                {"paneId": None, "starred": False, "starredPaneIds": self.stars.list()},
            )
        self.panes_seen.prune(current_pane_ids)
        if changed:
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
        if changed or connection_recovered:
            self._publish_herd_pulse()
        return copy.deepcopy(snapshot)

    def _refresh_loop(self) -> None:
        while not self._stop_event.is_set():
            self._refresh_event.wait(1.0)
            if self._stop_event.is_set():
                return
            if not self._refresh_event.is_set():
                continue
            self._refresh_event.clear()
            first_set_at = time.monotonic()
            while not self._stop_event.is_set():
                remaining = SNAPSHOT_MAX_DELAY_SECONDS - (time.monotonic() - first_set_at)
                if remaining <= 0:
                    break
                if self._refresh_event.wait(min(self._snapshot_debounce_seconds, remaining)):
                    self._refresh_event.clear()
                    continue
                break
            if self._stop_event.is_set():
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
        self._publish_herd_pulse()

    def _lookup_pane(self, pane_id: str) -> Optional[dict]:
        with self._lock:
            snapshot = copy.deepcopy(self._snapshot or {})
        return pane_index(snapshot).get(pane_id)

    def _handle_event(self, envelope: dict) -> None:
        event_name = str(envelope.get("event") or "herdr.event")
        alert, resolved = self.alerts.observe_event(envelope, lookup=self._lookup_pane)
        self.broker.publish(event_name, envelope)
        if alert:
            self._publish_alert(alert)
        focus_changed: list[dict] = []
        if event_name == "pane.focused":
            data = envelope.get("data")
            pane_id = ""
            if isinstance(data, dict):
                pane_id = str(data.get("pane_id") or _find_pane_id(data) or "")
            if pane_id:
                focus_changed = self.alerts.mark_read_for_pane(pane_id)
        if resolved or focus_changed:
            self._publish_read_state_changed()
            self._publish_herd_pulse()
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
        return {
            "ok": True,
            "snapshot": self.pi_semantic.enrich_snapshot(snapshot),
            "generatedAt": generated_at,
        }

    def _project_acked_statuses(self, workspaces: list[dict]) -> list[dict]:
        """Apply HTTP-only pane state enrichments to composite workspace copies."""

        # Herdr's native terminal UI keeps ``done`` until focus. This read-model
        # projection is for HTTP-facing apps only and never changes the cache.
        acked_done_panes = self.alerts.acked_done_panes()
        lifecycle_by_pane = self.panes_seen.lifecycle_map()
        for workspace in workspaces:
            panes = workspace.get("panes")
            if not isinstance(panes, list):
                continue
            for pane in panes:
                if not isinstance(pane, dict):
                    continue
                pane_id = str(pane.get("pane_id"))
                if pane.get("agent_status") == "done" and pane_id in acked_done_panes:
                    pane["agent_status"] = "idle"
                lifecycle = lifecycle_by_pane.get(pane_id)
                if lifecycle is not None:
                    pane["first_seen_at"] = lifecycle.get("firstSeenAt")
                    pane["last_activity_at"] = lifecycle.get("lastActivityAt")
                    working_since = lifecycle.get("workingSince")
                    if working_since is not None:
                        pane["working_since"] = working_since

            for tab in workspace.get("tabs", []):
                if not isinstance(tab, dict) or tab.get("agent_status") != "done":
                    continue
                tab_id = tab.get("tab_id")
                tab_panes = [pane for pane in panes if pane.get("tab_id") == tab_id]
                for status in _STATUS_ROLLUP_PRECEDENCE:
                    if any(pane.get("agent_status") == status for pane in tab_panes):
                        tab["agent_status"] = status
                        break

            if workspace.get("agent_status") == "done":
                for status in _STATUS_ROLLUP_PRECEDENCE:
                    if any(pane.get("agent_status") == status for pane in panes):
                        workspace["agent_status"] = status
                        break
        return workspaces

    def workspaces_response(self) -> dict:
        snapshot, generated_at = self._cached_snapshot()
        workspaces = self._project_acked_statuses(composite_workspaces(snapshot))
        return {
            "ok": True,
            "workspaces": self.pi_semantic.enrich_workspaces(
                snapshot,
                workspaces,
            ),
            "alerts": self.alerts.list(limit=100),
            "starredPaneIds": self.stars.list(),
            "generatedAt": generated_at,
        }

    def pi_snapshot_response(self, pane_id: str) -> dict:
        return self.pi_semantic.snapshot_response(pane_id)

    @property
    def quick_voice(self) -> QuickVoiceManager:
        with self._quick_voice_lock:
            if self._quick_voice is None:
                root = Path(self.environ.get("HOME") or str(Path.home()))
                path = self.environ.get("HERDR_QUICK_VOICE_STORE_PATH") or root / ".config/herdr-harness/quick-voice"
                self._quick_voice = QuickVoiceManager(self, store_path=Path(path))
            return self._quick_voice

    def pi_command(self, pane_id: str, command: str, payload: Optional[dict] = None) -> dict:
        return self.pi_semantic.command(pane_id, command, payload)

    def response_audio_capabilities(self) -> dict:
        return self.response_audio.capabilities()

    def prepare_response_audio(self, *, action: str, text: str) -> dict:
        return self.response_audio.prepare(action=action, text=text)

    def synthesize_response_audio(self, *, text: str) -> dict:
        return self.response_audio.synthesize(text=text)

    def workspace_response(self, workspace_id: str) -> Optional[dict]:
        snapshot, generated_at = self._cached_snapshot()
        workspace_record = next(
            (
                item for item in snapshot.get("workspaces", [])
                if isinstance(item, dict) and item.get("workspace_id") == workspace_id
            ),
            None,
        )
        if workspace_record is None:
            return None
        filtered_snapshot = {**snapshot, "workspaces": [workspace_record]}
        workspace = self._project_acked_statuses(composite_workspaces(filtered_snapshot))[0]
        workspace = self.pi_semantic.enrich_workspaces(snapshot, [workspace])[0]
        return {
            "ok": True,
            "workspace": workspace,
            "alerts": [
                item
                for item in self.alerts.list(limit=100)
                if item.get("workspaceId") == workspace_id
            ],
            "generatedAt": generated_at,
        }

    def _workspace_tool_context(self, workspace_id: str) -> tuple[dict, Path]:
        response = self.workspace_response(workspace_id)
        if response is None:
            raise workspace_tools.WorkspaceToolError(
                "Workspace not found",
                code="workspace_not_found",
                status=404,
            )
        workspace = response["workspace"]
        root = workspace_tools.workspace_root(workspace)
        if root is None:
            raise workspace_tools.WorkspaceToolError(
                "Workspace has no available checkout or pane directory",
                code="workspace_root_not_found",
                status=404,
            )
        return workspace, root

    def _pane_tool_context(self, pane_id: str) -> tuple[dict, Path]:
        snapshot, _ = self._cached_snapshot()
        pane = pane_index(snapshot).get(pane_id)
        if pane is None:
            raise workspace_tools.WorkspaceToolError(
                "Pane not found",
                code="pane_not_found",
                status=404,
            )
        for key in ("foreground_cwd", "cwd"):
            value = pane.get(key)
            if not isinstance(value, str) or not value or "\x00" in value:
                continue
            try:
                root = Path(value).expanduser()
                if root.is_absolute():
                    root = root.resolve()
                    if root.is_dir():
                        return pane, root
            except (OSError, RuntimeError):
                continue
        raise workspace_tools.WorkspaceToolError(
            "Pane has no available foreground or terminal directory",
            code="pane_root_not_found",
            status=404,
        )

    @staticmethod
    def _tool_call(
        operation: Callable[..., _ToolResult],
        *args: Any,
        **kwargs: Any,
    ) -> _ToolResult:
        """Expose cmux transport failures through Herdr's existing error contract."""

        try:
            return operation(*args, **kwargs)
        except cmux_tools.CmuxToolsError as exc:
            raise workspace_tools.WorkspaceToolError(
                str(exc),
                code=exc.code,
                status=exc.status,
            ) from exc

    @staticmethod
    def _skill_items(value: Any, *, default_scope: Optional[str] = None) -> list[dict]:
        if not isinstance(value, list):
            return []
        items: list[dict] = []
        for raw in value:
            if not isinstance(raw, dict):
                continue
            name = raw.get("name")
            skill_path = raw.get("skillFilePath", raw.get("skill_file_path"))
            if not isinstance(name, str) or not isinstance(skill_path, str):
                continue
            scope = raw.get("scope")
            if not isinstance(scope, str) or not scope:
                scope = default_scope
            items.append(
                {
                    "name": name,
                    "skill_file_path": skill_path,
                    "scope": scope,
                }
            )
        return items

    @staticmethod
    def _jira_ticket(value: Any) -> Optional[dict]:
        if not isinstance(value, dict):
            return None
        return {
            "key": value.get("key"),
            "project_key": value.get("projectKey", value.get("project_key")),
            "title": value.get("title", ""),
            "status": value.get("status", ""),
            "priority": value.get("priority", ""),
            "issue_type": value.get("issueType", value.get("issue_type", "")),
            "url": value.get("url", ""),
        }

    @staticmethod
    def _github_review_request(value: Any) -> Optional[dict]:
        if not isinstance(value, dict):
            return None
        owner = value.get("owner")
        repo = value.get("repo")
        repository = "/".join(
            part for part in (owner, repo) if isinstance(part, str) and part
        )
        return {
            "number": value.get("number"),
            "title": value.get("title", ""),
            "url": value.get("url", ""),
            "is_draft": bool(value.get("isDraft", value.get("is_draft", False))),
            "state": value.get("state", ""),
            "author": value.get("author", ""),
            "repository": repository,
        }

    @staticmethod
    def _decode_attachment(data_base64: str) -> bytes:
        if not isinstance(data_base64, str) or not data_base64:
            raise attachments.AttachmentError("data_base64 is required")
        maximum_encoded = ((attachments.MAX_ATTACHMENT_BYTES + 2) // 3) * 4
        if len(data_base64) > maximum_encoded:
            raise attachments.AttachmentError(
                "file exceeds 20 MB limit",
                code="attachment_too_large",
                status=413,
            )
        try:
            data = base64.b64decode(data_base64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise attachments.AttachmentError(
                "data_base64 must be valid base64"
            ) from exc
        if not data:
            raise attachments.AttachmentError("file is empty")
        if len(data) > attachments.MAX_ATTACHMENT_BYTES:
            raise attachments.AttachmentError(
                "file exceeds 20 MB limit",
                code="attachment_too_large",
                status=413,
            )
        return data

    @staticmethod
    def _decode_voice_recording(data_base64: str) -> bytes:
        if not isinstance(data_base64, str) or not data_base64:
            raise voice.VoiceError("data_base64 is required")
        maximum_encoded = ((voice.MAX_VOICE_AUDIO_BYTES + 2) // 3) * 4
        if len(data_base64) > maximum_encoded:
            raise voice.VoiceError(
                "recording exceeds the 20 MB limit",
                code="voice_recording_too_large",
                status=413,
            )
        try:
            data = base64.b64decode(data_base64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise voice.VoiceError("data_base64 must be valid base64") from exc
        if not data:
            raise voice.VoiceError("recording is empty")
        if len(data) > voice.MAX_VOICE_AUDIO_BYTES:
            raise voice.VoiceError(
                "recording exceeds the 20 MB limit",
                code="voice_recording_too_large",
                status=413,
            )
        voice.validate_voice_wav(data)
        return data

    def workspace_git_status(self, workspace_id: str) -> dict:
        _, root = self._workspace_tool_context(workspace_id)
        payload = self._tool_call(self.cmux_tools.git_status, root)
        return {
            "ok": True,
            "workspace_id": workspace_id,
            "root_path": (
                payload.get("cwd")
                or payload.get("rootPath")
                or payload.get("root_path")
                or str(root)
            ),
            "branch": payload.get("branch"),
            "staged": payload.get("staged") if isinstance(payload.get("staged"), list) else [],
            "unstaged": (
                payload.get("unstaged") if isinstance(payload.get("unstaged"), list) else []
            ),
            "untracked": (
                payload.get("untracked") if isinstance(payload.get("untracked"), list) else []
            ),
            "commits": payload.get("commits") if isinstance(payload.get("commits"), list) else [],
            "generated_at": utc_now(),
        }

    def workspace_git_diff(self, workspace_id: str, *, file: str, section: str) -> dict:
        _, root = self._workspace_tool_context(workspace_id)
        payload = self._tool_call(self.cmux_tools.git_diff, root, file, section)
        return {
            "ok": True,
            "workspace_id": workspace_id,
            "file": payload.get("file", file),
            "section": payload.get("section", section),
            "diff": payload.get("diff", ""),
            "truncated": payload.get("truncated", False),
        }

    def workspace_git_stage(self, workspace_id: str, *, file: str) -> dict:
        _, root = self._workspace_tool_context(workspace_id)
        payload = self._tool_call(self.cmux_tools.git_stage, root, file)
        return {
            "ok": True,
            "workspace_id": workspace_id,
            "file": payload.get("file", file),
        }

    def workspace_git_unstage(self, workspace_id: str, *, file: str) -> dict:
        _, root = self._workspace_tool_context(workspace_id)
        payload = self._tool_call(self.cmux_tools.git_unstage, root, file)
        return {
            "ok": True,
            "workspace_id": workspace_id,
            "file": payload.get("file", file),
        }

    def pane_git_status(self, pane_id: str) -> dict:
        pane, root = self._pane_tool_context(pane_id)
        payload = self._tool_call(self.cmux_tools.git_status, root)
        return {
            "ok": True,
            "pane_id": pane_id,
            "workspace_id": pane.get("workspace_id"),
            "root_path": (
                payload.get("cwd")
                or payload.get("rootPath")
                or payload.get("root_path")
                or str(root)
            ),
            "branch": payload.get("branch"),
            "staged": payload.get("staged") if isinstance(payload.get("staged"), list) else [],
            "unstaged": (
                payload.get("unstaged") if isinstance(payload.get("unstaged"), list) else []
            ),
            "untracked": (
                payload.get("untracked") if isinstance(payload.get("untracked"), list) else []
            ),
            "commits": payload.get("commits") if isinstance(payload.get("commits"), list) else [],
            "generated_at": utc_now(),
        }

    def pane_git_diff(
        self,
        pane_id: str,
        *,
        file: str,
        section: str,
        expected_root: str,
    ) -> dict:
        _, root = self._pane_tool_context(pane_id)
        payload = self._tool_call(
            self.cmux_tools.git_diff,
            root,
            file,
            section,
            expected_root=expected_root,
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "file": payload.get("file", file),
            "section": payload.get("section", section),
            "diff": payload.get("diff", ""),
            "truncated": payload.get("truncated", False),
        }

    def pane_git_stage(self, pane_id: str, *, file: str, expected_root: str) -> dict:
        _, root = self._pane_tool_context(pane_id)
        payload = self._tool_call(
            self.cmux_tools.git_stage,
            root,
            file,
            expected_root=expected_root,
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "file": payload.get("file", file),
        }

    def pane_git_unstage(self, pane_id: str, *, file: str, expected_root: str) -> dict:
        _, root = self._pane_tool_context(pane_id)
        payload = self._tool_call(
            self.cmux_tools.git_unstage,
            root,
            file,
            expected_root=expected_root,
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "file": payload.get("file", file),
        }

    def pane_git_open(
        self,
        pane_id: str,
        *,
        file: str,
        expected_root: str,
        reveal: bool,
    ) -> dict:
        pane, root = self._pane_tool_context(pane_id)
        payload = self._tool_call(
            self.cmux_tools.git_open_file,
            root,
            file,
            reveal=reveal,
            expected_root=expected_root,
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "workspace_id": pane.get("workspace_id"),
            "file": payload.get("path", file),
            "absolute_path": payload.get("absolute_path"),
            "revealed": bool(payload.get("revealed", reveal)),
        }

    def pane_git_commit_files(
        self,
        pane_id: str,
        *,
        commit_hash: str,
        expected_root: str,
    ) -> dict:
        _, root = self._pane_tool_context(pane_id)
        payload = self._tool_call(
            self.cmux_tools.git_commit_files,
            root,
            commit_hash,
            expected_root=expected_root,
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "hash": payload.get("hash", commit_hash),
            "files": payload.get("files") if isinstance(payload.get("files"), list) else [],
        }

    def pane_git_commit_diff(
        self,
        pane_id: str,
        *,
        commit_hash: str,
        file: str,
        expected_root: str,
    ) -> dict:
        _, root = self._pane_tool_context(pane_id)
        payload = self._tool_call(
            self.cmux_tools.git_commit_diff,
            root,
            commit_hash,
            file,
            expected_root=expected_root,
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "hash": payload.get("hash", commit_hash),
            "file": payload.get("file", file),
            "diff": payload.get("diff", ""),
            "truncated": payload.get("truncated", False),
        }

    def workspace_skills(self, workspace_id: str) -> dict:
        _, root = self._workspace_tool_context(workspace_id)
        payload = self._tool_call(self.cmux_tools.skills, root)
        project_skills = self._skill_items(
            payload.get("projectSkills", payload.get("project_skills")),
            default_scope="project",
        )
        user_skills = self._skill_items(
            payload.get("userSkills", payload.get("user_skills")),
            default_scope="user",
        )
        all_skills = self._skill_items(payload.get("skills"))
        if not all_skills:
            all_skills = project_skills + user_skills
        return {
            "ok": True,
            "workspace_id": workspace_id,
            "root_path": payload.get("rootPath") or payload.get("root_path") or str(root),
            "skills_directory": payload.get(
                "skillsDirectory", payload.get("skills_directory")
            ),
            "user_skills_directory": payload.get(
                "userSkillsDirectory", payload.get("user_skills_directory")
            ),
            "project_skills": project_skills,
            "user_skills": user_skills,
            "skills": all_skills,
        }

    def workspace_file_search(self, workspace_id: str, *, query: str, limit: int) -> dict:
        _, root = self._workspace_tool_context(workspace_id)
        payload = self._tool_call(self.cmux_tools.search_files, root, query, limit)
        return {
            "ok": True,
            "workspace_id": workspace_id,
            "root_path": payload.get("rootPath") or payload.get("root_path") or str(root),
            "query": payload.get("query", query),
            "files": payload.get("files") if isinstance(payload.get("files"), list) else [],
            "truncated": payload.get("truncated", False),
            "limit": payload.get("limit", limit),
        }

    def workspace_attachment(
        self,
        workspace_id: str,
        *,
        filename: str,
        content_type: str,
        data_base64: str,
    ) -> dict:
        # Resolving the context first prevents uploads from inventing arbitrary
        # workspace identifiers or choosing their own cmux workspace index.
        _, root = self._workspace_tool_context(workspace_id)
        data = self._decode_attachment(data_base64)
        identity = self._tool_call(
            self.cmux_tools.attachment_workspace_identity,
            root,
        )
        payload = self._tool_call(
            self.cmux_tools.upload_attachment,
            workspace_uuid=identity["uuid"],
            workspace_index=identity["index"],
            filename=filename,
            content_type=content_type,
            data=data,
        )
        attachment = payload.get("attachment")
        if not isinstance(attachment, dict):
            raise workspace_tools.WorkspaceToolError(
                "cmux returned an invalid attachment response",
                code="cmux_invalid_response",
                status=502,
            )
        original_filename = attachment.get(
            "originalFilename", attachment.get("original_filename")
        )
        normalized_type = attachment.get(
            "contentType", attachment.get("content_type")
        )
        created_at = attachment.get("createdAt", attachment.get("created_at"))
        required_strings = (
            attachment.get("id"),
            attachment.get("filename"),
            original_filename,
            normalized_type,
            attachment.get("path"),
            created_at,
        )
        if (
            any(not isinstance(value, str) or not value for value in required_strings)
            or not isinstance(attachment.get("size"), int)
            or isinstance(attachment.get("size"), bool)
        ):
            raise workspace_tools.WorkspaceToolError(
                "cmux returned an invalid attachment response",
                code="cmux_invalid_response",
                status=502,
            )
        return {
            "ok": True,
            "attachment": {
                "id": attachment.get("id"),
                "filename": attachment.get("filename"),
                "original_filename": original_filename,
                "content_type": normalized_type,
                "size": attachment.get("size"),
                "path": attachment.get("path"),
                "workspace_id": workspace_id,
                "created_at": created_at,
            },
        }

    def jira_assigned(self, *, project: str, limit: int) -> dict:
        payload = self._tool_call(
            self.cmux_tools.jira_assigned,
            project=project or None,
            limit=limit,
        )
        raw_tickets = payload.get("tickets")
        tickets = [
            ticket
            for ticket in (
                self._jira_ticket(item)
                for item in (raw_tickets if isinstance(raw_tickets, list) else [])
            )
            if ticket is not None
        ]
        return {
            "ok": True,
            "project": payload.get("project"),
            "projects": payload.get("projects", []),
            "site": payload.get("site"),
            "tickets": tickets,
        }

    def work_inbox(self) -> dict:
        try:
            review_payload = self.cmux_tools.github_review_requests()
            raw_requests = review_payload.get("items")
            review_requests = [
                request
                for request in (
                    self._github_review_request(item)
                    for item in (raw_requests if isinstance(raw_requests, list) else [])
                )
                if request is not None
            ]
            review_section = {
                "ok": review_payload.get("ok") is True,
                "items": review_requests,
                "error": review_payload.get("error"),
            }
        except cmux_tools.CmuxToolsError as exc:
            review_section = {"ok": False, "items": [], "error": str(exc)}

        try:
            jira_payload = self.cmux_tools.jira_assigned(limit=100)
            raw_tickets = jira_payload.get("tickets")
            jira_tickets = [
                ticket
                for ticket in (
                    self._jira_ticket(item)
                    for item in (raw_tickets if isinstance(raw_tickets, list) else [])
                )
                if ticket is not None
            ]
            jira_section = {"ok": True, "items": jira_tickets, "error": None}
        except cmux_tools.CmuxToolsError as exc:
            jira_section = {"ok": False, "items": [], "error": str(exc)}

        return {
            "ok": True,
            "review_requests": review_section,
            "jira_tickets": jira_section,
        }

    def active_work_board(self) -> dict:
        """Return durable Active Work state with live, explicitly untracked Jira candidates.

        Jira is an enrichment source only. A Jira or cmux outage must not make
        the durable board unavailable, and merely observing a candidate never
        creates a work item.
        """

        candidates: list[dict] = []
        jira_status: dict[str, Any] = {"ok": True, "error": None}
        try:
            payload = self.cmux_tools.jira_assigned(limit=100)
            site = payload.get("site")
            raw_tickets = payload.get("tickets")
            for raw in raw_tickets if isinstance(raw_tickets, list) else []:
                ticket = self._jira_ticket(raw)
                if ticket is None:
                    continue
                if isinstance(site, str) and site.strip():
                    ticket["site"] = site.strip()
                candidates.append(ticket)
                # Refresh only an already-tracked link. This method is
                # intentionally incapable of creating work from observation.
                try:
                    self.active_work.refresh_tracked_jira(ticket)
                except ActiveWorkError:
                    # One malformed optional Jira candidate must not make the
                    # durable Active Work board unavailable.
                    continue
        except cmux_tools.CmuxToolsError as exc:
            jira_status = {"ok": False, "error": str(exc)}

        result = self.active_work.board_projection(candidates)
        result["jira_candidates_status"] = jira_status
        return result

    def active_work_item(self, item_id: str) -> dict:
        item = self.active_work.item_projection(item_id)
        if item is None:
            raise ActiveWorkError(
                "Active Work item not found",
                code="active_work_item_not_found",
                status=404,
            )
        return {"ok": True, "item": item, "generated_at": utc_now()}

    def list_active_work_workflows(self) -> dict:
        return {
            "ok": True,
            "workflows": self.active_work.list_workflows(),
            "generated_at": utc_now(),
        }

    def get_active_work_workflow(self, slug: str, *, version: Optional[int] = None) -> dict:
        workflow = self.active_work.get_workflow(slug, version)
        return {"ok": True, "workflow": workflow, "generated_at": utc_now()}

    def apply_active_work_workflow(self, payload: dict) -> dict:
        config = parse_workflow_config(payload)
        result = self.active_work.apply_workflow(config)
        return {"ok": True, **result, "generated_at": utc_now()}

    def create_active_work_item(self, payload: dict, *, actor: str = "user") -> dict:
        item = self.active_work.create_item(payload, actor=actor)
        self._publish_active_work_updated(item, change="created")
        return {"ok": True, "item": item, "generated_at": utc_now()}

    def patch_active_work_item(
        self,
        item_id: str,
        payload: dict,
        *,
        actor: str = "user",
    ) -> dict:
        item = self.active_work.patch_item(item_id, payload, actor=actor)
        self._publish_active_work_updated(item, change="patched")
        return {"ok": True, "item": item, "generated_at": utc_now()}

    def transition_active_work_item(
        self,
        item_id: str,
        payload: dict,
        *,
        actor: str = "user",
    ) -> dict:
        item = self.active_work.transition(item_id, payload, actor=actor)
        self._publish_active_work_updated(item, change="transitioned")
        return {"ok": True, "item": item, "generated_at": utc_now()}

    def patch_active_work_stage(
        self, item_id: str, stage_key: str, payload: dict, *, actor: str = "user"
    ) -> dict:
        item = self.active_work.patch_stage(item_id, stage_key, payload, actor=actor)
        self._publish_active_work_updated(item, change="stage_patched")
        return {"ok": True, "item": item, "generated_at": utc_now()}

    def setup_active_work_jira(self, issue_key: str, *, actor: str = "user") -> dict:
        """Set up one explicitly selected Jira issue without creating Buzz resources."""

        payload = self._tool_call(self.cmux_tools.jira_issue, issue_key)
        ticket = self._jira_ticket(payload.get("ticket"))
        if ticket is None:
            raise ActiveWorkError(
                "Jira returned an invalid issue",
                code="active_work_jira_invalid_response",
                status=502,
            )
        site = payload.get("site")
        if isinstance(site, str) and site.strip():
            ticket["site"] = site.strip()
        result = self.active_work.setup_jira(ticket, actor=actor)
        item = result["item"]
        self._publish_active_work_updated(
            item,
            change="jira_setup" if result["created"] else "jira_refreshed",
        )
        return {"ok": True, **result, "generated_at": utc_now()}

    def ingest_active_work(self, payload: dict, *, actor: Optional[str] = None) -> dict:
        source_name = str(payload.get("source") or "ingest") if isinstance(payload, dict) else "ingest"
        result = self.active_work.ingest(
            payload,
            actor=actor or f"ingest:{source_name[:64]}",
        )
        item = result.get("item")
        if result.get("applied") and isinstance(item, dict):
            self._publish_active_work_updated(item, change="ingested")
        return {"ok": True, **result, "generated_at": utc_now()}

    def active_work_sync_targets(self) -> dict:
        return self.active_work.sync_targets()

    def _publish_active_work_updated(self, item: dict, *, change: str) -> None:
        self.broker.publish(
            "active_work.updated",
            {
                "work_item_id": item.get("id"),
                "revision": item.get("revision"),
                "change": change,
                "generated_at": utc_now(),
            },
        )

    def jira_issue(self, *, query: str) -> dict:
        payload = self._tool_call(self.cmux_tools.jira_issue, query)
        return {
            "ok": True,
            "site": payload.get("site"),
            "ticket": self._jira_ticket(payload.get("ticket")),
        }

    def transcribe_voice(
        self,
        *,
        filename: str,
        mime_type: str,
        data_base64: str,
    ) -> dict:
        data = self._decode_voice_recording(data_base64)
        payload = self._tool_call(
            self.cmux_tools.transcribe_voice,
            filename=filename,
            mime_type=mime_type,
            data=data,
        )
        text = payload.get("text")
        backend = payload.get("backend")
        language = payload.get("language")
        if (
            not isinstance(text, str)
            or not text.strip()
            or len(text) > voice.MAX_TRANSCRIPT_CHARACTERS
            or not isinstance(backend, str)
            or not backend
            or len(backend) > 64
            or (language is not None and not isinstance(language, str))
        ):
            raise workspace_tools.WorkspaceToolError(
                "cmux returned an invalid transcription response",
                code="cmux_invalid_response",
                status=502,
            )
        return {
            "ok": True,
            "text": text.strip(),
            "backend": backend,
            "language": language,
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

    def _request_native(self, method: str, params: dict) -> Any:
        try:
            result = self.client.request(method, params)
        except HerdrClientError as exc:
            self._record_request_error(exc)
            raise
        self._record_request_success()
        return result

    def invoke(self, method: str, params: dict) -> dict:
        result = self._request_native(method, params)
        try:
            self.refresh_snapshot()
        except HerdrClientError:
            pass
        return {"ok": True, "result": result}

    def pi_extension_args(self) -> list[str]:
        override = self.environ.get("HERDR_HARNESS_PI_EXTENSION_PATH")
        path = (
            Path(override).expanduser()
            if override
            else Path(__file__).resolve().parent.parent / "pi-semantic-bridge"
        )
        return ["--extension", str(path)] if path.exists() else []

    def _server_home(self) -> Path:
        raw_home = self.environ.get("HOME")
        candidate = Path(raw_home) if raw_home else Path.home()
        try:
            resolved = candidate.expanduser().resolve()
        except (OSError, RuntimeError) as exc:
            raise HerdrClientError(
                "The harness home directory could not be resolved",
                code="invalid_cwd",
            ) from exc
        if not resolved.is_dir():
            raise HerdrClientError(
                "The harness home directory is unavailable",
                code="invalid_cwd",
            )
        return resolved

    @staticmethod
    def _canonical_directory(value: object) -> Optional[Path]:
        if not isinstance(value, str) or not value.strip() or "\x00" in value:
            return None
        try:
            candidate = Path(value).expanduser().resolve()
        except (OSError, RuntimeError):
            return None
        return candidate if candidate.is_dir() else None

    @classmethod
    def _workspace_cwd(cls, snapshot: dict, workspace: dict) -> Optional[Path]:
        """Resolve a workspace's canonical directory from authoritative state."""

        candidates: list[object] = [workspace.get("cwd")]
        worktree = workspace.get("worktree")
        if isinstance(worktree, dict):
            candidates.extend((worktree.get("checkout_path"), worktree.get("cwd")))
        workspace_id = str(workspace.get("workspace_id") or "")
        panes = [
            pane
            for pane in snapshot.get("panes", [])
            if isinstance(pane, dict) and str(pane.get("workspace_id") or "") == workspace_id
        ]
        panes.sort(key=lambda pane: not bool(pane.get("focused")))
        for pane in panes:
            candidates.extend((pane.get("foreground_cwd"), pane.get("cwd")))
        for candidate in candidates:
            resolved = cls._canonical_directory(candidate)
            if resolved is not None:
                return resolved
        return None

    @staticmethod
    def _quick_new_identifier(
        value: object,
        key: str,
        *,
        before_ids: set[str],
    ) -> Optional[str]:
        """Return one response ID only when it was absent before the create call.

        Native create responses can include the target object alongside the
        newly created object. Treating that target as the result can start Pi
        in, and later roll back, a pane that the quick-session request does not
        own. Multiple unseen IDs are likewise not enough to establish
        ownership; the topology-diff recovery path must disambiguate them.
        """

        candidates: list[str] = []

        def collect(item: object) -> None:
            if isinstance(item, dict):
                identifier = item.get(key)
                if isinstance(identifier, (str, int)):
                    normalized = str(identifier)
                    if (
                        normalized
                        and normalized not in before_ids
                        and normalized not in candidates
                    ):
                        candidates.append(normalized)
                for child in item.values():
                    collect(child)
            elif isinstance(item, list):
                for child in item:
                    collect(child)

        collect(value)
        return candidates[0] if len(candidates) == 1 else None

    @staticmethod
    def _quick_record_sort_key(item: dict, identifier_key: str) -> tuple[int, str]:
        try:
            number = int(item.get("number"))
        except (TypeError, ValueError):
            number = 2**31 - 1
        return number, str(item.get(identifier_key) or "")

    @classmethod
    def _quick_exact_workspace(cls, snapshot: dict, label: str) -> Optional[dict]:
        matches = [
            item
            for item in snapshot.get("workspaces", [])
            if isinstance(item, dict) and item.get("label") == label and item.get("workspace_id")
        ]
        return min(matches, key=lambda item: cls._quick_record_sort_key(item, "workspace_id"), default=None)

    @classmethod
    def _quick_exact_tab(cls, snapshot: dict, workspace_id: str, label: str) -> Optional[dict]:
        matches = [
            item
            for item in snapshot.get("tabs", [])
            if isinstance(item, dict)
            and str(item.get("workspace_id") or "") == workspace_id
            and item.get("label") == label
            and item.get("tab_id")
        ]
        return min(matches, key=lambda item: cls._quick_record_sort_key(item, "tab_id"), default=None)

    @classmethod
    def _quick_anchor_pane(cls, snapshot: dict, tab_id: str) -> Optional[dict]:
        matches = [
            item
            for item in snapshot.get("panes", [])
            if isinstance(item, dict)
            and str(item.get("tab_id") or "") == tab_id
            and item.get("pane_id")
        ]
        return min(
            matches,
            key=lambda item: (not bool(item.get("focused")), str(item.get("pane_id") or "")),
            default=None,
        )

    @staticmethod
    def _quick_unique_created_candidate(candidates: list[dict], object_name: str) -> Optional[dict]:
        if len(candidates) == 1:
            return candidates[0]
        if len(candidates) > 1:
            raise HerdrClientError(
                f"A concurrent topology change made the new {object_name} ambiguous",
                code="quick_session_placement_conflict",
            )
        return None

    def _quick_recovery_snapshot(self) -> dict:
        return self.refresh_snapshot(force=True)

    def _quick_created_workspace_ids(
        self,
        raw: object,
        *,
        before_workspace_ids: set[str],
        before_tab_ids: set[str],
        before_pane_ids: set[str],
        desired_label: str,
    ) -> tuple[str, str, str]:
        workspace_id = self._quick_new_identifier(
            raw,
            "workspace_id",
            before_ids=before_workspace_ids,
        )
        pane_id = self._quick_new_identifier(raw, "pane_id", before_ids=before_pane_ids)
        tab_id = self._quick_new_identifier(raw, "tab_id", before_ids=before_tab_ids)
        if isinstance(raw, dict):
            workspace = raw.get("workspace")
            if isinstance(workspace, dict):
                raw_workspace_id = str(workspace.get("workspace_id") or "")
                if raw_workspace_id and raw_workspace_id not in before_workspace_ids:
                    workspace_id = raw_workspace_id
                raw_tab_id = str(workspace.get("active_tab_id") or "")
                if raw_tab_id and raw_tab_id not in before_tab_ids:
                    tab_id = raw_tab_id
            pane = raw.get("pane") or raw.get("root_pane")
            if isinstance(pane, dict):
                raw_pane_id = str(pane.get("pane_id") or "")
                if raw_pane_id and raw_pane_id not in before_pane_ids:
                    pane_id = raw_pane_id
                raw_tab_id = str(pane.get("tab_id") or "")
                if raw_tab_id and raw_tab_id not in before_tab_ids:
                    tab_id = raw_tab_id

        if workspace_id and pane_id and tab_id:
            return workspace_id, tab_id, pane_id

        snapshot = self._quick_recovery_snapshot()
        if not workspace_id:
            candidates = [
                item
                for item in snapshot.get("workspaces", [])
                if isinstance(item, dict)
                and item.get("label") == desired_label
                and str(item.get("workspace_id") or "") not in before_workspace_ids
            ]
            selected = self._quick_unique_created_candidate(candidates, "workspace")
            if selected is not None:
                workspace_id = str(selected.get("workspace_id") or "") or None
                tab_id = str(selected.get("active_tab_id") or tab_id or "") or None
        if workspace_id and not pane_id:
            candidates = [
                item
                for item in snapshot.get("panes", [])
                if isinstance(item, dict)
                and str(item.get("workspace_id") or "") == workspace_id
                and (not tab_id or str(item.get("tab_id") or "") == tab_id)
                and str(item.get("pane_id") or "") not in before_pane_ids
            ]
            selected = self._quick_unique_created_candidate(candidates, "workspace pane")
            if selected is not None:
                pane_id = str(selected.get("pane_id") or "") or None
                tab_id = str(selected.get("tab_id") or tab_id or "") or None
        if workspace_id and not tab_id:
            workspace = next(
                (
                    item
                    for item in snapshot.get("workspaces", [])
                    if isinstance(item, dict) and str(item.get("workspace_id") or "") == workspace_id
                ),
                None,
            )
            if workspace is not None:
                tab_id = str(workspace.get("active_tab_id") or "") or None
        if not workspace_id or not pane_id or not tab_id:
            raise HerdrClientError(
                "workspace.create did not return a workspace, tab, and pane",
                code="invalid_herdr_response",
            )
        return workspace_id, tab_id, pane_id

    def _quick_created_tab_ids(
        self,
        raw: object,
        *,
        workspace_id: str,
        before_tab_ids: set[str],
        before_pane_ids: set[str],
    ) -> tuple[str, str]:
        tab_id = self._quick_new_identifier(raw, "tab_id", before_ids=before_tab_ids)
        pane_id = self._quick_new_identifier(raw, "pane_id", before_ids=before_pane_ids)
        if isinstance(raw, dict):
            tab = raw.get("tab")
            if isinstance(tab, dict):
                raw_tab_id = str(tab.get("tab_id") or "")
                if raw_tab_id and raw_tab_id not in before_tab_ids:
                    tab_id = raw_tab_id
                pane = tab.get("root_pane")
                if isinstance(pane, dict):
                    raw_pane_id = str(pane.get("pane_id") or "")
                    if raw_pane_id and raw_pane_id not in before_pane_ids:
                        pane_id = raw_pane_id
            pane = raw.get("pane") or raw.get("root_pane")
            if isinstance(pane, dict):
                raw_pane_id = str(pane.get("pane_id") or "")
                if raw_pane_id and raw_pane_id not in before_pane_ids:
                    pane_id = raw_pane_id
                raw_tab_id = str(pane.get("tab_id") or "")
                if raw_tab_id and raw_tab_id not in before_tab_ids:
                    tab_id = raw_tab_id

        if tab_id and pane_id:
            return tab_id, pane_id

        snapshot = self._quick_recovery_snapshot()
        if not tab_id:
            candidates = [
                item
                for item in snapshot.get("tabs", [])
                if isinstance(item, dict)
                and str(item.get("workspace_id") or "") == workspace_id
                and str(item.get("tab_id") or "") not in before_tab_ids
            ]
            selected = self._quick_unique_created_candidate(candidates, "tab")
            if selected is not None:
                tab_id = str(selected.get("tab_id") or "") or None
        if tab_id and not pane_id:
            candidates = [
                item
                for item in snapshot.get("panes", [])
                if isinstance(item, dict)
                and str(item.get("tab_id") or "") == tab_id
                and str(item.get("pane_id") or "") not in before_pane_ids
            ]
            selected = self._quick_unique_created_candidate(candidates, "tab pane")
            if selected is not None:
                pane_id = str(selected.get("pane_id") or "") or None
        if not tab_id or not pane_id:
            raise HerdrClientError(
                "tab.create did not return a tab and pane",
                code="invalid_herdr_response",
            )
        return tab_id, pane_id

    def _quick_split_pane_id(
        self,
        raw: object,
        *,
        tab_id: str,
        before_pane_ids: set[str],
    ) -> str:
        pane_id = self._quick_new_identifier(raw, "pane_id", before_ids=before_pane_ids)
        if pane_id:
            return pane_id
        snapshot = self._quick_recovery_snapshot()
        candidates = [
            item
            for item in snapshot.get("panes", [])
            if isinstance(item, dict)
            and str(item.get("tab_id") or "") == tab_id
            and str(item.get("pane_id") or "") not in before_pane_ids
        ]
        selected = self._quick_unique_created_candidate(candidates, "split pane")
        pane_id = str(selected.get("pane_id") or "") if selected is not None else ""
        if not pane_id:
            raise HerdrClientError(
                "pane.split did not return a pane",
                code="invalid_herdr_response",
            )
        return pane_id

    @staticmethod
    def _quick_pane_retry_state(
        snapshot: dict,
        *,
        pane_id: str,
        workspace_id: str,
        tab_id: str,
    ) -> str:
        pane = next(
            (
                item
                for item in snapshot.get("panes", [])
                if isinstance(item, dict) and str(item.get("pane_id") or "") == pane_id
            ),
            None,
        )
        if pane is None:
            return "missing"
        if (
            str(pane.get("workspace_id") or "") != workspace_id
            or str(pane.get("tab_id") or "") != tab_id
        ):
            return "conflict"
        if any(
            isinstance(item, dict) and str(item.get("pane_id") or "") == pane_id
            for item in snapshot.get("agents", [])
        ):
            return "conflict"
        if any(
            pane.get(key)
            for key in ("agent", "display_agent", "agent_session", "agent_info")
        ):
            return "conflict"
        return "ready"

    def _quick_cached_result(self, request_id: Optional[str], signature: str) -> Optional[dict]:
        if request_id is None:
            return None
        now = time.monotonic()
        self._quick_session_results = {
            key: value for key, value in self._quick_session_results.items() if value[0] > now
        }
        cached = self._quick_session_results.get(request_id)
        if cached is None:
            return None
        _, cached_signature, result = cached
        if cached_signature != signature:
            raise HerdrClientError(
                "requestId was already used for a different quick session request",
                code="quick_session_request_conflict",
            )
        return copy.deepcopy(result)

    def _quick_store_result(self, request_id: Optional[str], signature: str, result: dict) -> None:
        if request_id is None:
            return
        self._quick_session_results[request_id] = (
            time.monotonic() + self._quick_session_idempotency_ttl,
            signature,
            copy.deepcopy(result),
        )

    @staticmethod
    def _quick_session_file_id(session_path: Path) -> str:
        try:
            with session_path.open("rb") as handle:
                raw_header = handle.readline(64 * 1024 + 1)
        except OSError as exc:
            raise HerdrClientError(
                "Pi session file is unavailable",
                code="agent_run_session_missing",
            ) from exc
        if not raw_header or len(raw_header) > 64 * 1024 or not raw_header.endswith(b"\n"):
            raise HerdrClientError(
                "Pi session file has an invalid header",
                code="invalid_pi_session_file",
            )
        try:
            header = json.loads(raw_header.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise HerdrClientError(
                "Pi session file has an invalid header",
                code="invalid_pi_session_file",
            ) from exc
        actual_session_id = header.get("id") if isinstance(header, dict) else None
        if (
            not isinstance(header, dict)
            or header.get("type") != "session"
            or not isinstance(actual_session_id, str)
            or not actual_session_id
            or len(actual_session_id) > 256
            or "\x00" in actual_session_id
        ):
            raise HerdrClientError(
                "Pi session file has an invalid header",
                code="invalid_pi_session_file",
            )
        return actual_session_id

    def _quick_wait_for_pi_session(
        self, pane_id: str, expected_session_id: Optional[str] = None
    ) -> None:
        """Wait until the bridge is ready, and verify a resumed session when requested."""

        # ``start`` is idempotent. Calling it here also makes direct service use
        # honor the same readiness contract as the long-running HTTP server.
        try:
            self.pi_semantic.start()
        except Exception as exc:
            raise HerdrClientError(
                "The new Pi pane could not start its semantic bridge",
                code="quick_session_not_ready",
            ) from exc
        deadline = time.monotonic() + self._quick_session_ready_timeout
        last_session_id: Optional[str] = None
        while True:
            try:
                self.refresh_snapshot(force=True)
            except HerdrClientError:
                pass
            except Exception as exc:
                raise HerdrClientError(
                    "The new Pi pane could not be verified",
                    code="quick_session_not_ready",
                ) from exc
            try:
                capability = self.pi_semantic.capability(pane_id)
            except PiSemanticError:
                capability = {}
            except Exception as exc:
                raise HerdrClientError(
                    "The new Pi pane could not be verified",
                    code="quick_session_not_ready",
                ) from exc
            if not isinstance(capability, dict):
                capability = {}
            observed = capability.get("session_id") if isinstance(capability, dict) else None
            last_session_id = str(observed) if isinstance(observed, str) and observed else None
            if capability.get("connected") is True:
                if expected_session_id is None:
                    return
                if last_session_id == expected_session_id:
                    return
                if last_session_id is not None:
                    raise HerdrClientError(
                        "The new Pi pane resumed a different session",
                        code="quick_session_identity_mismatch",
                    )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                detail = (
                    "The new Pi pane did not connect its semantic bridge"
                    if last_session_id is None
                    else "The new Pi pane did not confirm the requested session"
                )
                raise HerdrClientError(detail, code="quick_session_not_ready")
            time.sleep(min(0.05, remaining))

    def quick_pi_session(
        self,
        label: str,
        *,
        workspace_id: Optional[str] = None,
        tab_id: Optional[str] = None,
        cwd: Optional[str] = None,
        session_file: Optional[str] = None,
        session_id: Optional[str] = None,
        request_id: Optional[str] = None,
        workspace_label: Optional[str] = None,
        tab_label: Optional[str] = None,
        reuse_named_tab: bool = True,
        focus: bool = True,
        model: Optional[dict] = None,
        thinking_level: Optional[str] = None,
    ) -> dict:
        """Create an interactive Pi pane, optionally resuming an exact session."""

        with self._quick_session_lock:
            if model is not None and (
                not isinstance(model, dict) or set(model) != {"provider", "id"}
                or any(not isinstance(value, str) or not value.strip() or len(value) > 256 or "\x00" in value for value in model.values())
            ):
                raise HerdrClientError("model requires provider and id", code="invalid_agent_model")
            if thinking_level is not None and (not isinstance(thinking_level, str) or thinking_level not in THINKING_LEVELS):
                raise HerdrClientError("thinkingLevel is invalid", code="invalid_agent_thinking_level")
            if request_id is not None and (
                not isinstance(request_id, str) or not request_id or len(request_id) > 128
            ):
                raise HerdrClientError("requestId is invalid", code="invalid_request_id")
            signature = json.dumps(
                {
                    "label": label,
                    "workspace_id": workspace_id,
                    "tab_id": tab_id,
                    "cwd": cwd,
                    "session_file": session_file,
                    "session_id": session_id,
                    "workspace_label": workspace_label,
                    "tab_label": tab_label,
                    "reuse_named_tab": reuse_named_tab,
                    "focus": focus,
                    "model": model,
                    "thinking_level": thinking_level,
                },
                sort_keys=True,
                separators=(",", ":"),
                default=str,
            )
            cached = self._quick_cached_result(request_id, signature)
            if cached is not None:
                return cached

            if session_id is not None and (
                not isinstance(session_id, str)
                or not session_id
                or len(session_id) > 256
                or "\x00" in session_id
            ):
                raise HerdrClientError("sessionId is invalid", code="invalid_session_id")
            if session_id is not None and session_file is None:
                raise HerdrClientError(
                    "sessionId requires sessionFile",
                    code="session_file_required",
                )

            snapshot = self.refresh_snapshot(force=True)
            requested_cwd = self._canonical_directory(cwd) if cwd is not None else None
            if cwd is not None and requested_cwd is None:
                raise HerdrClientError(
                    "cwd must be an existing directory",
                    code="invalid_cwd",
                )
            extension_args = self.pi_extension_args()
            pi_extension_attached = bool(extension_args)
            agent_args = list(extension_args)
            expected_session_id: Optional[str] = None
            if session_file is not None:
                try:
                    session_path = Path(session_file).expanduser().resolve()
                except (OSError, RuntimeError) as exc:
                    raise HerdrClientError(
                        "Pi session file is unavailable",
                        code="agent_run_session_missing",
                    ) from exc
                if not session_path.is_file():
                    raise HerdrClientError(
                        "Pi session file is unavailable",
                        code="agent_run_session_missing",
                    )
                expected_session_id = self._quick_session_file_id(session_path)
                if session_id is not None and session_id != expected_session_id:
                    raise HerdrClientError(
                        "sessionId does not match the Pi session file",
                        code="quick_session_identity_mismatch",
                    )
                session_id = expected_session_id
                agent_args = ["--session", str(session_path), *extension_args]

            # CLI overrides apply to this session without Pi's set_model RPC
            # changing the user's global default for unrelated future chats.
            if model is not None:
                agent_args.extend(["--provider", model["provider"], "--model", model["id"]])
            if thinking_level is not None:
                agent_args.extend(["--thinking", thinking_level])

            workspaces = [
                item for item in snapshot.get("workspaces", []) if isinstance(item, dict)
            ]
            tabs = [item for item in snapshot.get("tabs", []) if isinstance(item, dict)]
            existing_workspace: Optional[dict] = None
            existing_tab: Optional[dict] = None
            explicit_destination = workspace_id is not None or tab_id is not None

            if tab_id is not None:
                existing_tab = next(
                    (item for item in tabs if str(item.get("tab_id") or "") == tab_id),
                    None,
                )
                if existing_tab is None:
                    raise HerdrClientError("Tab not found", code="tab_not_found")
                tab_workspace_id = str(existing_tab.get("workspace_id") or "")
                if workspace_id is not None and workspace_id != tab_workspace_id:
                    raise HerdrClientError(
                        "Tab does not belong to the requested workspace",
                        code="quick_session_target_conflict",
                    )
                workspace_id = tab_workspace_id

            if workspace_id is not None:
                existing_workspace = next(
                    (
                        item
                        for item in workspaces
                        if str(item.get("workspace_id") or "") == workspace_id
                    ),
                    None,
                )
                if existing_workspace is None:
                    raise HerdrClientError(
                        "Workspace not found",
                        code="workspace_not_found",
                    )
            else:
                desired_workspace_label = workspace_label or QUICK_PI_WORKSPACE_LABEL
                if reuse_named_tab:
                    existing_workspace = self._quick_exact_workspace(snapshot, desired_workspace_label)
                else:
                    home = self._server_home() if requested_cwd is None else None
                    target_cwd = requested_cwd or home
                    assert target_cwd is not None
                    if home is not None and target_cwd == home:
                        existing_workspace = next(
                            (
                                item
                                for item in workspaces
                                if str(item.get("label") or "").strip().casefold()
                                == desired_workspace_label.strip().casefold()
                                and self._workspace_cwd(snapshot, item) == home
                            ),
                            None,
                        )

            if existing_workspace is not None:
                workspace_id = str(existing_workspace.get("workspace_id") or "")
            if reuse_named_tab and existing_workspace is not None and existing_tab is None:
                existing_tab = self._quick_exact_tab(
                    snapshot,
                    str(existing_workspace.get("workspace_id") or ""),
                    tab_label or QUICK_PI_TAB_LABEL,
                )

            if requested_cwd is not None:
                target_cwd = requested_cwd
            elif existing_workspace is not None and (explicit_destination or not reuse_named_tab):
                target_cwd = self._workspace_cwd(snapshot, existing_workspace) or self._server_home()
            else:
                target_cwd = self._server_home()

            created_workspace = False
            created_tab = False
            cleanup_method: Optional[str] = None
            cleanup_params: Optional[dict] = None
            try:
                if existing_workspace is None:
                    desired_workspace_label = workspace_label or QUICK_PI_WORKSPACE_LABEL
                    before_workspace_ids = {
                        str(item.get("workspace_id"))
                        for item in snapshot.get("workspaces", [])
                        if isinstance(item, dict) and item.get("workspace_id")
                    }
                    before_tab_ids = {
                        str(item.get("tab_id"))
                        for item in snapshot.get("tabs", [])
                        if isinstance(item, dict) and item.get("tab_id")
                    }
                    before_pane_ids = {
                        str(item.get("pane_id"))
                        for item in snapshot.get("panes", [])
                        if isinstance(item, dict) and item.get("pane_id")
                    }
                    raw = self._request_native(
                        "workspace.create",
                        {"label": desired_workspace_label, "cwd": str(target_cwd), "focus": focus},
                    )
                    provisional_workspace_id = self._quick_new_identifier(
                        raw,
                        "workspace_id",
                        before_ids=before_workspace_ids,
                    )
                    if provisional_workspace_id:
                        cleanup_method = "workspace.close"
                        cleanup_params = {"workspace_id": provisional_workspace_id}
                    workspace_id, resolved_tab_id, pane_id = self._quick_created_workspace_ids(
                        raw,
                        before_workspace_ids=before_workspace_ids,
                        before_tab_ids=before_tab_ids,
                        before_pane_ids=before_pane_ids,
                        desired_label=desired_workspace_label,
                    )
                    tab_id = resolved_tab_id
                    created_workspace = True
                    created_tab = True
                    cleanup_method = "workspace.close"
                    cleanup_params = {"workspace_id": workspace_id}
                    if reuse_named_tab or tab_label is not None:
                        self._request_native(
                            "tab.rename",
                            {"tab_id": tab_id, "label": tab_label or QUICK_PI_TAB_LABEL},
                        )
                elif existing_tab is not None:
                    tab_id = str(existing_tab.get("tab_id") or "")
                    anchor = self._quick_anchor_pane(snapshot, tab_id)
                    if anchor is None:
                        snapshot = self._quick_recovery_snapshot()
                        anchor = self._quick_anchor_pane(snapshot, tab_id)
                    if anchor is None:
                        raise HerdrClientError(
                            "The target tab has no pane to split",
                            code="target_tab_unusable",
                        )
                    before_pane_ids = {
                        str(item.get("pane_id"))
                        for item in snapshot.get("panes", [])
                        if isinstance(item, dict) and item.get("pane_id")
                    }
                    raw = self._request_native(
                        "pane.split",
                        {
                            "target_pane_id": str(anchor["pane_id"]),
                            "direction": "right",
                            "cwd": str(target_cwd),
                            "focus": focus,
                        },
                    )
                    provisional_pane_id = self._quick_new_identifier(
                        raw,
                        "pane_id",
                        before_ids=before_pane_ids,
                    )
                    if provisional_pane_id:
                        cleanup_method = "pane.close"
                        cleanup_params = {"pane_id": provisional_pane_id}
                    pane_id = self._quick_split_pane_id(
                        raw,
                        tab_id=tab_id,
                        before_pane_ids=before_pane_ids,
                    )
                    cleanup_method = "pane.close"
                    cleanup_params = {"pane_id": pane_id}
                else:
                    workspace_id = str(existing_workspace["workspace_id"])
                    before_tab_ids = {
                        str(item.get("tab_id"))
                        for item in snapshot.get("tabs", [])
                        if isinstance(item, dict) and item.get("tab_id")
                    }
                    before_pane_ids = {
                        str(item.get("pane_id"))
                        for item in snapshot.get("panes", [])
                        if isinstance(item, dict) and item.get("pane_id")
                    }
                    params: dict[str, object] = {
                        "workspace_id": workspace_id,
                        "cwd": str(target_cwd),
                        "focus": focus,
                    }
                    if reuse_named_tab or tab_label is not None:
                        params["label"] = tab_label or QUICK_PI_TAB_LABEL
                    raw = self._request_native("tab.create", params)
                    provisional_tab_id = self._quick_new_identifier(
                        raw,
                        "tab_id",
                        before_ids=before_tab_ids,
                    )
                    if provisional_tab_id:
                        cleanup_method = "tab.close"
                        cleanup_params = {"tab_id": provisional_tab_id}
                    tab_id, pane_id = self._quick_created_tab_ids(
                        raw,
                        workspace_id=workspace_id,
                        before_tab_ids=before_tab_ids,
                        before_pane_ids=before_pane_ids,
                    )
                    created_tab = True
                    cleanup_method = "tab.close"
                    cleanup_params = {"tab_id": tab_id}

                name = "quick-pi-" + uuid.uuid4().hex[:8]
                start_params = {
                    "pane_id": pane_id,
                    "name": name,
                    "kind": "pi",
                    "args": agent_args,
                    "timeout_ms": 30000,
                }
                busy_deadline = time.monotonic() + QUICK_SESSION_AGENT_BUSY_TIMEOUT_SECONDS
                busy_waits = 0
                for attempt in range(QUICK_SESSION_AGENT_BUSY_RETRIES + 1):
                    try:
                        self._request_native("agent.start", start_params)
                        break
                    except HerdrClientError as exc:
                        if exc.code != "agent_pane_busy":
                            raise
                        while True:
                            try:
                                retry_snapshot = self._quick_recovery_snapshot()
                            except Exception as verification_error:
                                cleanup_method = None
                                cleanup_params = None
                                raise HerdrClientError(
                                    "The new pane could not be verified after Pi reported it busy",
                                    code="quick_session_outcome_unknown",
                                ) from verification_error
                            retry_state = self._quick_pane_retry_state(
                                retry_snapshot,
                                pane_id=pane_id,
                                workspace_id=str(workspace_id),
                                tab_id=str(tab_id),
                            )
                            if retry_state == "ready":
                                break
                            if retry_state == "conflict":
                                cleanup_method = None
                                cleanup_params = None
                                raise HerdrClientError(
                                    "The new pane was claimed or moved before Pi could start",
                                    code="quick_session_placement_conflict",
                                ) from exc
                            remaining = busy_deadline - time.monotonic()
                            if (
                                busy_waits >= QUICK_SESSION_AGENT_BUSY_RETRIES
                                or remaining <= 0
                            ):
                                cleanup_method = None
                                cleanup_params = None
                                raise HerdrClientError(
                                    "The new pane disappeared before Pi could start",
                                    code="quick_session_placement_conflict",
                                ) from exc
                            time.sleep(min(QUICK_SESSION_AGENT_BUSY_RETRY_SECONDS, remaining))
                            busy_waits += 1
                        if attempt >= QUICK_SESSION_AGENT_BUSY_RETRIES:
                            raise
                        remaining = busy_deadline - time.monotonic()
                        if busy_waits >= QUICK_SESSION_AGENT_BUSY_RETRIES or remaining <= 0:
                            raise
                        time.sleep(min(QUICK_SESSION_AGENT_BUSY_RETRY_SECONDS, remaining))
                        busy_waits += 1
                if expected_session_id is not None:
                    self._quick_wait_for_pi_session(pane_id, expected_session_id)
                    pi_semantic_ready = True
                elif pi_extension_attached:
                    try:
                        self._quick_wait_for_pi_session(pane_id, None)
                        pi_semantic_ready = True
                    except HerdrClientError as exc:
                        if exc.code != "quick_session_not_ready":
                            raise
                        pi_semantic_ready = False
                else:
                    pi_semantic_ready = False
            except Exception as original_error:
                cleanup_error: Optional[Exception] = None
                try:
                    if cleanup_method is not None and cleanup_params is not None:
                        self._request_native(cleanup_method, cleanup_params)
                except Exception as exc:
                    cleanup_error = exc
                try:
                    self.refresh_snapshot(force=True)
                except Exception:
                    pass
                if cleanup_error is not None:
                    raise HerdrClientError(
                        "The failed quick session could not be confirmed closed; "
                        "check Herdr before resuming the original Pi session",
                        code="quick_session_outcome_unknown",
                    ) from original_error
                raise
            try:
                self._request_native("pane.rename", {"pane_id": pane_id, "label": label})
            except HerdrClientError:
                pass
            try:
                self.refresh_snapshot(force=True)
            except HerdrClientError:
                pass
            result = {
                "ok": True,
                "workspace_id": workspace_id,
                "tab_id": tab_id,
                "pane_id": pane_id,
                "created_workspace": created_workspace,
                "created_tab": created_tab,
                "created_pane": True,
                "pi_extension_attached": pi_extension_attached,
                "pi_semantic_ready": pi_semantic_ready,
                "request_id": request_id,
                "session_id": session_id,
            }
            self._quick_store_result(request_id, signature, result)
            return result

    def _agent_topology(self) -> dict:
        snapshot, generated_at = self._cached_snapshot()
        lifecycle_by_pane = self.panes_seen.lifecycle_map()
        workspace_values = [
            item for item in snapshot.get("workspaces", []) if isinstance(item, dict)
        ][:40]
        pane_values = [item for item in snapshot.get("panes", []) if isinstance(item, dict)][:200]
        agent_by_pane = {
            str(item.get("pane_id")): item
            for item in snapshot.get("agents", [])
            if isinstance(item, dict) and item.get("pane_id")
        }
        topology = {
            "generatedAt": generated_at,
            "machine": {
                "hostname": socket.gethostname(),
                "herdrSession": self.client.session,
            },
            "focusedWorkspaceId": snapshot.get("focused_workspace_id"),
            "focusedPaneId": snapshot.get("focused_pane_id"),
            "workspaces": [
                {
                    "id": item.get("workspace_id"),
                    "label": str(item.get("label") or "")[:240],
                    "status": item.get("agent_status"),
                    "cwd": str(self._workspace_cwd(snapshot, item) or "")[:4096],
                }
                for item in workspace_values
            ],
            "panes": [
                {
                    "id": item.get("pane_id"),
                    "workspaceId": item.get("workspace_id"),
                    "tabId": item.get("tab_id"),
                    "title": str(
                        item.get("label")
                        or item.get("title")
                        or item.get("terminal_title_stripped")
                        or ""
                    )[:500],
                    "status": item.get("agent_status"),
                    "agent": str(
                        item.get("agent")
                        or agent_by_pane.get(str(item.get("pane_id")), {}).get("agent")
                        or ""
                    )[:120],
                    "cwd": str(item.get("foreground_cwd") or item.get("cwd") or "")[:4096],
                    "revision": item.get("revision"),
                    "firstSeenAt": lifecycle_by_pane.get(
                        str(item.get("pane_id")), {}
                    ).get("firstSeenAt"),
                    "lastActivityAt": lifecycle_by_pane.get(
                        str(item.get("pane_id")), {}
                    ).get("lastActivityAt"),
                    "workingSince": lifecycle_by_pane.get(
                        str(item.get("pane_id")), {}
                    ).get("workingSince"),
                }
                for item in pane_values
            ],
            "truncated": {
                "workspaces": len(snapshot.get("workspaces", [])) > len(workspace_values),
                "panes": len(snapshot.get("panes", [])) > len(pane_values),
            },
        }
        # Keep the private context file bounded even if native fields contain
        # unusually long or non-string values.
        while len(json.dumps(topology, default=str).encode("utf-8")) > 64 * 1024:
            if topology["panes"]:
                topology["panes"].pop()
                topology["truncated"]["panes"] = True
            elif topology["workspaces"]:
                topology["workspaces"].pop()
                topology["truncated"]["workspaces"] = True
            else:
                break
        return topology

    def start_agent_run(
        self,
        *,
        prompt: str,
        label: Optional[str] = None,
        mode: str = "ask",
        model: Optional[str] = None,
        thinking_level: Optional[str] = None,
        attachments: Optional[list] = None,
        system_prompt: Optional[str] = None,
        continue_from_run_id: Optional[str] = None,
        pane_id: Optional[str] = None,
    ) -> dict:
        display_label = (label or prompt.splitlines()[0].strip() or "One-off Agent")[:120]
        try:
            self.refresh_snapshot()
        except HerdrClientError:
            # A recent cached fleet summary is still useful during a brief
            # Herdr reconnect. _agent_topology will retry if no cache exists.
            pass
        # Inline surfaces (such as the Git workbench) scope the agent to the
        # pane's working directory instead of the server home.
        cwd = str(self._server_home())
        if pane_id is not None:
            _, pane_root = self._pane_tool_context(pane_id)
            cwd = str(pane_root)
        return self.agent_runs.start(
            prompt=prompt,
            label=display_label,
            cwd=cwd,
            topology=self._agent_topology(),
            mode=mode,
            model=model,
            thinking_level=thinking_level,
            attachments=attachments,
            system_prompt=system_prompt,
            continue_from_run_id=continue_from_run_id,
        )

    def get_agent_run(self, run_id: str) -> dict:
        return self.agent_runs.get(run_id)

    def list_agent_models(self) -> dict:
        return self.agent_runs.list_models()

    def agent_prompt_defaults(self) -> dict:
        return {
            "ok": True,
            "prompts": {
                "act": ACT_CHARTER,
                "ask": ASK_CHARTER,
                "cleanupJudge": DEFAULT_JUDGE_CHARTER,
            },
        }

    def cancel_agent_run(self, run_id: str) -> dict:
        return self.agent_runs.cancel(run_id)

    def promote_agent_run(
        self,
        run_id: str,
        *,
        workspace_id: Optional[str] = None,
        cwd: Optional[str] = None,
        workspace_label: Optional[str] = None,
    ) -> dict:
        with self._agent_promotion_lock:
            run, session_file = self.agent_runs.promotable(run_id)
            if run.get("status") == "promoted":
                return self.agent_runs.get(run_id)
            try:
                result = self.quick_pi_session(
                    str(run.get("label") or "Agent chat")[:120],
                    workspace_id=workspace_id,
                    cwd=cwd,
                    session_file=session_file,
                    workspace_label=workspace_label or "Agent chats",
                    reuse_named_tab=False,
                )
            except Exception:
                try:
                    self.agent_runs.release_promotion(run_id)
                except (AgentRunError, OSError):
                    pass
                raise
            return self.agent_runs.mark_promoted(
                run_id,
                workspace_id=str(result["workspace_id"]),
                pane_id=str(result["pane_id"]),
            )

    def delete_agent_run(self, run_id: str) -> dict:
        return self.agent_runs.delete(run_id)

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
            self._publish_read_state_changed()
            return {"ok": True, "alert": alert, "unreadCount": self.alerts.unread_count()}
        return None

    def mark_all_alerts_read(self) -> dict:
        changed = self.alerts.mark_all_read()
        if changed:
            self._publish_read_state_changed()
        return {"ok": True, "alerts": changed, "unreadCount": self.alerts.unread_count()}

    def mark_pane_alerts_read(self, pane_id: str) -> Optional[dict]:
        if self._lookup_pane(pane_id) is None:
            return None
        was_acked = pane_id in self.alerts.acked_done_panes()
        changed = self.alerts.mark_read_for_pane(pane_id)
        is_acked = pane_id in self.alerts.acked_done_panes()
        if changed or (not was_acked and is_acked):
            self._publish_read_state_changed()
            self._publish_herd_pulse()
        return {
            "ok": True,
            "paneId": pane_id,
            "alerts": changed,
            "unreadCount": self.alerts.unread_count(),
        }

    def _publish_read_state_changed(self) -> None:
        self.broker.publish(
            "alerts.read_state_changed",
            {"unread_count": self.alerts.unread_count()},
        )

    def set_pane_star(self, pane_id: str, starred: bool) -> Optional[dict]:
        if self._lookup_pane(pane_id) is None:
            return None
        changed = self.stars.set(pane_id, starred)
        if changed:
            self.broker.publish(
                "stars.changed",
                {"paneId": pane_id, "starred": starred, "starredPaneIds": self.stars.list()},
            )
        return {
            "ok": True,
            "paneId": pane_id,
            "starred": starred,
            "starredPaneIds": self.stars.list(),
            "generatedAt": utc_now(),
        }

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

    def register_live_activity(
        self,
        push_token: str,
        *,
        activity_id: str,
        bundle_id: str,
        environment: str,
        reveal_session_titles: bool = True,
    ) -> dict:
        result = self.push.register_live_activity(
            push_token,
            activity_id=activity_id,
            bundle_id=bundle_id,
            environment=environment,
            reveal_session_titles=reveal_session_titles,
        )
        self._publish_herd_pulse(force=True, activity_id=activity_id)
        return result

    def unregister_live_activity(
        self,
        activity_id: str,
        *,
        push_token: Optional[str] = None,
    ) -> dict:
        return self.push.unregister_live_activity(
            activity_id,
            push_token=push_token,
        )

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
                connection_changed = self._request_connected
                self._request_connected = False
                self._last_error = str(exc)
            if connection_changed:
                self._publish_herd_pulse()

    def _record_request_success(self) -> None:
        with self._lock:
            connection_changed = not self._request_connected
            self._request_connected = True
            if self._events_connected:
                self._last_error = None
        if connection_changed:
            self._publish_herd_pulse()
