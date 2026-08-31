"""Forward Pi activity from a remote harness into local board bubbles.

DevBox-floor buzz agents run their Pi sessions on another machine, so their
tool events never reach this Mac's journal. This poller holds one SSE stream
per relevant remote pane (a pane with an active board session under the
configured prefix), re-namespaces the pane id, and feeds the local
AgentActivityManager. Only structured tool-event envelopes cross the network —
never message bodies.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from typing import Any, Callable, Mapping, Optional

from .secret_file import SecretFileError, load_private_bearer_token_file

SSE_READ_TIMEOUT_SECONDS = 25.0
SNAPSHOT_TIMEOUT_SECONDS = 8.0
MAX_SSE_LINE_BYTES = 512 * 1024
ERROR_LOG_INTERVAL_SECONDS = 300.0

# Transport bookkeeping events carry no activity signal.
_TRANSPORT_EVENT_TYPES = frozenset({"ready", "stream.reset"})


class RemoteActivityPoller:
    """Watch remote Pi panes that have active board sessions and bubble them."""

    def __init__(
        self,
        active_panes: Callable[[], set],
        on_event: Callable[[dict], None],
        *,
        environ: Optional[Mapping[str, str]] = None,
        open_url: Optional[Callable[..., Any]] = None,
    ) -> None:
        self.environ = dict(os.environ if environ is None else environ)
        self.active_panes = active_panes
        self.on_event = on_event
        self._open_url = open_url or urllib.request.urlopen
        self.prefix = str(self.environ.get("HERDR_HARNESS_REMOTE_ACTIVITY_PREFIX") or "devbox")
        raw_poll = str(self.environ.get("HERDR_HARNESS_REMOTE_ACTIVITY_POLL_SECONDS") or "")
        try:
            poll = float(raw_poll) if raw_poll else 5.0
        except ValueError:
            poll = 5.0
        self.poll_seconds = min(max(poll, 1.0), 60.0)
        self.base_url = str(self.environ.get("HERDR_HARNESS_REMOTE_ACTIVITY_URL") or "").strip().rstrip("/")
        self.token = ""
        self._enabled = self._load_token()
        self._lock = threading.RLock()
        self._stop_event = threading.Event()
        self._readers: dict[str, tuple[threading.Event, threading.Thread]] = {}
        self._cursors: dict[str, int] = {}
        self._error_log_lock = threading.Lock()
        self._error_logged_at: dict[str, float] = {}
        self._reconcile_thread: Optional[threading.Thread] = None
        if self._enabled:
            print(
                f"[remote-activity] forwarding pi activity from {self.base_url} "
                f"(prefix {self.prefix})",
                file=sys.stderr,
                flush=True,
            )

    def _load_token(self) -> bool:
        if not self.base_url:
            return False
        token_path = str(self.environ.get("HERDR_HARNESS_REMOTE_ACTIVITY_TOKEN_FILE") or "").strip()
        if not token_path:
            return True
        try:
            self.token = load_private_bearer_token_file(token_path, field="remote activity token")
        except SecretFileError as exc:
            self._log_error(f"token:{token_path}", f"[remote-activity] disabled: {exc}")
            return False
        return True

    @property
    def enabled(self) -> bool:
        return self._enabled

    def pane_ids(self) -> list[str]:
        with self._lock:
            return sorted(self._readers)

    def start(self) -> None:
        if not self._enabled or self._reconcile_thread is not None:
            return
        self._reconcile_thread = threading.Thread(
            target=self._reconcile_loop,
            name="herdr-remote-activity",
            daemon=True,
        )
        self._reconcile_thread.start()

    def stop(self) -> None:
        with self._lock:
            readers = list(self._readers.values())
            self._readers.clear()
        self._stop_event.set()
        for stop, _thread in readers:
            stop.set()
        thread = self._reconcile_thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)
        self._reconcile_thread = None

    def _reconcile_loop(self) -> None:
        while not self._stop_event.is_set():
            self._reconcile()
            self._stop_event.wait(self.poll_seconds)

    def _reconcile(self) -> None:
        marker = f"{self.prefix}:"
        try:
            relevant = {
                pane_id[len(marker):]
                for pane_id in self.active_panes()
                if isinstance(pane_id, str) and pane_id.startswith(marker) and len(pane_id) > len(marker)
            }
        except Exception as exc:
            self._log_error(
                "reconcile",
                f"[remote-activity] reconcile failed: {exc}",
            )
            return
        with self._lock:
            stale = [pane for pane in self._readers if pane not in relevant]
            for pane in stale:
                stop, _thread = self._readers.pop(pane)
                stop.set()
                self._cursors.pop(pane, None)
            missing = sorted(pane for pane in relevant if pane not in self._readers)
            for pane in missing:
                stop = threading.Event()
                thread = threading.Thread(
                    target=self._reader,
                    args=(pane, stop),
                    name=f"remote-activity-{pane.replace(':', '-')}",
                    daemon=True,
                )
                self._readers[pane] = (stop, thread)
            started = [self._readers[pane][1] for pane in missing]
        for pane in stale:
            print(f"[remote-activity] stopped watching remote pane {pane}", file=sys.stderr, flush=True)
        for thread in started:
            thread.start()

    def _reader(self, pane_id: str, stop: threading.Event) -> None:
        print(f"[remote-activity] watching remote pane {pane_id}", file=sys.stderr, flush=True)
        while not stop.is_set():
            cursor = self._cursors.get(pane_id)
            if cursor is None:
                cursor = self._latest_cursor(pane_id)
                if cursor is None:
                    self._log_error(f"pane:{pane_id}", f"[remote-activity] {pane_id}: unavailable; retrying")
                    stop.wait(self.poll_seconds)
                    continue
                self._cursors[pane_id] = cursor
            try:
                self._stream(pane_id, self._cursors[pane_id], stop)
            except Exception as exc:
                self._log_error(f"pane:{pane_id}", f"[remote-activity] {pane_id}: {exc}")
            if not stop.is_set():
                stop.wait(self.poll_seconds)
        with self._lock:
            self._cursors.pop(pane_id, None)

    def _stream(self, pane_id: str, cursor: int, stop: threading.Event) -> None:
        request = urllib.request.Request(
            self._events_url(pane_id),
            headers={**self._headers(), "Last-Event-ID": str(cursor)},
        )
        with self._open_url(request, timeout=SSE_READ_TIMEOUT_SECONDS) as response:
            for raw_line in response:
                if stop.is_set():
                    return
                line = raw_line[:MAX_SSE_LINE_BYTES].decode("utf-8", errors="replace").strip()
                if not line.startswith("data: "):
                    continue
                try:
                    payload = json.loads(line[6:])
                except json.JSONDecodeError:
                    continue
                if isinstance(payload, dict):
                    self._forward(payload, pane_id)

    def _forward(self, payload: dict, pane_id: str) -> None:
        event = payload.get("event")
        if payload.get("pane_id") != pane_id or not isinstance(event, dict):
            return
        cursor = payload.get("cursor")
        if isinstance(cursor, int) and cursor > 0:
            self._cursors[pane_id] = max(self._cursors.get(pane_id, 0), cursor)
        if str(event.get("type") or "") in _TRANSPORT_EVENT_TYPES:
            return
        self.on_event({**payload, "pane_id": f"{self.prefix}:{pane_id}"})

    def _latest_cursor(self, pane_id: str) -> Optional[int]:
        url = f"{self.base_url}/api/v1/panes/{urllib.parse.quote(pane_id, safe='')}/pi/snapshot"
        try:
            with self._open_url(
                urllib.request.Request(url, headers=self._headers()),
                timeout=SNAPSHOT_TIMEOUT_SECONDS,
            ) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except Exception as exc:
            self._log_error(f"pane:{pane_id}", f"[remote-activity] {pane_id}: snapshot failed: {exc}")
            return None
        latest = payload.get("latest_cursor") if isinstance(payload, dict) else None
        return latest if isinstance(latest, int) and latest >= 0 else None

    def _events_url(self, pane_id: str) -> str:
        return f"{self.base_url}/api/v1/panes/{urllib.parse.quote(pane_id, safe='')}/pi/events"

    def _headers(self) -> dict[str, str]:
        headers = {"Accept": "text/event-stream", "User-Agent": "herdr-remote-activity/1"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def _log_error(self, key: str, message: str) -> None:
        now = time.monotonic()
        with self._error_log_lock:
            last = self._error_logged_at.get(key)
            if last is not None and now - last < ERROR_LOG_INTERVAL_SECONDS:
                return
            self._error_logged_at[key] = now
        print(message, file=sys.stderr, flush=True)
