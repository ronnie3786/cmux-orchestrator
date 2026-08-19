# Investigation 02 — Server API Contract & Transport (for a browser client)

Investigator B report. Read-only code inspection; no servers started, no network calls.

## Summary

The harness server is a **single-process, single-machine Python stdlib `ThreadingHTTPServer`**
(`dashboard.py` → `cmux_harness/server.py`), default port **9091**, bound to **0.0.0.0** (LAN +
tailnet reachable), advertised over Bonjour as `_cmux-harness._tcp` with TXT `path=/harness`.
It speaks **plain HTTP/1.1 JSON only — no TLS, no auth, no cookies/sessions, no CORS headers,
no OPTIONS handler** (preflights get 501 from `BaseHTTPRequestHandler`).

The API surface is much larger than the iOS app uses: the iOS client (`HarnessAPI.swift`) calls
**~26 distinct paths**; the server's self-catalog (`api_discovery.py`, served at `/api/discovery`)
lists **190 `endpoint()` entries** covering harness core, objectives, workspaces, workflow
(ideas/preflights/decisions/check-ins), git, GitHub, Jira, files, reviews, push, hooks, and a
whole **Orchestrator V2** subtree (`/api/orchestrator-v2/*`) with its own React SPA
(`/orchestrator-v2`) and the server's **only SSE endpoint**.

Live updates are **client polling everywhere** except one SSE change-signal stream
(`/api/orchestrator-v2/events/stream`). The iOS app polls `/api/status`+`/api/notifications`+
`/api/feed` every **2 s**, `/api/screen` every **500 ms** when a workspace is selected, and git
status every **10 s**. The server itself polls the local **cmux macOS app's Unix socket**
(JSON-RPC v2) every `pollInterval` (default **5 s**).

A browser client is feasible: the API is already consumed by three server-side HTML/JS pages
(same-origin). The blockers are: **no CORS/preflight support**, **no auth on a 0.0.0.0 socket
with terminal-write endpoints** (send keys, git write, file read/write, native `open`), **plain
HTTP** (mixed-content if the web app is HTTPS), **no browser discovery** (Bonjour is iOS-only;
browser needs a typed URL), and **no push channel** for harness state (only polling; APNs push
is iOS-native only).

## Endpoint Catalog

### Endpoints used by the iOS app (the web-app parity set)

All are under `http://host:9091` (the iOS "base URL" is `http://host:9091/harness`, but the
transport strips the `/harness` suffix — the API actually lives at root `/api/*`;
`/harness` itself is the HTML dashboard page). **Auth: none on every endpoint.**

| Method | Path | Purpose | Request | Response (Swift model) | iOS screen/reducer |
|---|---|---|---|---|---|
| GET | `/api/status` | Engine status + all workspaces/surfaces | — | `HarnessStatus` | Root list (ConnectionReducer), polled 2 s |
| GET | `/api/log` | Harness event log | — | `[LogEntry]` | Root/activity |
| GET | `/api/notifications` | cmux notifications | — | `NotificationsResponse` | Root, polled 2 s |
| POST | `/api/notifications/read` | Mark notifications read | `MarkNotificationsReadRequest{workspaceId?,surfaceId?}` | `BasicResponse` | Root (ConnectionReducer) |
| GET | `/api/feed` | cmux feed items (approvals etc.) | — | `FeedResponse` | Workspace detail, polled 2 s |
| POST | `/api/feed/reply` | Reply to feed request (approve etc.) | `FeedReplyRequest{requestID,kind,action?,mode?,selections?}` | `BasicResponse` | Workspace feed cards |
| GET | `/api/integrations/opencode` | OpenCode integration status | — | `OpenCodeIntegrationResponse` | Workspace (OpenCode cards) |
| POST | `/api/integrations/opencode` | Install OpenCode integration | `EmptyRequest{}` | `OpenCodeIntegrationResponse` | Workspace |
| GET | `/api/screen?index&lines` | Terminal screen text (cap 500 lines) | query | `ScreenResponse{ok,screen,lines}` | Workspace detail terminal, polled 500 ms |
| POST | `/api/toggle` | Global engine enable | `ToggleRequest{enabled}` | `BasicResponse` | Settings/root |
| POST | `/api/workspace` | Per-workspace auto mode | `WorkspaceToggleRequest{index,enabled,autoMode}` | `BasicResponse` | Workspace list |
| POST | `/api/workspace-star` | Star/unstar workspace | `WorkspaceStarRequest{index,starred}` | `BasicResponse` | Workspace list |
| POST | `/api/rename` | Rename workspace (also renames in cmux) | `RenameRequest{index,name}` | `BasicResponse` | Workspace list |
| POST | `/api/send` | Send text or key to terminal | `SendRequest{index,text?,key?,surfaceId?}`; keys whitelisted server-side | `BasicResponse` | Workspace input bar |
| POST | `/api/new-session` | Create worktree + cmux workspace + deliver prompt | `NewSessionRequest{projectPath,branchName,jiraUrl,prompt,command,sessionName}` | `NewSessionResponse{ok,workspace{index,uuid},worktreePath,branchName}` | New Session view |
| GET | `/api/git-status?index` | Git status (+ editor targets) | query | `GitStatus` | Git tab, polled 10 s |
| POST | `/api/git-stage` / `/api/git-unstage` | Stage/unstage file | `GitFileRequest{index,file}` | `BasicResponse` | Git tab |
| POST | `/api/git-diff` | File diff (staged/unstaged/untracked, 50 KB cap) | `GitDiffRequest{index,file,section}` | `GitDiffResponse{ok,diff}` | Git tab diff view |
| GET | `/api/github/pr-comments?index&includeResolved` | PR review threads (shells to `gh`) | query | `GitHubPRCommentsResponse` | Git tab PR comments |
| GET | `/api/skills?index` | List local skills | query | `SkillsResponse` | Tools views |
| GET | `/api/file-search?index&q` | Fuzzy file search in workspace | query | `FileSearchResponse` | Tools/file search |
| GET | `/api/jira/assigned?project&limit` | Assigned Jira tickets (shells to `acli`) | query | `JiraTicketsResponse` | Jira tickets view |
| GET | `/api/jira/issue?q` | One Jira issue | query | `JiraTicketResponse` | Jira/new session |
| POST | `/api/attachments` | Upload file to inject into terminal | **raw body** (not multipart); headers `X-Cmux-Workspace-Index`, `X-Cmux-Workspace-UUID`, `X-Cmux-Filename` (percent-encoded), `Content-Type`; ≤20 MB | `AttachmentUploadResponse` | Input/PhotoLibraryPicker |
| POST | `/api/push/register` | Register APNs device token | `PushDeviceRegistrationRequest{token,bundleId,environment}` | `BasicResponse` | App/PushNotificationBridge (iOS-only concept) |
| POST | `/api/push/clear` | Clear pending approval push | `PushApprovalClearRequest{workspaceID,workspaceUUID,surfaceID}` | `BasicResponse` | Workspace detail |

Request body structs: `cmux-harness-ios/cmux-harness-ios/Infrastructure/API/HarnessAPIRequestBodies.swift`.
Response models: `Models/HarnessResponseModels.swift`, `WorkspaceModels.swift`, `GitModels.swift`,
`DiffModels.swift`, `GitHubPRModels.swift`, `NotificationModels.swift`,
`SkillsFileJiraAttachmentModels.swift`, `SessionStateModels.swift`.

### Server-only endpoints (used by the built-in web dashboards / orchestrator, not by iOS)

Selected groups (full list: `cmux_harness/api_discovery.py`, 190 entries; also live at
`GET /api/discovery` and `docs/API_REFERENCE.md`):

- **Discovery/health**: `GET /api/discovery`, `/api/help`, `GET|POST /api/network`, `GET /api/config`, `POST /api/config`, `GET /api/models`, `GET /api/auto-policy-costs`.
- **Reviews**: `GET /api/reviews`, `GET /api/reviews/{id}`, `POST /api/reviews/{id}/rerun|dismiss`.
- **Git by-path variants** (used by the web dashboard instead of index-based): `/api/git-status-path`, `/api/git-diff-path`, `/api/git-stage-path`, `/api/git-unstage-path`, `/api/git-commit-files`, `/api/git-commit-diff`, `/api/git-open-file`, `POST /api/file-content`, `POST /api/open-in-native`, `POST /api/resolve-dropped-files`, `POST /api/workspace-open-root`.
- **Objectives (legacy)**: full CRUD + `/start`, `/message`, `/messages`, `/screen`, `/tasks/{id}/screen`, `/tasks/{id}/approve`, `/approve-hook|plan|contracts`, `/debug`, `/build-log`, `/console-logs`, `/status-summary`, `/context-health*`, `/action-buttons*`, `/action-inject`, `/open-worktree`, `/check-in`.
- **Workspaces (session records)**: CRUD + `/start`, `/message`, `/messages`, `/screen`, `/active-turn`, `/turns/{id}/finalize`, `/debug`, `/open-root`, `/build-log`, `/console-logs`, `/status-summary`, `/action-buttons*`, `/action-inject`.
- **Workflow**: `/api/command-center`, `/api/briefing`, ideas/preflights/decisions/check-ins CRUD + actions, `/api/context-health/attention`.
- **Logs by index/path**: `GET /api/workspace-build-log`, `GET /api/workspace-console-logs`.
- **Hooks**: `POST /api/hooks/pre-tool-use` (Claude hook callback).
- **Orchestrator V2** (`/api/orchestrator-v2/*`, ~60 endpoints): bootstrap, health, tasks CRUD + links (jira/pr/cmux-sessions), agent tools + runs + transcript, chat, AG-UI, CopilotKit proxy, AI chat proxy to Node sidecar, approvals, activity/audit, left-rail (Jira/PRs), PR reviews start, cmux sessions CRUD/screen/input/kill/restart, orphans, git by-path, voice/realtime, folder-picker, watcher, and **`GET /api/orchestrator-v2/events/stream` (SSE)** + `/events/token`.

## Live-Update Model

- **Server → clients: no push for harness state.** No WebSocket anywhere in `server.py`; the only
  streaming handler is **SSE** in `routes/orchestrator_v2.py:464` (`stream_state_events`), route
  registered at `routes/orchestrator_v2.py:31` — `/api/orchestrator-v2/events/stream`. It is a
  cheap change-signal only (`event: update` + heartbeats every 15 s; client refetches full data).
  There is also an SSE proxy for AG-UI runs (`/api/orchestrator-v2/agui/runs/{runId}/events`) and
  the sidecar proxy passes through `text/event-stream` (`orchestrator_v2_runtime.py:94`).
- **iOS client: pure polling** (`Feature/Support/HarnessFeatureEffects.swift`):
  - main refresh (`/api/status` + notifications + feed): **every 2 s** (line 10),
  - terminal screen (`/api/screen`): **every 500 ms** while a workspace is selected (line 57),
  - git status (`/api/git-status`): **every 10 s** on the git tab (line 68).
- **Built-in web dashboard does the same**: `static/dashboard.html:4282` `setInterval(refresh,2000)`,
  git poll 10 s (`:2399`), plus per-view timers in `static/orchestrator.js:5479+`.
- **Server → cmux: polling.** `HarnessEngine` is a `threading.Thread` (`engine.py:43`, run loop
  `:1058`) that polls the cmux Unix socket every `pollInterval` (default **5 s**, clamped 2–30,
  `engine.py:49`, `:284`) and caches screens; `/api/screen` itself also does a live socket read.
- Server-side push exists only as **APNs** to iOS devices (`push_notifications.py`), triggered by
  auto-policy approval alerts — irrelevant to a browser unless replaced with Web Push.

## File Transfer

- **Upload** `POST /api/attachments`: **raw request body, not multipart, not chunked-encoded.**
  Requires `Content-Length`; streamed to disk in 1 MB chunks by
  `attachments.save_attachment_stream` (`attachments.py:58`). **Limit 20 MB both sides**
  (`attachments.MAX_ATTACHMENT_BYTES`, `attachments.py:15`; iOS `attachmentMaxBytes`,
  `HarnessAPI.swift:24`); server answers 413 over limit. Filename/workspace are passed in custom
  headers (`X-Cmux-Filename` percent-encoded, `X-Cmux-Workspace-Index`, `X-Cmux-Workspace-UUID`)
  — these make browser uploads **preflighted (non-simple) requests**, so they need CORS
  `Access-Control-Allow-Headers` support. Files land in `$LOG_DIR/attachments/<workspace-key>/`
  with sanitized timestamped names; 7-day retention cleanup on server start (`dashboard.py:41`).
- **No download endpoint for attachments** (upload is one-way; the path is returned and the
  server pastes it into the terminal).
- **"Binary" payloads are JSON strings**: `/api/screen` returns terminal text in JSON;
  `/api/git-diff*` returns diff text in JSON (truncated at 50 KB); `/api/reviews` truncates
  `gitDiff` to 500 chars in list; `POST /api/file-content` caps at 500 KB. No image/screenshot
  binary endpoints exist — `/api/screen` is *text* screen scraping, not a screenshot.
- Static files (HTML/CSS/JS, orchestrator-v2 SPA assets) are served with correct content types
  and a path-traversal guard (`server.py` `_serve_orchestrator_v2_static`).

## Browser Compatibility / CORS

**(a) Does the server send CORS headers today?** **No.** `_json_response` (`server.py:161`) and
the static file servers send only `Content-Type`/`Content-Length`. There is **no `do_OPTIONS`**,
so a CORS preflight hits `BaseHTTPRequestHandler`'s default → **501 Unsupported method**. The
only CORS headers in the repo are in the standalone **demo server** (`demo.py:745-777`,
`Access-Control-Allow-Origin: *` incl. the X-Cmux-* headers) — proof someone already needed this
for a browser demo, but it was never ported to the real server.

**(b) Would a web app on a different origin be blocked?** **Yes.** Any `fetch` from
`http://laptop:5173` (or any non-`:9091` origin) to `http://mac:9091/api/...` is blocked by the
browser. JSON POSTs with `Content-Type: application/json` and the attachment upload (custom
X-Cmux-* headers) are preflighted and fail hard on the 501. Workarounds: serve the web app from
the same origin (drop it into `cmux_harness/static/` like the existing dashboards), add CORS +
OPTIONS to `server.py`, or put a same-origin reverse proxy in front.

**(c) Binding: localhost or LAN?** **LAN + tailnet.** `dashboard.py:53` binds `("0.0.0.0", port)`,
default port **9091** (CLI arg 1). `/api/network` enumerates LAN IPs and Tailscale host; URLs are
`http://<host>:9091/harness`. Reachable from any machine that can route to the Mac.

**(d) Stateful / session-cookie endpoints?** **No.** No cookies, no `Set-Cookie`, no `Session`,
no per-client state. All state is global in the `HarnessEngine` singleton + JSON files under
`storage.LOG_DIR`. Requests are independent; concurrency is a global `engine._lock`.
(A browser client can be fully stateless. Caveat: several endpoints are *machine*-stateful by
nature — `/api/toggle`, `/api/workspace`, git staging mutate the one shared server.)

**(e) TLS?** **Plain HTTP everywhere.** `ThreadingHTTPServer` with no TLS wrapping; all URL
builders (`server.py` `_network_payload`, iOS `harnessURLFromHost`) hardcode `http://`.
Consequence: an HTTPS-hosted web app hits **mixed-content** blocks calling it; also APNs-style
bearer tokens, Jira/GitHub data, and terminal contents transit unencrypted on LAN/tailnet.

## herdr/cmux Integration

- **No "herdr" anywhere.** Neither `cmux_harness/` nor the iOS app references herdr; the "sessions"
  the iOS app shows are **cmux workspaces/surfaces** (which may happen to run agents like
  claude/codex/opencode inside).
- The server talks to the **cmux macOS app** (must be running locally) over a **Unix domain
  socket**, JSON-RPC "v2" (`cmux_api.py`): socket path discovery probes env `CMUX_SOCKET_PATH`,
  `~/Library/Application Support/cmux/last-socket-path`, `cmux.sock` files and tagged sockets
  (`cmux_api.py:97-165`); `_v2_request(method, params)` (`:189`) calls e.g. `workspace.list`,
  `workspace.create`, `workspace.rename`, `surface.read_text`, `surface.send_text`,
  `surface.send_key`, `surface.focus`, `system.tree`, `system.ping`, `debug.terminals`.
- Fallbacks: v1 plain-text socket command `list_workspaces` (`engine.py:943` `refresh_workspaces`),
  and the **`cmux` CLI binary** (`cmux_cli.py`, default path
  `/Users/ronnierocha/projects/cmux/build/Build/Products/Release/cmux` — a **hardcoded
  user-specific path**, overridable via `CMUX_CLI_PATH`) for session create/list/input/kill in the
  orchestrator-v2 routes and `/api/new-session` (`server.py` shells `cmux new-workspace ...`).
- **Process model assumption: single machine, single instance.** The engine must run on the same
  Mac as the cmux app (Unix socket, `subprocess` to local git/acli/gh/`open`, local FS reads,
  native folder pickers). One engine thread + one HTTP server; state files under
  `storage.LOG_DIR` (workspace records, reviews, push devices/pending, attachments). No
  multi-instance coordination; port is the only knob.
- Sidecar: `OrchestratorV2Sidecar` (`orchestrator_v2_runtime.py`) launches a **Node agent
  sidecar** from `agent/orchestrator-v2` on port 8792 (loopback only), plus a file-watcher thread;
  the Python server proxies AI/CopilotKit/AG-UI calls to it.

## Deployment & Process Model

- **Run**: `python3 dashboard.py [port]` (default 9091), or `./cmux-dashboard start|stop|restart
  [port]` (bash wrapper with PID file `/tmp/cmux-dashboard.pid`, nohup, logs
  `/tmp/cmux-dashboard.log`).
- Startup (`dashboard.py`): attachment cleanup → `HarnessEngine().start()` (background polling
  thread) → `ThreadingHTTPServer(("0.0.0.0", port))` → `BonjourAdvertiser` (`dns-sd -R
  "_cmux-harness._tcp" ... path=/harness`, `discovery.py`) → Orchestrator V2 Node sidecar +
  watcher thread → opens the dashboard in a browser unless `CMUX_HARNESS_NO_BROWSER=1`.
- **Existing web dashboards (same-origin, already doing much of what a web app needs)**:
  - `/` → `static/home.html` (landing/links),
  - `/harness` → `static/dashboard.html` — **full harness UI in vanilla JS**: workspace list,
    terminal screen, git tab, diffs, PR comments, reviews, costs; polls `/api/status` every 2 s.
  - `/orchestrator` → `static/orchestrator.html/js` (legacy objectives UI),
  - `/workflow-orchestrator` → workflow UI,
  - `/orchestrator-v2` → built **React SPA** (assets in `static/orchestrator-v2/`) with tasks,
    cmux sessions, chat, voice, left-rail Jira/PRs; uses the SSE events stream.
  - `WEB_FIRST_PRODUCT_DIRECTION.md`, `docs/API_REFERENCE.md`, `docs/API_DISCOVERY.md` document
    the web-first direction already.
- **Multi-instance**: none. Port collision is the only guard; Bonjour advertises whatever port.
  Engine/cmux/socket/FS state all assume exactly one server per Mac.
- Env-var config: `OLLAMA_URL`, `CMUX_APNS_*` (push), `CMUX_CLI_PATH`,
  `ORCHESTRATOR_V2_AGENT_PORT/URL`, `ORCHESTRATOR_V2_WATCHER_INTERVAL`, `CMUX_HARNESS_NO_BROWSER`.

## Key Code Paths

- `dashboard.py:38` port default 9091 · `:53` bind `0.0.0.0` · `:57` Bonjour · `:58-62` sidecar/watcher
- `cmux_harness/server.py:161` `_json_response` (no CORS) · `:177` attachment handler · `:327` `do_GET` · `:799` `do_POST` · `:1671` `do_PATCH` · `:1709` `do_DELETE` · `:57-81` static page map · `:269` `/api/network` payload
- `cmux_harness/api_discovery.py` — 190-entry machine-readable catalog (`GET /api/discovery`)
- `cmux_harness/attachments.py:15` 20 MB limit · `:58` streaming save · `:106` retention cleanup
- `cmux_harness/discovery.py:6` `_cmux-harness._tcp` Bonjour via `dns-sd -R`
- `cmux_harness/engine.py:43` engine thread · `:49` pollInterval=5 · `:358` `get_status` · `:943` `refresh_workspaces` (socket → CLI fallback) · `:1058` poll loop
- `cmux_harness/cmux_api.py:97-165` socket discovery · `:189` `_v2_request` JSON-RPC
- `cmux_harness/cmux_cli.py:13` hardcoded CLI path (`CMUX_CLI_PATH` override)
- `cmux_harness/routes/orchestrator_v2.py:31` SSE route · `:464` `stream_state_events`
- `cmux_harness/orchestrator_v2_runtime.py:20-22` sidecar port 8792 / python 9091
- `cmux_harness/push_notifications.py:178-205` APNs JWT (ES256) via `CMUX_APNS_KEY_ID/TEAM_ID/KEY_PATH`
- `cmux_harness/demo.py:745-777` demo server WITH CORS (only place CORS exists)
- iOS: `Infrastructure/API/HarnessAPI.swift` (endpoint funcs, 20 MB limit) ·
  `HarnessAPITransport.swift` (15 s timeout, `/harness` base-path stripping, error envelope) ·
  `HarnessAPIRequestBodies.swift` · `Models/*.swift` ·
  `Feature/Support/HarnessFeatureEffects.swift:10/57/68` (2 s / 500 ms / 10 s polling) ·
  `Infrastructure/Discovery/HarnessServerDiscovery.swift` (Bonjour NetServiceBrowser)
