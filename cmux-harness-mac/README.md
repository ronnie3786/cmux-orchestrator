# cmux Harness Mac

Native SwiftUI macOS companion app for the cmux harness.

The app starts in managed-server mode. On launch it can start `dashboard.py`, polls the local harness APIs, and shows the same core surfaces as the iOS harness app: sessions, terminal mirroring, Feed approvals, Git status/diffs, PR comments, Jira tickets, file/skill references, attachments, voice notes, logs, and settings. Local Demo mode is available from the toolbar for UI work without cmux.

Settings cover the managed server port, launch-at-start behavior, whether to keep the server running after the window closes, crash restart behavior, Tailscale host connection, GitHub/Atlassian CLI diagnostics, and current review backend status.

## Run From This Checkout

```bash
cd cmux-harness-mac
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift run cmux-harness-mac
```

When running from this checkout, the app finds `../dashboard.py` and `../cmux_harness` automatically. You can also set:

```bash
CMUX_HARNESS_REPO_ROOT=/path/to/cmux-orchestrator
CMUX_HARNESS_PORT=9091
```

## Build

```bash
cd cmux-harness-mac
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift build
```

## Smoke Check

```bash
cd cmux-harness-mac
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift run cmux-harness-mac --smoke
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift run cmux-harness-mac --server-smoke 9101
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift run cmux-harness-mac --render-smoke /tmp/cmux-harness-mac-render-smoke
```

## Package `.app`

```bash
cd cmux-harness-mac
bash Scripts/package-mac-app.sh
```

The bundle is written to `.build/dist/cmux Harness.app`, includes `dashboard.py` plus `cmux_harness/` under `Contents/Resources/Python`, and is ad-hoc signed for local testing when `codesign` is available.

## Current Packaging State

The package script creates a local ad-hoc signed `.app` bundle with Python resources included. The next distribution step is Developer ID signing/notarization and, if needed, replacing the Python source bundle with a standalone server executable.
