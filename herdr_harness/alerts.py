"""Transition-aware alert store for Herdr agents."""

from __future__ import annotations

import json
import os
import tempfile
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

from .normalization import pane_index


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class AlertStore:
    """Keep actionable agent alerts and suppress repeated state observations.

    Herdr may describe a transition once through the event stream and again in
    the refreshed snapshot. The per-pane status baseline ensures those two
    observations produce a single alert while still allowing a future
    ``working -> blocked`` or ``working -> done`` transition to alert again.
    """

    ACTIONABLE_STATUSES = frozenset({"blocked", "done"})
    AGENT_STATUSES = frozenset({"idle", "working", "blocked", "done", "unknown"})
    STORE_VERSION = 1
    MAX_STORE_BYTES = 16 * 1024 * 1024

    def __init__(self, *, maximum: int = 500, store_path: Optional[Path] = None) -> None:
        self.maximum = max(10, int(maximum))
        self.store_path = Path(store_path).expanduser() if store_path is not None else None
        self._lock = threading.RLock()
        self._alerts: list[dict] = []
        self._status_by_pane: dict[str, str] = {}
        self._acked_done_panes: set[str] = set()
        self._dirty = False
        self._load()

    def _load(self) -> None:
        if self.store_path is None:
            return
        try:
            if self.store_path.stat().st_size > self.MAX_STORE_BYTES:
                return
            # Alert content can include pane titles and workspace names, so
            # tighten permissions even when loading a file created by an
            # older version or restored from backup.
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

        raw_alerts = payload.get("alerts")
        if isinstance(raw_alerts, list):
            # Walk newest-first so invalid or duplicate entries do not prevent
            # older valid alerts from filling the bounded journal.
            loaded: list[dict] = []
            seen_ids: set[str] = set()
            for item in reversed(raw_alerts):
                if not isinstance(item, dict):
                    continue
                alert_id = item.get("id")
                status = item.get("status")
                if (
                    not isinstance(alert_id, str)
                    or not alert_id
                    or alert_id in seen_ids
                    or status not in self.ACTIONABLE_STATUSES
                ):
                    continue
                alert = dict(item)
                alert["isRead"] = item.get("isRead") is True
                if not alert["isRead"]:
                    alert["readAt"] = None
                elif not isinstance(alert.get("readAt"), str):
                    alert["readAt"] = None
                loaded.append(alert)
                seen_ids.add(alert_id)
                if len(loaded) >= self.maximum:
                    break
            self._alerts = list(reversed(loaded))

        raw_statuses = payload.get("statusByPane")
        if isinstance(raw_statuses, dict):
            maximum_statuses = max(1_000, self.maximum * 4)
            for pane_id, status in raw_statuses.items():
                if len(self._status_by_pane) >= maximum_statuses:
                    break
                if (
                    isinstance(pane_id, str)
                    and pane_id
                    and isinstance(status, str)
                    and status in self.AGENT_STATUSES
                ):
                    self._status_by_pane[pane_id] = status

    def _mark_dirty_locked(self) -> None:
        if self.store_path is not None:
            self._dirty = True

    def _payload_locked(self) -> dict:
        return {
            "version": self.STORE_VERSION,
            "alerts": self._alerts,
            "statusByPane": self._status_by_pane,
        }

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
            # Alert delivery must remain available even when persistence is
            # temporarily unavailable. Keep the dirty bit set for a later
            # transition or acknowledgement to retry the write.
            return
        self._dirty = False

    def _truncate_locked(self) -> None:
        if len(self._alerts) > self.maximum:
            del self._alerts[: len(self._alerts) - self.maximum]

    def _build_alert(self, pane: dict, previous: str, current: str) -> dict:
        pane_id = str(pane.get("pane_id") or "")
        agent_info = pane.get("agent_info") if isinstance(pane.get("agent_info"), dict) else {}
        agent_name = (
            agent_info.get("name")
            or agent_info.get("display_agent")
            or pane.get("display_agent")
            or agent_info.get("agent")
            or pane.get("agent")
            or "Agent"
        )
        workspace_label = pane.get("workspace_label") or pane.get("workspace_id") or "workspace"
        pane_title = (
            agent_info.get("title")
            or pane.get("title")
            or pane.get("label")
            or pane.get("terminal_title_stripped")
        )
        if current == "blocked":
            title = f"{agent_name} needs you"
            message = f"Waiting for input in {workspace_label}."
            severity = "attention"
            kind = "agent_blocked"
        else:
            title = f"{agent_name} finished"
            message = f"Work completed in {workspace_label}."
            severity = "success"
            kind = "agent_done"
        if pane_title:
            message = f"{message[:-1]}: {pane_title}."
        created_at = utc_now()
        return {
            "id": f"alert_{uuid.uuid4().hex}",
            "kind": kind,
            "status": current,
            "previousStatus": previous,
            "severity": severity,
            "title": title,
            "message": message,
            "workspaceId": pane.get("workspace_id"),
            "workspaceLabel": pane.get("workspace_label"),
            "tabId": pane.get("tab_id"),
            "tabLabel": pane.get("tab_label"),
            "paneId": pane_id,
            "paneTitle": pane_title,
            "agentName": agent_name,
            "createdAt": created_at,
            "isRead": False,
            "readAt": None,
            "action": {"type": "open_pane", "paneId": pane_id},
        }

    def _mark_pane_alerts_read_locked(
        self,
        pane_id: str,
        read_at: Optional[str] = None,
    ) -> list[dict]:
        """Mark unread alerts for one pane read while the caller holds ``_lock``."""

        changed: list[dict] = []
        timestamp = read_at or utc_now()
        for alert in self._alerts:
            if alert.get("paneId") != pane_id or alert.get("isRead"):
                continue
            alert["isRead"] = True
            alert["readAt"] = timestamp
            changed.append(dict(alert))
        return changed

    def _observe(
        self,
        pane: dict,
        *,
        emit_when_new: bool = False,
        persist: bool = True,
        resolved: Optional[list[dict]] = None,
    ) -> Optional[dict]:
        pane_id = str(pane.get("pane_id") or "")
        if not pane_id:
            return None
        agent_info = pane.get("agent_info") if isinstance(pane.get("agent_info"), dict) else {}
        current = str(agent_info.get("agent_status") or pane.get("agent_status") or "unknown")
        with self._lock:
            previous = self._status_by_pane.get(pane_id)
            if previous != current:
                self._status_by_pane[pane_id] = current
                self._acked_done_panes.discard(pane_id)
                self._mark_dirty_locked()
                if (
                    previous is not None
                    and previous in self.ACTIONABLE_STATUSES
                    and current not in self.ACTIONABLE_STATUSES
                ):
                    resolved_alerts = self._mark_pane_alerts_read_locked(pane_id)
                    if resolved_alerts:
                        self._mark_dirty_locked()
                        if resolved is not None:
                            resolved.extend(resolved_alerts)
            if previous is None and not emit_when_new:
                if persist:
                    self._persist_locked()
                return None
            if previous == current or current not in self.ACTIONABLE_STATUSES:
                if persist:
                    self._persist_locked()
                return None
            alert = self._build_alert(pane, previous or "unknown", current)
            self._alerts.append(alert)
            self._truncate_locked()
            self._mark_dirty_locked()
            if persist:
                self._persist_locked()
            return dict(alert)

    def observe_snapshot(
        self,
        snapshot: dict,
        *,
        emit_initial: bool = False,
    ) -> tuple[list[dict], list[dict]]:
        panes = pane_index(snapshot)
        emitted: list[dict] = []
        resolved: list[dict] = []
        for pane in panes.values():
            alert = self._observe(
                pane,
                emit_when_new=emit_initial,
                persist=False,
                resolved=resolved,
            )
            if alert:
                emitted.append(alert)
        with self._lock:
            live_ids = set(panes)
            for pane_id in list(self._status_by_pane):
                if pane_id not in live_ids:
                    del self._status_by_pane[pane_id]
                    self._acked_done_panes.discard(pane_id)
                    self._mark_dirty_locked()
                    resolved_alerts = self._mark_pane_alerts_read_locked(pane_id)
                    if resolved_alerts:
                        self._mark_dirty_locked()
                        resolved.extend(resolved_alerts)
            self._persist_locked()
        return emitted, resolved

    def observe_event(
        self,
        envelope: dict,
        *,
        lookup: Optional[Callable[[str], Optional[dict]]] = None,
    ) -> tuple[Optional[dict], list[dict]]:
        event_name = str(envelope.get("event") or "").replace(".", "_")
        if event_name != "pane_agent_status_changed":
            return None, []
        data = envelope.get("data")
        if not isinstance(data, dict):
            return None, []
        pane_id = str(data.get("pane_id") or "")
        base = lookup(pane_id) if lookup and pane_id else None
        pane = dict(base) if isinstance(base, dict) else {}
        pane.update(data)
        agent_info = dict(pane.get("agent_info") or {})
        for key in ("agent", "display_agent", "agent_status", "state_labels", "title"):
            if key in data:
                agent_info[key] = data[key]
        pane["agent_info"] = agent_info
        # A status event is itself evidence of a transition. This matters for a
        # newly-created pane whose first snapshot may race the event stream.
        resolved: list[dict] = []
        return (
            self._observe(pane, emit_when_new=True, resolved=resolved),
            resolved,
        )

    def list(
        self,
        *,
        unread_only: bool = False,
        status: Optional[str] = None,
        limit: int = 100,
    ) -> list[dict]:
        bounded_limit = max(1, min(int(limit), self.maximum))
        with self._lock:
            values = reversed(self._alerts)
            filtered = [
                dict(item)
                for item in values
                if (not unread_only or not item.get("isRead"))
                and (not status or item.get("status") == status)
            ]
            return filtered[:bounded_limit]

    def unread_count(self) -> int:
        with self._lock:
            return sum(1 for item in self._alerts if not item.get("isRead"))

    def mark_read(self, alert_id: str) -> Optional[dict]:
        with self._lock:
            for alert in self._alerts:
                if alert.get("id") != alert_id:
                    continue
                if not alert.get("isRead"):
                    alert["isRead"] = True
                    alert["readAt"] = utc_now()
                    self._mark_dirty_locked()
                    self._persist_locked()
                return dict(alert)
        return None

    def mark_read_for_pane(self, pane_id: str, now: Optional[str] = None) -> list[dict]:
        with self._lock:
            if self._status_by_pane.get(pane_id) == "done":
                self._acked_done_panes.add(pane_id)
            changed = self._mark_pane_alerts_read_locked(pane_id, read_at=now)
            if changed:
                self._mark_dirty_locked()
                self._persist_locked()
            return changed

    def acked_done_panes(self) -> frozenset[str]:
        with self._lock:
            return frozenset(self._acked_done_panes)

    def mark_all_read(self) -> list[dict]:
        changed: list[dict] = []
        read_at = utc_now()
        with self._lock:
            for alert in self._alerts:
                if alert.get("isRead"):
                    continue
                alert["isRead"] = True
                alert["readAt"] = read_at
                changed.append(dict(alert))
            if changed:
                self._mark_dirty_locked()
                self._persist_locked()
        return changed
