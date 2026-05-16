# Native Mac Harness App Spec

## Goal

Build a separate native macOS app for cmux harness that provides the same core workflow as the native iOS app while also owning the local harness server lifecycle. Launching the Mac app should start and monitor the bundled `dashboard.py` server, removing the need to manually run `python3 dashboard.py`.

The app remains a companion to the existing cmux Mac app. It talks to cmux through the existing Automation socket and keeps the harness/dashboard APIs as the integration boundary.

## Product Shape

The Mac app is a native SwiftUI app that presents the harness experience directly on macOS:

- Session list and session detail.
- Terminal screen mirroring.
- Send text and allowed key commands.
- cmux Feed approval/reply flow.
- Auto mode controls.
- Git status, staging, diffs, and PR comment tools.
- Jira ticket lookup and assigned-ticket browsing.
- File search, skills, attachments, prompt helpers.
- Settings for server status, cmux socket health, Tailscale, GitHub CLI, Atlassian CLI, and review settings.

The app also exposes the same local HTTP server used by the browser and iOS app so existing clients continue to work:

- `http://localhost:9091/`
- `http://localhost:9091/harness`
- `/api/...`
- Bonjour service `_cmux-harness._tcp`

## Recommended Architecture

Use a two-process app:

1. **Native Mac shell**
   - SwiftUI app target.
   - Reuses as much of the iOS SwiftUI/TCA feature code as practical.
   - Owns server launch, health, restart, and shutdown.
   - Talks to the local harness APIs through the existing `HarnessClient`.

2. **Bundled harness server**
   - Package the Python harness code and `dashboard.py` with the app.
   - Start it as a child process on app launch.
   - Keep the current HTTP API as the contract.
   - Keep browser and iOS compatibility.

This avoids forking cmux and keeps cmux as an external dependency with a stable Automation socket boundary.

## Repo Layout

Add a new sibling app next to the iOS app:

```text
cmux-harness-mac/
  cmux-harness-mac.xcodeproj
  cmux-harness-mac/
    App/
      cmux_harness_macApp.swift
      MacAppDelegate.swift
      ServerSupervisor.swift
      ServerStatusMenu.swift
    Feature/
      MacHarnessFeature.swift
      SharedHarnessFeatureAdapters.swift
    Views/
      Root/
      Sessions/
      Git/
      Jira/
      Settings/
    Infrastructure/
      API/
      Persistence/
      Server/
    Resources/
      Python/
        dashboard.py
        cmux_harness/
```

Longer term, extract shared Swift code from the iOS target into a local Swift package:

```text
Packages/HarnessShared/
  Sources/HarnessShared/
    API/
    Models/
    FeatureCore/
    Views/
```

That package should hold models, API transport, reducers, and reusable views. The iOS and Mac apps can then supply platform-specific shells and controls.

## Server Bundling

Phase 1 should bundle the current Python files and run them with the system Python:

```text
/usr/bin/env python3 dashboard.py 9091
```

The app should set:

- `PYTHONPATH` to the bundled resource directory.
- Working directory to the app resource directory or repo directory in Debug.
- Optional `CMUX_HARNESS_PORT`, default `9091`.
- Optional `CMUX_SOCKET_PATH` passthrough.

Phase 2 can improve distribution by embedding a standalone Python runtime or producing a PyInstaller/Briefcase-style server executable, but that is not needed for the first usable build.

## Server Supervisor

Create `ServerSupervisor` as an `ObservableObject` or TCA dependency responsible for:

- Finding an available port, defaulting to `9091`.
- Starting `dashboard.py`.
- Polling `/api/status` and `/api/network`.
- Publishing server state: stopped, starting, running, unhealthy, crashed.
- Capturing recent stdout/stderr for diagnostics.
- Restarting the server on crash unless disabled.
- Stopping the server on app quit by default.
- Offering "Open Browser Dashboard" for `/harness`.

The server should bind to `0.0.0.0` as it does today so iPhone clients still connect over LAN or Tailscale. The app UI must clearly show that this exposes local control APIs on the network.

## Server Security

Before broader distribution, add an optional shared-token gate to the Python API:

- Generate a token on first Mac app launch.
- Store it in Keychain.
- Pass it to the server through an environment variable.
- Add `Authorization: Bearer <token>` or `X-Cmux-Harness-Token`.
- Let localhost browser access remain easy during development, but require the token for LAN/Tailscale access.

This is important because the current API can send terminal input, create sessions, upload attachments, and change automation state.

## Mac UI Scope

### First Screen

Unlike iOS, the Mac app should not lead with a connection setup page when it is managing the server itself. The first screen should be the working harness:

- Left sidebar: sessions/workspaces, filters, connection state.
- Main pane: selected session terminal.
- Right inspector or tabbed detail: Git, PR comments, Jira, files, attachments, logs.
- Top toolbar: server state, cmux socket state, new session, refresh, settings.

If the server or cmux socket is unavailable, show inline recovery panels in the working layout rather than a separate onboarding wall.

### Feature Parity With iOS

Reuse or port:

- Local demo mode for UI testing without cmux.
- Server status and workspace polling.
- Session list sorting, starring, filtering, and search.
- Terminal screen view and prompt input.
- New Claude/shell session flow.
- Auto/off/super-auto controls.
- Feed approval responses.
- Git status, staged/unstaged/untracked groups.
- Diff viewer.
- GitHub PR comments and prompt insertion.
- Jira assigned tickets and lookup.
- File search and skill insertion.
- Attachment upload.
- Push approval handling is replaced on Mac by local notifications.

### Mac-Specific Additions

- Menu bar status item: server running, cmux connected, workspace count.
- Dock/menu commands:
  - Start Server
  - Stop Server
  - Restart Server
  - Open Browser Dashboard
  - Open cmux
  - Copy iPhone URL
- Local notifications for human approval alerts.
- Settings page for:
  - server port
  - launch server at app start
  - keep server running after closing window
  - Tailscale host
  - GitHub/Jira CLI diagnostics
  - APNs token settings only if iOS push remains supported

## API Compatibility

Keep these current API routes intact because the iOS app and browser dashboard already depend on them:

- `GET /api/status`
- `GET /api/log`
- `GET /api/feed`
- `POST /api/feed/reply`
- `GET /api/screen`
- `POST /api/toggle`
- `POST /api/workspace`
- `POST /api/workspace-star`
- `POST /api/rename`
- `POST /api/send`
- `POST /api/new-session`
- Git routes: status, stage, unstage, diff.
- GitHub PR comment routes.
- Jira routes.
- File search and skills routes.
- Attachment upload routes.
- Network and config routes.

The Mac app should consume those APIs just like iOS in Phase 1. Direct in-process Swift-to-Python coupling should be avoided.

## Build Phases

### Phase 0: Code Sharing Prep

- Identify iOS files safe to share: models, API transport, request bodies, response models, reducers, reusable views.
- Move shared code into a local Swift package or duplicate lightly for the first prototype.
- Keep iOS behavior unchanged.

### Phase 1: Mac App Shell + Server Management

- Create macOS SwiftUI app target.
- Add `ServerSupervisor`.
- Bundle Python harness resources.
- Start `dashboard.py` on launch.
- Show server health, cmux socket health, and workspace count.
- Add "Open Browser Dashboard".

Exit criteria:

- User can launch Mac app and browse to `/harness` without manually running Python.
- iPhone app can connect to the Mac app-managed server.
- cmux app sessions appear when cmux Automation is enabled.

### Phase 2: Native Mac Harness UI

- Port session list and terminal detail.
- Add send text/key controls.
- Add auto-mode controls.
- Add Feed approval UI.
- Add new session flow.

Exit criteria:

- Core daily cmux control works without using the browser dashboard.

### Phase 3: Git, Jira, Files, Attachments

- Port Git status and diff views.
- Port PR comment lookup and prompt insertion.
- Port Jira ticket browsing and lookup.
- Port file search, skills, and attachment upload.

Exit criteria:

- Mac app has practical feature parity with iOS for coding workflow support.

### Phase 4: Distribution Hardening

- Add token-based LAN auth.
- Add app sandbox/hardened runtime decisions.
- Decide whether to embed Python or require system Python.
- Add signed release workflow.
- Add migration handling for config in `~/.cmux-harness`.

Exit criteria:

- A signed app can be installed and used by a non-developer Mac account with cmux installed.

## Packaging Decision

Recommended first build:

- macOS app target in Xcode.
- Bundle Python source as resources.
- Use system `python3`.
- Keep config/log storage in `~/.cmux-harness`.

Recommended later build:

- Produce a standalone harness server binary or embedded Python runtime.
- Code sign app plus helper/server payload.
- Add update path.

## Testing Plan

Automated:

- Python route tests remain unchanged.
- Add tests for server token auth once introduced.
- Swift unit tests for URL normalization, server supervisor state transitions, and reducer behavior.

Manual smoke:

1. Launch cmux.
2. Enable Automation socket.
3. Launch Mac harness app.
4. Confirm server starts.
5. Confirm `/api/status` returns `socketFound: true`, `connected: true`.
6. Confirm browser `/harness` works.
7. Confirm iOS app discovers/connects to the Mac app-managed server.
8. Confirm sending text to a cmux workspace works.
9. Confirm new session creation works.
10. Confirm Git, Jira, and file features work in a real repo.

## Main Risks

- Python runtime packaging can become the largest distribution issue.
- Current local HTTP API has no network auth.
- macOS sandboxing may conflict with launching Python, running CLIs, reading repos, opening files, and talking to Unix sockets.
- Sharing iOS SwiftUI views directly may be less efficient than sharing models/reducers and building Mac-specific layouts.
- Port collisions on `9091` need graceful fallback or clear user control.

## Recommendation

Build the Mac app as a separate companion app with an app-managed bundled server. Keep the HTTP API as the contract, reuse the iOS app's client/model/reducer work where practical, and defer any fork of cmux until there is a proven need to move features directly into the terminal app.
