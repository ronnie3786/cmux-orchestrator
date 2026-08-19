# 02 — Herdr Harness Server API Contract & Transport (for a browser client)

**Investigator:** planner subagent (local qwen3.8-27b), read-only, plus live GET probes of
9092. **Orchestrator** independently re-verified on 2026-08-18: 401 shape, terminal-stream
503, `GET /live-activities` 404, `OPTIONS` 204, legacy `/api/*` 404s, absence of any
loopback auth bypass (`client_address` appears only in the stdlib `handle_error`
override), absence of `HERDR_HARNESS_CORS_ORIGIN` in the launch script, and the running
process's `PATH` (`/Users/ronnierocha/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin` — no
`/opt/homebrew/bin`). Orchestrator additionally **live-captured real terminal frames** by
running the herdr observer CLI directly (server-side stream is dead on the running
instance — see §4) and confirmed the `frames()` wrapping in `terminal.py`. All checks
passed; corrections from the live captures are marked **(live-verified)** below.

---

## Summary

The backend is a **single-process Python stdlib `ThreadingHTTPServer`**
(`herdr_dashboard.py` → `herdr_harness/server.py`), default port **9092**, bound to
**127.0.0.1 (loopback only)** — LAN access is deliberately out; tailnet access comes from
**Tailscale serve terminating HTTPS** (`https://ronniesitym4mbp.tail1db61d.ts.net:8461` →
`http://127.0.0.1:9092`, verified via `tailscale serve status` + `/api/v1/network`).
Unlike Phase 1 (9091: no auth, no TLS, no CORS, polling), this server has **Bearer-token
auth on every `/api/v1/*` route** (`hmac.compare_digest`, `server.py:290`), **three SSE
streams** (global events, per-pane terminal frames, per-pane Pi semantic events),
**opt-in CORS** (`HERDR_HARNESS_CORS_ORIGIN` env, off by default), and serves exactly
**one static page** (`/`, an inline setup HTML with a token-check UI).

It talks to the **Herdr** macOS app over a **Unix socket, newline-delimited JSON** (one
request `{id,method,params}\n` per line; connection-per-request for one-shots, one
long-lived `events.subscribe` stream with auto-reconnect). Live herdr is **0.8.0,
protocol 19**. Git/skills/file-search/Jira/attachments/voice are **proxied server-side**
to the cmux harness at `http://127.0.0.1:9091` (`HERDR_HARNESS_CMUX_URL`,
`cmux_tools.py:479`) — **both servers must be running** for full parity. There are **no
legacy `/api/*` routes on 9092** (handoff §4's "legacy" list is stale; everything is
`/api/v1/*` — verified live, `/api/status` → 404).

**Two live findings that will shape the plan:**
1. `GET /api/v1/panes/{id}/stream` (the terminal-frame SSE) currently returns **503
   `terminal_observer_unavailable: "herdr executable was not found"`** on the running
   server — the launchd PATH lacks `/opt/homebrew/bin` and `HERDR_BIN_PATH` is not
   exported (details §4). The frame contract was live-verified anyway by running the
   observer CLI directly (§3.2/§4).
2. `GET /api/v1/live-activities` **does not exist** (404; only POST register/unregister).
   HerdPulse data has no GET endpoint today.

## 1. Server Architecture

**Process model** (`herdr_dashboard.py`):
- Entry: `python3 -u herdr_dashboard.py --no-browser` under launchd
  `com.ronnierocha.herdr-harness` (KeepAlive, `RunAtLoad`; logs
  `~/Library/Logs/herdr-harness.log`). Args: `--host` (env `HERDR_HARNESS_HOST`, default
  `127.0.0.1`), `--port` (env `HERDR_HARNESS_PORT`, default **9092**), `--socket`,
  `--session`, `--no-browser`, `--allow-insecure-local`.
- Refuses to start without `HERDR_HARNESS_API_TOKEN` unless `--allow-insecure-local`
  **and** loopback bind (`herdr_dashboard.py:51-59`).
- Builds `HerdrClient` (socket) + `HerdrService` (state) + `make_server()`;
  `serve_forever(poll_interval=0.25)`.
- `HerdrHTTPServer(ThreadingHTTPServer)` (`server.py:1004`): `daemon_threads=True`,
  `allow_reuse_address=True`; handler `protocol_version = "HTTP/1.1"` (keep-alive).
- Service threads (`service.py`): `herdr-events` (reconnecting `events.subscribe` loop,
  `service.py:268`), `herdr-snapshot-refresh` (woken by events, `service.py:244`),
  **one `pi-semantic-*` watcher thread per detected Pi pane** (51 threads live). Global
  state = one cached snapshot under an `RLock` + `EventBroker` (deque, maxlen **1024**,
  `events.py:14`).

**TLS/HTTPS**: none in the Python process. `tailscale serve --bg --https=8461 9092`
terminates TLS (tailnet-only cert) and proxies to loopback. `/api/v1/network` returns the
serve command and suggested URL (captured §7). The loopback bind means the app is
reachable exactly two ways: `localhost:9092` and the 8461 tailnet URL.

**Herdr socket client** (`client.py`):
- Socket resolution (`client.py:84`): `HERDR_SOCKET_PATH` wins; else default session →
  `~/.config/herdr/herdr.sock`, named session →
  `~/.config/herdr/sessions/<name>/herdr.sock` (launch script sets
  `HERDR_SESSION=default`; `HERDR_CONFIG_PATH` relocates).
- Protocol: NDJSON. Request `{"id":"harness:<uuid>","method":"...","params":{}}\n` →
  response `{"id":...,"result":{...}}` or `{"id":...,"error":{"code","message"}}`.
  `events.subscribe` acks with `result.type == "subscription_started"` then streams
  `{"event":<type>,"data":{...}}` envelopes until disconnect; client auto-reconnects with
  backoff 0.25 s → 5 s (`client.py:248`), max line 32 MB.
- Status mapping herdr error code → HTTP (`server.py:171`):
  `herdr_unavailable`/`herdr_disconnected`→503, `*timeout*`→504, `*_not_found`→404,
  `conflict`/`busy`→409, `invalid_*`→400, else 502.

**Auth** (`server.py:290-310`): `Authorization: Bearer <token>` checked with
`hmac.compare_digest` against `HERDR_HARNESS_API_TOKEN` on **every** `/api/v1` route.
401 body `{"ok": false, "error": {"code": "unauthorized", "message": "A valid bearer
token is required"}}` + `WWW-Authenticate: Bearer realm="Herdr Harness"` **(live-
verified byte-exact)**. **No loopback bypass** (no remote-address check anywhere —
verified by grep; the handoff's "mirror Phase-1 P0 loopback bypass" does not apply: a
local browser session also needs the token). The **only** endpoint served before the auth
check is `GET /` (setup HTML, `server.py:343`). Unknown paths 404 pre-auth. Special
case: when no token is configured at all, `POST /api/v1/push/*` and
`POST /api/v1/live-activities*` refuse with 503 `api_token_required`
(`server.py:355-367`).

**CORS** (`server.py:256, 266-270, 981-987`): `do_OPTIONS` → **204** with
`Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS` and
`Access-Control-Allow-Headers: Authorization, Content-Type, Last-Event-ID`.
`Access-Control-Allow-Origin` (+`Vary: Origin`) is sent **only if** env
`HERDR_HARNESS_CORS_ORIGIN` is set — it is **not** set in the launch script (verified),
so cross-origin browser requests are blocked today.

**Static serving**: only `GET /` → inline `SETUP_HTML` (`server.py:62-89`, ~3.4 KB dark
status page that probes `/api/v1/health` with a manually entered token). No static
directory, no `/herdr-web`, no other assets.

**Bodies/limits**: default JSON body cap **1 MB** (`server.py:26`); attachment JSON
29 MB (`attachments.py:11`, 20 MB decoded); voice JSON 29 MB (`voice.py:9`). Common
response headers: `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`. Error
envelope: `{"ok":false,"error":{"code","message"},"generatedAt"}`.

**Upstream cmux proxy** (`cmux_tools.py`, base `HERDR_HARNESS_CMUX_URL` default
`http://127.0.0.1:9091`): server-side only; used by `/api/v1/workspaces/{id}/git*`,
`/skills`, `/files`, `/attachments`, `/api/v1/jira/*`, `/api/v1/voice/transcriptions`.
Upstream paths hit: `/api/git-status-path`, `/api/git-diff-path`, `/api/git-stage-path`,
`/api/git-unstage-path`, `/api/skills?path=`, `/api/file-search`, `/api/jira/assigned`,
`/api/jira/issue`, `/api/status`, `/api/attachments`, `/api/orchestrator-v2/voice/local/
transcribe` (`cmux_tools.py:631-938`).

## 2. Complete Route Table

All routes require Bearer (except `GET /`). IDs validated against
`^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$`. Mutation results are wrapped
`{"ok":true,"result":<herdr result>}`.

### GET

| Path | Query | Response (key fields) | Purpose |
|---|---|---|---|
| `/` (no auth) | — | HTML setup page | Status/token-check page |
| `/api/v1` | — | `{ok, service, version:1, endpoints{...}, mutations[...], generatedAt}` | Self-catalog (`server.py:204`) |
| `/api/v1/health` | — | `{ok, session, herdr:{connected, requestConnected, eventsConnected, socketFound, version, protocol, lastError}, cache:{available, stale, generatedAt}, alerts:{unread}, generatedAt}` | Liveness + connection state |
| `/api/v1/network` | — | `{ok, bindAddress, port, hostname, localName, lanAddresses[], tailscale{available, dnsName, ipv4, source}, tailscaleServeCommand, urls{localhost, tailscale, requested}, apiBasePath:"/api/v1", session, authRequired}` | URL discovery for clients |
| `/api/v1/snapshot` | — | `{ok, snapshot{version, protocol, focused_workspace_id, focused_tab_id, focused_pane_id, workspaces[], tabs[], panes[], layouts[], agents[]}, generatedAt}` | Full state; panes carry `pi_semantic` capability object when Pi detected |
| `/api/v1/workspaces` | — | `{ok, workspaces[<composite: workspace_id, number, label, focused, pane_count, tab_count, active_tab_id, agent_status, tabs[], panes[], agents[], layouts[]>], alerts[≤100], generatedAt}` | Sidebar/list view + attention data |
| `/api/v1/workspaces/{id}` | — | `{ok, workspace:<composite>, alerts:[filtered to ws], generatedAt}`; 404 if unknown | Detail view |
| `/api/v1/workspaces/{id}/git` | — | `{ok, workspace_id, root_path, branch, staged[], unstaged[], untracked[], commits[], generated_at}` (cmux-proxied) | Git tab |
| `/api/v1/workspaces/{id}/git/diff` | `file` (req), `section` (default `unstaged`) | `{ok, workspace_id, file, section, diff, truncated}` | Diff view |
| `/api/v1/workspaces/{id}/skills` | — | `{ok, workspace_id, root_path, skills_directory, user_skills_directory, project_skills[], user_skills[], skills[]}` (each `{name, skill_file_path, scope}`) | Skills view |
| `/api/v1/workspaces/{id}/files` | `q`/`query` (≤512), `limit` 1–500 (default 80) | `{ok, workspace_id, root_path, query, files[], truncated, limit}` | File search |
| `/api/v1/jira/assigned` | `project`, `limit` 1–100 (default 50) | `{ok, project, projects[], site, tickets[{key, project_key, title, status, priority, issue_type, url}]}` | Jira view |
| `/api/v1/jira/issue` | `q`/`key` (≤2048) | `{ok, site, ticket{...}}` | Single issue |
| `/api/v1/alerts` | `unread` (bool), `limit` 1–500 (default 100), `status` ∈ {blocked, done} | `{ok, alerts[], unreadCount, generatedAt}` | Attention Deck (journal, persisted) |
| `/api/v1/panes/{id}/output` | `source` ∈ {visible, recent, **recent_unwrapped** (default), detection}, `format` ∈ {text (default), ansi}, `lines` 1–5000 (default 240), `stripAnsi` (auto-true for text) | `{ok, output{pane_id, workspace_id, tab_id, source, format, text, revision, truncated}, result, generatedAt}` | Terminal text snapshot |
| `/api/v1/panes/{id}/pi/snapshot` | — | `{ok, protocol, pane_id, connected, available, capabilities{...}, session{...}, state{...}, entries[], pending_interactions[], cursor, latest_cursor, oldest_cursor, truncated, generated_at}`; 404 if pane not Pi-detected | Pi chat state |
| `/api/v1/panes/{id}/pi/models` | — | passthrough of bridge `list_models` command | Model picker |
| `/api/v1/push/status` | — | `{ok, apns{configured, environment, topicConfigured, deviceCount, liveActivityCount, reason}, generatedAt}` | APNs config visibility |
| `/api/v1/events` | `after` (int, default 0), `once` (bool) | **SSE** — see §3.1 | Core live transport |
| `/api/v1/panes/{id}/stream` | `cols` 20–300 (default 100), `rows` 8–160 (default 32) | **SSE** — see §3.2 | Terminal frames |
| `/api/v1/panes/{id}/pi/events` | `after` (int, default 0), `once` (bool) | **SSE** — see §3.3 | Pi semantic events |

### POST / PATCH / DELETE

| Method & path | Body | Purpose |
|---|---|---|
| POST `/api/v1/workspaces` | `{cwd? (abs existing dir), label? (≤120), focus? (default true), env? (≤64 valid names)}` → `workspace.create` | New workspace |
| PATCH `/api/v1/workspaces/{id}` | `{label}` → `workspace.rename` | Rename |
| DELETE `/api/v1/workspaces/{id}` | — → `workspace.close` | Close |
| POST `/api/v1/workspaces/{id}/focus` | — → `workspace.focus` | Focus |
| POST `/api/v1/workspaces/{id}/tabs` | `{cwd?, label?, focus?, env?}` → `tab.create` | New tab |
| POST `/api/v1/workspaces/{id}/git/stage` · `git/unstage` | `{file}` (≤4096) | Git staging (cmux-proxied) |
| POST `/api/v1/workspaces/{id}/attachments` | `{filename (≤512), content_type? (≤255), data_base64}` ≤ 20 MB decoded | Upload; returns `{ok, attachment{id, filename, original_filename, content_type, size, path, workspace_id, created_at}}` |
| PATCH `/api/v1/tabs/{id}` | `{label}` | Rename tab |
| DELETE `/api/v1/tabs/{id}` | — | Close tab |
| POST `/api/v1/tabs/{id}/focus` | — | Focus tab |
| PATCH `/api/v1/panes/{id}` | `{label}` (nullable) | Rename pane |
| DELETE `/api/v1/panes/{id}` | — | Close pane |
| POST `/api/v1/panes/{id}/focus` | — | Focus pane |
| POST `/api/v1/panes/{id}/split` | `{direction: right (default) \| down, focus? (default true), cwd?, env?, ratio? (0.05–0.95)}` | Split |
| POST `/api/v1/panes/{id}/send-text` | `{text}` ≤ 128 KB (may be empty) | Type text into pane |
| POST `/api/v1/panes/{id}/send-keys` | `{keys: [...]}` 1–64 entries, each `^[A-Za-z0-9+_-]{1,32}$` | Send named keys |
| POST `/api/v1/panes/{id}/run` | `{command}` ≤ 32 KB → `pane.send_input` + `["enter"]` | Run shell command |
| POST `/api/v1/panes/{id}/prompt` | `{text, wait? (bool), until? (status or [status]), timeoutMs? 100–300000}` → `agent.prompt` (wait requires `wait=true`) | Prompt a detected agent |
| POST `/api/v1/panes/{id}/start-agent` (alias `agents`) | `{name ^[a-z][a-z0-9_-]{0,31}$, kind ∈ {pi, claude, codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, maki}, args? (≤64), timeoutMs 3001–300000 (default 30000)}` → `agent.start` | Spawn agent in pane |
| POST `/api/v1/panes/{id}/pi/prompt` · `pi/steer` · `pi/follow-up` | `{text}` ≤ 128 KB | Pi semantic commands |
| POST `/api/v1/panes/{id}/pi/abort` | `{}` | Abort Pi run |
| POST `/api/v1/panes/{id}/pi/model` | **exactly** `{provider, id}` (≤256 each) | Switch Pi model |
| POST `/api/v1/panes/{id}/pi/thinking-level` | **exactly** `{level}` (≤64) | Set thinking level |
| POST `/api/v1/panes/{id}/pi/interactions/{interactionId}/respond` | subset of `{value (≤128 KB), confirmed (bool), cancelled (bool)}` | Bridge rejects today (`interactionResponse: false` → 501 `unsupported`) |
| POST `/api/v1/agents/{target}/prompt` | same as pane prompt | Prompt by agent target id |
| POST `/api/v1/alerts/{id}/read` | — | `{ok, alert, unreadCount}`; 404 unknown |
| POST `/api/v1/alerts/read-all` | — | `{ok, alerts:[changed], unreadCount}` |
| POST `/api/v1/push/devices` (alias `push/register`) | `{deviceToken\|token, bundleId? (≤255), environment: sandbox (default) \| production}` | APNs device register |
| POST `/api/v1/push/unregister` | `{deviceToken\|token}` | APNs unregister |
| POST `/api/v1/live-activities` | `{activityId, pushToken, bundleId, environment}` | Register Live Activity token + force HerdPulse update |
| POST `/api/v1/live-activities/unregister` | `{activityId, pushToken?}` | Unregister |
| POST `/api/v1/voice/transcriptions` | `{filename, mime_type? (default audio/wav), data_base64}` — strictly 16 kHz mono 16-bit PCM WAV ≤ 20 MB, ≤ 10 min | `{ok, text, backend, language}` (cmux-proxied) |

**Legacy `/api/*` on 9092: none** — `GET /api/status` etc. return 404 (verified live).
The handoff doc §4 "legacy proxied endpoints" (`/api/attachments`, `/api/file-search`,
…) do not exist on 9092; the equivalents above are all under `/api/v1`.

## 3. SSE Deep-Dive

All three streams: `Content-Type: text/event-stream; charset=utf-8`,
`Connection: keep-alive`, `X-Accel-Buffering: no`, `retry: 1000` preamble; comment-line
heartbeats `: heartbeat <iso>` when idle. Event name charset is sanitized to
`[A-Za-z0-9_.-]` (`_EVENT_NAME_RE`, `server.py:35`).

### 3.1 `GET /api/v1/events` (global broker)

- Replay: `Last-Event-ID` header **or** `?after=N` (default 0 → replays the whole ≤1024
  buffer — ~2 MB observed live). `?once=true` closes after replay (useful for tests).
- Preamble (no `id:` lines): `event: ready` →
  `{"event":"ready","generatedAt","lastEventId":110205,"oldestEventId":109182}`; then
  optionally `event: stream.reset` →
  `{"event":"stream.reset","reason":"backend_restarted"|"replay_gap","resumeAfter":N,"generatedAt"}`.
  **Meaning:** `ready` is the cursor-window handshake; `stream.reset` means the requested
  cursor is stale (server restarted, or the cursor fell out of the 1024-event ring) —
  client must resync (refetch snapshot) from `resumeAfter`.
- Event wire format: `id: <brokerSeq>` / `event: <name>` /
  `data: {"id":N,"event":"<name>","data":<payload>,"generatedAt":"..."}`.
- **Event type inventory** (server emit sites):
  - `snapshot.updated` (`service.py:230`, after every snapshot refresh):
    `{generatedAt, initial, focusedWorkspaceId, focusedTabId, focusedPaneId,
    paneRevisions:{paneId:revision}}`
  - `connection.changed` (`service.py:293`):
    `{state: "connecting"|"connected"|"disconnected", error}`
  - `alert.created` (`service.py:827`), `alert.updated` (`service.py:816/823`): full alert
    object (shape §7)
  - `push.live_activity` (`service.py:140`), `push.delivery` (`service.py:831`): APNs
    delivery results
  - `pi.<type>` (`service.py:191`): **every Pi journal event re-published globally** —
    types per §3.3
  - Raw Herdr events (`service.py:307`): SSE name = herdr event type; `data` = full herdr
    envelope, so the real payload is nested at **`data.data`**. Subscribed types
    (`client.py:26-52`): `workspace.created|updated|metadata_updated|renamed|moved|reordered|closed|focused`,
    `worktree.created|opened|removed`, `tab.created|closed|focused|renamed|moved`,
    `pane.created|closed|updated|focused|moved|exited|agent_detected`, `layout.updated`,
    plus **per-pane** `pane.agent_status_changed` for every live pane (re-subscribed when
    topology changes). Fallback name `herdr.event` if an envelope lacks `event`.
- Live 14 s capture (from `after=0`): 1022 replayed ids, then **1366×
  `pi.message_update`** (thinking deltas from an active pane), 5×
  `pi.tool_execution_update`, 3× `pi.message_start`, 3× `pi.message_end`, 2×
  `pi.tool_execution_start`, 2× `pi.tool_execution_end`, 1× `pi.turn_start`, 1×
  `pi.turn_end`. **~2 MB / 14 s** while a Pi pane streams.

### 3.2 `GET /api/v1/panes/{id}/stream` (terminal frames)

- Spawns `herdr terminal session observe <paneId> --cols C --rows R`
  (`terminal.py:33-42`); slot limited by `BoundedSemaphore(HERDR_HARNESS_TERMINAL_MAX_
  STREAMS, default 8, 1–64)` → 503 `terminal_observer_unavailable` over limit; hard
  lifetime `terminal_max_seconds` (`HERDR_HARNESS_TERMINAL_MAX_SECONDS`, default 3600,
  60–86400, `service.py:89`).
- **Record wrapping (verified by reading `terminal.py:76-119`):** the CLI emits flat
  frame records; `TerminalObserver.frames()` wraps each as
  `{"event": record.get("event") or "terminal.frame", "data": <entire raw record>}`. The
  server then sends `event: <wrapped.event>` / `data: <wrapped.data>` — so the SSE `data:`
  for a frame is the **complete raw record** below (the `data: {}` fallback in
  `server.py` is never hit for real frames).
- Preamble: `event: ready` → `{"paneId","cols","rows"}`.
- **Frame record shape (live-verified 2026-08-18 by running the observer CLI directly):**
  ```json
  {"bytes":"<base64 ANSI of the screen or delta>","encoding":"ansi","full":true,
   "height":32,"seq":1,"type":"terminal.frame","width":100}
  ```
  `encoding` is the string **`"ansi"`** (neither "base64" nor "utf-8"); the iOS app
  ignores the value — it base64-decodes `bytes` and parses UTF-8 ANSI
  (`TerminalGrid.swift:108`).
- **Emission behavior (live-verified):** frames are **content-driven, not timer-driven**.
  A fresh attach emits a `full:true` frame (`seq` starts at 1); subsequent frames arrive
  only when terminal content changes (an idle Pi pane whose status line ticks emitted
  consecutive full frames `seq 1, 2`; a quiet working pane emitted exactly 1 frame in
  15 s; a dead shell emitted 0 frames in 15 s). When the observer has no output for 10 s,
  `frames()` synthesizes `{"event":"heartbeat"}` → server writes a
  `: terminal heartbeat <ts>` **comment** (not an SSE event). **Delta frames
  (`full:false`) were not captured in this pass** (requires live terminal activity to
  observe; capturing one would require sending input, out of scope for a read-only
  investigation) — the client contract for them is defined by
  `Models/TerminalGrid.swift:106-121`: apply only if `seq > lastSequence` (stale/dropped
  deltas silently discarded), resize grid to frame dims (copy overlap, clamp cursor),
  then parse the ANSI payload.
- Terminal process exit → `event: terminal.closed` data `{"returnCode":N}`; lifetime
  reached → `event: terminal.closed` data `{"reason":"lifetime_limit"}`; bad JSON line /
  non-zero exit → `event: terminal.error` data `{"message":...[,"returnCode":N]}`
  (`terminal.py` + `server.py:865-896`, verified).
- **Live server state: 503** `{"ok":false,"error":{"code":"terminal_observer_unavailable",
  "message":"herdr executable was not found"}}` **(live-verified twice)** — see §4.

### 3.3 `GET /api/v1/panes/{id}/pi/events` (Pi semantic journal)

- Pane must be Pi-detected (404 otherwise); a disconnected bridge still serves the
  durable snapshot.
- Preamble (no `id:`): `event: pi.ready` →
  `{"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id","cursor":<client
  last_id>,"latest_cursor","oldest_cursor","connected","event":{"type":"ready","connected"},
  "generated_at"}`. Reset: `event: pi.stream.reset` with
  `event:{type:"stream.reset",reason:"backend_restarted"|"replay_gap",resumeAfter}`.
- Event wire format: `id: <pane cursor>` / `event: pi.<type>` /
  `data: {"id":<brokerSeq>,"event":"pi.<type>","data":{"protocol","pane_id","session_id",
  "cursor","event":{...type-specific...},"generated_at"},"generatedAt"}`.
- **Event types** (bridge emits, `pi-semantic-bridge.ts:786-795`): `session_start`,
  `session_shutdown`, `session_info_changed`, `session_before_switch`,
  `session_before_fork`, `session_before_compact`, `session_compact`,
  `session_before_tree`, `session_tree`, `before_agent_start`, `agent_start`,
  `agent_end`, `agent_settled`, `turn_start`, `turn_end`, `message_start`,
  `message_update`, `message_end`, `tool_execution_start`, `tool_execution_update`,
  `tool_execution_end`, `model_select`, `thinking_level_select`, `input`, `tool_call`,
  `tool_result`; plus synthesized: `bridge.connection` (harness journal
  connect/disconnect), `stream.reset` (bridge instance change / compaction),
  `bridge.payload_omitted` (>512 KB record dropped). `message_update` carries deltas
  (`assistantMessageEvent:{type:"thinking_delta"|"text_delta"|"toolCall_delta",contentIndex,
  delta}` — see §7 capture); `turn_end`/snapshot `state` carry
  `context:{tokens, contextWindow, percent}`.
- Live: replayed 3× `pi.bridge.connection` for `w1:p1`, then heartbeats at **~38 ms
  cadence** — the journal's single shared `threading.Condition` gets `notify_all` on
  every pane's ingest (`pi_semantic.py:307/375/424/486`), so with 50 active Pi panes an
  idle pane's stream wakes constantly and writes comment heartbeats. Harmless
  (EventSource ignores comments) but chatty.

## 4. Terminal Frame Format — Runtime Gap on the Running Server

`TerminalObserver` (`terminal.py:18-31`) resolves the binary via `HERDR_BIN_PATH` env or
`shutil.which("herdr")`. The **running** launchd process has
`PATH=/Users/ronnierocha/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin` (launchd user env;
verified via `ps eww` on PID 63510) — **`/opt/homebrew/bin/herdr` is not on it, and the
launch script does not export `HERDR_BIN_PATH`**. Result: every `/panes/{id}/stream`
request on the live server is 503 (verified). The frame *contract* was nevertheless
**live-verified** by orchestrator running the CLI directly (this Mac's interactive PATH
does include `/opt/homebrew/bin`): full-frame shape, `encoding:"ansi"`, content-driven
emission, `seq` from 1 on attach (§3.2). Fix = one line in the launch script
(`export HERDR_BIN_PATH=/opt/homebrew/bin/herdr` or extend PATH) + a launchd restart;
the architect should decide timing (it touches the running service — see §11 gotchas:
launchd KeepAlive revives it).

## 5. pi-semantic-bridge (README read in full)

- **What it is:** a Pi extension (TS, `pi-semantic-bridge/extensions/pi-semantic-bridge.
  ts`, own `package.json`) adding a pane-scoped semantic side channel to the stock TUI.
  Load: `herdr agent start ... -- --extension <dir>`, `pi -e <dir>` in a Herdr shell, or
  durable `pi install <dir>` (idempotent). Requires `HERDR_SOCKET_PATH` +
  `HERDR_PANE_ID` env (set by Herdr-managed shells).
- **Socket:** `/tmp/herdr-pi-<uid>/<sha256(herdr-socket-path)[:8]>-<sha256(pane_id)>.sock`
  (fallback dir `/tmp/hp-<uid>/`), dir 0700, socket 0600; harness verifies type/owner/
  mode before use (`pi_semantic.py:57-123, 802-815`).
- **Protocol:** NDJSON `herdr.pi.semantic` **v1** (forward-compatible). Wire record:
  `{protocol, pane_id, instance_id, sequence, kind: "event"|"snapshot"|"hello",
  session_id, event|snapshot|capabilities, generated_at}`. Server→bridge:
  `{type:"subscribe", instance_id, after:<seq>}` (resumes from journal position) and
  `{type:"command", command, payload}` (commands: `prompt`, `steer`, `follow_up`,
  `abort`, `list_models`, `set_model`, `set_thinking_level`,
  `interaction_response` — last one unsupported → 501).
- **Server side** (`PiSemanticManager`, `pi_semantic.py:704`): detects Pi panes from
  snapshot `panes[].agent/display_agent == "pi"` or `agents[]` (`_pi_pane_ids`), starts
  one watcher thread per pane (reconnect backoff 0.25 s→10 s), journals checkpoints
  (after `agent_settled`, before shutdown) + a bounded contiguous event suffix into
  **SQLite** `~/.config/herdr-harness/pi-semantic.sqlite3` (namespaced by sha256 of the
  Herdr socket path). Journal → main broker (`pi.<type>`), and exposed via
  `/pi/snapshot` + `/pi/events`.
- **Documented runtime check whether the bridge is loaded in a pane:**
  `GET /api/v1/panes/{paneId}/pi/snapshot` (and the `pi_semantic` object injected onto
  every Pi pane in `/api/v1/snapshot` + `/api/v1/workspaces` by `enrich_snapshot`/
  `enrich_workspaces`) — fields `connected`, `available`, `capabilities`, `cursor`.
- **Current live state (checked 2026-08-18):** 15 workspaces / 59 panes; **51 panes
  detected as Pi; 50 bridge-connected**, 1 not connected (`wK:p7`, `available:true`).
  Capability variants: 3 (newer bridges advertise
  `listModels/setModel/setThinkingLevel:true`; two older ones don't — bridge version
  skew). `w1:p1` snapshot: `connected:true, cursor:3, session 01a01036-...`,
  `state:{idle:true, model:{provider:"custom-lux-27b", id:"qwen3.8-27b-bf16"},
  thinkingLevel:"medium", context:{tokens:0, contextWindow:131072, percent:0}}`,
  2 checkpoint entries. **Journal size: 259 MB** (no visible retention/trim policy
  beyond per-pane contiguous-suffix bounds) — flag, don't act.

## 6. Uncommitted Worktree Changes

`git diff` on `herdr_harness/client.py` + `herdr_harness/service.py` (HEAD `78a6548` does
**not** contain them):

- **`client.py`:** adds `POST_17_SUBSCRIPTIONS = frozenset({"workspace.reordered"})` and
  `default_subscriptions(protocol=)` — returns the full 25-type
  `DEFAULT_SUBSCRIPTIONS` but **drops `workspace.reordered` when the server protocol is
  known and `< 19`** (comment: subscribing an unknown type makes the *entire*
  `events.subscribe` reject on older Herdr servers). `subscribe_forever` changed: when no
  provider/static list is given, it now re-reads the protocol from `session.snapshot` on
  **every reconnect** and builds a filtered subscription list (so an upgraded server
  gains the new event without a restart).
- **`service.py`:** `_subscriptions()` (the provider path actually used in production)
  now reads `self._snapshot["protocol"]` under lock and uses
  `default_subscriptions(protocol=...)` instead of the unconditional tuple.
- **Is the RUNNING server included? No.** Process 63510 (launchd, KeepAlive) started
  **2026-08-17 18:00:26**; both edited files have mtime **2026-08-17 18:49:23**;
  `__pycache__/*.pyc` mtimes are Aug 14 (pre-edit). The live server still subscribes
  unconditionally. Since live Herdr is protocol 19, behavior is currently identical; the
  shim activates on the next launchd restart. Minor nit: comment says "after protocol 17"
  but the gate is `protocol < 19` (i.e. treated as a protocol-19 feature).

## 7. Live Probe (GET only, 127.0.0.1:9092, 2026-08-18 02:24–02:28 UTC)

`GET /` (no token) → **200 text/html, 3405 bytes** (setup page). Herdr: **0.8.0 /
protocol 19 / connected** (health below).

**401 shape (no token):** `HTTP/1.1 401 Unauthorized` +
`WWW-Authenticate: Bearer realm="Herdr Harness"` + body
`{"ok": false, "error": {"code": "unauthorized", "message": "A valid bearer token is
required"}}` **(re-verified by orchestrator, byte-exact)**

**`/api/v1/health`:**
```json
{"ok":true,"service":"herdr-harness","session":"default",
 "herdr":{"connected":true,"requestConnected":true,"eventsConnected":true,"socketFound":true,
          "version":"0.8.0","protocol":19,"lastError":null},
 "cache":{"available":true,"stale":false,"generatedAt":"2026-08-18T02:24:04.351Z"},
 "alerts":{"unread":123},"generatedAt":"2026-08-18T02:24:27.606Z"}
```

**`/api/v1/snapshot`** — top: `{ok, snapshot, generatedAt}`; `snapshot` keys:
`version, protocol, focused_workspace_id, focused_tab_id, focused_pane_id, workspaces[15],
tabs[15], panes[59], layouts[15], agents[51]`. Sample composite pane (from
`/api/v1/workspaces` nesting; `layouts` carry the rects):
```json
{"pane_id":"w1:p1","terminal_id":"term_6593f5056df261","workspace_id":"w1","tab_id":"w1:t1",
 "focused":false,"cwd":"/Users/ronnierocha/Documents/Development/Doximity-Claude",
 "label":"π fresh (blank)","agent":"pi","terminal_title":"π - Doximity-Claude",
 "agent_status":"idle","agent_session":{"source":"herdr:pi","agent":"pi","kind":"path",
  "value":"~/.pi/agent/sessions/.../2026-08-14T02-07-13....jsonl"},
 "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":215,"viewport_rows":26},"revision":1,
 "pi_semantic":{"available":true,"connected":true,"protocol_version":1,"session_id":"01a01036-...",
  "cursor":3,"oldest_cursor":1,
  "capabilities":{"prompt":true,"steer":true,"followUp":true,"abort":true,"listModels":false,
   "setModel":false,"setThinkingLevel":false,"interactionResponse":false}}}
```
```json
"layouts[0]": {"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,
 "area":{"x":36,"y":1,"width":204,"height":56},"focused_pane_id":"w1:p6",
 "panes":[{"pane_id":"w1:p1","focused":false,"rect":{"x":36,"y":1,"width":26,"height":28}},
          {"pane_id":"w1:p6","focused":true,"rect":{"x":87,"y":1,"width":51,"height":28}}]}
```
(These are **terminal-cell** coordinates: `area` = tab area in cols/rows, each pane a
`rect` inside it — exactly what the Topology Radar needs.)

**`/api/v1/workspaces`** — `{ok, workspaces[15], alerts[100], generatedAt}`; workspace
keys: `workspace_id, number, label, focused, pane_count, tab_count, active_tab_id,
agent_status, tabs[], panes[], agents[], layouts[]`. Alert sample (journal, cap 500,
125 persisted, 123 unread):
```json
{"id":"alert_4b25b4d155ab49418b5bffe1d46a3acc","kind":"agent_done","status":"done",
 "previousStatus":"working","severity":"success","title":"pi finished",
 "message":"Work completed in Development: π - Development.",
 "workspaceId":"wN","workspaceLabel":"Development","tabId":"wN:t1","tabLabel":"Development pi",
 "paneId":"wN:p6","paneTitle":"π - Development","agentName":"pi",
 "createdAt":"2026-08-18T02:24:04.263Z","isRead":false,"readAt":null,
 "action":{"type":"open_pane","paneId":"wN:p6"}}
```
**`/api/v1/alerts?limit=2`** → `{ok, alerts[...], unreadCount:123, generatedAt}` (same
alert shape).

**`/api/v1/network`:**
```json
{"ok":true,"bindAddress":"127.0.0.1","port":9092,"hostname":"ronniesitym4mbp.lan",
 "localName":"ronniesitym4mbp.local","lanAddresses":["192.168.86.52"],
 "tailscale":{"available":true,"dnsName":"ronniesitym4mbp.tail1db61d.ts.net","ipv4":"",
  "source":"environment"},
 "tailscaleServeCommand":"tailscale serve --bg --https=8461 9092","tailscaleServePort":8461,
 "urls":{"localhost":"http://localhost:9092","localName":"","tailscale":"https://ronniesitym4mbp.tail1db61d.ts.net:8461",
  "tailscaleSuggested":"https://ronniesitym4mbp.tail1db61d.ts.net:8461","requested":"http://127.0.0.1:9092"},
 "apiBasePath":"/api/v1","session":"default","authRequired":true}
```

**`/api/v1/jira/assigned?limit=2`:**
```json
{"ok":true,"project":null,"projects":["IOSDOX"],"site":"doximity.atlassian.net",
 "tickets":[{"key":"IOSDOX-26368","project_key":"IOSDOX",
  "title":"Enable Text Selection in SwiftUI Markdown View","status":"In Progress",
  "priority":"Medium","issue_type":"Story",
  "url":"https://doximity.atlassian.net/browse/IOSDOX-26368"}]}
```

**`/api/v1/panes/w1:p1/output?lines=12`:**
```json
{"ok":true,"output":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1",
 "source":"recent_unwrapped","format":"text",
 "text":" update\n Changelog:\n https://pi.dev/change\n...\n~/Documents/Developm...\n0.0%/131k (auto)  (cust\n🔌 MCP: 6 servers en...","revision":0,"truncated":true},
 "result":{...},"generatedAt":"..."}
```

**`/api/v1/push/status`:** `{"ok":true,"apns":{"configured":false,"environment":"sandbox",
"topicConfigured":false,"deviceCount":1,"liveActivityCount":0,
"reason":"HERDR_APNS_KEY_ID, HERDR_APNS_TEAM_ID, and HERDR_APNS_KEY_PATH are
required"},"generatedAt":"..."}` — APNs **not configured** on this Mac (one iOS device
registered in `push-devices.json`).

**`/api/v1/events` (14 s, `curl -N`):** `retry: 1000` → `event: ready`
`data: {"event":"ready","generatedAt":"...","lastEventId":110205,"oldestEventId":109182}`
→ immediate replay of the 1024-buffer (ids 109182… with `id:` on every line), then live
events. Type counts: 1366 `pi.message_update`, 5 `pi.tool_execution_update`, 3
`pi.message_start`, 3 `pi.message_end`, 2 `pi.tool_execution_start`, 2
`pi.tool_execution_end`, 1 `pi.turn_start`, 1 `pi.turn_end` (~2 MB). Sample:
```
id: 109184
event: pi.message_update
data: {"id":109184,"event":"pi.message_update",
 "data":{"protocol":{"name":"herdr.pi.semantic","version":1},
  "pane_id":"wN:p1","session_id":"01a00f1d-...","cursor":22025,
  "event":{"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":" and"},
   "type":"message_update"},
  "generated_at":"2026-08-18T02:25:25.777Z"},"generatedAt":"2026-08-18T02:25:25.799Z"}
```

**`/api/v1/panes/w1:p1/pi/events`:** `event: pi.ready`
`data: {"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"w1:p1","cursor":0,
"latest_cursor":3,"oldest_cursor":1,"connected":true,"event":{"type":"ready","connected":true}}`
→ replay `id: 1..3` all `pi.bridge.connection` (connected true/false/true) → heartbeat
comments.

**`/api/v1/panes/wN:p6/stream?cols=100&rows=32`:** `{"ok":false,"error":
{"code":"terminal_observer_unavailable","message":"herdr executable was not found"}}`
(503) — root cause §4; direct-CLI captures in §3.2.

**`GET /api/v1/live-activities`:** 404 `{"ok":false,"error":{"code":"not_found",
"message":"Endpoint not found"}}` **(re-verified by orchestrator)**.
**`OPTIONS /api/v1/health`:** 204 with the Allow-Methods/Allow-Headers (no
`Access-Control-Allow-Origin` — env not set) **(re-verified by orchestrator)**.

## 8. Decisions the Architect Must Make

1. **Static serving vs new port:** serve the web app from 9092 at `/herdr-web` (small
   `server.py` change; same-origin makes CORS moot, matches handoff recommendation) vs.
   separate origin + `HERDR_HARNESS_CORS_ORIGIN` (OPTIONS preflight already implemented
   and lists `Authorization, Content-Type, Last-Event-ID`).
2. **SSE auth for browsers:** native `EventSource` **cannot set the `Authorization`
   header**, and the server accepts Bearer **only** via header (no `?token=` query
   support). Options: add a `?token=` fallback in `server.py`, do fetch+ReadableStream
   SSE (headers work), or accept the Phase-1-style `#token=` fragment + fetch transport
   for *all* traffic. This is the single biggest transport decision.
3. **Terminal stream is dead on the live server** (`herdr` not on launchd PATH, no
   `HERDR_BIN_PATH`). Decide: fix the launch script + restart (server-side change,
   touches the running service) vs. defer web terminal until then vs. fall back to
   `/panes/{id}/output` polling for v1. The frame contract (§3.2/§4) is
   **live-verified for full frames**; delta frames still need an on-wire sample — plan a
   verification step during implementation (a pane with live output will produce them).
4. **Event volume / replay strategy:** fresh `EventSource` with no cursor replays up to
   1024 events (~2 MB under Pi activity). Decide initial-connection strategy (connect
   with `?after=` once known, or tolerate replay) and `stream.reset` handling (refetch
   snapshot on `replay_gap`/`backend_restarted`).
5. **HerdPulse parity:** there is **no GET HerdPulse endpoint** (handoff §4 was wrong) —
   derive from `snapshot.updated` + `alerts` + pane `agent_status`, or skip;
   APNs/Live-Activity registration exists but APNs is unconfigured on this Mac (push is
   a no-op here).
6. **Readiness of `pane.send-keys` for the key deck:** keys are a strict whitelist
   `^[A-Za-z0-9+_-]{1,32}$` (e.g. `enter`, `escape`, `up`) — verify exact key names
   Herdr accepts before building the Command Lens key deck (only the regex is verifiable
   here; the iOS app sends `up/down/tab/enter/left/right/escape/backspace`).
7. **Pi Chat data path:** everything flows through the 9092 API (`pi/snapshot` +
   `pi/events` + `pi/*` commands) — no browser Unix-socket involvement. Decide v1 depth
   given capability skew (older bridges lack `setModel`/`setThinkingLevel`) and that
   `interactionResponse` is unsupported (501).

## 9. Unknowns / Risks

- **Delta terminal frames unverified on the wire** — contract taken from
  `TerminalGrid.swift`; full frames live-verified. Delta-gap behavior (silently dropped
  `seq <= lastSequence`) may force client-side resync logic via `TerminalRefreshPolicy`
  (see doc 01 §4.5).
- **Broker ring is only 1024 events** and Pi streaming produces >100 events/s per active
  pane — any browser disconnect longer than a few seconds will hit `replay_gap`; the web
  client must treat `stream.reset` + snapshot refetch as the normal resync path, not an
  error.
- **Pi journal growth** (259 MB SQLite, no visible retention) — not a web concern
  directly, but `pi/snapshot` entries are bounded checkpoint suffixes, so snapshot size
  is safe; expect the file to keep growing.
- **Heartbeat comment flood** on `pi/events` from the shared condition
  (`notify_all` on any pane) — wasteful but benign; don't build UI on comment cadence.
- **Both servers required**: git/skills/files/attachments/Jira/voice on 9092 are
  502-prone if the 9091 cmux harness is down (envelope maps upstream failures via
  `cmux_tools_error`).
- **Capability skew across Pi panes** (3 capability variants observed) — UI must read
  per-pane `capabilities`, not assume.
- **Alert journal state**: 123 unread of 125 (cap 500) — Attention Deck should assume a
  dirty journal and lean on `unreadCount`/`read-all`.
- **No loopback auth bypass** exists (contrary to the handoff's "mirror Phase-1 P0"
  suggestion) — local browser use also needs the Bearer token.
- The running server predates the `POST_17_SUBSCRIPTIONS` shim (§6); irrelevant on
  protocol 19, but any investigation of "what does the running server subscribe to"
  should remember it's the pre-shim code until the next launchd restart.

## Key Code Paths

- `herdr_dashboard.py:44-70` port/token gate · `:78-86` service env defaults (alert
  store, pi store)
- `herdr_harness/server.py:26` 1 MB body cap · `:62-89` setup HTML · `:171` herdr→HTTP
  status map · `:204` api_description · `:256` CORS env · `:290` Bearer check ·
  `:340-409` dispatch (auth order, push guard, body caps) · `:411-804` route table ·
  `:806` `/events` SSE · `:865` terminal SSE · `:898` pi SSE · `:981` do_OPTIONS ·
  `:1004` server class
- `herdr_harness/client.py:26` DEFAULT_SUBSCRIPTIONS · `:56-65` POST_17 shim
  (uncommitted) · `:84` socket resolution · `:200` one-shot request · `:248`
  subscribe_forever (reconnect/backoff)
- `herdr_harness/service.py:82-96` terminal limits · `:148` start/threads · `:185-242`
  snapshot refresh + `snapshot.updated` · `:250-262` `_subscriptions` (uncommitted
  protocol gate) · `:296-310` event handling · `:789-803` health
- `herdr_harness/terminal.py:28-31` binary resolution (503 root cause) · `:44-59`
  observe command · `:61-119` frames (wrap, heartbeat/error/closed)
- `herdr_harness/events.py:13-48` broker (1024 ring, wait_after)
- `herdr_harness/pi_semantic.py:57` socket path · `:154-690` journal (ingest/bounds/
  wait/snapshot) · `:704-1030` manager (watchers, commands, capability, enrich)
- `herdr_harness/cmux_tools.py:479` `HERDR_HARNESS_CMUX_URL` · `:627-938` proxied ops
- `pi-semantic-bridge/extensions/pi-semantic-bridge.ts:786-795` emitted event list ·
  `:390-448` record shaping (event/snapshot/hello)
- iOS (contract cross-check): `herdr-harness-ios/herdr-harness-ios/Models/APIResponses.
  swift:100` `TerminalFrame` · `Models/TerminalGrid.swift:106-121` full/delta apply ·
  `Infrastructure/HerdrAPIClient.swift:527-560` terminal SSE parser
  (ready/heartbeat/frame/closed/error)
