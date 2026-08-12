# Herdr Harness backend

This package is a standard-library HTTP adapter for Herdr 0.8. It talks to the
native newline-delimited JSON Unix socket, caches `session.snapshot`, composes
workspace relationships without dropping unknown Herdr fields, and forwards
native events through Server-Sent Events.

`snapshot.updated` SSE records are intentionally compact. They carry focused
IDs and pane revisions, then clients fetch `/snapshot` or `/workspaces` when
they need the complete native records. This keeps the replay buffer bounded
even for large sessions.

## Run

Create a stable token once so restarting the backend does not invalidate the
credential already stored in the iOS Keychain:

```bash
mkdir -p "$HOME/.config/herdr-harness"
umask 077
openssl rand -hex 32 > "$HOME/.config/herdr-harness/api-token"
chmod 600 "$HOME/.config/herdr-harness/api-token"
```

Reuse it for every launch:

```bash
export HERDR_SESSION=herdr-ios-fixtures
export HERDR_HARNESS_API_TOKEN="$(<"$HOME/.config/herdr-harness/api-token")"
printf 'Herdr pairing token: %s\n' "$HERDR_HARNESS_API_TOKEN"
python3 herdr_dashboard.py --no-browser
```

Do not repeat the generation block unless intentionally rotating the token and
updating the iOS app.

The launcher refuses to start without authentication. An unauthenticated
loopback server is available only through the explicit development override
`--allow-insecure-local`, and that override cannot bind to a shared address.

The server binds to loopback on port `9092` by default. The setup page is at
`/`. Publish the complete REST and SSE surface privately with Tailscale Serve:

```bash
tailscale serve status
tailscale serve --bg --https=8461 9092
tailscale serve status
```

Use 8461 only when the first status command proves that exact port is unused.
If another handler owns it, choose a different unused high port, set
`HERDR_HARNESS_TAILSCALE_HTTPS_PORT` to that port, and substitute it in every
command and URL. The dedicated listener preserves the default HTTPS root but
cannot preserve a handler already on the same port. Remove only the handler you
created with `tailscale serve --https=<chosen-port> off`.

Use the exact HTTPS URL from `tailscale serve status` in the iOS app. SSE
topology and terminal-frame streams use the same origin. The raw Herdr Unix
socket is never shared. For an explicitly trusted LAN, opt in with
`HERDR_HARNESS_HOST=0.0.0.0`; bearer authentication is still mandatory through
the launcher, and the iOS app still requires HTTPS for non-loopback hosts.
To publish the verified address through `/api/v1/network`, start or restart
the backend with `HERDR_HARNESS_TAILSCALE_URL` set to that exact HTTPS URL.

Configuration:

- `HERDR_SOCKET_PATH`: explicit Herdr API socket.
- `HERDR_SESSION`: `default` or a named Herdr session.
- `HERDR_HARNESS_API_TOKEN`: bearer token required by the launcher and every
  API route. It is optional only with the explicit loopback-only
  `--allow-insecure-local` development override.
- `HERDR_HARNESS_PORT` and `HERDR_HARNESS_HOST`: listener overrides. The host
  defaults to `127.0.0.1`.
- `HERDR_HARNESS_TAILSCALE_URL`: exact verified Serve URL advertised by
  `/network`, including port or path. Tailscale identity alone is never
  reported as a working endpoint.
- `HERDR_HARNESS_TAILSCALE_HTTPS_PORT`: suggested isolated Serve port, default
  `8461`.
- `HERDR_CLIENT_SOCKET_PATH`: optional raw terminal client socket override used
  by `herdr terminal session observe`.
- `HERDR_APNS_KEY_ID`, `HERDR_APNS_TEAM_ID`, and `HERDR_APNS_KEY_PATH`: optional
  APNs token credentials.
- `HERDR_APNS_TOPIC`: default iOS bundle identifier, unless supplied during
  device registration.
- `HERDR_APNS_ENV`: `sandbox` (default) or `production`.
- `HERDR_HARNESS_PUSH_STORE_PATH`: optional persisted-device file override.
- `HERDR_HARNESS_ALERT_STORE_PATH`: persisted alert journal. The launcher
  defaults to `~/.config/herdr-harness/alerts.json` with mode `0600`.
- `HERDR_HARNESS_ATTACHMENTS_DIR`: prompt attachment storage root, default
  `~/.config/herdr-harness/attachments`. Files use mode `0600`.
- `HERDR_HARNESS_ATTACHMENT_RETENTION_SECONDS`: attachment TTL, default seven
  days. `HERDR_HARNESS_ATTACHMENT_CLEANUP_SECONDS` controls the background
  cleanup cadence, which defaults to at most one hour.
- `HERDR_HARNESS_TERMINAL_MAX_STREAMS`: concurrent terminal observer limit,
  default `8`.
- `HERDR_HARNESS_TERMINAL_MAX_SECONDS`: renewal lifetime for each observer,
  default `3600`.

For any Tailscale-shared server, set `HERDR_HARNESS_API_TOKEN` to a long random
value and configure the same value in the iOS app.

APNs background delivery requires a signed physical device, a provisioning
profile with Push Notifications, and an Apple `.p8` key whose team and topic
match the signed app. Debug device registrations use `sandbox`; Release uses
`production`. Simulator and in-app local notification tests do not prove APNs
delivery. See the root `HERDR_HARNESS.md` runbook for full device setup and
troubleshooting.

## Core API

- `GET /api/v1/health`
- `GET /api/v1/network`
- `GET /api/v1/snapshot`
- `GET /api/v1/workspaces`
- `GET /api/v1/workspaces/{id}`
- `GET /api/v1/panes/{id}/output`
- `GET /api/v1/panes/{id}/stream?cols=100&rows=32`
- `GET /api/v1/events`
- `GET /api/v1/alerts`, `POST /api/v1/alerts/{id}/read`
- `GET /api/v1/push/status`, `POST /api/v1/push/devices`, and
  `POST /api/v1/push/unregister`
- Workspace create, rename, focus, and close routes.
- Tab create, rename, focus, and close routes.
- Pane split, rename, focus, close, text, key, and atomic command routes.
- `POST /api/v1/panes/{id}/prompt` uses Herdr's agent-aware prompt API.
- `POST /api/v1/panes/{id}/start-agent` starts a supported agent in an
  existing shell pane.

Mutation results retain Herdr's native `result` object. The snapshot route
returns the raw `SessionSnapshot`. Workspace records add only `tabs`, `panes`,
`agents`, and `layouts`, each containing native Herdr records.

The pane stream route launches Herdr's terminal observer and relays its NDJSON
terminal frames as authenticated SSE. `/output` remains the low-cost text or
ANSI snapshot fallback.

APNs device registration is protected by the API bearer token and persisted in
a mode-0600 JSON file. Delivery is disabled until all signing credentials and a
topic are available. Agent `blocked` and `done` transitions enqueue delivery on
a background thread, so APNs latency never stalls the native Herdr event loop.
The implementation invokes the system `openssl` for ES256 token signing and
`curl --http2` for Apple's HTTP/2 endpoint, without third-party Python packages.
Push registration and removal return `503 api_token_required` when the harness
bearer token is not configured, even though the rest of the API may run in its
optional unauthenticated development mode.

### Mutation contract

All mutation responses are `{ "ok": true, "result": <native Herdr result> }`
unless noted. Identifiers are URL-encoded path components.

- `POST /workspaces`: `{label?, cwd?, focus?, env?}`
- `PATCH /workspaces/{id}`: `{label}`
- `DELETE /workspaces/{id}` and `POST /workspaces/{id}/focus`: `{}`
- `POST /workspaces/{id}/tabs`: `{label?, cwd?, focus?, env?}`
- `PATCH /tabs/{id}`: `{label}`
- `DELETE /tabs/{id}` and `POST /tabs/{id}/focus`: `{}`
- `PATCH /panes/{id}`: `{label}`; `null` clears the label
- `DELETE /panes/{id}` and `POST /panes/{id}/focus`: `{}`
- `POST /panes/{id}/split`: `{direction, ratio?, cwd?, focus?, env?}`
- `POST /panes/{id}/send-text`: `{text}`
- `POST /panes/{id}/send-keys`: `{keys: ["ctrl+c"]}`
- `POST /panes/{id}/run`: `{command}` for atomic text plus Enter
- `POST /panes/{id}/prompt`: `{text, wait?, until?, timeoutMs?}`
- `POST /panes/{id}/start-agent`: `{name, kind, args?, timeoutMs?}`
- `POST /alerts/{id}/read` and `POST /alerts/read-all`: `{}`
- `POST /push/devices`: `{deviceToken, bundleId, environment}`
- `POST /push/unregister`: `{deviceToken}`. Tokens never appear in URLs.

Prefix every path above with `/api/v1`. Input lengths, ratios, key names,
statuses, paths, and timeouts are bounded in `server.py`; invalid input returns
an error envelope with HTTP 4xx. `GET /api/v1` returns a machine-readable route
index. SSE sends `stream.reset` when replay continuity cannot be guaranteed.

## Demo topology

```bash
herdr --session herdr-ios-fixtures server
python3 scripts/setup_herdr_demo.py --session herdr-ios-fixtures
```

This creates three repeatable demo workspaces with three panes each in the
isolated named session. Existing workspaces are reused only when their label,
fixture marker, and pane paths prove ownership. Missing panes are repaired and
extra panes are preserved. To opt into real AI processes:

```bash
python3 scripts/setup_herdr_demo.py \
  --session herdr-ios-fixtures \
  --start-agents \
  --agent-kind codex
```

Starting real agents may consume provider quota. The script therefore requires
the explicit `--start-agents` flag. Partial failures report every agent that
was started plus a scoped recovery command. Stop the complete fixture with
`herdr session stop herdr-ios-fixtures --json`.
