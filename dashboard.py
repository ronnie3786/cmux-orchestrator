#!/usr/bin/env python3
"""cmux Auto-Approve Dashboard — entry point."""

import sys
import webbrowser
from http.server import ThreadingHTTPServer

from cmux_harness import attachments
from cmux_harness.engine import HarnessEngine
from cmux_harness.server import make_handler


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

    server = ThreadingHTTPServer(("0.0.0.0", port), handler_class)
    server.engine = engine

    print(f"⚡ cmux Orchestrator: http://localhost:{port}")
    webbrowser.open(f"http://localhost:{port}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
