"""Live activity bubbles for Pi sessions on the Active Work board.

Consumes Pi event envelopes, keeps a bounded per-pane ring of recent tool
calls, and turns them into a short comic-style bubble written to the session
row and published over SSE. ``tool_execution_start`` triggers a debounced
update; ``agent_settled`` always bypasses the debounce.
"""

from __future__ import annotations

import json
import os
import queue
import threading
import time
import urllib.request
from collections import deque
from typing import Any, Mapping, Optional

from .active_work import utc_now

DEFAULT_MODEL_URL = "http://100.120.49.92:8012/v1"
DEFAULT_MODEL_NAME = "qwen3.8-27b-bf16"
MODEL_TIMEOUT_SECONDS = 4.0
DEFAULT_DEBOUNCE_SECONDS = 20.0
MIN_DEBOUNCE_SECONDS = 2.0
MAX_DEBOUNCE_SECONDS = 300.0
RING_LIMIT = 48
MAX_GIST_CHARS = 100
MAX_PROMPT_CHARS = 1600
MAX_MESSAGE_CHARS = 40
MAX_MESSAGE_WORDS = 3

_TOOL_RING_TYPES = frozenset({"tool_call", "tool_execution_start"})
_SESSION_BOUNDARY_TYPES = frozenset({"session_start", "session_shutdown"})
_READ_TOOLS = frozenset({"read", "grep", "find"})
_WRITE_TOOLS = frozenset({"write", "edit"})
_TEST_TOOLS = frozenset({"test", "pytest", "xcodebuild"})
_BROWSE_TOOLS = frozenset({"web", "web_search", "websearch", "browse", "browser", "http", "fetch"})


class AgentActivityManager:
    """Turn Pi tool activity into short live bubbles on Active Work sessions."""

    def __init__(
        self,
        active_work: Any,
        broker: Any,
        environ: Optional[Mapping[str, str]] = None,
        *,
        model_url: Optional[str] = None,
        model_name: Optional[str] = None,
        timeout: float = MODEL_TIMEOUT_SECONDS,
        debounce: Optional[float] = None,
    ) -> None:
        self.environ = dict(os.environ if environ is None else environ)
        self.active_work = active_work
        self.broker = broker
        if model_url is None:
            model_url = self.environ.get("HERDR_HARNESS_ACTIVITY_MODEL_URL", DEFAULT_MODEL_URL)
        self.model_url = str(model_url).strip() if str(model_url).strip() else ""
        self.model_name = model_name or self.environ.get(
            "HERDR_HARNESS_ACTIVITY_MODEL_NAME", DEFAULT_MODEL_NAME
        )
        self.timeout = timeout
        if debounce is None:
            raw = self.environ.get("HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS", "")
            try:
                debounce = float(raw) if raw else DEFAULT_DEBOUNCE_SECONDS
            except ValueError:
                debounce = DEFAULT_DEBOUNCE_SECONDS
            debounce = min(max(debounce, MIN_DEBOUNCE_SECONDS), MAX_DEBOUNCE_SECONDS)
        self.debounce_seconds = debounce
        self._lock = threading.Lock()
        self._rings: dict[str, deque] = {}
        self._last_written: dict[str, str] = {}
        self._last_write_at: dict[str, float] = {}
        self._statuses: dict[str, str] = {}
        self._queue: "queue.Queue[tuple[str, str]]" = queue.Queue()
        self._stop_event = threading.Event()
        self._started = False
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            self._started = True
            self._stop_event = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="herdr-agent-activity",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        with self._lock:
            if not self._started:
                return
            self._started = False
        self._stop_event.set()
        thread = self._thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)
        self._thread = None

    def handle_event(self, envelope: Any) -> None:
        try:
            self._handle_event(envelope)
        except Exception:
            pass

    def _handle_event(self, envelope: Any) -> None:
        if not isinstance(envelope, dict):
            return
        pane_id = envelope.get("pane_id")
        event = envelope.get("event")
        if not isinstance(pane_id, str) or not pane_id or not isinstance(event, dict):
            return
        event_type = event.get("type")
        if event_type in _SESSION_BOUNDARY_TYPES:
            with self._lock:
                self._rings.pop(pane_id, None)
                self._last_written.pop(pane_id, None)
                self._last_write_at.pop(pane_id, None)
                self._statuses.pop(pane_id, None)
            return
        if event_type in _TOOL_RING_TYPES:
            entry = self._tool_entry(event_type, event)
            if entry is not None:
                with self._lock:
                    ring = self._rings.get(pane_id)
                    if ring is None:
                        ring = self._rings[pane_id] = deque(maxlen=RING_LIMIT)
                    ring.append(entry)
                if event_type == "tool_execution_start":
                    self._enqueue(pane_id, "tool_execution_start")
            return
        if event_type == "agent_settled":
            self._enqueue(pane_id, "agent_settled")

    @staticmethod
    def _tool_entry(event_type: Any, event: dict) -> Optional[tuple[str, str]]:
        if event_type == "tool_execution_start":
            name = event.get("toolName")
            args = event.get("args")
        else:
            call = event.get("toolCall")
            if isinstance(call, dict):
                name = call.get("name") or call.get("toolName")
                args = call.get("arguments") or call.get("args")
            else:
                name = event.get("name")
                args = event.get("args")
        name = str(name or "").strip()
        if not name:
            return None
        gist = ""
        if name == "bash" and isinstance(args, dict):
            command = args.get("command")
            if isinstance(command, str):
                gist = " ".join(command.split())[:MAX_GIST_CHARS]
        elif name == "subagent" and isinstance(args, dict):
            agent_name = args.get("agent") or args.get("name") or args.get("agentName")
            if isinstance(agent_name, str) and agent_name:
                gist = " ".join(agent_name.split())[:MAX_GIST_CHARS]
        return (name, gist)

    def _enqueue(self, pane_id: str, trigger: str) -> None:
        with self._lock:
            if not self._started:
                return
        self._queue.put((pane_id, trigger))

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                pane_id, trigger = self._queue.get(timeout=0.25)
            except queue.Empty:
                continue
            try:
                self._summarize(pane_id, trigger)
            except Exception:
                pass

    def _summarize(self, pane_id: str, trigger: str) -> None:
        with self._lock:
            if trigger != "agent_settled":
                last_at = self._last_write_at.get(pane_id)
                if last_at is not None and time.monotonic() - last_at < self.debounce_seconds:
                    return
        phrase = self._canned_phrase(pane_id)
        if phrase is None and self.model_url:
            phrase = self._model_phrase(pane_id)
        if phrase is None:
            with self._lock:
                phrase = None if pane_id in self._last_written else "working"
        if phrase is None:
            return
        with self._lock:
            if phrase == self._last_written.get(pane_id):
                return
            status = "running" if self._statuses.get(pane_id) in (None, "unknown", "queued") else None
        now = utc_now()
        item = self.active_work.update_session_activity(
            pane_id,
            activity_message=phrase,
            activity_message_at=now,
            status=status,
            last_seen_at=now,
        )
        if item is None:
            with self._lock:
                self._last_written.pop(pane_id, None)
                self._last_write_at.pop(pane_id, None)
                self._statuses.pop(pane_id, None)
            return
        with self._lock:
            self._last_written[pane_id] = phrase
            self._last_write_at[pane_id] = time.monotonic()
            self._remember_status_locked(pane_id, item)
        self.broker.publish(
            "active_work.updated",
            {
                "work_item_id": item.get("id"),
                "revision": item.get("revision"),
                "change": "activity",
                "generated_at": utc_now(),
            },
        )

    def _remember_status_locked(self, pane_id: str, item: dict) -> None:
        sessions = item.get("pi_sessions")
        if not isinstance(sessions, list):
            return
        for session in sessions:
            if isinstance(session, dict) and session.get("pane_id") == pane_id:
                status = session.get("status")
                if isinstance(status, str) and status:
                    self._statuses[pane_id] = status
                return

    def _canned_phrase(self, pane_id: str) -> Optional[str]:
        with self._lock:
            entries = list(self._rings.get(pane_id) or ())
        if not entries:
            return None
        reads = writes = 0
        for name, gist in reversed(entries):
            lowered = gist.lower()
            if name == "subagent":
                return "delegating"
            if name == "bash" and "git commit" in lowered:
                return "committing"
            if name == "bash" and "git push" in lowered:
                return "pushing"
            if name == "bash" and ("gh pr" in lowered or "gh review" in lowered):
                return "reviewing"
            if name in _TEST_TOOLS or (
                name == "bash" and ("pytest" in lowered or "xcodebuild" in lowered)
            ):
                return "running tests"
            if name in _BROWSE_TOOLS:
                return "browsing"
            if name in _READ_TOOLS:
                reads += 1
            elif name in _WRITE_TOOLS:
                writes += 1
        total = len(entries)
        if reads / total >= 0.6:
            return "scanning code"
        if writes / total > 0.5:
            return "editing code"
        return None

    def _model_phrase(self, pane_id: str) -> Optional[str]:
        with self._lock:
            entries = list(self._rings.get(pane_id) or ())
        if not entries:
            return None
        lines = [f"- {name}: {gist}" if gist else f"- {name}" for name, gist in entries]
        tool_text = "\n".join(lines)[:MAX_PROMPT_CHARS]
        prompt = (
            "Recent tool activity of a coding agent (newest last):\n"
            f"{tool_text}\n"
            "Describe in 1 to 3 comic-style words what the agent is doing right now. "
            "Reply with only those words."
        )
        body = {
            "model": self.model_name,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 24,
            "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        request = urllib.request.Request(
            f"{self.model_url}/chat/completions",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except Exception:
            return None
        choices = payload.get("choices") if isinstance(payload, dict) else None
        if not isinstance(choices, list) or not choices:
            return None
        first = choices[0] if isinstance(choices[0], dict) else None
        message = first.get("message") if isinstance(first, dict) else None
        content = message.get("content") if isinstance(message, dict) else None
        return self._sanitize(content)

    @staticmethod
    def _sanitize(raw: Any) -> Optional[str]:
        if not isinstance(raw, str):
            return None
        text = " ".join(raw.split())
        if not text or len(text) > MAX_MESSAGE_CHARS:
            return None
        if len(text.split()) > MAX_MESSAGE_WORDS:
            return None
        return text
