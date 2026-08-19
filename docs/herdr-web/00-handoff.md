# Herdr Harness Web App — Handoff Doc (Phase 2)

**Date:** 2026-08-18
**Decision (Ronnie):** "Both." Keep the finished cmux harness web app (branch `feat/harness-web-app`).
Build a second web app with **`herdr-harness-ios` parity** — the web equivalent of the iOS app that
lives **only** on the `codex/herdr-harness` feature branch.

This doc is the onboarding for a fresh session. Read it top to bottom, then start with
**§9 Execution Plan** step 1.

---

## 1. The two products (do not confuse them)

| | **cmux harness** (web app DONE) | **herdr harness** (web app TO BUILD) |
|---|---|---|
| iOS app | `cmux-harness-ios/` (70 Swift files, on `main`) | `herdr-harness-ios/` (175 Swift files, **only on `codex/herdr-harness`**) |
| Backend | `cmux_harness/server.py` + `dashboard.py`, port **9091**, plain HTTP + JSON polling | `herdr_harness/` + `herdr_dashboard.py`, port **9092**, HTTPS + **SSE** + Bearer auth |
| Data model | cmux workspaces/surfaces/sessions | Herdr workspaces/tabs/panes/agents (own socket protocol, no tmux) |
| Signature features | — | Attention Deck, Pane Topology Radar, Command Lens, **Native Pi Chat**, HerdPulse Live Activities, haptics, iPad 3-column split |
| Git worktree | `/Users/ronnierocha/Documents/Development/cmux-harness` | `/Users/ronnierocha/Documents/Development/cmux-herdr-harness` |
| Branch | `feat/harness-web-app` (off `main`) | `codex/herdr-harness` (worktree is checked out at `78a6548`) |
| Tailnet HTTPS | `https://ronniesitym4mbp.tail1db61d.ts.net:8443` → 9091 | `https://ronniesitym4mbp.tail1db61d.ts.net:8461` → 9092 |
| Auth | `X-Cmux-Token` header (token in `~/.cmux-harness/web-token.txt`) | `Authorization: Bearer <token>` (token in `~/.config/herdr-harness/api-token`) |

**Which iOS app is Ronnie's real one:** `herdr-harness-ios`. Evidence: this Mac has
DerivedData only for `herdr-harness-ios`, and the launchd/launch script + Tailscale serve
config all point at the feature-branch worktree. The Phase-1 brief named `cmux-harness-ios`
explicitly, which is why Phase 1 built the cmux replica — that decision is now kept as-is.

The Phase-2 web app must be the web equivalent of the **herdr** app, talking to the **9092**
backend, not the 9091 one.

## 2. Phase 1 (cmux web app) — state of the world

- Branch: `feat/harness-web-app` in `/Users/ronnierocha/Documents/Development/cmux-harness`
  (13 commits, unpushed). Served at `/harness-web` by the 9091 server (launchd
  `com.ronnierocha.cmux-dashboard`).
- Live URLs: `http://<mac>:9091/harness-web/#token=<token>` (LAN) or
  `https://ronniesitym4mbp.tail1db61d.ts.net:8443/harness-web/#token=<token>` (tailnet).
  Token: `cat ~/.cmux-harness/web-token.txt`.
- Verified: 245 web tests + 130 server tests, tsc clean, final adversarial review clean,
  CDP screenshots of terminal + Git tab, tailnet auth matrix 401/200.
- Full record: `docs/web-app/01`–`04` (investigation, API contract, feasibility, plan) and
  this repo's git history.

## 3. Herdr harness environment facts (verified 2026-08-18)

- **Worktree:** `/Users/ronnierocha/Documents/Development/cmux-herdr-harness`
  (branch `codex/herdr-harness`, at `78a6548`; one dirty file: `project.pbxproj` — Xcode noise).
- **Server:** `herdr_dashboard.py` entry point, `herdr_harness/` package. Port **9092**.
  Running under launchd **`com.ronnierocha.herdr-harness`** (KeepAlive). Launch script:
  `~/.config/herdr-harness/launch-herdr-harness.sh` — exports `HERDR_SESSION=default`,
  `HERDR_HARNESS_API_TOKEN` (read from `~/.config/herdr-harness/api-token` at start),
  `HERDR_HARNESS_TAILSCALE_URL`, `HERDR_HARNESS_TAILSCALE_HTTPS_PORT=8461`.
- **Tailscale serve:** `https://ronniesitym4mbp.tail1db61d.ts.net:8461` → `127.0.0.1:9092`
  (tailnet only). The iOS app uses exactly this URL.
- **Auth:** Bearer token required when `HERDR_HARNESS_API_TOKEN` is set (it is). `hmac.compare_digest`
  check in `herdr_harness/server.py` (~line 290). `/` serves a status page with a token-check UI.
- **Upstream proxy:** git/skills/file-search/Jira/attachments are **proxied to the cmux server**
  at `http://127.0.0.1:9091` (override: `HERDR_HARNESS_CMUX_URL`, server-side only). So **both
  servers must be running** for full parity.
- **Herdr protocol:** newline-delimited JSON over Herdr's Unix socket (NOT tmux). Requires
  Herdr ≥ 0.8.0 (protocol 19).
- **`pi-semantic-bridge/`:** optional Pi extension (TS, has its own `package.json` + tests) that
  publishes semantic lifecycle events over a private pane-scoped Unix socket. This powers
  Native Pi Chat. **Check at runtime whether it's loaded** in current pi panes (per-session
  load; see its README in the worktree).
- **Fixtures:** `scripts/setup_herdr_demo.py` — repeatable fixture topology in an isolated named
  Herdr session `herdr-ios-fixtures` (does not touch the default session).
- **iOS app:** Swift 6, SwiftUI, Observation, structured concurrency, **zero third-party deps**.
  `HERDR_HARNESS.md` in the worktree is the product spec (read it in full first).

## 4. Herdr API surface (preliminary — verify in Phase-2 investigation)

From `herdr_harness/server.py` route scan:

- `GET /api/v1/health` — herdr.connected + cache state (this is what the status page probes)
- `GET /api/v1/snapshot` — full state (workspaces/tabs/panes/agents)
- `GET /api/v1/workspaces` — workspace list
- `GET /api/v1/events` — **SSE stream** (the core transport; replaces 500ms/2s polling)
- `GET /api/v1/alerts` — attention deck data (blocked/done, alert journal)
- `GET /api/v1/live-activities` — HerdPulse data
- `GET /api/v1/push/status`, `POST /api/v1/push/` — APNs registration
- `GET /api/v1/network` — network info
- `GET /api/v1/jira/assigned`
- `POST /api/v1/voice/transcriptions` (+ legacy `GET /api/attachments`, `POST /api/attachments`,
  `GET /api/file-search`, `GET /api/git-status-path`, `GET /api/git-diff-path`,
  `POST /api/git-stage-path`, `POST /api/git-unstage-path`, `GET /api/jira/assigned`,
  `GET /api/jira/issue`, `GET /api/skills`, `GET /api/status`) — cmux-proxied utilities
- Terminal: base64 **ANSI full + delta frames** (see `herdr_harness/terminal.py` and
  `Models/TerminalGrid.swift`, `TerminalSource.swift`, `TerminalRefreshPolicy.swift`)
- Actions: agent messages via `agent.prompt`, shell via `pane.send_input`, keys via
  `pane.send_keys` (see `herdr_harness/cmux_tools.py` / `workspace_tools.py`)

Response envelope: `{"ok":false,"error":{"code":...,"message":...},"generatedAt":...}`
(verified live against 9092).

## 5. iOS app feature map (what "parity" means)

175 Swift files; `Views/` has 74 files in: `Attention/`, `Pane/`, `Root/`, `Settings/`,
`Shared/`, `Sidebar/`, `Workspace/`. Model clusters worth naming:

- **Attention Deck:** `Views/Attention/`, `Models/HerdrAlert.swift`, `AgentStatus.swift`,
  `State/HerdrAppModel.swift` — transition-aware blocked/done alerts, ranked panes, unread
  state, deep navigation.
- **Pane Topology Radar:** `Models/HerdrLayout.swift`, `HerdrPane.swift`, `HerdrTab.swift`,
  `HerdrWorkspace.swift` — spatial preview from real layout rectangles.
- **Command Lens:** status-aware prompt suggestions, agent-aware composer, key deck
  (Esc/arrows/Tab/Ctrl-C) — see `Views/Pane/`.
- **Native Pi Chat:** ~30 `Models/Pi*` files (`PiConversation*`, `PiSemantic*`, `PiMarkdown*`,
  `PiToolInvocation`, `PiThinkingBlock`, …), `Infrastructure/PiConversationSSEParser.swift`,
  `State/PiConversationReducer.swift` + `PiConversationStore.swift` — a semantic projection
  of a live Pi session (message turns, collapsed thinking, structured tool cards, streaming
  status, prompt/steer/follow-up/stop controls), sourced from the `pi-semantic-bridge` socket.
- **Terminal:** `Models/TerminalGrid.swift` — bounded Swift terminal grid applying cursor
  movement/erasure/dimensions/colors to base64 full+delta frames; keeps last good frame,
  falls back to text snapshot, auto-reconnects.
- **HerdPulse:** `HerdPulseWidgets/` (Live Activity + lock screen), `Infrastructure/HerdPulse*`
  (coordinator, registration client/retry, token receiver), `Models/HerdPulse*`.
- **Platform:** `Design/HerdrHaptic*` (haptics), `Infrastructure/KeychainStore.swift`,
  `NotificationManager.swift`, `ActiveServerConnection.swift`, `ServerConfiguration.swift`.
- **Nav:** `Models/AppTab.swift`, `SidebarTree.swift`, `WorkspaceRoute.swift`,
  `WorkspaceFilter.swift`, `AppTab` — iPhone typed stack nav, iPad balanced 3-column split.

## 6. Web equivalence — what ports, what needs a decision

| iOS feature | Web equivalent |
|---|---|
| SSE `/api/v1/events` | Native `EventSource` — **replaces** all Phase-1 polling stores. Reuse the store architecture; swap the transport. |
| Bearer token auth | Same `#token=` fragment + client-side injection pattern as Phase 1, but header is `Authorization: Bearer`. Loopback bypass semantics mirror Phase-1 P0. |
| Static serving | **Recommended:** serve from the 9092 server at `/herdr-web` (same-origin, kills CORS — same P0 decision as Phase 1). Needs a small `herdr_harness` change. Alternative: new port. Decide in planning. |
| TerminalGrid (full+delta frames) | **Investigate the frame format first.** The Phase-1 ANSI renderer (`frontend/harness-web/src/terminal/ansi.ts`) handles styled text but NOT a cursor-addressed grid. Delta frames likely need a small grid state machine (port the logic of `TerminalGrid.swift`). This is the single biggest technical risk. |
| Native Pi Chat | Web version of the semantic conversation view (turns, thinking collapse, tool cards, streaming). Depends on `pi-semantic-bridge` being loaded in the pane — verify at runtime; the bridge talks to a Unix socket, so the browser must get Pi data **through the 9092 API** (check how `PiConversationSSEParser` + the server expose it). |
| Attention Deck | Ports directly (alerts endpoint + ranked list + badges). |
| Pane Topology Radar | SVG/CSS spatial layout from `HerdrLayout` rects — straightforward. |
| Command Lens | Input bar + key deck — Phase-1 input bar (quick keys, drafts, autocomplete) is a strong base. |
| HerdPulse Live Activities | No browser equivalent. **Decision:** (a) skip in v1, (b) browser Notifications API as degraded equivalent, (c) skip entirely. |
| Haptics | Skip (Web Haptics not meaningful on Mac). |
| APNs push | **Decision:** skip v1 / Web Push as later equivalent. |
| iPad 3-column split | Responsive 3-column at wide widths (Phase-1 is already responsive with a <900px drawer). |
| Keychain / server picker | localStorage server list + token (Phase-1 settings modal pattern). |

## 7. Reusable assets from Phase 1 (in `feat/harness-web-app`)

- `frontend/harness-web/` — Vite 6 + React 18 + TS + zustand + vitest scaffold, dark theme
  (`src/styles/global.css`), `src/api/client.ts` (token header + timeout + abort merge),
  `src/store/connectionStore.ts` (reconnect state machine), `src/lib/workspaceGroups.ts`
  (grouping + search/filter), `src/hooks/useOverlay.ts` (Esc layers + scroll lock),
  `src/lib/hashRoute.ts` (deep links), `src/components/ApprovalBanner.tsx` pattern.
- `src/terminal/ansi.ts` — ANSI SGR → styled spans (16/256/truecolor). Reuse for Pi Chat
  tool output / terminal text; **not** enough for the grid terminal (see §6).
- Phase-1 commit convention: per-phase commits, plain messages, no AI attribution,
  stage explicit paths only.
- **Subagent infra:** `.pi/agents/{planner,reviewer,architect,coder}.md` (in the cmux-harness
  repo, **untracked** — machine-specific model ID). Model: `custom-lux-27b/qwen3.8-27b-bf16`
  (baseUrl `http://100.120.49.92:8012/v1`), reasoning `xhigh`, context 131072.
  Invoke with `agentScope: "both"`. All 10 Phase-1 implementation/review runs cost $0.
  If the `.pi/agents/` dir is missing in a fresh session, recreate the 4 agent files
  (frontmatter: `name`, `description`, `model: custom-lux-27b/qwen3.8-27b-bf16:xhigh`).

## 8. Costs so far (ledger: `~/.pi/agent/spend/usage.jsonl`)

- Phase 1 planning (kimi-k3/Fireworks, 4 runs): **$2.9861**
- Phase 1 implementation + review (local qwen3.8-27b, 10 runs, 1,502 turns): **$0.00**
- Phase 1 total: **$2.9861**

## 9. Execution plan for the fresh session

Mirror the Phase-1 pipeline (it worked — 7 phases, sequential local-qwen coders,
orchestrator verifies + commits, final adversarial review):

1. **Investigation (read-only, subagent planner):** in the `cmux-herdr-harness` worktree —
   read `HERDR_HARNESS.md` in full; map every `/api/v1/*` route + SSE event types + action
   endpoints with request/response shapes; probe the **live 9092** (token:
   `cat ~/.config/herdr-harness/api-token`) to verify the envelope and the terminal frame
   format; check `pi-semantic-bridge` runtime state; produce `docs/herdr-web/01-investigation-ios-app.md`
   + `02-investigation-api-server.md` (in the cmux-harness repo, next to the Phase-1 docs).
2. **Architecture (subagent architect):** frame-format deep dive (full vs delta,
   `TerminalGrid.swift` semantics), SSE store design, Pi Chat data path, static-serving
   decision, port/namespace decision → `03-feasibility-assessment.md`.
3. **Plan (subagent planner):** phase split (suggest: P0 scaffold+auth+static, P1
   connection+sidebar+attention deck, P2 terminal grid + delta frames, P3 Pi Chat,
   P4 command lens + input, P5 topology radar + pane topology, P6 settings/servers +
   responsive split, P7 polish + notifications decision) → `04-implementation-plan.md`.
   **Ronnie reviews the plan before implementation** (he approved this way in Phase 1).
4. **Implementation:** sequential coder subagents per phase, orchestrator runs
   `npx tsc --noEmit` + `npm test` + `npm run build` + `python3 -m unittest` after each,
   live-curls 9092, commits per phase. Do NOT push.
5. **Final adversarial review** (reviewer subagent) → fix findings → commit.
6. **Verify in browser** (throwaway Chrome + CDP, as in Phase 1) + **tailnet check**
   (`curl https://ronniesitym4mbp.tail1db61d.ts.net:8461/...` with Bearer token).
7. **Report to Ronnie:** Slack (slack-me skill) with URL + token, cost ledger, QA list.

## 10. Open questions for Ronnie (ask during planning, not blocking)

1. Serve the herdr web app from 9092 at `/herdr-web` (recommended) or a separate port?
2. HerdPulse: skip, or Web Notifications as a degraded equivalent?
3. Web Push (APNs replacement): v1 or later?
4. Pi Chat depth: full semantic conversation (tool cards, thinking collapse) in v1, or
   terminal-view-first with Pi Chat as a fast-follow?
5. Does the web app need the `scripts/setup_herdr_demo.py` fixtures for QA, or is the
   real `default` Herdr session enough?

## 11. Gotchas (learned in Phase 1)

- The 9091 cmux server is **launchd-managed** (`com.ronnierocha.cmux-dashboard`,
  KeepAlive, log `~/Library/Logs/cmux-dashboard.log`); 9092 is `com.ronnierocha.herdr-harness`.
  Never kill server PIDs expecting them dead — launchd revives them. The Phase-1 `cmux-dashboard`
  wrapper's `pgrep -f "dashboard.py"` is too broad and once killed the herdr server
  (it self-recovered).
- Don't `git add -A` in either worktree (untracked `.pi/`, `artifacts/`, demo docs).
- The herdr worktree has one dirty file (`project.pbxproj`, Xcode-generated) — leave it.
- `HERDR_HARNESS_CMUX_URL` defaults to `http://127.0.0.1:9091` — both servers must be up
  for git/Jira/skills/file-search/attachments parity.
- Phase-1 parity lesson: **agent-facing prompt strings are byte-exact-critical**; verify
  against Swift sources. Same will apply to any command-lens prompt suggestions.
- Local 27B model: sequential runs only, one phase per run, keep prompts tight;
  orchestrator verifies everything (the model is fast but not infallible).
