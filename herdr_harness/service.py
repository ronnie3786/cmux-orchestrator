"""Stateful Herdr adapter used by the HTTP API."""

from __future__ import annotations

import base64
import binascii
import copy
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, TypeVar

from .alerts import AlertStore, utc_now
from . import attachments, cmux_tools, voice, workspace_tools
from .client import DEFAULT_SUBSCRIPTIONS, HerdrClient, HerdrClientError
from .cleanup import CleanupManager
from .events import EventBroker
from .network import network_payload
from .normalization import composite_workspaces, pane_index
from .pi_semantic import PiSemanticManager
from .push_notifications import APNsManager
from .stars import StarStore
from .terminal import TerminalObserver, TerminalObserverError


_ToolResult = TypeVar("_ToolResult")


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
        broker: Optional[EventBroker] = None,
        push: Optional[APNsManager] = None,
        environ: Optional[Mapping[str, str]] = None,
        tools: Optional[cmux_tools.CmuxToolsClient] = None,
        pi_semantic: Optional[PiSemanticManager] = None,
        cleanup: Optional[CleanupManager] = None,
    ) -> None:
        production_environment = environ is None
        self.environ = dict(os.environ if production_environment else environ)
        self.client = client or HerdrClient(environ=self.environ)
        self.cmux_tools = tools or cmux_tools.CmuxToolsClient(environ=self.environ)
        alert_store_path = self.environ.get("HERDR_HARNESS_ALERT_STORE_PATH") or None
        self.alerts = alerts or AlertStore(store_path=alert_store_path)
        star_store_path = self.environ.get("HERDR_HARNESS_STAR_STORE_PATH") or None
        self.stars = stars or StarStore(store_path=star_store_path)
        self.broker = broker or EventBroker()
        self.push = push or APNsManager(environ=self.environ)
        self.pi_semantic = pi_semantic or PiSemanticManager(
            self.client.socket_path,
            environ=None if production_environment else self.environ,
            on_event=self._publish_pi_event,
        )
        self.cleanup = cleanup or CleanupManager(self, environ=self.environ)
        self._lock = threading.RLock()
        self._quick_session_lock = threading.Lock()
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

    @staticmethod
    def _herd_pulse_state(snapshot: dict, *, connected: bool) -> dict:
        workspaces = [item for item in snapshot.get("workspaces", []) if isinstance(item, dict)]
        panes = [item for item in snapshot.get("panes", []) if isinstance(item, dict)]
        working = sum(item.get("agent_status") == "working" for item in panes)
        attention = sum(item.get("agent_status") == "blocked" for item in panes)
        ready = sum(item.get("agent_status") == "done" for item in panes)
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
            "connection": connection,
            "phase": phase,
            "updatedAt": int(time.time()),
        }

    def _publish_herd_pulse(self, *, force: bool = False, activity_id: Optional[str] = None) -> bool:
        with self._lock:
            snapshot = copy.deepcopy(self._snapshot or {})
            connected = self._request_connected and self._events_connected
        content_state = self._herd_pulse_state(snapshot, connected=connected)
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
            self.refresh_snapshot()
        except HerdrClientError:
            pass
        self.pi_semantic.start()
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
        self.pi_semantic.stop()
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

    def _publish_pi_event(self, envelope: dict) -> None:
        event = envelope.get("event") if isinstance(envelope, dict) else None
        event_type = str(event.get("type") or "event") if isinstance(event, dict) else "event"
        self.broker.publish(f"pi.{event_type}", envelope)

    def refresh_snapshot(self) -> dict:
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
        if self.stars.prune(current_pane_ids):
            self.broker.publish(
                "stars.changed",
                {"paneId": None, "starred": False, "starredPaneIds": self.stars.list()},
            )
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

    def workspaces_response(self) -> dict:
        snapshot, generated_at = self._cached_snapshot()
        return {
            "ok": True,
            "workspaces": self.pi_semantic.enrich_workspaces(
                snapshot,
                composite_workspaces(snapshot),
            ),
            "alerts": self.alerts.list(limit=100),
            "starredPaneIds": self.stars.list(),
            "generatedAt": generated_at,
        }

    def pi_snapshot_response(self, pane_id: str) -> dict:
        return self.pi_semantic.snapshot_response(pane_id)

    def pi_command(self, pane_id: str, command: str, payload: Optional[dict] = None) -> dict:
        return self.pi_semantic.command(pane_id, command, payload)

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

    def pi_extension_args(self) -> list[str]:
        override = self.environ.get("HERDR_HARNESS_PI_EXTENSION_PATH")
        path = (
            Path(override).expanduser()
            if override
            else Path(__file__).resolve().parent.parent / "pi-semantic-bridge"
        )
        return ["--extension", str(path)] if path.exists() else []

    def quick_pi_session(self, label: str) -> dict:
        with self._quick_session_lock:
            snapshot = self.refresh_snapshot()
            existing_workspace = next(
                (
                    item
                    for item in snapshot.get("workspaces", [])
                    if isinstance(item, dict)
                    and str(item.get("label") or "").strip().casefold() == "random tasks"
                ),
                None,
            )
            if existing_workspace is None:
                result = self.invoke(
                    "workspace.create",
                    {"label": "random tasks", "cwd": os.path.expanduser("~"), "focus": True},
                )
                raw = result["result"]
                workspace = raw.get("workspace")
                workspace_id = workspace.get("workspace_id") if isinstance(workspace, dict) else None
                pane = raw.get("pane") or raw.get("root_pane")
                pane_id = pane.get("pane_id") if isinstance(pane, dict) else None
                if not workspace_id or not pane_id:
                    raise HerdrClientError(
                        "workspace.create did not return a workspace and pane",
                        code="invalid_herdr_response",
                    )
                created_workspace = True
            else:
                workspace_id = str(existing_workspace["workspace_id"])
                result = self.invoke("tab.create", {"workspace_id": workspace_id, "focus": True})
                raw = result["result"]
                pane = raw.get("pane") or raw.get("root_pane")
                pane_id = pane.get("pane_id") if isinstance(pane, dict) else None
                if not pane_id:
                    pane_id = _find_pane_id(raw)
                if not pane_id:
                    raise HerdrClientError(
                        "tab.create did not return a pane",
                        code="invalid_herdr_response",
                    )
                created_workspace = False

            extension_args = self.pi_extension_args()
            pi_extension_attached = bool(extension_args)
            name = "quick-pi-" + uuid.uuid4().hex[:8]
            self.invoke(
                "agent.start",
                {
                    "pane_id": pane_id,
                    "name": name,
                    "kind": "pi",
                    "args": extension_args,
                    "timeout_ms": 30000,
                },
            )
            try:
                self.invoke("pane.rename", {"pane_id": pane_id, "label": label})
            except HerdrClientError:
                pass
            return {
                "ok": True,
                "workspace_id": workspace_id,
                "pane_id": pane_id,
                "created_workspace": created_workspace,
                "pi_extension_attached": pi_extension_attached,
            }

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
    ) -> dict:
        result = self.push.register_live_activity(
            push_token,
            activity_id=activity_id,
            bundle_id=bundle_id,
            environment=environment,
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
