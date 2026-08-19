# 03 — Feasibility Assessment — Herdr Harness Web App (iOS parity)

**Author:** coder-bee subagent (qwen3.8-27b-bf16:medium — first pipeline step run on the
user-level agent per Ronnie's instruction), read-only. **Orchestrator** re-verified on
2026-08-18: all line counts (server.py 1026, herdr_dashboard.py 106, events.py 50,
TerminalGrid.swift 419, PiConversationReducer.swift 761, PiConversationStore.swift 389,
PiConversationSSEParser.swift 82, TerminalRefreshPolicy.swift 26), the pre-auth dispatch
insertion point (`server.py:340-348`, `path == "/"` branch before the `api/v1` 404 check),
the `deque(maxlen=...)` broker ring, `streamSilenceLimit = 25`, and Phase-1
`package.json`/`vite.config.ts` values. One citation corrected: the static-serving copy
pattern `_serve_orchestrator_v2_static` lives in **Phase-1's 9091 codebase**
(`cmux_harness/server.py:312`), not in `herdr_harness/server.py` — it is a reference
pattern from the sibling server, and 9092 has no static mount today.

**Inputs:** `docs/herdr-web/00-handoff.md`, `01-investigation-ios-app.md`,
`02-investigation-api-server.md`; Phase-1 `docs/web-app/03-feasibility-assessment.md`
(structure template); `frontend/harness-web/src/` (21 test files, ~19.5k LOC; 13 phase
commits); worktree `cmux-herdr-harness` @ `78a6548` spot-checked read-only.

---

## Verdict

**FEASIBLE — and structurally simpler than Phase 1 in the places that mattered.**

Phase 1's hard problem (no auth, no streaming, hand-rolled polling) is inverted here: the
9092 server is *already* a browser-grade API — Bearer auth, three purpose-built SSE
streams, CORS preflight, and an HTML shell pattern (`GET /` → `SETUP_HTML`) that
anticipates a token-entry web client (doc 02 §1). The iOS app itself is a thin
event-driven client: **one global SSE + one terminal SSE per open pane + one Pi SSE per
open Pi pane, with no global polling loop** (doc 01 §5). That maps cleanly onto a React
app: Phase 1's zustand store architecture survives; its polling transports are deleted
and replaced by a single ~250-LOC fetch-based SSE client.

What changes shape vs Phase 1:

1. **Transport:** polling stores → event-driven stores around `/api/v1/events`
   (doc 02 §3.1). The store *topology* is the same; the *cadence engine* is replaced.
2. **Auth:** `X-Cmux-Token` on plain HTTP with loopback bypass → `Authorization: Bearer`
   with **no loopback bypass** (verified in `_authorized`, `herdr_harness/server.py:290-310`
   — header check only, no address logic). Local browser use needs the token too, exactly
   like the iOS app.
3. **Terminal:** Phase 1 polled `/api/screen` at 500 ms and rendered linear ANSI text.
   Here the server pushes **cursor-addressed grid frames** (full + delta, `seq`-deduped)
   over SSE, with an 850 ms text-snapshot arbitration layer (doc 01 §4.5). This is the
   single largest new engineering chunk: porting `TerminalGrid.swift` (419 lines,
   verified) to TS.
4. **New major surface: Native Pi Chat.** ~30 `Models/Pi*` files (28 verified) + a
   761-line self-contained reducer (`PiConversationReducer.swift`) that is a bounded,
   unit-testable port with an all-HTTP data path (doc 01 §4.4, doc 02 §3.3). No browser
   Unix sockets involved.
5. **Server diff is smaller than Phase 1's** — Phase 1 needed auth invented; here it's a
   static mount + a one-line launch-script PATH fix.

Conditions: (a) serve same-origin from 9092 at `/herdr-web` (pre-auth, like `GET /`);
(b) fetch-based SSE transport (no `?token=`); (c) treat `stream.reset`/replay_gap as the
**normal** resync path (1024-event ring vs >100 events/s under Pi streaming — doc 02 §9);
(d) fix the launch-script `HERDR_BIN_PATH` before terminal-stream QA (doc 02 §4).

---

## Verified Claims

| Claim | Verdict | Evidence |
|---|---|---|
| Server is single-process stdlib `ThreadingHTTPServer`, loopback-only 9092, TLS via `tailscale serve` 8461 | **Verified** | doc 02 §1/§7 (`/api/v1/network` capture: `bindAddress:127.0.0.1`, serve command); `herdr_dashboard.py` (106 lines) + `server.py` (1,026 lines, orchestrator re-counted) |
| Bearer auth header-only, `hmac.compare_digest`, no `?token=`, **no loopback bypass** | **Verified (re-checked in worktree)** | `server.py:290-310` `_authorized`: reads only `Authorization` header; 401 body byte-exact per doc 02 §7. Grep confirms no client-address logic (doc 02 §1) |
| CORS opt-in: `OPTIONS` → 204 with `Authorization, Content-Type, Last-Event-ID`; origin header only if `HERDR_HARNESS_CORS_ORIGIN` set (it is **not** in the launch script) | **Verified (re-checked)** | `server.py` `do_OPTIONS`; launch script `~/.config/herdr-harness/launch-herdr-harness.sh` read directly — env vars: `HERDR_SESSION`, `HERDR_HARNESS_API_TOKEN`, `HERDR_HARNESS_TAILSCALE_URL/_PORT` only |
| Static serving = only `GET /` (SETUP_HTML token-check page); dispatch has a clean pre-auth insertion point | **Verified (re-checked, orchestrator)** | `server.py:55-95` (`SETUP_HTML`), `_dispatch` `server.py:340-348`: `path == "/"` branch returns before the `api/v1` 404 check — `/herdr-web` mounts there |
| Broker ring = 1024 events, integer sequence, `Last-Event-ID`/`?after=` replay, `ready` + `stream.reset` semantics | **Verified** | `herdr_harness/events.py` (50 lines, `deque(maxlen=...)` ring, `after()`, `wait_after()`); live capture doc 02 §3.1/§7 (~2 MB / 14 s under Pi activity; 1366 `pi.message_update`) |
| Terminal frame contract `{type:"terminal.frame", bytes: base64, encoding:"ansi", full, height, seq, width}`; content-driven emission; `full:true` on attach; delta `seq` dedupe rule | **Verified (full frames live; deltas not)** | doc 02 §3.2 (orchestrator ran the observer CLI directly); delta rule from `TerminalGrid.swift:106-121` (doc 01 §4.5) — **delta payload never captured on the wire** |
| Terminal stream 503 on the running server; root cause = launchd PATH lacks `/opt/homebrew/bin` and launch script sets no `HERDR_BIN_PATH` | **Verified (re-checked)** | doc 02 §4 (503 live-verified twice; `ps eww` PATH); launch script re-read — no `HERDR_BIN_PATH` line |
| Pi data path is 100% HTTP: `pi/snapshot`, `pi/events`, `pi/*` commands; bridge is server-side | **Verified** | doc 02 §3.3/§5 (51 Pi panes detected, 50 bridge-connected live; socket paths validated server-side in `pi_semantic.py:57-123`); iOS side doc 01 §4.4 — `PiConversationSSEParser.swift` is 82 lines (verified) |
| Pi capability skew: 3 variants (some lack `setModel`/`setThinkingLevel`); `interactionResponse` unsupported (501) | **Verified** | doc 02 §5 (live `pi_semantic.capabilities` samples: `setModel:false`/`true` both observed; `interactionResponse:false`); route table doc 02 §2 (501 `unsupported`) |
| `GET /api/v1/live-activities` does not exist (HerdPulse has no GET data source) | **Verified** | doc 02 §7 (404 live-verified); route table doc 02 §2 (POST register/unregister only) |
| iOS app has **no global polling loop**; cadences = 1 global SSE + per-pane SSEs + 850 ms terminal snapshot poll + 2 s legacy-Pi snapshot poll | **Verified** | doc 01 §5 (endpoint/cadence table), §4.4 (Pi 2 s poll, backoff ×1.7 cap 8 s), §4.5 (850 ms poll + `TerminalRefreshPolicy.swift` — 26 lines, `streamSilenceLimit = 25` s, verified) |
| iOS state topology: one `@Observable` app model + per-pane `PiConversationStore` + pulse coordinator (no TCA) | **Verified** | doc 01 §2 (`HerdrAppModel.swift` ~700 lines); Phase-1 TCA mapping does not carry over, topology does |
| `FleetSummaryView` / `PaneSessionHeader` are dead code (0 references) | **Verified** | doc 01 §3/§7.12 (investigator verified 0 refs; orchestrator spot-checked) |
| Git/skills/files/Jira/attachments/voice are cmux-proxied → both servers required | **Verified** | doc 02 §1/§9 (`HERDR_HARNESS_CMUX_URL` default `127.0.0.1:9091`); doc 01 §1 |
| Phase 1 assets reusable: Vite 6/React 18/TS/zustand/vitest scaffold, `api/client.ts` (token header + timeout + abort merge), `connectionStore.ts` (reconnect state machine), `terminal/ansi.ts` (SGR parser), `lib/hashRoute.ts`, build→static pipeline, 21 test files | **Verified (read this session, orchestrator re-checked)** | `package.json` (vite `^6.0.5`, react `^18.3.1`, zustand `^5.0.2`, vitest `^2.1.8`; `base:"/harness-web/"`, outDir→`cmux_harness/static/harness-web`); `client.ts` (localStorage token, `X-Cmux-Token` injection, 15 s timeout, external-signal abort merge); `connectionStore.ts` (failure-threshold reconnect machine); `ansi.ts` (Run/SGR parser, **no cursor addressing**); `hashRoute.ts` (pure parse/serialize) |
| Uncommitted worktree shim (`POST_17_SUBSCRIPTIONS` protocol<19 gate) is **not in the running server** | **Verified** | doc 02 §6 (process started 08-17 18:00:26 vs file mtimes 18:49:23; `__pycache__` pre-edit); `git status` re-checked: dirty = `project.pbxproj`, `xcscheme`, `client.py`, `service.py` — matches |
| Static-mount copy pattern exists in the sibling 9091 codebase | **Verified (citation corrected)** | `_serve_orchestrator_v2_static` is at `cmux_harness/server.py:312` (Phase-1's 9091 server, doc web-app/02) — reference pattern only; 9092's `herdr_harness/server.py` has **no** static mount today, so the mount is new code modeled on that pattern |

**Assumptions (flagged, not observed):** (1) the `/herdr-web` static mount won't collide
with Tailscale serve config (it won't — serve proxies everything to 9092); (2) the Vite
build for the herdr app can drop into a `herdr_harness/static/herdr-web/` dir the same way
Phase 1 did (pattern proven in the 9091 server, above); (3) fetch streaming reads work
through Tailscale serve's proxy without chunked-encoding breakage (verify in P0 with a 10 s
live browser test — the server already sends `X-Accel-Buffering: no`, doc 02 §3).

---

## Architecture Options & Recommendation

### Decision 1 — SSE auth transport (highest-leverage call)

**Constraint:** browser `EventSource` cannot set `Authorization`; server accepts Bearer
header-only (doc 01 §7.1, doc 02 §1 — both verified in code). Three live streams: global
(integer `id:` + `Last-Event-ID`), terminal (per-frame `seq` in payload, **no replay at
all** — reconnect yields a fresh `full` frame), Pi (opaque string cursor as `?after=` +
`id:` fallback) (doc 02 §3.1-3.3).

| Option | How it works | Tradeoffs |
|---|---|---|
| **A. fetch + `ReadableStream` SSE client, used for all three streams (REST already uses fetch with headers)** | One shared `src/api/sse.ts` (~200-300 LOC): open `fetch(path, {headers: Authorization})`, iterate `response.body.getReader()`, split on `\n\n`, parse `id:`/`event:`/`data:`/`: comment`, track cursor per stream type, manual reconnect with backoff, `Last-Event-ID` resend, `retry:` honored. | (+) Zero server change; token never appears in a request line (no server/serve/proxy log leakage); one transport for all three cursor models; mirrors the iOS transport exactly (URLSession line parser — `PiConversationSSEParser.swift` 82 lines, `HerdrAPIClient.swift:527-560` terminal SSE — direct ports). (−) We own reconnect/backoff/`visibilitychange` semantics; background-tab fetch suspension needs explicit close/resume (easy: cursor replay covers global+Pi; terminal re-attach is free). |
| B. Add `?token=` fallback to `server.py` + native `EventSource` | Server accepts token from query when header absent. | (+) Free browser reconnect + `Last-Event-ID` auto-resend. (−) Token in URL → stdlib `BaseHTTPRequestHandler` logs every request line to the launchd log, Tailscale serve logs it, and it's one click away from a browser bookmark/history leak on a **terminal-write** API; new auth surface on a security-critical path; still need manual `Last-Event-ID` for the Pi opaque-cursor stream and still need manual handling for the terminal stream (which has no `id:` replay) — so `EventSource`'s free features only cover 1 of 3 streams. Net: server change + leak vector for ~30% of the plumbing. |
| C. Cookie session (set-cookie on static shell, `SameSite=Lax`) | Server-side auth rewrite. | Larger server diff, CSRF surface, and nothing `EventSource`-specific is gained that A doesn't already cover. Rejected. |

**Recommendation: A.** fetch-SSE for all three streams; token stays in `#fragment` +
localStorage, injected as `Authorization: Bearer` by the shared client (Phase 1's
`client.ts` pattern with a 2-line header change). The three cursor models map to one
client configured per stream: `{cursorKind: "int-header" | "none" | "opaque-after"}`.
Backoff copied from iOS: terminal 0.65 s ×1.7 cap 5 s, Pi 0.65 s ×1.7 cap 6 s, global
2 s ×2 cap 15 s (doc 01 §5). `visibilitychange` → close streams on hidden, reopen on
visible (iOS suspends equivalently; push handled the background — here we simply resume,
doc 01 §4.5/§4.4).

### Decision 2 — Static hosting

| Option | How | Tradeoffs |
|---|---|---|
| **A. Serve from 9092 at `/herdr-web` (pre-auth, same as `GET /`)** | New branch in `_dispatch` before the `api/v1` 404 check (anchor `server.py:340-348`, verified): serve `herdr_harness/static/herdr-web/*` with path-traversal guard + `index.html` fallback for `/herdr-web/`. Vite `base:"/herdr-web/"`, `outDir` into the worktree static dir (Phase-1 build pipeline pattern, verified). | (+) Same-origin kills CORS/preflight/mixed-content/discovery in one move — the Phase-1 P0 decision, and the handoff §6 recommendation; pre-auth static is safe because the shell holds no secrets and `SETUP_HTML` already establishes the "token entered client-side" pattern; ~30-40 LOC, no new Python deps. (−) Touches the running launchd service for deployment (rebuild + `launchctl kickstart`) — same chore as the terminal fix below, so batch them. |
| B. Separate origin (e.g. second port / vite-hosted) + `HERDR_HARNESS_CORS_ORIGIN` | Set env in launch script; preflight already implemented (`do_OPTIONS` verified). | (+) Isolated deploy. (−) Two deployables; CORS on a Bearer terminal-write API is a standing misconfig risk; origin must be exact (no `*`); dev-only benefit — `vite build` is seconds, and a temporary dev-mode CORS export covers hot-reload without a permanent config surface. |

**Recommendation: A.** Serve same-origin, pre-auth, at `/herdr-web`. Keep
`HERDR_HARNESS_CORS_ORIGIN` available (env only) for occasional `vite dev` work, never in
the launch script.

### Decision 3 — Terminal renderer: port `TerminalGrid.swift` vs xterm.js

**Deep dive (frame format, doc 02 §3.2 + doc 01 §4.5):**
- Wire: SSE `event: terminal.frame`, `data:` = complete raw record
  `{type:"terminal.frame", bytes:<base64>, encoding:"ansi", full:bool, height, seq,
  width}` — **live-verified** by running the observer CLI (encoding is the string
  `"ansi"`; the app ignores the value and base64→UTF-8 parses,
  `TerminalGrid.swift:108`).
- Emission is **content-driven**: fresh attach → `full:true, seq=1`; idle pane →
  consecutive full frames; quiet pane → 1 frame in 15 s; dead shell → 0. Heartbeats are
  `: comment` lines (ignored by any SSE reader). `terminal.closed`/`terminal.error`
  terminate (doc 02 §3.2).
- **Delta frames (`full:false`) were not captured on the wire** (read-only investigation
  couldn't send input). Client contract from `TerminalGrid.swift:106-121`: apply only if
  `seq > lastSequence` (stale deltas silently dropped), resize-to-frame-dims (copy
  overlap, clamp cursor), then parse ANSI.
- Grid semantics to replicate (doc 01 §4.5): ESC CSI subset (`H f A B C D G d J K m`,
  `?25h/l`), OSC ignored, `\r\n\b\t` with 8-col tabs, auto-wrap at last column,
  scroll-on-linefeed at bottom, SGR incl. 38/48 `;r;g;b` and `;5;n`; 16-color base
  palette + 216 cube + 24-step ramp; `visibleRows` trims trailing blanks; 100×32 default
  (cols/rows come from the stream query).
- Arbitration (`TerminalRefreshPolicy.swift`, 26 lines): 850 ms GET
  `/panes/{id}/output?source=recent_unwrapped&lines=160` runs alongside the stream;
  snapshot replaces grid only when forced / grid didn't advance / text changed without
  frames / stream silent ≥ 25 s; failed snapshot degrades to `.disconnected` + error pill
  only when the stream is already stale. Source labels
  `connecting/live/watching/offline` + `W×H · fN` toolbar metadata are byte-exact UI
  (doc 01 §6).

| Option | Assessment |
|---|---|
| **Port `TerminalGrid.swift` (419 lines) to a TS `terminal/grid.ts`** | (~600-800 LOC TS + tests, one bounded chunk.) Deterministic and *verifiable*: the Swift module has tests in the 20-file suite to cross-check behavior, and the output contract (trimmed rows, exact palette, cursor rendering) matches the product byte-for-byte. Fixed 100×32 grid → DOM is a 32-row `<pre>`/grid of spans — trivial to render, trivial to scroll, zero virtualization. Phase 1's `ansi.ts` SGR color-resolution (16/256/truecolor → CSS) is reusable; the grid state machine is new. |
| xterm.js | Mature ANSI, but: ~1 MB dep vs a zero-dep repo posture (KISS); its viewport/scrollback/fit semantics don't match the app (no scrollback parity, no "last non-blank row" trim, no `W×H · fN` model, cursor-blink/selection are a different UX); and it fights the snapshot-fallback pattern (we'd render xterm for frames and a plain `<pre>` for snapshots — two renderers). The one thing xterm would give (unbounded scrollback) is not in the iOS product. |

**Recommendation: port the grid.** Keep `TerminalRefreshPolicy` semantics as-is (it's 26
lines — the design is the code). **Plan a live delta-frame capture in the terminal
phase**: drive one pane with keystrokes, record 2-3 delta records, and unit-test against
them. If a delta record surprises the contract, the 850 ms snapshot arbitration bounds
the blast radius, and snapshot-only rendering is an acceptable degraded v1 (iOS keeps the
last good frame + falls back to snapshot — same escape hatch, doc 01 §4.5). **Note:** the
live server returns 503 on `/panes/{id}/stream` until the launch-script PATH fix lands
(doc 02 §4) — the fix is a one-liner
(`export HERDR_BIN_PATH=/opt/homebrew/bin/herdr`) + `launchctl kickstart`, and it's
needed for *any* terminal QA, so it belongs in P0/P1, not deferred.

### Decision 4 — SSE store design (restructuring Phase 1's polling stores)

Phase 1: `connectionStore` (2 s `/api/status` poll + failure-threshold machine),
`workspacesStore`, `gitStore` etc. all on intervals. Phase 2 replaces the *cadence
engine*, keeps the store topology:

| New/changed module | Design | Evidence |
|---|---|---|
| `src/api/sse.ts` (new) | The fetch-SSE client from Decision 1; per-stream cursor strategy (`int-header` / `none` / `opaque-after`); backoff per iOS values | doc 02 §3; doc 01 §5 |
| `src/store/eventStream.ts` (new, replaces App-level polling loop) | Owns the global `/api/v1/events` stream. On `ready` → store `lastEventId`. On `stream.reset` (`replay_gap` \| `backend_restarted`) → **silent `/workspaces` refetch, not an error** — with >100 events/s under Pi streaming and a 1024 ring, any hiccup > a few seconds hits this (doc 02 §9); it is the normal resync path. Dispatch: `snapshot.updated` → debounced (≈500 ms) `/workspaces` refetch (iOS re-refreshes with spinner hidden on exactly this event, doc 01 §2 `runConnection`); Pi-capability events (`pi.bridge.connection`, `pi.session_start/shutdown`, `pi.session_info_changed`, `pi.session_tree`) → same silent refetch (doc 01 §2, lines 655-661); `alert.created`/`alert.updated` → alert store upsert + unread badge; `connection.changed` → connection state; `push.*` → ignore in v1 (no APNs on this Mac, doc 02 §7); raw herdr events (payload nested at `data.data`, doc 02 §3.1) → **don't parse individually**: the server already coalesces them into `snapshot.updated` via its snapshot-refresh thread (doc 01 §2), so a generic "any unrecognized event" arm maps to the same debounced refetch. `pi.*` journal re-publications (~1366 in 14 s live, doc 02 §3.1) are **ignored** by global state — Pi pane state comes from the per-pane Pi stream; ignoring them is what keeps a streaming Pi pane from thrashing `/workspaces`. |
| `src/store/connectionStore.ts` (rework) | Phase 1's state machine survives; inputs change: initial `/health` probe (doc 02 §7 shape) + `connection.changed` events + stream liveness. `disconnected/connecting/live/failed` (doc 01 §2 `ConnectionState`). | doc 02 §7 |
| `src/store/workspacesStore.ts` (rework) | Same derived selectors as iOS (`visibleWorkspaces`, `attentionPanes` ranking blocked→done→working→idle→unknown by `attentionRank` then `revision` desc, `unreadAlertCount`, `canControl`) (doc 01 §2); mutations trigger post-action silent refresh (iOS parity). | doc 01 §2/§4.1 |
| `src/store/terminalStore.ts` (new) | Per-open-pane: frame stream + 850 ms snapshot poll + `TerminalRefreshPolicy` arbitration (Decision 3). One pane at a time (iOS opens one terminal stream per selected pane; server semaphore caps 8, doc 02 §3.2). | doc 01 §4.5 |
| `src/store/piStore.ts` (new, per pane) | Port of `PiConversationStore` (389 lines): `follow()` → `pi/snapshot` → protocol/`available` check → reducer.replace → SSE `pi/events?after=<cursor>` (+`Last-Event-ID`); legacy-bridge path (snapshot lacks `state.context` or disconnected) → 2 s snapshot poll with content-change detection, backoff ×1.7 cap 8 s, auto-upgrade when a new bridge appears (doc 01 §4.4). 2048-entry cursor LRU dedup; `stream.reset`/`session_tree`/`session_compact` → authoritative snapshot reload. | doc 01 §4.4; doc 02 §3.3 |
| git/skills/files/jira stores (rework) | Same components as Phase 1's Git tab etc.; endpoints move to `/api/v1/workspaces/{id}/git*` etc. (cmux-proxied, doc 02 §2); error cards on 502-upstream (both-servers dependency, doc 02 §9). | |

**Net:** Phase 1's `setInterval` loop in `App.tsx` disappears; one long-lived global
stream + lazily-opened per-pane streams; everything else is event-driven or on-demand —
exactly the iOS cadence table (doc 01 §5).

### Decision 5 — Pi Chat data path & depth

- **Data path (no surprises):** everything is HTTP through 9092 —
  `GET /panes/{id}/pi/snapshot`, `GET /panes/{id}/pi/events?after=`,
  `GET /panes/{id}/pi/models`, `POST pi/{prompt,steer,follow-up,abort,model,thinking-
  level}`, `POST pi/interactions/{id}/respond` (doc 02 §2/§3.3). The Unix socket lives
  entirely server-side (`pi_semantic.py` validates type/owner/mode before use, doc 02 §5).
  The browser never touches it.
- **Port scope (bounded, verified sizes):** `PiConversationReducer.swift` 761 lines +
  `PiConversationStore.swift` 389 + `PiConversationSSEParser.swift` 82 + 28 `Pi*` model
  types. The reducer is self-contained and unit-tested on the Swift side (doc 01 §7.4) —
  port it with its test table as fixtures. Event vocabulary: 24 bridge types + 3
  synthesized (`bridge.connection`, `stream.reset`, `bridge.payload_omitted`)
  (doc 02 §3.3); wire envelope `{protocol, paneId, sessionId, cursor, connected,
  event:{...}}` with `pi.`-prefix normalization (doc 01 §4.4).
- **Capability skew (must design around):** 3 live variants — newer bridges advertise
  `listModels/setModel/setThinkingLevel: true`; two older ones don't;
  `interactionResponse: false` on **all** (respond → 501 `unsupported`, doc 02 §2/§5). UI
  rule: read per-pane `capabilities` from the snapshot's `pi_semantic` object
  (doc 02 §7 pane sample); hide model/thinking chips when unsupported (iOS shows "Model
  switching isn't supported by this Pi session" on 501 — doc 01 §6); interaction cards
  render (parity) with respond attempt → 501 → error notice. Do **not** assume a global
  capability (doc 02 §9).
- **Legacy degradation:** panes with old/no bridge still serve durable snapshots; the 2 s
  snapshot-poll keeps them readable and auto-upgrades on bridge appearance (doc 01 §4.4,
  doc 01 §8). The web app must implement the same loop or legacy panes look broken.
- **Depth recommendation:** full semantic conversation in v1 (turns, thinking disclosure,
  tool cards, notices, context meter, status bar, prompt/steer/follow-up/stop). It's the
  feature that differentiates this app from Phase 1, the port is bounded and testable,
  and the data path is already API-only. It is the largest single chunk, so it gets its
  own phase with the Swift test table as acceptance fixtures. (Ronnie's call per handoff
  §10.4 — but terminal-first only makes sense if the timeline compresses.)

---

## UI Parity Map

### Ports 1:1 (same behavior, idiomatic translation)

| iOS screen/feature | Web equivalent | Notes |
|---|---|---|
| Onboarding (URL + pairing token + demo button, Keychain footnote) | Same modal; token → localStorage | Phase-1 settings-modal pattern; string parity from doc 01 §6 |
| Attention Deck (journal "Recent signals" + ranked "Live queue" + NEW capsule + badge + mark-read) | Same, two sections | `alerts` ride in `GET /workspaces` (doc 01 §4.1); `POST /alerts/{id}/read`; assume dirty journal (123/125 unread live, doc 02 §9) and expose read-all |
| Workspace list (search, All/Needs you/Active filter, AttentionStrip top-2, worktree connector glyphs, cards) | Same; filter bar = segmented control | Ranking/labels byte-exact (doc 01 §6) |
| Workspace hero + Pane Topology Radar | SVG from `layouts[].panes[].rect` (area-relative scaling, 4 pt radius, focus/selection highlight) | Pure rect math — doc 01 §4.2 says "trivial"; live layout sample confirmed terminal-cell coordinates (doc 02 §7) |
| Pane list per tab, PaneCard (rail, rev N, agent icon, `pane.id`) | Same | `tabs[]` grouping, loose panes fallback (doc 01 §3) |
| Terminal view (grid, source label + dot, `W×H · fN`/`rN`, Pause/Resume follow, refresh) | Ported grid (Decision 3) + Phase-1-style selectable `<pre>` | Source labels byte-exact (doc 01 §6) |
| Command Lens (status-aware placeholder, agent-aware send `run` vs `prompt`, key deck Up/Down/Tab/Enter + Left/Right/Esc/Bkspc, aux bar attach/voice/@file/jira) | Same; key deck → buttons POSTing `send-keys {keys:[...]}` (whitelist `^[A-Za-z0-9+_-]{1,32}$`, doc 02 §2 — the iOS 8 keys all pass it); Interrupt = menu action | Attachments = base64 JSON (doc 01 §4.3) — Phase-1 upload pipeline ports directly |
| Git tab (503-line view: staged/unstaged/untracked, stage/unstage, diff sheet, recent commits) | Phase-1 Git tab re-pointed at `/api/v1/workspaces/{id}/git*` | Strings byte-exact (doc 01 §6) |
| Skills view (3 insert styles `/name`, `$name`, `` `path` ``), file search sheet, Jira picker + insert block | Same modals; cmux-proxied endpoints | Insert tokens force Terminal mode + refocus (doc 01 §4.3) |
| Sidebar "chats" drawer (tree, context menus, collapse persistence) | Persistent left rail at desktop widths; overlay drawer on narrow (Phase-1 drawer pattern) | Collapse set → localStorage (doc 01 §2) |
| Settings (connection card, demo toggle, smart alerts, Private-by-design, About) | Same form | Push status line derived from `/api/v1/push/status` (doc 02 §7) |
| Connection pill / toasts (2.2 s auto-dismiss) / "Connection issue" error alert | Same components | Phase-1 `ApprovalBanner`/toast patterns reuse |
| Deep navigation + `herdr://pane/<id>` + pending-pane queue | Hash route `#pane=<id>` (extend Phase-1 `hashRoute.ts`) + same pending-pane-until-data queue | doc 01 §2/§7.7 |
| iPad 3-column (workspaces \| panes \| session) | CSS 3-column at wide breakpoint (Phase-1 <900 px drawer inverts to a rail) | doc 01 §4.7 |
| Workspace/pane mutations (create/rename/split/focus/close/start-agent, confirm dialogs) | Same menus + confirm modals | Endpoints doc 02 §2; confirm copy byte-exact (doc 01 §6) |
| Pi Chat (full: banner, context meter, timeline, thinking disclosure, tool cards, interaction cards, status bar, model/thinking chips) | Port per Decision 5 | Markdown must render sanitized (see Risks) |
| Stale-state repair on every refresh (`repairNavigation`) | Route guards: prune dead workspace/pane selections, reselect first workspace (doc 01 §2) | Needed for workspaces closing under the app |

### Needs a web-idiom replacement

| iOS idiom | Web replacement |
|---|---|
| Pull-to-refresh | Refresh buttons (browser pull reloads the page — suppress) |
| Context menus (⋯) / swipe actions | Dropdown menu component / hover action buttons |
| Keychain token | localStorage + onboarding token field (Phase-1 pattern, header name changed) |
| Local notifications (time-sensitive blocked alerts) | In-app badge always; optional `Notification` API (same-origin HTTPS qualifies) for the deck — decision in Open Questions |
| APNs deep link / launch-queued tokens | Notification click → `#pane=<id>` + pending-pane queue (parity semantics, doc 01 §2) |
| NavigationSplitView collapse behavior | Responsive breakpoints (above) |
| Voice (AVAudioRecorder → 16 kHz mono WAV base64, `Models/VoiceTranscription.swift:39-45`) | **Out of v1** — browser records webm/opus; the server contract is *strictly* WAV (doc 02 §2 "strictly 16 kHz mono 16-bit PCM WAV"); a WebAudio resample pipeline is a real project, not a toggle. Mic button renders disabled/hidden in v1 (flag for Ronnie) |
| Demo mode (`DemoData` + per-method demo branches) | Mock fetch adapter keyed on a flag (parity + offline dev/CI) or drop — Open Question |

### Impossible / not worth doing

- **HerdPulse Live Activities** (Dynamic Island/lock screen) — no browser equivalent.
  Aggregate content is counts-only by design (doc 01 §4.6), which makes a *Web
  Notifications* "pulse" a cheap degraded follow-up (periodic notification "3 needs you ·
  2 working" while the tab is backgrounded). There is also **no GET endpoint** for pulse
  data (doc 02 §7) — everything needed is already in `/workspaces` state, so no server
  work either way.
- **APNs / Web Push** — no server endpoints exist for VAPID; APNs is unconfigured on this
  Mac (`apns.configured:false`, doc 02 §7) so the native path is inert here regardless.
  Later, if ever.
- **Haptics** — skip (doc 01 §7.11; no meaningful Mac-web equivalent).
- **`FleetSummaryView`, `PaneSessionHeader`** — dead code, 0 references (doc 01 §7.12).
  Excluded.
- **`herdr://` URL scheme handling** — replaced by hash routes; not replicable, not
  needed.

---

## Required Server Changes

| # | Change | Size | Anchor / notes |
|---|---|---|---|
| 1 | **Static mount `/herdr-web`**: pre-auth branch in `_dispatch` serving `herdr_harness/static/herdr-web/` (path-traversal guard, `index.html` fallback for the bare path). Served like `GET /` — before the `api/v1` auth gate | **S** (~30-40 lines) | `server.py:340-348` (verified insertion point); copy the pattern from the 9091 server's `_serve_orchestrator_v2_static` (`cmux_harness/server.py:312`) |
| 2 | **Launch script: `export HERDR_BIN_PATH=/opt/homebrew/bin/herdr`** + `launchctl kickstart` restart → terminal stream un-503s | **1 line** + restart | `~/.config/herdr-harness/launch-herdr-harness.sh` (re-read: line absent today); root cause doc 02 §4; batch with #1's restart. **Touches the running service** — do it deliberately (doc 00 §11 gotchas: launchd KeepAlive revives killed PIDs; the cmux wrapper's `pgrep` is too broad) |
| 3 | `?token=` query auth | — | **Not required** under Decision 1 (fetch-SSE). Rejected: token-in-URL log exposure (Decision 1 table) |
| 4 | `HERDR_HARNESS_CORS_ORIGIN` in launch script | — | **Not required** same-origin (Decision 2). Leave env-only for optional `vite dev` |
| 5 | HerdPulse GET endpoint | — | **Not required**: aggregate derives from `/workspaces` client-side (doc 01 §4.6 counts are already workspace state; doc 02 §7 confirms no GET exists and APNs is inert) |
| 6 | Vite build output dir in worktree (`herdr_harness/static/herdr-web/`) + `base:"/herdr-web/"` | **S** (frontend config) | Mirrors Phase-1 `vite.config.ts` (verified) |

No endpoint changes are needed for UI parity — the doc 02 §2 route table is complete for
everything in the parity map, including all Pi and terminal routes.

---

## Security Assessment

**Posture is better than Phase 1's was at launch, not worse:** Bearer auth on every
`/api/v1` route (`hmac.compare_digest`, doc 02 §1), loopback bound + tailnet-only TLS
termination, CORS off by default (verified: env unset, `do_OPTIONS` sends no
`Access-Control-Allow-Origin`), 1 MB body caps, terminal observation read-only (input
only via explicit Bearer-gated action routes, doc 01 §1).

Token handling:
- **`#token=` fragment + localStorage, injected as `Authorization: Bearer`** — same
  Phase-1 pattern (verified `client.ts`), header swapped. The fragment is never
  transmitted (browser strips it before the request line), survives reloads, and with
  Decision 1's fetch-SSE the token **never appears in any URL, log, or proxy record** —
  the concrete win over the `?token=` alternative.
- **No loopback bypass (verified in code):** a browser at `http://localhost:9092` needs
  the token exactly like the tailnet URL — same UX as the iOS app, whose onboarding
  requires the pairing token even for localhost (doc 01 §5, `ServerConfiguration`
  http-localhost-only rule). The handoff's "mirror Phase-1 loopback bypass"
  (doc 00 §6) **does not apply**; deliberately not recommending adding one.
- **Pre-auth static is safe:** the shell + assets contain no secrets; `SETUP_HTML`
  already sets the precedent of a token-less entry point that probes `/health` with
  client-entered credentials (doc 02 §1).

Residuals:
- **XSS is the token's only real enemy** (localStorage is readable by same-origin JS; our
  app is the only same-origin JS). React escapes by default; the one injection-shaped
  surface is **Pi assistant markdown** (doc 01 §4.4 custom markdown → SwiftUI). Rule for
  the plan: render markdown through a sanitizer (or a constrained renderer), never
  `dangerouslySetInnerHTML` on bridge-supplied content.
- **Drive-by from other origins is blocked** by CORS-off + Bearer (cross-origin fetch
  gets no origin header and no cookie path) — strictly better than Phase 1's early
  state.
- **Token at rest** in `~/.config/herdr-harness/api-token` (file perms per doc 00 §3) and
  in browser localStorage; rotation = relaunch (launch script re-reads the file, verified
  comment in script).

---

## Top Risks

1. **`replay_gap` is the normal path, not an error.** 1024-event ring vs >100 events/s
   per active Pi pane (live: ~1366 `pi.message_update` in 14 s, doc 02 §3.1/§9) — any
   browser disconnect, tab suspension, or slow load longer than a few seconds yields
   `stream.reset {reason:"replay_gap"}`. If the web client surfaces this as an error
   banner (Phase-1 reflex), the app looks broken every time the Pi herd gets busy.
   *Mitigation:* Decision 4 codifies reset→silent `/workspaces` refetch; `ready` is a
   handshake, not data; unit-test the resync loop with a synthetic gap fixture; keep the
   iOS backoff values (doc 01 §5).
2. **Pi event volume / replay cost.** Fresh connect with `?after=0` replays up to ~2 MB
   (doc 02 §3.1). *Mitigation:* one-time replay on first connect is fine; on reconnect
   send the last-seen `Last-Event-ID` (the sse client tracks it); ignore `pi.*` journal
   re-publications in global state (only capability events matter, doc 01 §2); debounce
   `/workspaces` refetch at ~500 ms.
3. **Terminal delta frames unverified on the wire.** Contract is from
   `TerminalGrid.swift`; full frames live-verified, deltas never captured (doc 02
   §3.2/§9). If a real delta payload deviates, the grid can corrupt until the next full
   frame. *Mitigation:* live-capture step inside the terminal phase (send keystrokes to
   one pane, record delta records, add them as fixtures); `seq` dedup + 850 ms snapshot
   arbitration bounds corruption to one frame cycle; snapshot-only is the accepted
   degraded mode (iOS has the same fallback, doc 01 §4.5).
4. **Terminal stream 503 blocks all terminal QA until the launchd env is fixed.**
   *Mitigation:* one-line launch-script change + kickstart in P0/P1 (Required Changes
   #2); CLI-direct verification already de-risks the frame contract (doc 02 §4); do the
   restart deliberately per doc 00 §11 (KeepAlive, broad `pgrep` gotcha).
5. **Both-servers-required dependency (silent degradation).** git/skills/files/Jira/
   attachments/voice proxy to 9091 (`HERDR_HARNESS_CMUX_URL`, doc 02 §1/§9); if the cmux
   server is down, those tools 502 while the app otherwise looks live. *Mitigation:*
   per-tool error cards (iOS parity — `Git unavailable` / `Skills unavailable` strings,
   doc 01 §6); `/health` distinguishes `herdr.connected` vs `cache.stale` for the
   connection pill; document the dependency in the onboarding fine print.
6. **Uncommitted worktree shim ≠ running server.** The `protocol<19` subscription gate in
   `client.py`/`service.py` is not in the running process (doc 02 §6); QA comparing
   "worktree code" vs "live 9092" can be confused. No-op at protocol 19 today.
   *Mitigation:* treat the running server as the QA source of truth; flag the uncommitted
   files for Ronnie to commit (they're his, not ours — we don't touch them, doc 00 §11).
7. **Pi capability skew + `interactionResponse` 501.** 3 live capability variants;
   respond unsupported everywhere (doc 02 §5). *Mitigation:* per-pane capability-driven
   UI (Decision 5), 501 → graceful notice strings already spec'd (doc 01 §6); fixture
   tests for all 3 variants.
8. **Dirty alert journal.** 123 unread of 125 (cap 500) on day one (doc 02 §9).
   *Mitigation:* Attention Deck assumes unread state, uses `unreadCount`/`read-all`,
   never "clear on load".
9. **Stdlib-server fragility on additions.** The static mount and SSE paths are
   hand-rolled on `BaseHTTPRequestHandler` (doc 02 §1). *Mitigation:* server diff frozen
   at Required Changes #1/#2 (both tiny, one is a config line); no new endpoints, no new
   deps — same boring-technology posture as Phase 1's assessment.

---

## Open Questions (decisions only Ronnie can make)

1. **Serve path** (handoff §10.1): from 9092 at `/herdr-web` (recommended — Decision 2)
   or a separate origin + CORS env? *Rec: `/herdr-web`; the separate-origin mode only
   costs an env var to keep as a dev escape hatch.*
2. **HerdPulse** (handoff §10.2): skip, or Web Notifications degraded equivalent? *Rec:
   skip the Live-Activity UI in v1; the data is already in state and the APNs path is
   inert on this Mac (doc 02 §7); the notifications-only "pulse" is a cheap follow-up
   that the counts-only content contract makes safe (doc 01 §4.6).*
3. **Web Push / APNs replacement** (handoff §10.3): v1 or later? *Rec: later — no VAPID
   endpoints exist (doc 02 §2), it's new server surface + a service worker, and there's
   nothing on this Mac to receive it today.*
4. **Pi Chat depth** (handoff §10.4): full semantic conversation in v1, or
   terminal-first? *Rec: full in v1 (Decision 5) — the reducer port is bounded,
   self-contained, unit-testable, and it's the feature that makes this app more than
   Phase 1. Only compress it if the schedule forces it; the data path doesn't change
   either way.*
5. **Demo fixtures** (handoff §10.5): `scripts/setup_herdr_demo.py` isolated session for
   QA, or the real `default` session? *Rec: QA against the real `default` session (51 Pi
   panes, 50 bridge-connected, mixed capability variants — doc 02 §5 — which is exactly
   the skew the UI must survive); keep the fixture script available for repeatable
   isolated runs. Separately: port `DemoData` as a mock adapter for offline dev/CI
   (cheap, and it doubles as the vitest fixture base) — doc 01 §7.9.*
6. **Voice pipeline** (doc 01 §7.10): out of v1 (recommended — the server contract is
   strictly 16 kHz WAV, doc 02 §2; browser capture is webm/opus). Confirm: hide the mic
   button or show it disabled with a tooltip?
7. **Haptics + dead code** (doc 01 §7.11/7.12): confirm skip / confirm exclusion
   (`FleetSummaryView`, `PaneSessionHeader` — verified 0 references). No action expected.
8. **Deep-link + layout mapping** (doc 01 §7.7/7.8): `#pane=<id>` hash route with
   pending-pane queue parity, and sidebar-drawer → persistent left rail on desktop.
   *Rec: as proposed in the parity map — both follow Phase-1 patterns already built
   (`hashRoute.ts`, drawer).*

---

**Bottom line for the planner (step 3):** P0 = scaffold + Bearer client + `/herdr-web`
mount + launch-script fix + sse.ts; P1 = global event stream + connection + sidebar +
Attention Deck; P2 = terminal grid port + delta capture + refresh policy; P3 = Pi Chat
(reducer port); P4 = Command Lens + attachments; P5 = topology radar + pane/workspace
mutations; P6 = Git/Skills/Files/Jira re-point + settings + responsive 3-column; P7 =
polish + notifications decision. Every phase validates against live 9092 with the Bearer
token, and the Swift test tables (20 files, doc 01 header) are the acceptance fixtures
for the grid, reducer, and policy ports.
