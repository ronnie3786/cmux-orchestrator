#!/usr/bin/env python3
"""cmux Auto-Approve Dashboard — entry point."""

import errno
import os
import sys
import webbrowser
from http.server import ThreadingHTTPServer

from cmux_harness import attachments
from cmux_harness.discovery import BonjourAdvertiser
from cmux_harness.engine import HarnessEngine
from cmux_harness.orchestrator_v2_runtime import OrchestratorV2Sidecar
from cmux_harness.orchestrator_v2_watcher import OrchestratorV2Watcher
from cmux_harness.server import make_handler


_CLIENT_DISCONNECT_ERRNOS = {
    errno.EBADF,
    errno.ECONNABORTED,
    errno.ECONNRESET,
    errno.EPIPE,
}


class DashboardHTTPServer(ThreadingHTTPServer):
    """Threaded server that treats browser disconnects as normal traffic."""

    daemon_threads = True

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionAbortedError, ConnectionResetError)):
            return
        if isinstance(exc, OSError) and exc.errno in _CLIENT_DISCONNECT_ERRNOS:
            return
        super().handle_error(request, client_address)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9091

    cleanup = attachments.cleanup_old_attachments()
    if cleanup.get("deletedFiles"):
        print(
            f"[harness] Cleaned {cleanup['deletedFiles']} old attachment"
            f"{'s' if cleanup['deletedFiles'] != 1 else ''}"
        )

    engine = HarnessEngine()
    engine.callback_base_url = f"http://127.0.0.1:{port}"
    engine.start()

    handler_class = make_handler(engine)

    server = DashboardHTTPServer(("0.0.0.0", port), handler_class)
    server.engine = engine

    advertiser = BonjourAdvertiser(port)
    advertised = advertiser.start()
    v2_sidecar = OrchestratorV2Sidecar(python_port=port)
    sidecar_started = v2_sidecar.start()
    v2_watcher = OrchestratorV2Watcher(interval_seconds=600)
    v2_watcher.start()

    print(f"⚡ cmux harness home: http://localhost:{port}")
    print(f"   Harness:      http://localhost:{port}/harness")
    print(f"   Orchestrator V2: http://localhost:{port}/orchestrator-v2")
    if sidecar_started:
        print("   Orchestrator V2 agent sidecar: started")
    if advertised:
        print("   LAN discovery: Bonjour service _cmux-harness._tcp")
    if os.environ.get("CMUX_HARNESS_NO_BROWSER", "").strip().lower() not in {"1", "true", "yes"}:
        webbrowser.open(f"http://localhost:{port}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        v2_watcher.stop()
        v2_sidecar.stop()
        advertiser.stop()
        server.server_close()


if __name__ == "__main__":
    main()
