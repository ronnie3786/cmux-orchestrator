# Herdr Harness

Herdr Harness is the Herdr-native companion to the original cmux harness. It
keeps Herdr's workspace, tab, pane, layout, and agent model intact, then makes
that model available to a polished SwiftUI app over authenticated HTTPS and
Server-Sent Events.

## Product shape

The app follows one deliberate path:

```text
Attention-aware workspace deck
  -> workspace topology and pane list
    -> live terminal and agent session
```

The home screen answers "where do I need to look?" before it asks the user to
navigate. Blocked agents and unseen completed work rise above active and idle
sessions. The iPhone layout uses typed stack navigation, while iPad uses a
balanced three-column split view.

Four extra capabilities go beyond the cmux version:

1. **Attention Deck:** transition-aware blocked and done alerts, ranked panes,
   unread state, deep navigation from notifications, and optional APNs.
2. **Pane Topology Radar:** a compact spatial preview built from Herdr's real
   layout rectangles and split geometry.
3. **Command Lens:** status-aware prompt suggestions, an agent-aware composer,
   and a compact Esc, arrow, Tab, and Ctrl-C key deck.
4. **Native Pi Chat:** a semantic projection of a live Pi session with native
   message turns, collapsed thinking, structured tool cards, streaming status,
   and prompt, steer, follow-up, and stop controls. The stock Pi TUI keeps
   running in the same pane and remains available as a sibling Terminal view.

The selected terminal consumes Herdr's base64 ANSI full and delta frames
directly. A bounded Swift terminal grid applies cursor movement, erasure,
dimensions, colors, and text styles without issuing a second HTTP request per
frame. If the live observer disconnects, the app retains the last good frame,
falls back to the low-cost text snapshot when necessary, and reconnects
automatically.

Git status and diffs, Skills, project-file search, Jira, and prompt attachments
reuse the existing cmux harness API. The iPhone never opens the cmux server's
plain-HTTP port directly. It sends every request through the authenticated
Herdr HTTPS API, which resolves the selected Herdr checkout and proxies the
operation to cmux on the same Mac.

## Components

- `herdr-harness-ios/`: Swift 6, SwiftUI, Observation, and structured
  concurrency. No third-party app dependencies.
- `herdr_dashboard.py`: the companion HTTP server entry point.
- `herdr_harness/`: native Herdr socket adapter, cached model, REST API, SSE,
  terminal observer bridge, alert journal, network discovery, and optional
  APNs.
- `pi-semantic-bridge/`: an optional Pi extension that publishes semantic
  lifecycle events through a private, pane-scoped Unix socket without replacing
  or parsing Pi's TUI.
- `scripts/setup_herdr_demo.py`: repeatable fixture topology with optional real
  agents.

The backend speaks newline-delimited JSON directly to Herdr's Unix socket. It
does not use tmux. Agent messages use `agent.prompt`; shell commands use
Herdr's atomic `pane.send_input`; key presses use `pane.send_keys`.

## Fresh work Mac setup

This runbook keeps the fixture data in the isolated named Herdr session
`herdr-ios-fixtures`. It does not modify an existing default or work session.
The verified stack is Herdr 0.8.0 with protocol 19, Python 3.9 or newer, Xcode
26, Swift 6, and an iOS 26 simulator or device.

### 1. Clone this branch

```bash
git clone --branch codex/herdr-harness git@github.com:ronnie3786/cmux-orchestrator.git
cd cmux-orchestrator
```

If the repository already exists on the work Mac, use `git fetch origin` and
`git switch codex/herdr-harness` instead.

### 2. Install and verify the prerequisites

Install Herdr with its official installer, then reopen the shell if `herdr` is
not immediately on `PATH`:

```bash
curl -fsSL https://herdr.dev/install.sh | sh
command -v herdr
herdr --version
python3 --version
```

The harness requires Herdr 0.8 or newer and Python 3.9 or newer. Install Xcode
26 from Apple and add an iOS 26 simulator runtime in Xcode Settings. A physical
iPhone must run iOS 26 or newer.

For private iPhone access, install Tailscale on both the work Mac and iPhone,
sign into the same tailnet, and verify the Mac CLI:

```bash
tailscale version
tailscale status
```

MagicDNS, HTTPS certificates, and Serve must be allowed by the tailnet policy.
A tailnet administrator may need to enable them. Tailscale is not required for
an iOS simulator running on the backend Mac.

A real Codex fixture also requires the Codex CLI to be installed, on `PATH`,
and authenticated with an account that has available provider quota:

```bash
command -v codex
codex --version
```

A native Pi chat fixture requires Pi 0.83 or newer. The extension can be loaded
for one session directly from this checkout, so verification does not require a
global Pi install or settings change:

```bash
command -v pi
pi --version
```

The auxiliary Git, Skills, Files, Jira, and attachment screens require the
existing cmux harness server. Start it on the same Mac and leave it running:

```bash
CMUX_HARNESS_NO_BROWSER=1 python3 dashboard.py
curl -sS http://127.0.0.1:9091/api/status
```

The Herdr backend uses `http://127.0.0.1:9091` by default. Set
`HERDR_HARNESS_CMUX_URL` only when the cmux API is listening at a different
trusted address. This upstream URL is server configuration and is never
accepted from an iPhone request.

Prompt attachments are stored and retained by cmux, not Herdr. The dashboard
cleans expired cmux attachments when it starts. Herdr resolves the live cmux
workspace UUID and index from `/api/status` by matching the server-resolved
checkout path before forwarding each upload.

### 3. Start the isolated Herdr fixture

In terminal one, start the empty headless session and leave it running:

```bash
herdr --session herdr-ios-fixtures server
```

In terminal two, create the persistent fixture directories and topology:

```bash
python3 scripts/setup_herdr_demo.py \
  --session herdr-ios-fixtures \
  --root "$HOME/.local/share/herdr-harness/demo"
```

A pristine session receives these fixture-owned workspaces:

| Workspace | Panes | Purpose |
| --- | ---: | --- |
| Herdr Command Center | 3 | Live agent overview and triage |
| Herdr Feature Lab | 3 | Implementation, tests, and notes |
| Herdr Review Deck | 3 | Review findings and release readiness |

The setup command is repeatable. It repairs missing fixture panes, preserves
extra user-created panes, and refuses to claim a colliding label or non-owned
directory. A refreshed session therefore has at least three panes per fixture
workspace, while a pristine session has exactly nine fixture panes.

To start one real Codex session in an owned fixture pane:

```bash
herdr integration install codex
python3 scripts/setup_herdr_demo.py \
  --session herdr-ios-fixtures \
  --root "$HOME/.local/share/herdr-harness/demo" \
  --start-agents \
  --agent-kind codex \
  --agent-count 1
```

Starting an agent can consume provider quota. Codex may ask to review the hook
installed by the integration command. Review it before deciding whether to
trust it. Herdr can still detect the process through its screen manifest when
the hook is not trusted.

To start one real Pi session with native Chat while preserving its ordinary TUI,
choose an owned fixture pane and load the repository extension explicitly:

```bash
herdr --session herdr-ios-fixtures agent start mobile-pi \
  --kind pi \
  --pane <pane-id> \
  --timeout 60000 \
  -- \
  --extension "$PWD/pi-semantic-bridge"
```

This starts one Pi process with two projections. Pi continues to draw and accept
input in its stock TUI. The extension only mirrors typed semantic events to the
harness, and the iOS pane screen offers native Chat and Terminal as sibling
modes. It never starts a second Pi runtime against the same session.

Verify the native state at any time:

```bash
herdr --session herdr-ios-fixtures api snapshot
```

### 4. Create a stable pairing token and start the API

Generate the bearer token once. Keep this file private and reuse the same token
after every backend restart so the Keychain value on the iPhone remains valid:

```bash
mkdir -p "$HOME/.config/herdr-harness"
umask 077
openssl rand -hex 32 > "$HOME/.config/herdr-harness/api-token"
chmod 600 "$HOME/.config/herdr-harness/api-token"
```

Do not repeat that generation block unless intentionally rotating the pairing
credential. Start the backend in terminal three:

```bash
export HERDR_SESSION=herdr-ios-fixtures
export HERDR_HARNESS_API_TOKEN="$(<"$HOME/.config/herdr-harness/api-token")"
printf 'Herdr pairing token: %s\n' "$HERDR_HARNESS_API_TOKEN"
python3 herdr_dashboard.py --no-browser
```

The backend listens only on `127.0.0.1:9092` by default. Verify it locally:

```bash
curl -sS \
  -H "Authorization: Bearer $HERDR_HARNESS_API_TOKEN" \
  http://127.0.0.1:9092/api/v1/health
```

### 5. Publish through Tailscale without replacing another handler

First inspect every existing Serve handler:

```bash
tailscale serve status
```

Use port 8461 only if that exact HTTPS port is unused. If it is already owned,
choose another unused high port, such as 8462, everywhere below. Never disable
or replace a handler you did not create for Herdr Harness.

```bash
tailscale serve --bg --https=8461 9092
tailscale serve status
```

The second command is the source of truth for the URL. It should have this
shape:

```text
https://<work-mac>.<tailnet>.ts.net:8461
```

Open that root URL in Safari on the iPhone before pairing. If desired, restart
the backend with the verified value exported so `/api/v1/network` can advertise
it:

```bash
export HERDR_HARNESS_TAILSCALE_HTTPS_PORT=8461
export HERDR_HARNESS_TAILSCALE_URL="https://<work-mac>.<tailnet>.ts.net:8461"
python3 herdr_dashboard.py --no-browser
```

The raw Herdr socket remains local to the Mac. Plain LAN access is an explicit
browser/API opt-in through `HERDR_HARNESS_HOST=0.0.0.0`; the iOS app rejects
remote plain HTTP and requires Tailscale HTTPS. To remove only the handler you
created, run `tailscale serve --https=8461 off`, substituting your chosen port.

### 6. Build and pair the iOS app

Open the shared project:

```bash
open herdr-harness-ios/herdr-harness-ios.xcodeproj
```

Select the `herdr-harness-ios` scheme and an iOS 26 destination.

- Simulator on the backend Mac: use `http://localhost:9092` and the pairing
  token. Tailscale is not required.
- Physical iPhone: use the exact Tailscale HTTPS URL from `tailscale serve
  status` and the same token. `localhost` points at the iPhone and will not
  reach the Mac.

Simulator builds do not require an Apple developer team. For a physical build,
sign into Xcode and select team `L2M32HMQZH` if it is available. Otherwise
select an accessible team and change the app to a unique bundle identifier so
Xcode can create a provisioning profile. If the bundle identifier changes,
use that same value as the APNs topic.

The server URL is editable in onboarding and Settings. The token is stored in
Keychain. If the backend token is intentionally rotated, update the saved token
in Settings before reconnecting. A built-in demo mode is available from
onboarding and through the `-HerdrDemoMode` launch argument.

### 7. Point the app at real workspaces

The backend exposes exactly one Herdr session at a time. After validating the
isolated fixture, stop the backend and restart it with the name of the existing
work session, or `default` for the default Herdr session:

```bash
export HERDR_SESSION=default
export HERDR_HARNESS_API_TOKEN="$(<"$HOME/.config/herdr-harness/api-token")"
python3 herdr_dashboard.py --no-browser
```

The app will then show that session's real workspaces, tabs, panes, layouts,
and agents with the same navigation and controls.

## API overview

All `/api/v1` endpoints support bearer authentication. The setup page at `/`
is intentionally public and contains no session data.

- `GET /api/v1/health`, `/network`, `/snapshot`, and `/workspaces`
- `GET /api/v1/events` for replayable topology and lifecycle SSE
- `GET /api/v1/panes/{id}/output` for text or ANSI snapshots
- `GET /api/v1/panes/{id}/stream` for live terminal-frame SSE
- `GET /api/v1/panes/{id}/pi/snapshot` for authoritative Pi conversation state
- `GET /api/v1/panes/{id}/pi/events` for cursor-replayable Pi semantic SSE
- `POST /api/v1/panes/{id}/pi/prompt`, `/steer`, `/follow-up`, and `/abort`
- Workspace and tab create, rename, focus, and close operations
- Pane split, rename, focus, close, text, key, and command operations
- `POST /api/v1/panes/{id}/prompt` and `/start-agent`
- Alert list, mark-read, and mark-all-read operations
- Optional APNs status, device registration, and removal operations
- Bearer-protected Herd Pulse Live Activity registration and removal operations

See `herdr_harness/README.md` for the exact contract and APNs environment
variables.

## Universal links

Any pane can be opened directly from a tappable link, so an agent that knows a
pane ID can hand the user a link that lands on that exact chat.

Two equivalent forms open the same pane:

```text
https://<mac-host>.<tailnet>.ts.net[:port]/open/pane/{paneId}
herdr://pane/{paneId}
```

Percent-encode the pane ID (`w1:p2` becomes `w1%3Ap2`). Agents should prefer
`GET /api/v1/panes/{paneId}/link` (bearer-protected), which returns
`universalLink` and `customSchemeLink` built from the harness's own notion of
its public base URL: `HERDR_HARNESS_PUBLIC_URL` if set, else
`HERDR_HARNESS_TAILSCALE_URL`, else the request's Host header when an HTTPS
front end vouches for it via `X-Forwarded-Proto` (tailscale serve sets it).

Port matters for how the link opens. Apple only matches universal links on
the default HTTPS port, so one-tap open-in-app requires fronting the harness
at 443 (`tailscale serve --bg --https=443 9092`, when 443 is free on that
Mac) and a portless base URL. On any other port — including the runbook's
dedicated 8461 — the https link still reaches the right pane, just via a
brief Safari hop: the unauthenticated `/open/pane/{paneId}` fallback page
bounces through `herdr://pane/{paneId}` (Safari asks once to open the app).
The `herdr://` form is always a direct one-tap open and needs no server.

How the pieces fit:

- `GET /.well-known/apple-app-site-association` is served unauthenticated so
  iOS can validate the associated domain. App IDs default to this project's
  team and bundle; override with a comma-separated `HERDR_HARNESS_APP_IDS`.
- `GET /open/pane/{paneId}` is an unauthenticated fallback page that bounces
  to `herdr://pane/{paneId}` when the link opens in a browser instead of the
  app. It contains no session data.
- The app entitlement uses `applinks:*.tail1db61d.ts.net?mode=developer`.
  The `mode=developer` flag makes Developer Mode devices fetch the
  association file directly from the host over the tailnet instead of
  through Apple's CDN (which cannot reach a private tailnet host). The
  fetch always targets port 443, which is why one-tap universal links
  require the 443 front. This works for Xcode-installed development
  builds; the wildcard covers every machine on the tailnet, so the same
  build works against the personal and work Macs. A different tailnet
  requires editing
  `herdr-harness-ios/herdr-harness-ios/herdr_harness_ios.entitlements`.
- `tailscale serve` must front the harness (see the setup runbook) so the
  ts.net certificate is valid; associated domains require real HTTPS.
- The custom scheme `herdr://pane/{paneId}` needs no server support and is
  the fallback when the universal link association is unavailable.

## Optional background push alerts

The app's local notification flow and Attention Deck can be exercised in the
simulator. Actual background APNs delivery requires a signed physical device,
the Push Notifications capability in its provisioning profile, and an Apple
APNs `.p8` signing key. The key's Team ID must match the signing team, and the
topic must exactly match the app bundle identifier.

Configure the backend before launch:

```bash
export HERDR_APNS_KEY_ID="<apple-key-id>"
export HERDR_APNS_TEAM_ID="<apple-team-id>"
export HERDR_APNS_KEY_PATH="$HOME/.config/herdr-harness/AuthKey_<id>.p8"
export HERDR_APNS_TOPIC="<app-bundle-identifier>"
export HERDR_APNS_ENV=sandbox
```

Debug builds register for the APNs sandbox; Release builds register for
production. Set `HERDR_APNS_ENV` to match. On the iPhone, enable Smart Agent
Alerts and grant notification permission so the device token is registered.
The in-app local test proves the UI and permission flow, not Apple's remote
delivery. Check the backend's delivery readiness with authenticated
`GET /api/v1/push/status`.

Herd Pulse can be started from the waveform button in the workspace header.
Its ActivityKit push token is registered separately from alert notification
tokens. The server sends only privacy-safe aggregate counts and connection
state to the Lock Screen and Dynamic Island. It never sends workspace names,
pane identifiers, paths, prompts, or terminal content.

## Verification

Backend regression suite:

```bash
PYTHONPYCACHEPREFIX=/tmp/herdr-harness-pycache \
python3 -m unittest -v \
  tests.test_herdr_client \
  tests.test_herdr_service \
  tests.test_herdr_push \
  tests.test_pi_semantic \
  tests.test_herdr_http \
  tests.test_herdr_network
```

iOS unit and UI suite:

```bash
xcrun simctl list devices available
SIMULATOR_NAME="<an available iOS 26 simulator>"
xcodebuild \
  -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME,OS=latest" \
  test
```

The UI smoke test drills from a ranked workspace into its pane list and then
into the live-session composer. Native Pi verification also covers real prompt,
thinking, tool success, tool failure, steer, follow-up, stop, reconnect, and
offline transcript flows while the same process remains visible in Terminal.
Unit tests cover native JSON decoding, forward-compatible fields, attention
ordering, fixture integrity, terminal full and delta frames, Pi semantic
reduction and replay, output variants, alerts, secure URL validation, and demo
actions.

## Security notes

- Use a long bearer token whenever the server is shared.
- Tailscale Serve is the recommended remote boundary.
- The iOS token is stored in Keychain.
- APNs tokens are persisted mode `0600` and never returned in full.
- APNs remains inert until explicit Apple signing credentials are configured.
- Alert history and read state are persisted mode `0600` by the launcher.
- Backend mutation inputs are bounded and validated before native Herdr calls.
- Terminal observation is read-only. Input always uses explicit action routes.
- Terminal observers are concurrency-limited and periodically renewed.
- Pi semantic sockets live in a bridge-owned mode-`0700` directory, use
  mode-`0600`, and are independently checked for type, owner, and permissions.
- Pi system prompts, provider signatures, and cumulative provider internals are
  not copied into the semantic journal or iOS stream.
- Pi transcript checkpoints and replay cursors are scoped to the selected Herdr
  session, bounded on disk, and retained for offline read-only history.

## Troubleshooting

Herdr socket or snapshot errors:

- Confirm terminal one is still running `herdr --session
  herdr-ios-fixtures server`.
- Run `herdr --session herdr-ios-fixtures api snapshot`.
- Confirm the backend's `HERDR_SESSION` names the same session.

The backend returns `401`:

- Reload `HERDR_HARNESS_API_TOKEN` from the persistent token file.
- Re-enter that same token in app Settings. Generating a new token without
  updating the app creates an intentional mismatch.

Port 9092 is already in use:

```bash
lsof -nP -iTCP:9092 -sTCP:LISTEN
```

Stop the old Herdr Harness backend or choose another
`HERDR_HARNESS_PORT`, then update the simulator or Serve target.

The Tailscale URL does not load:

- Confirm both devices are online in `tailscale status` and are in the same
  tailnet.
- Recheck `tailscale serve status`, the HTTPS port, MagicDNS, certificate, and
  tailnet Serve policy.
- Open the setup root in iPhone Safari before debugging the app.
- Remote plain HTTP is intentionally rejected by the iOS app.

Topology updates or terminal frames appear stale:

- Inspect authenticated `GET /api/v1/health`; both `connected` and
  `eventsConnected` should be true.
- Move the app to the foreground or reopen the pane to trigger a bounded SSE
  reconnect. The last good terminal frame remains visible during recovery.

Native Pi Chat is unavailable or read-only:

- Confirm the pane is running Pi with `--extension "$PWD/pi-semantic-bridge"`.
- Open Terminal mode to confirm the ordinary Pi TUI is still responsive.
- Check `GET /api/v1/panes/{id}/pi/snapshot`; `available` may remain true for an
  offline retained transcript, while `connected` must be true to send commands.
- Restarting the harness does not require restarting Pi. The bridge reconnects
  and publishes an authoritative active-branch snapshot.

Alert history cannot persist:

```bash
ls -l "$HOME/.config/herdr-harness/alerts.json"
chmod 600 "$HOME/.config/herdr-harness/alerts.json"
```

The file should be owned by the backend user and mode `0600`. If it is
malformed, stop the backend, move it to a backup name, and restart. The alert
journal will be recreated without deleting the backup.

To stop the isolated fixture and every optional real agent in it:

```bash
herdr session stop herdr-ios-fixtures --json
```
