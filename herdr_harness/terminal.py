"""Bridge Herdr's raw terminal observer CLI to iterable frame records."""

from __future__ import annotations

import json
import os
import selectors
import shutil
import subprocess
import threading
from collections import deque
from pathlib import Path
from typing import Iterator, Mapping, Optional


class TerminalObserverError(RuntimeError):
    pass


class TerminalObserver:
    """Own a single ``herdr terminal session observe`` subprocess."""

    def __init__(
        self,
        pane_id: str,
        *,
        cols: int,
        rows: int,
        socket_path: str,
        session: str,
        environ: Optional[Mapping[str, str]] = None,
    ) -> None:
        source_env = dict(os.environ if environ is None else environ)
        binary = source_env.get("HERDR_BIN_PATH") or shutil.which("herdr")
        if not binary:
            raise TerminalObserverError("herdr executable was not found")
        self._environment = source_env
        self._environment["HERDR_SESSION"] = session
        self._environment["HERDR_SOCKET_PATH"] = socket_path
        client_socket = str(Path(socket_path).with_name("herdr-client.sock"))
        self._environment.setdefault("HERDR_CLIENT_SOCKET_PATH", client_socket)
        self._command = [
            binary,
            "terminal",
            "session",
            "observe",
            pane_id,
            "--cols",
            str(cols),
            "--rows",
            str(rows),
        ]
        self._process: Optional[subprocess.Popen] = None
        self._stderr_lines: deque[str] = deque(maxlen=64)
        self._stderr_lock = threading.Lock()
        self._stderr_thread: Optional[threading.Thread] = None

    def _drain_stderr(self, stream: object) -> None:
        """Drain stderr continuously so a noisy observer cannot block itself."""

        try:
            fd = stream.fileno()  # type: ignore[union-attr]
            buffer = bytearray()
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                buffer.extend(chunk)
                while b"\n" in buffer:
                    raw, _, remainder = buffer.partition(b"\n")
                    buffer = bytearray(remainder)
                    with self._stderr_lock:
                        self._stderr_lines.append(raw.decode("utf-8", errors="replace")[-8192:])
            if buffer:
                with self._stderr_lock:
                    self._stderr_lines.append(buffer.decode("utf-8", errors="replace")[-8192:])
        except (AttributeError, OSError):
            pass

    def start(self) -> "TerminalObserver":
        if self._process is not None:
            return self
        try:
            self._process = subprocess.Popen(
                self._command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self._environment,
            )
        except OSError as exc:
            raise TerminalObserverError(f"Could not start Herdr terminal observer: {exc}") from exc
        if self._process.stderr is not None:
            self._stderr_thread = threading.Thread(
                target=self._drain_stderr,
                args=(self._process.stderr,),
                name="herdr-terminal-stderr",
                daemon=True,
            )
            self._stderr_thread.start()
        return self

    def frames(self, *, heartbeat_seconds: float = 2.0) -> Iterator[dict]:
        process = self.start()._process
        if process is None or process.stdout is None:
            return
        selector = selectors.DefaultSelector()
        stdout_fd = process.stdout.fileno()
        selector.register(stdout_fd, selectors.EVENT_READ)
        buffer = bytearray()

        def record_for(line: bytes) -> Optional[dict]:
            try:
                record = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return {
                    "event": "terminal.error",
                    "data": {"message": "Herdr emitted an invalid terminal frame"},
                }
            if not isinstance(record, dict):
                return None
            return {"event": str(record.get("event") or "terminal.frame"), "data": record}

        try:
            while True:
                ready = selector.select(max(0.25, float(heartbeat_seconds)))
                if not ready:
                    if process.poll() is not None:
                        break
                    yield {"event": "heartbeat", "data": {}}
                    continue
                try:
                    chunk = os.read(stdout_fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buffer.extend(chunk)
                while b"\n" in buffer:
                    line, _, remainder = buffer.partition(b"\n")
                    buffer = bytearray(remainder)
                    if record := record_for(line):
                        yield record
        finally:
            selector.close()
        if buffer and (record := record_for(bytes(buffer))):
            yield record
        return_code = process.poll()
        if self._stderr_thread is not None:
            self._stderr_thread.join(timeout=1.0)
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
        if return_code not in {None, 0}:
            with self._stderr_lock:
                stderr_lines = list(self._stderr_lines)
            yield {
                "event": "terminal.error",
                "data": {
                    "message": "\n".join(stderr_lines).strip()
                    or f"Herdr terminal observer exited with status {return_code}",
                    "returnCode": return_code,
                },
            }
        else:
            yield {"event": "terminal.closed", "data": {"returnCode": return_code or 0}}

    def close(self) -> None:
        process = self._process
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1.0)
        if self._stderr_thread is not None:
            self._stderr_thread.join(timeout=1.0)
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass

    def __enter__(self) -> "TerminalObserver":
        return self.start()

    def __exit__(self, _exc_type, _exc, _traceback) -> None:
        self.close()
