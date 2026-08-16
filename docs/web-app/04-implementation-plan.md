# Implementation Plan — cmux-harness Web App (iOS parity)

**Author:** Planner · **Date:** 2026-08-12
**Inputs:** `docs/web-app/01-investigation-ios-app.md`, `02-investigation-api-server.md`, `03-feasibility-assessment.md` (all verified against code).
**Direction locked by feasibility doc:** Option A — new `frontend/harness-web/` Vite + React + TypeScript SPA, built into `cmux_harness/static/harness-web/`, served same-origin at `/harness-web`, 500 ms ANSI-scrape terminal in v1, `X-Cmux-Token` shared-secret auth.

---

## 1. Goal & Scope

**Goal:** Ronnie can open `http://<mac>:9091/harness-web` (LAN or Tailscale) on a laptop browser and drive every cmux workspace/agent session with the same screens and behaviors the iOS app (`cmux-harness-ios`) provides today.

"Same exact UI + functionality" means: **the same 20-screen map, the same data, the same polling cadences, the same interaction cards, the same prompt-formatting helpers** — translated to web idioms (see §5). Pixel-identical styling is *not* required; layout and behavior parity is.

### IN scope (v1)

- All **26 iOS endpoints** (see §4) consumed from a TypeScript API client mirroring `HarnessAPI.swift`.
- The full iOS screen map (01-investigation §"Navigation & Screen Map"):
  1. Server setup (web variant: manual URL + token entry — no Bonjour/demo)
  2. Session sidebar (search, filters, star/auto badges, unread badges, expiry countdown, connection card, AutoReconnectChip)
  3. Workspace detail shell (4 tabs, pane tab bar, ⋯ menu, session details sheet, rename dialog)
  4. Terminal tab (ANSI render, auto-scroll, selectable text)
  5. FeedInteractionCard (permission / question wizard / plan / generic)
  6. OpenCodeTerminalFallbackCard + JS port of the prompt detector (277 LOC Swift) incl. key-sequence submission and integration upsell
  7. Input bar (quick keys, skill autocomplete, attachment tray, per-session drafts)
  8. Easy-mode keyboard (2×4 big keys)
  9. Git tab (status/stage/unstage, recent commits, PR comments incl. request-fix)
  10. Diff viewer modal + line-comment composer (JS port of `parseUnifiedDiffLines`)
  11. Activity tab
  12. Skills tab (3 insert actions)
  13. File search modal
  14. Jira modal (assigned + exact lookup, insert/copy)
  15. Settings (server sources — localStorage)
  16. New Session modal (Claude/Shell, worktree, prompt)
  17. Voice note recorder (MediaRecorder + WebAudio waveform)
  18. File/photo attach (`<input type="file" multiple>`)
  19. Approval banner (foreground, driven by 2 s polling — replaces APNs banner)
  20. Shared components (badges, error banner, stat pills, countdown, diff colors)
- Polling scheduler mirroring iOS cadences (2 s global / 500 ms screen / 10 s git) with `document.visibilitychange`-aware pausing.
- Server: `/harness-web` static route + `X-Cmux-Token` auth check (§6).
- Small iOS patch: send `X-Cmux-Token` header from `HarnessAPITransport.swift` so the iOS app keeps working once auth is on (companion change, separate PR OK).

### OUT of scope (v1) — defer to v2

| Deferred item | Why |
|---|---|
| WebSocket / true-pty terminal (Option C) | Feasibility rejected it for v1; stdlib server has no WS framing. Revisit as SSE change-signal first. |
| Web Push (VAPID + service worker) | Needs HTTPS + a new push provider in `push_notifications.py`. Foreground banner from polling covers the real need. |
| Bonjour/discovery | Impossible in browsers; moot same-origin. |
| Demo mode (`LocalDemoHarnessStore` port) | Optional mock; drop unless Ronnie asks (decision #5). |
| CORS / `do_OPTIONS` | Only needed for separate-origin dev; skip (decision #6). |
| New server endpoints | The 26-endpoint contract is complete; freeze it. |
| Replacing `/harness`, `/orchestrator`, `/workflow-orchestrator`, `/orchestrator-v2` | Untouched; regression-checked only (decision #4). |
| Haptics | No web equivalent. |
| m4a voice notes | Browser produces webm/opus; attachment endpoint is format-agnostic — acceptable functional equivalent. |

---

## 2. Architecture (one page)

```
laptop browser ──http(LAN/Tailscale)──> Mac :9091  ThreadingHTTPServer (stdlib, unchanged core)
   │                                              ├─ /harness-web/*  → cmux_harness/static/harness-web/  (NEW, ~25 lines)
   │  same-origin fetch /api/* + X-Cmux-Token     ├─ /api/*           → existing handlers + token guard (NEW)
   └────────────────────────────────────────────> └─ /harness, /orchestrator-v2, ... (untouched)

frontend/harness-web/  (Vite 6 + React 18 + TypeScript; template cloned from frontend/orchestrator-v2/)
  vite.config.ts: base "/harness-web/", build.outDir "../../cmux_harness/static/harness-web"
  src/
    api/client.ts         — fetch wrapper: base "", 15 s timeout (60 s uploads), error envelope,
                            injects X-Cmux-Token from localStorage
    api/endpoints.ts      — 26 typed functions mirroring HarnessAPI.swift (§4)
    api/types.ts          — TS models ported from iOS Models/*.swift
    store/                — polling scheduler + state slices (see below)
    terminal/ansi.tsx     — ANSI→React renderer (see Terminal below)
    terminal/detector.ts  — JS port of OpenCodeTerminalInteractionDetector.swift
    components/...        — screens mirroring the iOS view tree
```

**State/data layer.** Plain React + a small typed store — **no new state framework** beyond what's needed for 500 ms updates: recommend **`zustand`** (one 1 KB dep, selector subscriptions prevent re-rendering the whole tree on each screen poll; orchestrator-v2's single-component pattern is the anti-example we are avoiding). Store slices mirror the TCA reducer slices: `connection` (2 s loop, sources, errors), `session` (selection, 500 ms screen loop, drafts), `git` (10 s loop, diff, PR comments), `tools` (skills/file-search/Jira), `attachments`. Polling scheduler: one `setInterval` per loop, each gated on `document.visibilityState === "visible"`; on `visibilitychange → visible`, fire an immediate catch-up refresh. Per-session drafts + sources + token in `localStorage` (keys prefixed `harness-web:`).

**Terminal rendering.** Primary: **ANSI→React renderer** (`terminal/ansi.tsx`) — seeded from the existing `ansiToHtml` in `cmux_harness/static/orchestrator.js:249-253`, extended toward `TerminalTextStyler.swift`'s palette/semantic highlighting as needed. Rationale: the iOS terminal is a *selectable, read-mostly text view* fed by full-screen snapshots every 500 ms — a styled `<pre>` with memoized line spans matches that semantics exactly, keeps text selection/copy free, and avoids xterm.js's stateful-buffer mismatch with snapshot polling (xterm wants a byte stream; feeding it full-screen snapshots requires reset-and-rewrite each poll). **Fallback:** if fidelity/perf disappoints, swap the renderer internals for xterm.js (write-with-reset per snapshot) behind the same `<TerminalView text=...>` component interface — no other code changes. The OpenCode detector consumes the *plain* text (already stripped), so it is renderer-independent.

**Component library.** **Plain CSS modules + `lucide-react` icons** — exactly what orchestrator-v2 uses (see its `package.json`: lucide-react only, hand-written `styles.css`). No Tailwind/MUI; stay consistent with the repo's existing frontend.

**Build/output wiring.** `vite.config.ts`: `base: "/harness-web/"`, `build.outDir: "../../cmux_harness/static/harness-web"`, `emptyOutDir: true` — identical pattern to `frontend/orchestrator-v2/vite.config.js:6-12`. Built assets are committed the same way orchestrator-v2's are (follow the repo's existing convention).

**Path.** `/harness-web` — verified free: `_STATIC_CONTENT` is an exact-path map (`server.py:73-82`) and `_serve_orchestrator_v2_static` only prefixes `/orchestrator-v2` (`server.py:262-265`). No clashes.

**Auth flow (`X-Cmux-Token`).** Server side: on startup, load-or-generate a random hex token at `$LOG_DIR/web-token.txt`; print the ready-to-open URL `http://<host>:9091/harness-web/#token=<tok>` to stdout. Guard: every non-loopback request to `/api/*` and `/harness-web/*` must carry header `X-Cmux-Token: <tok>` or get `401 {"ok":false,"error":"unauthorized"}`. Loopback (127.0.0.1/::1) bypassed so Mac-local dashboards keep working. Client side: on first load the app reads `#token=` from the URL fragment (never sent to the server), stores it in localStorage, strips it from the URL; if absent and a 401 is seen, show a one-field "paste token" screen. This simultaneously blocks the drive-by-POST/CSRF vector (custom header ⇒ preflight ⇒ server never answers OPTIONS ⇒ browser blocks) and gates LAN access.

---

## 3. Phase Breakdown

Each phase ends with a demonstrable win on the laptop. Effort: S < half day, M ~1 day, L 2+ days.

### Phase 0 — Scaffold + static serving + token auth (S)

**Objective:** `http://<mac>:9091/harness-web` serves a "hello" SPA on the laptop, token-gated.

Work items:
1. NEW `frontend/harness-web/` — clone `frontend/orchestrator-v2/` scaffolding minus CopilotKit/ai-sdk deps: `package.json` (react, react-dom, lucide-react, zustand; dev: vite@^6, @vitejs/plugin-react, typescript, vitest), `vite.config.ts` (base `/harness-web/`, outDir `../../cmux_harness/static/harness-web`), `tsconfig.json`, `index.html`, `src/main.tsx`, `src/App.tsx` (placeholder), `src/styles/`.
2. MODIFY `cmux_harness/server.py`:
   - Add `_serve_harness_web_static(self, path)` mirroring `_serve_orchestrator_v2_static` (`server.py:261-300`) including the traversal guard, rooted at `_STATIC_DIR / "harness-web"`.
   - Call it first in `do_GET` next to the orchestrator-v2 call (`server.py:359-361`).
   - Add token guard: in `make_handler` (`server.py:135`), helper `_auth_ok()` checking `self.client_address` loopback or `self.headers.get("X-Cmux-Token") == token`; call at the top of `do_GET` (`:327`), `do_POST` (`:799`), `do_PATCH` (`:1671`), `do_DELETE` (`:1709`) for paths starting `/api/` or `/harness-web`; 401 JSON otherwise.
   - Token load-or-create helper + startup log line printing the `#token=` URL (near `dashboard.py:41-56` startup).
3. Client token bootstrap in `src/api/client.ts` + token-paste screen in `App.tsx`.
4. iOS companion patch (can land separately): add `X-Cmux-Token` header in `HarnessAPITransport.swift` request builder, token stored via `HarnessSettingsStore`.

**Verification:** `cd frontend/harness-web && npm install && npm run build`; `./cmux-dashboard restart`; from the laptop: open the printed URL → placeholder page renders; `curl http://<mac>:9091/api/status` → 401; `curl -H "X-Cmux-Token: <tok>" ...` → 200; on the Mac: `http://localhost:9091/harness` still works (loopback bypass); `/orchestrator-v2` loads.

### Phase 1 — Server connection + session sidebar + status/log (M)

**Objective:** laptop shows the live session list, connection status, and activity — the app's skeleton.

Work items:
1. `src/api/types.ts` — port `HarnessStatus`, `Workspace`, `LogEntry`, `NotificationsResponse` from iOS `Models/WorkspaceModels.swift`, `SessionStateModels.swift`, `NotificationModels.swift`.
2. `src/api/endpoints.ts` — `getStatus, getLog, getNotifications, markNotificationsRead, toggle` (+ client error-envelope handling mirroring `HarnessAPITransport.swift`).
3. `src/store/connection.ts` — 2 s loop (status+log+notifications parallel, mirroring `HarnessFeatureEffects.swift:10`), visibility-aware; derive Connected/Reconnecting/NoSocket; error banner state; stale-selection pruning.
4. `src/components/Sidebar/` — `HomeHeader` (title, refresh / +new / settings buttons, source pill), `ConnectionCard` (dot, title, updated time, AutoReconnectChip → `POST /api/toggle`), `SearchFilterBar` (All / Needs You / Auto), `WorkspaceCard` (star ⚡ badges, branch/dir/panes chips, unread badge, "Needs You" derivation = latest log action containing "human", auto-expiry countdown via 30 s timer), `SessionContextMenu` as dropdown (auto-mode radio → `/api/workspace`, star → `/api/workspace-star`, rename dialog → `/api/rename`).
5. `src/components/ErrorBanner.tsx`; session grouping util (`WorkspaceSessionGroup` port).
6. `src/App.tsx` — split layout (sidebar + empty detail placeholder), responsive collapse to drawer under ~768 px.

**Depends:** Phase 0. **Verification (laptop):** sidebar matches iOS sidebar side-by-side (same sessions, badges, branch chips); toggle auto-reconnect from laptop, watch iOS reflect it within 2 s; disconnect cmux app → dot turns red on both.

### Phase 2 — Terminal tab + interaction cards (L) ← the core win

**Objective:** select a session on the laptop, watch its terminal live at 500 ms, answer OpenCode prompts, send text/keys.

Work items:
1. `src/api/endpoints.ts` += `getScreen(index, lines=200), getFeed, replyFeed, getOpenCodeIntegration, installOpenCodeIntegration, sendText, sendKey` (keys whitelisted: up/down/tab/enter/left/right/escape/backspace).
2. `src/store/session.ts` — selection state; 500 ms screen loop (`HarnessFeatureEffects.swift:57` parity), paused when hidden or when no session selected; feed reply pending-ID dedupe (`pendingFeedReplyIDs` parity).
3. `src/terminal/ansi.tsx` — ANSI→React renderer (seed: `cmux_harness/static/orchestrator.js:249-253`; palette from `TerminalTextStyler.swift`); component auto-scrolls to bottom on new content unless user scrolled up; "(no terminal data yet)" empty state.
4. `src/terminal/detector.ts` — line-for-line port of `OpenCodeTerminalInteractionDetector.swift` (277 LOC; pure string parsing over last 48 lines): permission / question / questionReview shapes + plain-text stripping.
5. `src/components/Terminal/` — `TerminalView`, `FeedInteractionCard` (permission Allow once/Always/Reject; question multi-step wizard + custom answer + review screen; plan approve/manual/reject; generic key buttons; `supportsNativeReply === false` → fallback note), `OpenCodeFallbackCard` (choices, manual key buttons, **computed key sequence** `[down, up, down×selectedIndex, enter]` via repeated `/api/send`), integration upsell (`POST /api/integrations/opencode`).
6. Minimal input row for this phase (text + send + quick keys); full input bar lands in Phase 4.
7. Detail shell: `DetailTabBar` (Terminal/Git/Activity/Skills — only Terminal + Activity live this phase), `SessionPaneTabBar` (pane pills + `selectWorkspacePane`), `SessionDetailsSheet` (metadata card incl. cost), rename dialog reuse.

**Depends:** Phase 1. **Verification (laptop):** run an OpenCode session on the Mac; trigger a permission prompt → card appears on laptop, click "Allow once" → terminal advances; scrollback/select/copy text works; type in input bar → appears in the Mac's cmux terminal; pane switching works on a multi-pane session. Side-by-side with iOS: same prompt detected on both.

### Phase 3 — Git tab + diff viewer + PR comments (M)

**Objective:** full git workflow from the laptop.

Work items:
1. `src/api/endpoints.ts` += `getGitStatus, stageFile, unstageFile, getGitDiff, getPRComments(includeResolved)`.
2. `src/store/git.ts` — 10 s poll only while Git tab + Status segment visible (`HarnessFeatureEffects.swift:68` parity); PR comments load on demand.
3. `src/components/Git/` — `GitStatusView` (Repository section, Clean state, Staged/Unstaged `GitFileRow`s with hover action buttons + right-click menu replacing swipe actions: Diff/Stage/Unstage, Recent Commits), loading/error/empty states.
4. `src/components/Git/DiffSheet.tsx` — modal; port `parseUnifiedDiffLines` (`DiffViews.swift:264`) to `src/lib/unifiedDiff.ts` (metadata/hunk/context/addition/deletion rows, old/new gutters, green/red backgrounds); tap-line → `DiffLineCommentSheet` → formatted block appended to input draft via the port of `formatDiffLineReviewPrompt` (`HarnessFeatureHelpers.swift`), jump to Terminal tab.
5. `src/components/Git/PRComments.tsx` — show-resolved toggle, PR header + external link, per-file thread rows (line pills, Resolved/Outdated, code-context block, comment bubbles), insert-to-prompt / copy / open link / **Request fix** (formatted thread via `formatPRCommentThreadPrompt` port → `sendText`).

**Depends:** Phase 2 (input-draft plumbing). **Verification (laptop):** stage/unstage a file, open its diff, add a line comment → lands in terminal draft; open PR comments, click Request fix → agent receives the thread; side-by-side diff vs iOS for the same file.

### Phase 4 — Full input bar (drafts, skills autocomplete, attachments, voice) (M)

**Objective:** the iOS input experience, complete.

Work items:
1. `src/components/Input/InputBar.tsx` — expandable action row, multiline auto-growing textarea (1–6 rows), send button enable/disable rules (draft non-empty OR an uploaded attachment; blocked while uploads in flight), quick-key rows (row 1 always, row 2 when expanded), focus management (jump-to-Terminal + focus after inserts from other screens).
2. Drafts: `localStorage` per workspace UUID, restored on select, trimmed when sessions disappear (`HarnessSettingsStore.detailDrafts` parity).
3. `SkillAutocomplete` — `/` or `$` at token start → panel (max 3 suggestions from `getSkills(index)` lazy-loaded, cancel, tap-to-replace).
4. `src/store/attachments.ts` + `AttachmentTray` — chips with Uploading/Added/Error+retry/remove states; upload = raw-body fetch with `X-Cmux-Workspace-Index/UUID/Filename` (percent-encoded) + `Content-Type`, 20 MB client-side cap (`HarnessAPI.swift:24` parity), 60 s timeout; send concatenates server paths + message, space-joined + "\n".
5. File/photo attach via `<input type="file" multiple>` (images and any-file modes).
6. `VoiceNoteSheet.tsx` — MediaRecorder + WebAudio analyser waveform (44 samples), duration counter, 10-min cap, playback preview, discard-confirm, save → attachment pipeline (webm/opus).
7. `EasyModeKeyboard.tsx` — 2×4 big-key grid, hides tab bar, forced Terminal tab.

**Depends:** Phase 2. **Verification (laptop):** attach a photo + a file + a 5-second voice note, send → agent receives paths; drafts survive reload and session switching; `/`+skill autocomplete inserts.

### Phase 5 — Tools: Jira, file search, Skills tab (S-M)

**Objective:** the three tool surfaces.

Work items:
1. `src/api/endpoints.ts` += `getSkills, fileSearch(q), getJiraAssigned, getJiraIssue`.
2. `src/components/Tools/FileSearchModal.tsx` — ≥3 chars, re-issue per keystroke with cancellation (AbortController; parity with `fileSearchCancelID`), tap → append `` `path` `` to draft + focus Terminal.
3. `src/components/Tools/JiraModal.tsx` — exact lookup field (key or browse URL), assigned list grouped by project, status/priority pills, copy-key toast (1.6 s), insert block (`formatJiraTicketPrompt` port) → Terminal.
4. `src/components/Tools/SkillsTab.tsx` — Project/User sections, per-skill menu: insert as `/name` (Claude Code), `$name` (Codex CLI), or `` `path` ``; pull-to-refresh → refresh button.
5. `src/components/Tools/ActivityTab.tsx` — log rows for selected session (free from the 2 s loop).

**Depends:** Phase 4 (draft/focus plumbing). **Verification (laptop):** insert a Jira ticket and a file path into the input; skills insert in all 3 formats.

### Phase 6 — Session management + settings (M)

**Objective:** create/manage sessions and server sources entirely from the laptop.

Work items:
1. `src/api/endpoints.ts` += `newSession, renameWorkspace` (star/workspace/toggle already done).
2. `NewSessionModal.tsx` — Claude/Shell segmented, project path default `~/Documents/Development/sample-app`, JIRA URL auto-extract `ABC-123` → Branch, prompt field, Creating state; on success: close, 750 ms wait, refresh, auto-select new session + progress overlay (two phases, `SessionCreationProgressOverlay` parity).
3. `SettingsModal.tsx` — saved server sources CRUD in localStorage (name + URL), active-source switching, delete-active fallback behavior. Note: sources exist for multi-server parity; with same-origin serving the current server is implicit, so sources list is informational + future-proofing (flag to Ronnie if he'd rather cut it — decision #7).
4. Multi-pane polish: git-dirty dots + unread badges on pane pills; session-state badge in nav.

**Depends:** Phase 1. **Verification (laptop):** create a Claude session with a Jira URL → worktree + workspace appears, auto-selected; create a Shell session; rename + star + auto-mode all stick (verify on iOS too).

### Phase 7 — Notifications banner, approval deep-link, polish (S)

**Objective:** parity for the remaining overlays + hardening.

Work items:
1. `ApprovalBanner.tsx` — top overlay when 2 s polling surfaces an `approval_required` notification/feed item: workspace name, request/reason, tap → select session + `POST /api/push/clear` + `markNotificationsRead` (optimistic local clear, server confirm), ✕ dismiss. (No `/api/push/register` — that's APNs-only.)
2. URL routing — `react-router` not required; hand-rolled `#/sessions/:uuid` hash routing so banner clicks/refresh/deep-links land on a session (also enables bookmarking).
3. Polish pass against §5 mapping: focus outlines, keyboard shortcuts (Enter send / Esc dismiss), scroll-lock management, responsive drawer behavior, 30 s expiry countdown ticking, error-banner coverage on every screen.
4. Regression sweep per §7.

**Depends:** Phases 2–6. **Verification (laptop):** trigger an approval-required state on the Mac → banner appears on laptop within 2 s, tap jumps to the session; reload on a session URL restores it.

---

## 4. API Parity Table

All endpoints at root `/api/*` on `http://<host>:9091`, plain JSON, no auth today (token added Phase 0). Web functions live in `frontend/harness-web/src/api/endpoints.ts`.

| # | Method/Path | Web client fn | Phase |
|---|---|---|---|
| 1 | GET `/api/status` | `getStatus()` | 1 |
| 2 | GET `/api/log` | `getLog()` | 1 |
| 3 | GET `/api/notifications` | `getNotifications()` | 1 |
| 4 | POST `/api/notifications/read` | `markNotificationsRead(req)` | 1 |
| 5 | POST `/api/toggle` | `setEngineEnabled(enabled)` | 1 |
| 6 | POST `/api/workspace` | `setWorkspaceAutoMode(index, enabled, autoMode)` | 1 |
| 7 | POST `/api/workspace-star` | `setWorkspaceStarred(index, starred)` | 1 |
| 8 | POST `/api/rename` | `renameWorkspace(index, name)` | 1 (dialog), wired 6 |
| 9 | GET `/api/screen?index&lines` | `getScreen(index, lines=200)` | 2 |
| 10 | GET `/api/feed` | `getFeed()` | 2 |
| 11 | POST `/api/feed/reply` | `replyFeed(req)` | 2 |
| 12 | GET `/api/integrations/opencode` | `getOpenCodeIntegration()` | 2 |
| 13 | POST `/api/integrations/opencode` | `installOpenCodeIntegration()` | 2 |
| 14 | POST `/api/send` | `sendText(index, text, surfaceId?)` / `sendKey(index, key, surfaceId?)` | 2 |
| 15 | GET `/api/git-status?index` | `getGitStatus(index)` | 3 |
| 16 | POST `/api/git-stage` | `stageFile(index, file)` | 3 |
| 17 | POST `/api/git-unstage` | `unstageFile(index, file)` | 3 |
| 18 | POST `/api/git-diff` | `getGitDiff(index, file, section)` | 3 |
| 19 | GET `/api/github/pr-comments?index&includeResolved` | `getPRComments(index, includeResolved)` | 3 |
| 20 | GET `/api/skills?index` | `getSkills(index)` | 4 (autocomplete), 5 (tab) |
| 21 | POST `/api/attachments` | `uploadAttachment(index, uuid, filename, blob, contentType)` (raw body + X-Cmux-* headers, ≤20 MB) | 4 |
| 22 | GET `/api/file-search?index&q` | `fileSearch(index, q)` | 5 |
| 23 | GET `/api/jira/assigned?project&limit` | `getJiraAssigned(limit=50)` | 5 |
| 24 | GET `/api/jira/issue?q` | `getJiraIssue(q)` | 5 |
| 25 | POST `/api/new-session` | `newSession(req)` | 6 |
| 26 | POST `/api/push/clear` | `clearPushApproval(req)` | 7 |
| — | POST `/api/push/register` | **not ported** (APNs-only; Web Push is v2) | — |
| + | GET `/api/network` | `getNetworkInfo()` (nice-to-have for a "server info" section in Settings) | 6 |

---

## 5. iOS→Web UX Mapping

| iOS idiom | Web replacement |
|---|---|
| NavigationSplitView sidebar/detail | CSS grid split layout; <768 px → sidebar as slide-over drawer |
| Swipe actions (stage/unstage/diff) | Hover-revealed action buttons + right-click context menu |
| Pull-to-refresh | Explicit refresh buttons (polling already covers freshness); never implement browser pull-refresh |
| Context menus (⋯) | Dropdown menu component (custom, ~100 LOC, or headless popover — no kit) |
| Modal sheets | Centered modal dialogs with backdrop + Esc to dismiss (voice sheet: non-dismissable, fixed height) |
| APNs push + banner + deep link | 2 s polling-driven in-app `ApprovalBanner` + `#/sessions/:uuid` hash route (Web Push deferred to v2) |
| Bonjour LAN scan / Tailscale probe | None — same-origin means you're already on the server; Settings shows server URL + `/api/network` info |
| Haptics | Dropped (no meaningful web equivalent) |
| PHPicker / fileImporter | `<input type="file" multiple>` (image-only and any-file variants) |
| AVAudioRecorder (m4a) + waveform | MediaRecorder (webm/opus) + WebAudio AnalyserNode waveform; server attachment endpoint is format-agnostic |
| UserDefaults | `localStorage` (`harness-web:` prefix): token, sources, last session, per-session drafts |
| Tab bar hidden while keyboard focused | Hide tab bar while input textarea focused (same rule) |
| Auto-scroll with retry nudges | `scrollIntoView` on content change unless user scrolled up (stick-to-bottom flag) |
| Dynamic Type accessibility stacking | Responsive CSS (buttons stack under narrow widths) |
| Rename alert / confirmation dialogs | Native-styled modal dialogs |
| Copied toast (1.6 s) | Same, small toast component |

---

## 6. Server-Side Changes (consolidated)

Stdlib Python only; no new frameworks, no new deps.

| # | Change | Anchor | Size |
|---|---|---|---|
| S1 | `_serve_harness_web_static(path)` + dispatch call in `do_GET` | mirror `cmux_harness/server.py:261-300`; dispatch at `server.py:359-361` | S (~25 lines) |
| S2 | Token auth: `_auth_ok()` helper in `make_handler`; guard at top of `do_GET`/`do_POST`/`do_PATCH`/`do_DELETE` for `/api/*` + `/harness-web/*`; loopback bypass; 401 JSON | `server.py:135` (make_handler), `:327`, `:799`, `:1671`, `:1709` | S-M (~60 lines) |
| S3 | Token load-or-generate at `$LOG_DIR/web-token.txt` + startup log printing `http://<host>:<port>/harness-web/#token=<tok>` | near `dashboard.py:41-56` startup; use `storage.LOG_DIR` (same as `attachments.py`) | S (~20 lines) |
| S4 | (iOS companion, separate PR) send `X-Cmux-Token` from `HarnessAPITransport.swift`; token field in iOS Settings | `cmux-harness-ios/.../Infrastructure/API/HarnessAPITransport.swift`, `HarnessSettingsStore.swift` | S |
| S5 | *(optional, only if Ronnie wants vite dev-server workflow)* CORS + `do_OPTIONS` copying `demo.py:745-777`, origin allowlist — **requires S2** | `server.py:155-166` | S |
| — | Explicitly NOT doing: websockets, Web Push provider, multipart uploads, CORS-by-default | — | — |

---

## 7. Verification & QA Plan

**Per-phase build/run loop (every phase):**
1. `cd frontend/harness-web && npm run build` (outputs to `cmux_harness/static/harness-web/`).
2. `./cmux-dashboard restart` (bash wrapper; logs `/tmp/cmux-dashboard.log`).
3. Open `http://<mac-lan-or-tailscale>:9091/harness-web` on the **laptop** (that is the target device — verification on the Mac alone doesn't count).
4. Run the phase's checklist (in §3 "Verification" bullets) with the **iOS app open side-by-side** on the same server; any mutation made on one client must appear on the other within one poll cycle (≤2 s; ≤500 ms for terminal).

**Global regression checks (Phases 0, 6, 7 minimum):**
- `/harness` (dashboard.html) loads and its 2 s refresh works (loopback and LAN — LAN requires token-free read or dashboard exemption; see Decision #1).
- `/orchestrator-v2` SPA loads, its SSE stream connects.
- `/`, `/orchestrator`, `/workflow-orchestrator` render.
- iOS app full smoke: connect, list, terminal, send key, feed reply (proves S2 didn't break the iOS contract — gated on S4 landing).
- `curl` matrix: no-token → 401; bad token → 401; good token → 200; loopback no-token → 200.

**Load sanity (Phase 2):** with 3 laptop tabs open on different sessions, watch `/tmp/cmux-dashboard.log` and cmux app responsiveness — screen polls serialize on `engine._lock`; confirm no visible stall. If stalls appear, apply the documented mitigation (visibility-aware pause is already in; add per-screen fingerprint short-circuit).

---

## 8. Decisions Needed from Ronnie

Recommended defaults — "yes to all" is a valid answer.

1. **Auth:** adopt `X-Cmux-Token` shared-secret for `/api/*` + `/harness-web/*`, loopback bypassed, plus the small iOS header patch (S4). → **RECOMMENDED: yes.** (Kills the drive-by-POST vector the feasibility doc flags as the one real security regression of a browser client.) Note: LAN access to the *old* dashboards breaks from the laptop unless we also exempt GET-read endpoints or add token support to them — recommend leaving old dashboards Mac-local-only in v1.
2. **Terminal renderer:** ANSI→React `<pre>` renderer (seeded from `orchestrator.js:249-253`) behind a `TerminalView` interface; xterm.js only as a drop-in fallback. → **RECOMMENDED: yes** (matches iOS selectable-text semantics; xterm's stateful buffer fights snapshot polling).
3. **Notifications:** foreground banner from existing polling for v1; Web Push (VAPID/HTTPS) deferred to v2. → **RECOMMENDED: yes.**
4. **Existing dashboards:** leave `/harness`, `/orchestrator`, `/workflow-orchestrator`, `/orchestrator-v2` untouched; no consolidation in this project. → **RECOMMENDED: yes.**
5. **Demo mode:** drop from the web app (no `LocalDemoHarnessStore` port). → **RECOMMENDED: yes** (can be added later as a mock fetch adapter if ever needed).
6. **Dev workflow:** build-and-restart only; no CORS/`do_OPTIONS` (no `vite dev` against the live server). → **RECOMMENDED: yes** (build is ~seconds; avoids the CORS-with-auth complexity).
7. **Settings "server sources":** keep a minimal version (localStorage, informational) or cut entirely since same-origin makes the server implicit? → **RECOMMENDED: keep minimal** (cheap, preserves screen parity).
8. **Component kit:** plain CSS modules + lucide-react, consistent with orchestrator-v2; add zustand for state. → **RECOMMENDED: yes.**

---

## 9. Risks & Mitigations (top 5)

1. **Terminal fidelity/perf** (JS renderer must do justice to 500 ms × 200-line ANSI snapshots). → Same bytes as iOS; memoized line spans; stick-to-bottom scrolling; xterm.js fallback behind a component interface; fingerprint short-circuit if load shows.
2. **Auth lands wrong and either breaks iOS or doesn't protect.** → Land S2+S4 together (or gate only `/harness-web` until S4 ships); `curl` matrix in §7 on every server change; loopback bypass keeps Mac-local dashboards alive.
3. **Scope creep** ("while we're here, orchestrator-v2 features / websocket terminal / Web Push"). → Parity contract frozen at 26 endpoints + iOS screen map (§1); deferred list is explicit; any addition requires re-planning.
4. **Browser tab throttling silently degrades 500 ms polling; multiple tabs hammer the single cmux socket.** → `visibilitychange`-aware pausing + catch-up refresh (built into the Phase 1 scheduler); load sanity check in Phase 2; SSE change-signal as the known v2 upgrade path (`routes/orchestrator_v2.py:464` precedent).
5. **Detector port drift** — the OpenCode prompt formats evolve and the Swift/JS copies diverge. → Port is line-for-line (277 LOC, pure functions); add a shared test fixture: capture real prompt transcripts, run through both detectors, assert identical parse results (vitest in harness-web; the Swift side already treats it as pure logic).
