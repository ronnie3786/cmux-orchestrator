"""Low-level client for Herdr's NDJSON Unix socket API.

Herdr accepts one JSON request per line and returns one JSON response per line.
An ``events.subscribe`` request keeps the socket open after its acknowledgement
and emits event envelopes until either side disconnects.
"""

from __future__ import annotations

import json
import os
import re
import socket
import threading
import uuid
from pathlib import Path
from typing import Callable, Iterable, Mapping, Optional


DEFAULT_MAX_LINE_BYTES = 32 * 1024 * 1024
_METHOD_RE = re.compile(r"^[a-z][a-z0-9_.]{0,127}$")
_SESSION_RE = re.compile(r"^[A-Za-z0-9._-]+$")

# These subscriptions do not require a pane-specific target. Agent status
# subscriptions are added dynamically by HerdrService for every live pane.
DEFAULT_SUBSCRIPTIONS = (
    "workspace.created",
    "workspace.updated",
    "workspace.metadata_updated",
    "workspace.renamed",
    "workspace.moved",
    "workspace.reordered",
    "workspace.closed",
    "workspace.focused",
    "worktree.created",
    "worktree.opened",
    "worktree.removed",
    "tab.created",
    "tab.closed",
    "tab.focused",
    "tab.renamed",
    "tab.moved",
    "pane.created",
    "pane.closed",
    "pane.updated",
    "pane.focused",
    "pane.moved",
    "pane.exited",
    "pane.agent_detected",
    "layout.updated",
)


class HerdrClientError(RuntimeError):
    """Base error for transport and protocol failures."""

    def __init__(self, message: str, *, code: str = "herdr_transport_error"):
        super().__init__(message)
        self.code = code


class HerdrAPIError(HerdrClientError):
    """An error response returned by the Herdr server."""

    def __init__(self, code: str, message: str, *, response: Optional[dict] = None):
        super().__init__(message, code=code or "herdr_api_error")
        self.response = response or {}


def resolve_socket_path(
    socket_path: Optional[str] = None,
    session: Optional[str] = None,
    *,
    environ: Optional[Mapping[str, str]] = None,
) -> str:
    """Resolve a Herdr API socket using the same environment knobs as Herdr.

    ``HERDR_SOCKET_PATH`` always wins. The default session lives directly in
    Herdr's config directory, while named sessions live below ``sessions``.
    ``HERDR_CONFIG_PATH`` may point at a non-default config file.
    """

    env = os.environ if environ is None else environ
    explicit = socket_path or env.get("HERDR_SOCKET_PATH")
    if explicit:
        value = os.path.abspath(os.path.expanduser(str(explicit)))
        if "\x00" in value:
            raise ValueError("HERDR_SOCKET_PATH contains a null byte")
        return value

    selected_session = str(session or env.get("HERDR_SESSION") or "default").strip()
    if not _SESSION_RE.fullmatch(selected_session) or selected_session in {".", ".."}:
        raise ValueError("HERDR_SESSION contains unsupported characters")

    config_path = env.get("HERDR_CONFIG_PATH")
    if config_path:
        config_dir = Path(config_path).expanduser().resolve().parent
    else:
        config_dir = Path(env.get("HOME") or Path.home()) / ".config" / "herdr"

    if selected_session == "default":
        return str(config_dir / "herdr.sock")
    return str(config_dir / "sessions" / selected_session / "herdr.sock")


class HerdrClient:
    """Thread-safe, connection-per-request Herdr API client."""

    def __init__(
        self,
        socket_path: Optional[str] = None,
        session: Optional[str] = None,
        *,
        timeout: float = 4.0,
        max_line_bytes: int = DEFAULT_MAX_LINE_BYTES,
        environ: Optional[Mapping[str, str]] = None,
    ) -> None:
        env = os.environ if environ is None else environ
        self.session = str(session or env.get("HERDR_SESSION") or "default")
        self.socket_path = resolve_socket_path(socket_path, self.session, environ=environ)
        self.timeout = max(0.1, float(timeout))
        self.max_line_bytes = max(1024, int(max_line_bytes))

    def _connect(self) -> socket.socket:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout)
        try:
            connection.connect(self.socket_path)
        except OSError as exc:
            connection.close()
            raise HerdrClientError(
                f"Cannot connect to Herdr session {self.session!r} at {self.socket_path}: {exc}",
                code="herdr_unavailable",
            ) from exc
        return connection

    @staticmethod
    def _request_payload(method: str, params: Optional[dict], request_id: str) -> bytes:
        if not _METHOD_RE.fullmatch(str(method or "")):
            raise ValueError("invalid Herdr API method")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            raise TypeError("Herdr API params must be a dictionary")
        payload = {"id": request_id, "method": method, "params": params}
        return json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"

    def _read_line(self, connection: socket.socket) -> bytes:
        chunks = bytearray()
        while True:
            try:
                chunk = connection.recv(min(65536, self.max_line_bytes + 1 - len(chunks)))
            except socket.timeout as exc:
                raise HerdrClientError("Timed out waiting for Herdr", code="herdr_timeout") from exc
            except OSError as exc:
                raise HerdrClientError(f"Failed reading from Herdr: {exc}") from exc
            if not chunk:
                raise HerdrClientError("Herdr closed the socket before replying", code="herdr_disconnected")
            chunks.extend(chunk)
            newline = chunks.find(b"\n")
            if newline >= 0:
                return bytes(chunks[:newline])
            if len(chunks) > self.max_line_bytes:
                raise HerdrClientError("Herdr response exceeded the configured size limit", code="response_too_large")

    def _decode_envelope(self, raw: bytes) -> dict:
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise HerdrClientError("Herdr returned invalid NDJSON", code="invalid_herdr_response") from exc
        if not isinstance(value, dict):
            raise HerdrClientError("Herdr returned a non-object response", code="invalid_herdr_response")
        return value

    @staticmethod
    def _raise_for_error(response: dict) -> None:
        error = response.get("error")
        if not isinstance(error, dict):
            return
        raise HerdrAPIError(
            str(error.get("code") or "herdr_api_error"),
            str(error.get("message") or "Herdr request failed"),
            response=response,
        )

    def request_envelope(
        self,
        method: str,
        params: Optional[dict] = None,
        *,
        request_id: Optional[str] = None,
    ) -> dict:
        """Perform one request on a fresh Unix socket connection."""

        identifier = request_id or f"harness:{uuid.uuid4().hex}"
        payload = self._request_payload(method, params, identifier)
        with self._connect() as connection:
            try:
                connection.sendall(payload)
            except OSError as exc:
                raise HerdrClientError(f"Failed writing to Herdr: {exc}") from exc
            response = self._decode_envelope(self._read_line(connection))
        self._raise_for_error(response)
        if response.get("id") != identifier:
            raise HerdrClientError("Herdr response ID did not match the request", code="mismatched_response")
        if "result" not in response:
            raise HerdrClientError("Herdr response did not include a result", code="invalid_herdr_response")
        return response

    def request(
        self,
        method: str,
        params: Optional[dict] = None,
        *,
        request_id: Optional[str] = None,
    ) -> dict:
        """Return the native Herdr ``result`` object for a one-shot request."""

        result = self.request_envelope(method, params, request_id=request_id).get("result")
        if not isinstance(result, dict):
            raise HerdrClientError("Herdr result was not an object", code="invalid_herdr_response")
        return result

    def ping(self) -> dict:
        return self.request("ping", {})

    def snapshot(self) -> dict:
        result = self.request("session.snapshot", {})
        snapshot = result.get("snapshot")
        if not isinstance(snapshot, dict):
            raise HerdrClientError("Herdr snapshot response was malformed", code="invalid_herdr_response")
        return snapshot

    def subscribe_forever(
        self,
        callback: Callable[[dict], None],
        *,
        subscriptions: Optional[Iterable[dict]] = None,
        subscription_provider: Optional[Callable[[], Iterable[dict]]] = None,
        stop_event: Optional[threading.Event] = None,
        restart_event: Optional[threading.Event] = None,
        on_state: Optional[Callable[[str, Optional[BaseException]], None]] = None,
        minimum_backoff: float = 0.25,
        maximum_backoff: float = 5.0,
    ) -> None:
        """Maintain an ``events.subscribe`` stream with bounded reconnects.

        ``restart_event`` lets a caller rebuild pane-specific subscriptions
        after the topology changes without stopping the outer reconnect loop.
        """

        stop = stop_event or threading.Event()
        restart = restart_event or threading.Event()
        static_subscriptions = list(subscriptions or ({"type": item} for item in DEFAULT_SUBSCRIPTIONS))
        backoff = max(0.05, float(minimum_backoff))

        while not stop.is_set():
            if on_state:
                on_state("connecting", None)
            connection: Optional[socket.socket] = None
            try:
                active_subscriptions = list(
                    subscription_provider() if subscription_provider is not None else static_subscriptions
                )
                identifier = f"harness:events:{uuid.uuid4().hex}"
                payload = self._request_payload(
                    "events.subscribe",
                    {"subscriptions": active_subscriptions},
                    identifier,
                )
                connection = self._connect()
                connection.sendall(payload)
                connection.settimeout(min(1.0, self.timeout))
                buffer = bytearray()
                acknowledged = False

                while not stop.is_set() and not restart.is_set():
                    try:
                        chunk = connection.recv(65536)
                    except socket.timeout:
                        continue
                    if not chunk:
                        raise HerdrClientError("Herdr event stream disconnected", code="herdr_disconnected")
                    buffer.extend(chunk)
                    if len(buffer) > self.max_line_bytes:
                        raise HerdrClientError("Herdr event exceeded the size limit", code="response_too_large")
                    while b"\n" in buffer:
                        raw, _, remainder = buffer.partition(b"\n")
                        buffer = bytearray(remainder)
                        if not raw.strip():
                            continue
                        envelope = self._decode_envelope(bytes(raw))
                        if envelope.get("id") == identifier:
                            self._raise_for_error(envelope)
                            result = envelope.get("result") or {}
                            if not isinstance(result, dict) or result.get("type") != "subscription_started":
                                raise HerdrClientError(
                                    "Herdr did not acknowledge the event subscription",
                                    code="invalid_herdr_response",
                                )
                            acknowledged = True
                            backoff = max(0.05, float(minimum_backoff))
                            if on_state:
                                on_state("connected", None)
                            continue
                        if "event" in envelope and isinstance(envelope.get("data"), dict):
                            callback(envelope)
                if restart.is_set():
                    restart.clear()
                    continue
                if not acknowledged:
                    raise HerdrClientError("Herdr event subscription ended before acknowledgement")
            except (HerdrClientError, HerdrAPIError, OSError, ValueError) as exc:
                if stop.is_set():
                    break
                if on_state:
                    on_state("disconnected", exc)
                if stop.wait(backoff):
                    break
                backoff = min(maximum_backoff, backoff * 2.0)
            finally:
                if connection is not None:
                    try:
                        connection.close()
                    except OSError:
                        pass
