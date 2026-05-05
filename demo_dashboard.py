#!/usr/bin/env python3
"""Run the public cmux Harness demo backend used for TestFlight review."""

import os
import sys
from http.server import ThreadingHTTPServer

from cmux_harness.demo import DemoHarness, make_demo_handler


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", "9097"))
    demo = DemoHarness()
    handler_class = make_demo_handler(demo)
    server = ThreadingHTTPServer(("0.0.0.0", port), handler_class)

    print(f"cmux harness demo server: http://localhost:{port}")
    print(f"Use in iOS: http://localhost:{port}/harness")
    print("Reset state: POST /api/demo/reset")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
