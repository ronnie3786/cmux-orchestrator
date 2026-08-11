"""Bridge Herdr's raw terminal observer CLI to iterable frame records."""

from __future__ import annotations

import json
import os
import selectors
import shutil
import subprocess
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

    def start(self) -> "TerminalObserver":
        if self._process is not None:
            return self
        try:
            self._process = subprocess.Popen(
                self._command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self._environment,
                bufsize=0,
            )
        except OSError as exc:
            raise TerminalObserverError(f"Could not start Herdr terminal observer: {exc}") from exc
        return self

    def frames(self, *, heartbeat_seconds: float = 10.0) -> Iterator[dict]:
        process = self.start()._process
        if process is None or process.stdout is None:
            return
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            while True:
                ready = selector.select(max(0.25, float(heartbeat_seconds)))
                if not ready:
                    if process.poll() is not None:
                        break
                    yield {"event": "heartbeat", "data": {}}
                    continue
                line = process.stdout.readline()
                if not line:
                    break
                try:
                    record = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    yield {
                        "event": "terminal.error",
                        "data": {"message": "Herdr emitted an invalid terminal frame"},
                    }
                    continue
                if not isinstance(record, dict):
                    continue
                yield {"event": str(record.get("event") or "terminal.frame"), "data": record}
        finally:
            selector.close()
        return_code = process.poll()
        stderr = b""
        if process.stderr is not None:
            try:
                stderr = process.stderr.read(8192)
            except OSError:
                stderr = b""
        if return_code not in {None, 0}:
            yield {
                "event": "terminal.error",
                "data": {
                    "message": stderr.decode("utf-8", errors="replace").strip()
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

    def __enter__(self) -> "TerminalObserver":
        return self.start()

    def __exit__(self, _exc_type, _exc, _traceback) -> None:
        self.close()
