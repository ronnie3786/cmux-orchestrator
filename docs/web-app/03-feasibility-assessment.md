# Feasibility Assessment — cmux-harness Web App (iOS parity)

**Author:** Architect subagent · **Date:** 2026-08-12 · **Mode:** read-only code verification + assessment
**Inputs:** `docs/web-app/01-investigation-ios-app.md`, `docs/web-app/02-investigation-api-server.md` (both read in full; key claims spot-checked against code below).

---

## Verdict

**FEASIBLE WITH CONDITIONS.**

The server is already a web host: it serves four HTML dashboards and a built React SPA same-origin, and the entire iOS feature set runs over ~26 plain JSON REST endpoints with no auth, no cookies, no streaming requirements. A browser client with "same exact UI + functionality" is straightforward **if**:

1. **The web app is served same-origin from the harness server** (exactly like `/orchestrator-v2` today). This eliminates CORS, preflight, mixed-content, and discovery problems in one move.
2. **Terminal stays 500 ms ANSI-scrape polling for v1** (parity with iOS). A real websocket/pty terminal is a v2 upgrade, not a launch requirement.
3. **APNs push and Bonjour are consciously replaced** (foreground banner via existing polling + optional Web Push later; manual URL/bookmark instead of LAN scan).
4. **Some minimal auth/CSRF hardening is decided by Ronnie before exposing this to a browser** — the browser threat model is worse than the iOS one (see Security).

The one genuinely hard port is the terminal layer: ~1,400 LOC Swift ANSI styler (`TerminalTextStyler`) plus the OpenCode prompt detector. Both are portable, and there is already a JS ANSI parser precedent in the repo (`cmux_harness/static/orchestrator.js:249-253`).

---

## Verified Claims

| Claim | Verdict | Evidence |
|---|---|---|
| Server serves `/`, `/harness`, `/orchestrator`, `/workflow-orchestrator` as same-origin HTML | **Verified** | `cmux_harness/server.py:43-53` (`_STATIC_DIR`, `_STATIC_PAGES` map), preloaded at `server.py:64-81` |
| Built React SPA at `/orchestrator-v2` | **Verified** | `server.py:261-300` `_serve_orchestrator_v2_static` serves `cmux_harness/static/orchestrator-v2/` incl. path-traversal guard (`server.py:268-274`); built assets present (`static/orchestrator-v2/index.html` + `assets/`) |
| SPA framework/stack | **Verified: Vite 6 + React 18, single `App.jsx` (~2,900 LOC) + `styles.css` (~4,000 LOC), vitest** | `frontend/orchestrator-v2/package.json`; `vite.config.js:6` sets `base: "/orchestrator-v2/"`, `:8` builds straight into `../../cmux_harness/static/orchestrator-v2`; SPA fetches **same-origin relative** `"/api/orchestrator-v2"` (`frontend/orchestrator-v2/src/App.jsx:48`) |
| No CORS headers / no OPTIONS handler | **Verified** | `_json_response` (`server.py:155-166`) sends only `Content-Type`/`Content-Length`; repo-wide grep finds no `do_OPTIONS`/`Access-Control` in `server.py`. Only the standalone demo server has CORS: `cmux_harness/demo.py:745-777` (`Access-Control-Allow-Origin: *` + `X-Cmux-*` allow-headers + `do_OPTIONS`) |
| No auth on any endpoint; bound 0.0.0.0:9091; plain HTTP | **Verified** | Bind: `dashboard.py:41` (default port 9091), `dashboard.py:56` `DashboardHTTPServer(("0.0.0.0", port))`. Only "token" in `server.py` is APNs device registration (`server.py:1023-1027`). `ThreadingHTTPServer` with no TLS wrapper |
| Live updates = client polling (2 s / 500 ms / 10 s); only SSE is orchestrator-v2 events | **Verified** | iOS: `cmux-harness-ios/.../Feature/Support/HarnessFeatureEffects.swift:10` (2 s), `:57` (500 ms screen), `:68` (10 s git). Web dashboards: `static/dashboard.html:4282` `setInterval(refresh,2000)` + 500 ms expanded-screen poll (`:4284-4289`). Only SSE: `cmux_harness/routes/orchestrator_v2.py:31-32` route → `:464` `stream_state_events`, `Content-Type: text/event-stream` at `:475`. **No WebSocket anywhere** (grep over `cmux_harness/` = 0 hits) |
| `/api/screen` returns scraped ANSI text, 500 ms-pollable | **Verified** | `server.py:424-445`: caps `lines` at 500 (`:432`), resolves workspace, calls `cmux_api.cmux_read_workspace` (`cmux_api.py:220`) → JSON-RPC `surface.read_text` over the cmux Unix socket (`cmux_api.py:228`). Returns raw text (ANSI escapes included) as a JSON string |
| `/harness` is the HTML dashboard; API lives at root `/api/*` | **Verified** | `/harness` → `dashboard.html` (`server.py:46`); API dispatch in `do_GET` (`server.py:327+`) / `do_POST` (`server.py:799+`) at root |
| Attachments = raw body + `X-Cmux-*` headers, 20 MB | **Verified** | `server.py:177-201` handler reads `X-Cmux-Filename`/`X-Cmux-Workspace-UUID`/`X-Cmux-Workspace-Index` (`server.py:189-201`); 20 MB cap `attachments.py:15`; 1 MB-chunk streaming save `attachments.py:58` |
| Existing React terminal precedent | **Verified (bonus)** | The orchestrator-v2 SPA **already renders cmux session screens in React**: fetch at `App.jsx:1451`, 5 s auto-refresh loop `:1456-1465`, send-input + optimistic double-refresh `:1466+`, SSE+poll hybrid with `EventSource` reconnect (`App.jsx:1442+`). This is a working in-repo proof of the exact pattern the web app needs |

**Observed vs. assumed:** everything above is observed in code. Assumptions are flagged inline below.

---

## Architecture Options & Recommendation

### Option A — Same-origin React SPA served by the harness server (RECOMMENDED)

- **Stack:** Clone the `frontend/orchestrator-v2` template: new sibling e.g. `frontend/harness-web/` with Vite + React 18 (+ TypeScript this time; orchestrator-v2 is plain JSX and is already a 2,900-line `App.jsx` monolith — don't repeat that). Build into `cmux_harness/static/harness-web/` with `base: "/harness-web/"`, served by a copy of `_serve_orchestrator_v2_static` (`server.py:261`).
- **Serving:** Same-origin `http://<mac>:9091/harness-web`. All fetches relative (`/api/...`) — zero CORS work, zero mixed-content.
- **Terminal strategy:** Keep the iOS contract: poll `/api/screen?index&lines=200` every 500 ms, render ANSI text with a JS renderer (xterm.js in "write scraped text" mode, or port the `orchestrator.js:249-253` `ansiToHtml` approach and extend it to match `TerminalTextStyler`'s semantic highlighting). Port `OpenCodeTerminalInteractionDetector` to JS (~200-300 LOC of pure text parsing — mechanical port).
- **Push/notifications:** v1 = foreground banner driven by the existing 2 s `/api/notifications` + `/api/feed` polling (exactly what the iOS in-app banner does minus APNs). v2 (optional) = Web Push (VAPID + service worker) as a second provider next to `push_notifications.py`.
- **Discovery:** None. Bookmark the URL; optionally keep the Tailscale MagicDNS host entry field from ServerSetup as a simple form.
- **Scoring:** (a) *fastest path to parity* — API contract unchanged, transport code is thin fetch wrappers, all iOS polling semantics copy over; (b) *server changes* — ~30 lines to serve the SPA, nothing else required; (c) *security* — same as today plus browser threat model (below); same-origin removes CORS misconfig risk; (d) *maintainability* — Vite build drops static files the stdlib server already knows how to serve; no new Python deps. This is the established pattern in this repo, twice over (`dashboard.html`, `orchestrator-v2`).

### Option B — Separate-origin web app (e.g. Vite dev server / laptop-hosted) + add CORS to server.py

- **Stack:** Any React app hosted wherever; server gains `do_OPTIONS` + `Access-Control-Allow-Origin/Headers/Methods`. Precedent exists: `demo.py:745-777` (someone already needed exactly this for a browser demo).
- **Terminal/push/discovery:** Same as A, but every request is cross-origin; attachment uploads are preflighted (custom `X-Cmux-*` headers, `server.py:189-201`) so `Access-Control-Allow-Headers` must include them (demo.py already shows the list).
- **Scoring:** (a) similar speed once CORS is in, but adds a permanent config surface (origin allowlist); (b) server change small but touches *every* response path; (c) **worse security posture** — CORS on an unauthenticated terminal-write API means any website the laptop visits could drive the Mac's terminals if origin is `*` or reflectively set; (d) two deployables to keep in sync.
- **Verdict:** Only worth it as a *dev-mode* convenience (vite `--host` for hot reload). Production serving should be Option A. If adopted, CORS must be paired with the token auth below, never shipped alone.

### Option C — Real terminal: xterm.js + WebSocket (or SSE-up/key-down) streaming

- **Stack:** Option A's SPA, but terminal backed by a WebSocket endpoint bridging the cmux socket (`surface.read_text` polling server-side, pushed on change) or a true pty proxy. xterm.js renders.
- **Server cost:** This is the big one — `server.py` is stdlib `ThreadingHTTPServer`; there is **no WebSocket support** and adding RFC6455 framing + per-connection threads to `BaseHTTPRequestHandler` is doable but fragile (~300-500 lines or a new dependency, violating "boring technology"/stdlib posture). The Node sidecar (`orchestrator_v2_runtime.py`, port 8792) could host the WS instead, but that couples the web app to orchestrator-v2 infrastructure.
- **Scoring:** (a) *slower* to parity — new protocol, new failure modes, and the iOS app's detector expects scraped full-screen text anyway; (b) largest server change; (c) neutral security-wise (still needs auth); (d) better long-term terminal UX (scrollback, resize, true interactivity) but the server currently can't even get cursor-positioned alternate-screen fidelity from `surface.read_text` — **assumption:** scraped text will look "close enough," because it's literally the same bytes the iOS app renders today.
- **Verdict:** Rejected for v1. Revisit only if 500 ms polling proves sluggish over Tailscale; the intermediate step is SSE-for-screen (change-signal like `orchestrator_v2.py:464`) not full WS.

### Option D — Extend the existing vanilla-JS `dashboard.html`

Rejected outright: it's a ~4,300-line inline-script page with a *different* UI (its own workspace/git/reviews layout), not the iOS UI. Parity means a rewrite anyway; a fresh Vite/React app clones an existing build pipeline instead of growing the worst file in the repo.

### Recommendation: **Option A**, with Option C's SSE-lite as a tracked v2 upgrade, and CORS (Option B) only behind auth if dev-server workflow is wanted.

**Reasoning:** the repo has already solved this exact problem once (`frontend/orchestrator-v2` → `static/orchestrator-v2` → `_serve_orchestrator_v2_static`, same-origin relative API, SSE+poll hybrid). Cloning that template gets "same exact UI + functionality" with the smallest possible server diff and zero new dependencies — the right posture for a stdlib Python server owned by one person.

---

## UI Parity Map

### Ports 1:1 (same behavior, minor idiomatic translation)

| iOS screen/feature | Web equivalent | Notes |
|---|---|---|
| Session sidebar list (search, filters, starred, badges, auto-expiry countdown) | Same layout, responsive collapse to drawer | Data identical (`/api/status` 2 s) |
| Detail tabs: Terminal / Git / Activity / Skills + pane tab bar | Tabs component | Same polling rules per tab |
| Terminal text view (ANSI, auto-scroll, selectable) | xterm.js **or** ported ansiToHtml renderer | The one real engineering chunk |
| FeedInteractionCard (permission/question wizard/plan) | Same card UI | Pure JSON contract, zero server work |
| OpenCodeTerminalFallbackCard + detector | Port detector to JS (pure string parsing) | Key-sequence submission (`[down,up,down×n,enter]`) works via same `/api/send` |
| Input bar: quick keys, skill autocomplete, attachment tray, drafts | Same; drafts → localStorage | |
| Git tab: status/stage/unstage/diff viewer/PR comments/request-fix | Same, incl. diff parser port (JS) | `/api/git-*`, `/api/github/pr-comments` |
| File search, Jira sheets, Skills tab | Same modals | Existing endpoints |
| New Session, Settings (server sources), Session Details, rename | Same modals; sources → localStorage | |
| Demo mode | Optional: mock fetch adapter (parity with `LocalDemoHarnessStore`) or drop | Ronnie's call |
| Connection status / AutoReconnectChip / error banners | Same | Derived from poll failures |

### Needs a web-idiom replacement

| iOS idiom | Web replacement |
|---|---|
| Swipe actions (stage/unstage/diff) | Hover action buttons + right-click context menu |
| Pull-to-refresh | Refresh button + the polling that already exists (browser pull-to-refresh would reload the page — suppress/avoid) |
| Context menus (⋯) | Dropdown menu component |
| Haptics | Drop (or `navigator.vibrate`, Android Chrome only — not worth it) |
| PHPicker / fileImporter | `<input type="file" multiple>` |
| Voice notes (AVAudioRecorder m4a, waveform) | MediaRecorder (webm/opus) + WebAudio analyser; server attachment endpoint is content-type-agnostic so this works — **verify**: handler passes `Content-Type` through (`server.py:177-201`) |
| APNs push + deep link | v1: in-app banner from 2 s polling + URL routing (`/harness-web/sessions/:id`). v2: Web Push (VAPID + service worker) |
| Bonjour LAN scan / Tailscale probe | Manual URL entry; browser can't do Bonjour. If same-origin, discovery is moot — you're already on the server |
| NavigationSplitView iPhone collapse | Responsive CSS breakpoint → drawer |

### Impossible / not worth doing

- **Bonjour discovery** — impossible in a browser. Moot under same-origin.
- **Haptics** — no real equivalent; drop.
- **Exact m4a voice notes** — browser records webm/opus; functional equivalent, different container. Fine since the attachment endpoint is format-agnostic.
- **Background notifications without new server work** — Web Push needs a VAPID provider in `push_notifications.py`; out of v1 scope.

---

## Required Server Changes

Minimum for Option A v1:

| # | Change | Size | Anchor |
|---|---|---|---|
| 1 | Serve the new SPA: add `/harness-web` route mirroring `_serve_orchestrator_v2_static` (incl. its traversal guard) + page-map entry | **S** (~25 lines) | `server.py:43-53`, `server.py:261-300`, dispatch at `server.py:359-361` |
| 2 | **Auth token (recommended before browser exposure):** shared-secret header check (`X-Cmux-Token`) inside `make_handler`, bypassed for loopback, token file under `storage.LOG_DIR`, 401 JSON otherwise. Also blocks CSRF (custom header forces preflight, which we never answer) | **S-M** (~80-120 lines incl. SPA token entry + localStorage) | wrap `do_GET/do_POST/do_PATCH/do_DELETE` in `server.py:327/799/1671/1709`; or one guard in a `dispatch` choke point |
| 3 | Nothing else. API contract is unchanged. | — | |

Optional / conditional:

| # | Change | Size | Anchor |
|---|---|---|---|
| 4 | CORS + `do_OPTIONS` (only if Ronnie wants vite dev-server or separate-origin hosting). Copy the `demo.py:745-777` header set into `_json_response` + static responses, origin allowlist — **requires #2** | **S** | `server.py:155-166`, `demo.py:745-777` |
| 5 | Web Push provider (VAPID) alongside APNs for background notifications | **M-L** (new dependency or hand-rolled VAPID JWT + push encryption; service worker endpoints) | `cmux_harness/push_notifications.py:178-205` |
| 6 | SSE change-signal for harness state (mirror the orchestrator-v2 pattern) to cut 2 s polling | **M** | `routes/orchestrator_v2.py:31`, `:464-475` |
| 7 | Multipart attachment upload (nicer browser UX than raw-body fetch) | **S** (raw body works fine from `fetch` too — skip unless wanted) | `server.py:177-201`, `attachments.py:58` |

No new endpoints are needed for UI parity: the iOS 26-endpoint set is complete.

---

## Security Assessment

**Current posture (observed):** unauthenticated `ThreadingHTTPServer` on `0.0.0.0:9091` (`dashboard.py:56`), plain HTTP, with **terminal-write** (`/api/send`), git-write, file read/write, `open-in-native`, and shell-outs to `gh`/`acli`. On the iOS client this was arguably tolerable (an app you install, on a network you trust).

**Why a browser client is worse:**
1. **CSRF / drive-by writes today, without any web app:** the API has no cookies and no auth, so classic CSRF token logic doesn't apply — but the inverse is worse: *any* web page Ronnie's browser visits can `fetch("http://<mac-lan-ip>:9091/api/send", {method:"POST", body: JSON.stringify(...), headers:{"Content-Type":"text/plain"}})` — a **simple request, no preflight**, body still parses as JSON server-side (`server.py` `_read_body` json.loads regardless of content type). LAN IP guessable / DNS-rebinding-able. An attacker page could type into his agent terminals.
2. **LAN exposure:** anything on the LAN (or tailnet) already has full terminal control. A web UI normalizes leaving this open in a browser tab.
3. **Plain HTTP:** terminal contents, Jira data, and (if added) tokens transit in cleartext — acceptable on tailnet (WireGuard-encrypted), weak on café LAN.

**Minimum acceptable bar (my recommendation):**
- Add the `X-Cmux-Token` shared-secret header check (#2 above). One token, stored in a file on the Mac, pasted into the web app once, kept in localStorage. This single change kills both the drive-by-POST vector (custom header → preflight → 501/deny) and casual LAN access.
- Keep exposure Tailscale-only by habit; optionally add a `--bind` flag so Ronnie can bind to the tailnet interface or 127.0.0.1 + `tailscale serve`.
- No CORS unless auth lands first. Never `Access-Control-Allow-Origin: *` on the real server (that's fine only in `demo.py`, which has no real terminals).

**Ronnie must decide:** token vs. "my LAN/tailnet is trusted, ship without auth." That's a real tradeoff (one-time paste UX vs. zero friction) — his call, but the browser drive-by vector pushes me to insist on at least the header check. TLS termination (self-signed vs. `tailscale serve` HTTPS) is also his call; Web Push requires a secure context, so if he wants background push later, HTTPS becomes mandatory.

---

## Top Risks

1. **Terminal rendering fidelity + performance.** 500 ms polling of up to 500 ANSI lines per selected session, now from a browser, with a JS renderer that must match `TerminalTextStyler` (1,402 LOC Swift). *Mitigation:* reuse the same bytes/semantics as iOS; engine already caches screens (`engine.py:53`); use xterm.js (battle-tested ANSI) rather than re-porting the styler pixel-perfect; add per-screen fingerprint short-circuit later if load matters.
2. **Security exposure becomes real.** Drive-by POST from any visited web page can already write to terminals; shipping a web app increases the chance this server stays open forever. *Mitigation:* `X-Cmux-Token` header check + no-CORS default + Tailscale-only habit (see Security).
3. **Scope creep against a moving target.** 190 endpoints, 4 existing dashboards, an orchestrator-v2 SPA, and an actively-evolving iOS app. "Same exact UI" could metastasize. *Mitigation:* freeze the parity contract at the 26 iOS endpoints and the iOS screen map; explicitly do not rebuild orchestrator-v2 features.
4. **Stdlib Python server fragility as features land.** Every addition (auth, SSE, WS, CORS) is hand-rolled on `BaseHTTPRequestHandler` (7,900 LOC across `server.py` + routes). *Mitigation:* keep server diff to serving statics + one auth guard; resist websocket temptation in v1; the SSE pattern already exists to copy if push is needed.
5. **Browser tab lifecycle vs. polling cadence.** Background tabs throttle timers; 500 ms screen polling silently degrades, and multiple open tabs multiply socket reads against the single cmux Unix socket guarded by a global lock (`engine._lock`). *Mitigation:* `document.visibilitychange`-aware polling (pause/slow in background, catch-up on focus); reuse the engine's existing screen cache; eventually the SSE change-signal.

---

## Open Questions (decisions only Ronnie can make)

1. **Auth:** shared-secret `X-Cmux-Token` header (recommended) vs. no auth (trust LAN/tailnet)? If token: also protect the 4 existing dashboards, or only the new app + mutating endpoints?
2. **Exposure:** keep binding `0.0.0.0`, or add `--bind` and run Tailscale-only / `tailscale serve` (which also gives HTTPS for free, unlocking future Web Push)?
3. **Dashboard consolidation:** does the new web app *replace* `/harness` (`dashboard.html`)? Which of `/`, `/orchestrator`, `/workflow-orchestrator`, `/orchestrator-v2` stay?
4. **Notifications:** is foreground-banner-from-polling enough for v1, or is background Web Push a launch requirement (forces HTTPS + VAPID work)?
5. **Terminal ambition:** scraped-text parity now (recommended), or invest in xterm.js + streaming from day one?
6. **Dev workflow:** same-origin-only (no CORS ever) vs. also support `vite dev` hot-reload from the laptop (requires CORS + auth first)?
7. **Demo mode:** port the mock store for offline demoing, or drop it in the web version?
