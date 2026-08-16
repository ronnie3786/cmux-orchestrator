# iOS App Feature & UI Inventory (for Web App Replication)

**Source:** `cmux-harness-ios/cmux-harness-ios` — SwiftUI + TCA (The Composable Architecture), 55 Swift files, ~14,200 LOC.
**Purpose:** complete feature/UI inventory so a team can rebuild every screen and behavior as a web app.

---

## Summary

The iOS app is a **remote control client for a cmux "harness" server** (a Mac running `dashboard.py`, reachable over LAN/Tailscale at `http://<host>:9091/harness`). It talks to a **plain REST JSON API** (`/api/...`) — no websocket, no SSE, no push channel in-app. All live data comes from **HTTP polling**:

- **Global refresh** (status + workspaces + log + notifications + feed + OpenCode integration) every **2 seconds**.
- **Terminal screen text** for the selected session every **500 ms** (last 200 lines).
- **Git status** for the selected session every **10 seconds** (only while the Git tab is showing "Status").

The app is a **single-window, split-view** app: a sidebar list of "sessions" (cmux workspaces, grouped by pane) and a detail pane with 4 tabs (Terminal / Git / Activity / Skills). Everything else is modal sheets (Settings, New Session, File Search, Jira, Diff viewer, Session Details, Voice Recorder) plus a rename alert and a push-notification banner overlay.

The single most important and hardest feature to port is the **agent-interaction layer**: the app parses live terminal text to detect OpenCode permission/question/review prompts (`OpenCodeTerminalInteractionDetector`) and overlays tappable cards that send arrow/enter/escape keys back into the terminal — plus a richer server-provided "feed" of native structured interactions (permission / question / plan) when the OpenCode integration is installed on the server.

State is **one big TCA reducer** (`HarnessFeature`) with ~90 actions, split across 5 reducer files (Connection, NewSession, Session, Git, Tools, Attachments). Local persistence is UserDefaults (server sources, Tailscale host, last selected workspace, per-session input drafts, demo-mode flag).

---

## Navigation & Screen Map

Entry: `cmux_harness_iosApp` → `ContentView` → `HarnessRootView` (`Views/Root/HarnessRootView.swift:10`).

```
HarnessRootView
├── if !isServerConfigured → ServerSetupView          (full-screen, NOT a sheet)
└── if isServerConfigured → NavigationSplitView       (HarnessRootView.swift:16)
    ├── sidebar: WorkspaceListView                    (session list + header + search/filter)
    └── detail:  WorkspaceDetailView  (if selected)   (4 tabs)
    │            or ContentUnavailableView("No Session Selected")
    │
    │   WorkspaceDetailView tabs (DetailTab enum, HarnessUIEnums.swift:56):
    │   ├── .terminal → DetailTerminalLayout          (terminal text + input bar / easy mode / interaction cards)
    │   ├── .git      → GitStatusView                 (segmented: Status | PR Comments)
    │   ├── .activity → ActivityListView              (log entries for this session)
    │   └── .skills   → SkillsListView                (project + user skills)
    │
    ├── sheet: SettingsView            ($store.isShowingSettings)
    ├── sheet: NewSessionView          ($store.isShowingNewSession)
    ├── sheet: FileSearchView          ($store.isShowingFileSearch)
    ├── sheet: JiraTicketsView         ($store.isShowingJiraTickets)
    ├── sheet: DiffSheetView           (store.diffSheet != nil)
    ├── sheet: SessionDetailsSheet     (local @State in WorkspaceDetailView)
    ├── sheet: PhotoLibraryPicker      (local @State in DetailInputBar)
    ├── sheet: VoiceNoteRecorderSheet  (local @State in DetailInputBar, fixed 540pt, non-dismissable)
    ├── alert: "Rename Session"        (store.renameWorkspaceID != nil)
    ├── overlay: PushApprovalBanner    (pushBridge.banner != nil, top of screen)
    └── overlay: SessionCreationProgressOverlay (store.quickSessionCreation != nil, blocks UI)
```

**Navigation notes**
- No tab bar, no push navigation stack. Selection in the sidebar `List(selection:)` drives `selectWorkspace`; `NavigationSplitView` handles collapse on iPhone.
- Selecting a session **resets detail state** (tab → Terminal, clears git/skills/PR/file-search/jira state) and starts 500 ms screen polling.
- Workspaces are **grouped into "sessions"** by `sessionGroupID` (workspace UUID); a session with multiple panes shows a `SessionPaneTabBar` (horizontal pill strip) inside the detail view to switch panes (`selectWorkspacePane`).
- Pull-to-refresh on the session list sends `.refresh`. Pull-to-refresh exists on the Git and Skills tabs too.
- Deep link entry: tapping a push notification (or its in-app banner) → `openPushApproval` → selects the matching workspace.

---

## Per-Screen Inventory

### 1. ServerSetupView (`Views/Root/ServerSetupViews.swift:10`)

**Display:** dark gradient onboarding page. Header "Connect to your Mac." Cards:
1. **Try Local Demo Mode** card — orange gradient card, explains simulated data, "Start Local Demo" button.
2. **Hosted Review Demo** card — hidden (`showsHostedReviewDemo` hardcoded `false`); would show a build-configured demo server URL + "Use Demo Server" button.
3. **Use Server Source** card — Name field + Server URL field ("your-mac.local:9091/harness") + "Save and Connect".
4. **Optional Tailscale** card — MagicDNS host field + "Try Tailscale" (probe) and "Scan LAN" (Bonjour) buttons.
5. Discovery status area — spinner + status message, or green success message, or orange error.
6. **Discovered servers** list — tappable rows (name + URL) after LAN scan.

**Actions:** Start Local Demo · Save and Connect · Try Tailscale (probe `http://host:9091/harness`) · Scan LAN (Bonjour `_cmux-harness._tcp.` 4s) · tap discovered server · text entry.

**Data/refresh:** no polling. Auto-runs `.discoverServer` on appear when no server configured (Tailscale host tried first, then Bonjour).

---

### 2. WorkspaceListView — sidebar (`Views/Workspace/WorkspaceListViews.swift:10`)

**Display (top to bottom):**
1. **HomeHeaderView** — big "cmux" title, subtitle "Manage your terminal sessions", 3 round buttons (Refresh / +New Session / Settings), and a **server source menu** (pill showing active source name; menu lists saved sources with checkmark + "Manage Sources").
2. **DashboardSummaryView** — connection card: colored dot (green connected / orange reconnecting-or-demo / red no socket), title (Connected / Reconnecting / No cmux Socket / Local Demo Mode), "Updated HH:MM" label; **AutoReconnectChip** toggle when disconnected (global auto-approve enable/disable); demo-mode explainer + "Connect Real Server" button.
3. **SessionSearchFilterBar** — search text field + filter menu (All / Needs You / Auto).
4. **Sessions** section header with count.
5. **WorkspaceCardView** per session group: status indicators (star ★, auto-mode ⚡ / ⚡⚡ icons), title + subtitle (cwd / panes), unread-notification badge (blue capsule, 99+ cap), branch chip, directory chip, "N panes" chip, session-state badge ("Session" green / "Needs You" orange), auto-expiration countdown (updates every 30 s), and a **SessionContextMenu** (⋯).
6. Error banner section when `errorMessage` set (dismissable).

**Actions per session card:**
- Tap card → select session (opens detail).
- ⋯ menu → Auto Mode section (Off / Auto / Super Auto radio), Star toggle, Details (detail view only), Rename (opens rename alert), New Session (quick shell session in same directory, with progress overlay + auto-switch).
- Pull-to-refresh → `.refresh`.

**Data:** `status.workspaces` grouped via `WorkspaceSessionGroup.groups`; unread counts from `notifications`; session state ("Needs You") derived from latest log entry whose action contains "human" (`SessionStateModels.swift:47`). Sort: starred first, then alphabetical.

**Refresh:** via global 2 s polling; also `.refreshable`.

---

### 3. WorkspaceDetailView (`Views/Workspace/WorkspaceDetailViews.swift:10`)

**Chrome:** nav bar title = session group display name + star/auto indicators; trailing ⋯ SessionContextMenu (adds "Details" and "Easy Mode" toggle here). Demo mode banner on top (hidden while keyboard focused). `SessionDetailTabBar` (Terminal / Git / Activity / Skills — icon + label + underline) hidden when input focused or Easy Mode on. `SessionPaneTabBar` when the session has multiple panes (pane pills with git-dirty dot and unread badges).

**Actions:** tab switch · pane switch · ⋯ menu (auto mode / easy mode / star / details / rename / new session) · Session Details sheet shows metadata card (worktree, branch, directory, state badge, session cost colored by amount, auto-expiration).

---

### 4. Terminal tab — DetailTerminalLayout (`WorkspaceDetailViews.swift:137`)

The core screen. Vertical stack:

1. **TerminalScrollView** (`Views/Shared/TerminalScrollView.swift:10`) — scrollable, selectable terminal text rendered from ANSI-escaped raw text via `TerminalTextStyler` (full ANSI parser + semantic highlighter, 1,400 LOC — colors, bold/italic/underline, interaction-option highlighting). Auto-scrolls to bottom on new text (with 50/150/300 ms retry nudges). Tap terminal → dismiss keyboard. Shows "(no terminal data yet)" when empty.
2. **FeedInteractionCard** (if a server feed item matches this workspace and `supportsNativeReply`) — see screen 5.
3. **OpenCodeTerminalFallbackCard** (else, if the detector parses an OpenCode prompt from terminal text) — see screen 6.
4. **Input area** (only when no interaction card is active):
   - **EasyModeKeyboard** (when enabled) — 2 rows × 4 big buttons (Up/Down/Tab/Enter, Left/Right/Esc/Bkspc), ~25% of screen height.
   - **DetailInputBar** (default) — see screen 7.

**Data/refresh:** terminal text from `/api/screen?index&lines=200` polled every **500 ms** while selected; feed items come with the 2 s global refresh.

---

### 5. FeedInteractionCard (`Views/Workspace/FeedInteractionCard.swift:4`)

Native structured reply UI for server-provided feed items (OpenCode events bridged through the cmux integration). Header = title + "OpenCode · Awaiting response" + busy spinner while submitting. Four kinds:

- **permission** — detail text + monospaced pattern list (scoped by permissionType: bash/edit/external_directory) + buttons **Allow once / Always / Reject** → `POST /api/feed/reply {action: approve|deny, mode: once|always|deny}`.
- **question** — multi-step wizard: "Question N of M", option rows (single-select `OpenCodeChoiceRow`), "Or type a custom answer" field, Back/Next, final **Review answers** screen listing all chosen answers, Submit → `reply(action: "answer", selections: [...])`.
- **plan** — detail + **Approve plan / Keep manual / Reject** (modes `autoAccept` / `manual` / `deny`).
- **default/generic** — detail + terminal-navigation buttons (Previous/Next/Confirm/Dismiss that send arrow/enter/esc keys).

Feed items with multi-select questions are NOT natively supported (`supportsNativeReply == false`) — the app falls back to the terminal card and shows an orange fallback note. On reply success the item is removed locally and a refresh fires; failure shows the error banner. Duplicate submissions blocked via `pendingFeedReplyIDs`.

---

### 6. OpenCodeTerminalFallbackCard (`Views/Workspace/OpenCodeTerminalFallbackCard.swift:4`)

Screen-scraped interaction UI when there is no native feed item. `OpenCodeTerminalInteractionDetector.detect` (`Views/Shared/OpenCodeTerminalInteractionDetector.swift:4`) parses the last 48 lines of plain terminal text and recognizes three prompt shapes:

- **permission** ("Permission required" + Allow once/Allow always/Reject + footer hints) → detail + choices list + manual key buttons Previous/Next (horizontal arrows) / Confirm / Reject.
- **question** (numbered option list + "select/enter/dismiss" footer) → tappable option list; "Next" sends a **computed key sequence** `[down, up, down×selectedIndex, enter]` to move OpenCode's cursor to the chosen row and advance (`submitSelectedOption`, FallbackCard ~line 320). Dismiss sends Escape.
- **questionReview** ("Review/Submit/Dismiss" screen) → read-only list of parsed answer label/value pairs + buttons Edit answers (Tab) / Submit (Enter) / Dismiss (Esc).

Also embeds the **integration upsell**: if the server reports `cmuxAvailable && !installed` show "Enable native controls" button (`POST /api/integrations/opencode`); if installed show "restart OpenCode" hint.

---

### 7. DetailInputBar (`Views/Input/DetailInputBar.swift:30`)

**Display:** expandable action row + multiline TextField (1–6 lines) + circular Send button + quick-key row.

**Actions:**
- **Chevron** toggles expanded action menu: **paperclip** (confirmation dialog → Photo Library via PHPicker, or Files via `fileImporter`, multi-select) · **mic** (Voice Note sheet) · **@** (File Search sheet) · **ticket** (Jira sheet).
- **Quick-key buttons**: row 1 (Up/Down/Tab/Enter) always visible; row 2 (Left/Right/Esc/Bkspc) only when menu expanded. Each sends `POST /api/send {key}`.
- **Skill autocomplete**: typing `/` or `$` at a token start pops `SkillAutocompletePanel` (max 3 filtered suggestions from loaded skills, Cancel button, tap replaces token and refocuses). Lazy-loads skills on first trigger.
- **AttachmentTray** above the field: chips per attachment with filename, status (Uploading spinner / Added / error + retry ↻ / remove ✕).
- **Send** (disabled unless draft non-empty or an uploaded attachment exists; blocked while uploads in flight with error "Wait for attachment uploads to finish"). Send concatenates uploaded attachment server paths + message, space-joined, appends "\n", posts to `/api/send {text}`. Clears draft + attachments.
- **Focus management**: `detailInputFocusRequest` counter forces focus + cursor-to-end after inserting content from other screens (skills/files/Jira/PR comments/diff comments all jump back to Terminal tab and focus the field).
- Haptics on every CTA (light impact) and Send (medium impact) — `HarnessHaptics`.

**Drafts persist per workspace** in UserDefaults (`HarnessSettingsStore.detailDrafts`), restored on session select, trimmed when sessions disappear.

---

### 8. EasyModeKeyboard (`Views/Input/EasyModeKeyboard.swift:4`)

Full-width 2×4 grid of large key buttons (same 8 HarnessKeys) replacing the input bar. Toggled from detail ⋯ menu. Forces Terminal tab; hides tab bar. Meant for one-handed "drive the agent" use.

---

### 9. GitStatusView — Git tab (`Views/Git/GitViews.swift:10`)

Segmented picker **Status | PR Comments**; pull-to-refresh both.

**Status segment:**
- Repository section (branch, path).
- "Clean" empty state.
- **Staged** section: `GitFileRow` (status letter + monospaced path + diff magnifier button). Swipe actions: Diff (blue) + Unstage (orange). Context menu: same.
- **Unstaged** section (unstaged files + untracked "?"): swipe/context = Diff + Stage (green).
- **Recent Commits** section: message + short hash rows.
- Loading spinner / ErrorBanner (retry) / "No Git Data" states.

**PR Comments segment** (`GitPRCommentsSections`):
- "Show resolved" toggle (footer shows "N resolved threads hidden"); toggling reloads.
- Pull Request section: `#number title`, `owner/name`, "Open PR" (external browser).
- Per-file sections of `GitPRThreadRow`: line label pill (Line N / Lines N–M / File), Resolved/Outdated pills, inline **code context** block (monospaced lines with target line highlighted), comment bubbles (author, createdAt, selectable body). Row actions: **insert into prompt** (green ⊕ — appends formatted thread to input draft, jumps to Terminal), **copy** (pasteboard), **open link**, and big **"Request fix"** button — sends the formatted thread straight to the agent as a message (no editing), returns to Terminal tab.
- Empty states: "No PR Comments" / "Only Resolved Threads".

**Refresh:** git status polled every 10 s only while Git tab + Status segment visible; PR comments load on demand (no polling).

---

### 10. DiffSheetView (`Views/Git/DiffViews.swift:8`)

Modal sheet showing a unified diff for one file+section. Instruction note ("Tap a line of code to add a comment or instruction to send."). Client-side **unified diff parser** (`parseUnifiedDiffLines`) producing metadata/hunk/context/addition/deletion rows with old/new line-number gutters and green/red backgrounds; hunks blue. Tapping a commentable line opens **DiffLineCommentSheet** (460pt detent): line preview + TextEditor + "Insert Comment" → appends a formatted block (`Please address this review comment: File/Line/Code/Comment`) to the terminal input draft, switches to Terminal tab, focuses input. Loading spinner / error / Done button.

---

### 11. ActivityListView — Activity tab (`Views/Tools/ActivitySkillsFileSearchViews.swift:10`)

Simple list of `LogEntry` rows for the selected session: action (bold) + formatted timestamp, promptType, reason. Empty state "No Activity". Data comes free with the 2 s global refresh (filtered by workspace index).

---

### 12. SkillsListView — Skills tab (`ActivitySkillsFileSearchViews.swift:33`)

Sections **Project Skills** / **User Skills**; each `SkillMenuRow` shows name + monospaced file path and opens a menu with three insert actions:
- **Claude Code** — appends `/skillname` to draft
- **Codex CLI** — appends `$skillname`
- **File Path** — appends `` `path` ``

All three switch to Terminal tab + focus input. Pull-to-refresh, loading/error/empty states. Loaded on tab entry and lazily for autocomplete.

---

### 13. FileSearchView — sheet (`ActivitySkillsFileSearchViews.swift:104`)

Modal "Files" sheet: monospaced search field (autofocused), results list (tap → append `` `path` `` to draft, focus input, close). Requires ≥3 chars; debounced-ish via TCA cancellation (re-issue on each keystroke, `fileSearchCancelID`). Endpoint `GET /api/file-search?index&q`.

---

### 14. JiraTicketsView — sheet (`Views/Tools/JiraTicketsView.swift:10`)

Modal "Jira" sheet:
- **Exact Lookup** section: field for Jira key or browse URL + search button (spinner while resolving) → result row.
- **Assigned** sections grouped by project key, sorted: rows show key (tap → copy to pasteboard + "Copied KEY" toast, 1.6 s), title, status & priority pills; per-row **open link** (external) and **insert** (`text.badge.plus`) → appends a formatted block (Jira: KEY / Title / URL / Status / Priority / Type / "Please use this ticket as context.") to the input draft and returns to Terminal.
- Toolbar: refresh (loads `GET /api/jira/assigned?limit=50`) + Done. Auto-loads on appear if empty.

---

### 15. SettingsView — sheet (`Views/Root/SettingsNewSessionViews.swift:10`)

Form sheet:
- Demo Mode section (when active): explainer + "Connect Real Server".
- **Active Source**: menu to switch saved sources + URL (selectable text).
- **Source Details / New Source**: name + URL fields, Save/Add Source, "Add Another Source".
- **Saved Sources** list: tap to switch (green checkmark), ⋯ menu = Use / Edit / Delete.
- Toolbar Cancel / Save (disabled when URL empty).

Deleting the active source auto-switches to the next, or clears config → re-runs discovery → ServerSetup screen.

---

### 16. NewSessionView — sheet (`SettingsNewSessionViews.swift:118`)

Form sheet:
- **Mode** segmented picker: Claude | Shell.
- Project path field (always; defaults `~/Documents/Development/sample-app`).
- Shell mode: Name field (default "Shell").
- Claude mode: **Worktree** section (JIRA URL field — typing auto-extracts `ABC-123` into the Branch field if branch empty; Branch field) + **Prompt** section (multiline initial prompt).
- Error section; toolbar Cancel / Create (shows "Creating" while in flight).

Creates via `POST /api/new-session` (command = `claude` or `zsh`). On success: closes sheet, waits 750 ms, refreshes; for quick-create-from-workspace also shows `SessionCreationProgressOverlay` (two phases: creating → switching) and auto-selects the new session once it appears.

---

### 17. VoiceNoteRecorderSheet (`Views/Input/VoiceNoteRecorder.swift:324`)

540pt non-dismissable sheet: big 96pt mic/stop record button, live waveform (44 level samples), monospaced duration counter, status text (10-minute limit), playback preview (play/pause + progress), error line, Discard (with confirmation dialog) / Save buttons. Records `.m4a` (AAC high quality) to a temp file; Save hands the URL to the attachment pipeline. Uses `AVAudioApplication.requestRecordPermission`, `AVAudioSession` record/playback categories.

---

### 18. PhotoLibraryPicker (`Views/Input/PhotoLibraryPicker.swift:33`)

`PHPickerViewController` wrapper: images only, max 10, exports selected items to temp URLs, reports failures/oversize (>20 MB) counts as a warning message that lands in the error banner.

---

### 19. PushApprovalBanner (overlay, `ServerSetupViews.swift:~400`)

Top-of-screen floating card when an `approval_required` push arrives while app is foregrounded: orange warning icon, workspace name, request/reason text, tap → open that session (and clear badge + server-side approval via `/api/push/clear`), ✕ dismiss.

---

### 20. Supporting components (Shared)

- `SessionBadge` (green "Session" / orange "Needs You"), `ConnectionDot`, `AutoExpirationText` (30 s TimelineView countdown), `ErrorBanner` (message + retry/dismiss), `StatPill`, `formatTimestamp`, path abbreviation helpers, diff colors (`Views/Shared/SharedViewSupport.swift`).
- `OpenCodeActionButton` (primary/secondary/destructive/neutral/attention roles), `OpenCodeChoiceRow` (selectable option row), `OpenCodeInteractionHeader`, `openCodeInteractionCardChrome()` modifier — shared card styling for both interaction cards.
- `TerminalTextStyler` (1,402 lines): ANSI parser + semantic highlighter + palette; also produces `plainText` used by the interaction detector.

---

## Refresh & Connection Model

**All HTTP/JSON REST polling. No websocket/SSE.** Base URL: user-configured, e.g. `http://mac.local:9091/harness` or `http://<tailscale-host>:9091/harness`. 15 s request timeout (60 s for attachment uploads).

| Loop | Interval | Scope | Endpoint(s) | Started/cancelled |
|---|---|---|---|---|
| Global refresh | **2 s** | app-wide | `/api/status` + `/api/log` + `/api/notifications` + `/api/feed` + `/api/integrations/opencode` (parallel `async let`) | onAppear while configured; cancelled onDisappear / server switch |
| Screen text | **500 ms** | selected session | `/api/screen?index&lines=200` | while a workspace is selected |
| Git status | **10 s** | selected session | `/api/git-status?index` | only on Git tab + Status segment |

On-demand: diff, PR comments (with `includeResolved`), skills, file search (≥3 chars), Jira assigned/lookup, stage/unstage, send text/key, feed reply, new session, rename, star, auto-mode, toggles, attachment upload, push register/clear, mark-notifications-read.

**Failure handling:** any request failure sets `errorMessage` → dismissable ErrorBanner in sidebar (some screens have their own scoped error + retry). Connection state derived from `status.connected`/`socketFound`: Connected / Reconnecting (socket exists but poll failing) / No cmux Socket — shown as colored dot + title, with an **AutoReconnectChip** toggle (global enable/disable, `POST /api/toggle`). Stale-selection handling: if the selected workspace vanishes from status, detail state resets and polling stops. Marking notifications read is optimistic locally + confirmed server-side. Selecting a session also clears the server-side push approval for it.

**Demo mode:** `cmux-demo://local/harness` URL routes every client call to an in-memory `LocalDemoHarnessStore` actor inside `HarnessClient.swift` (seeded workspaces, screens, log, Jira, feed; ~800 LOC) — the web app could replicate this as a mock adapter or drop it.

---

## iOS-Only Capabilities (web-translation risk)

| Capability | What it does | Used by | Web translation risk |
|---|---|---|---|
| **APNs push notifications** (`App/PushNotificationBridge.swift`) | Registers device token with server (`/api/push/register`, sandbox in DEBUG), receives `approval_required` pushes, shows in-app banner when foregrounded, deep-links to session on tap, clears badge | Root overlay + session selection | **HIGH** — web needs Web Push (service worker + VAPID) or in-app polling/SSE; server API currently expects APNs tokens. Foreground banner can be replicated; background push needs new server support. |
| **Bonjour LAN discovery** (`Infrastructure/Discovery/HarnessServerDiscovery.swift`) | `NetServiceBrowser` for `_cmux-harness._tcp.` 4 s scan | ServerSetup | **HIGH** — impossible in browser. Replace with manual URL entry / server-provided directory / well-known hostname. |
| **Tailscale host probing** | Builds `http://host:9091/harness` and probes `/api/status` | ServerSetup | **MEDIUM** — browser fetch works if CORS allows; mixed-content (https page → http host) will be blocked. Server needs HTTPS or the web app must be served from the harness itself. |
| **PHPicker photo library** (`Views/Input/PhotoLibraryPicker.swift`) | Image picker, ≤10, 20 MB cap | Input bar | **LOW** — `<input type="file" accept="image/*" multiple>`. |
| **File importer** (`fileImporter`, any UTI, multi) | Attach arbitrary files | Input bar | **LOW** — same file input. |
| **Voice note recording** (`Views/Input/VoiceNoteRecorder.swift`) | AVAudioRecorder m4a, waveform, 10 min cap, playback preview, permission flow | Input bar | **MEDIUM** — MediaRecorder API (webm/opus not m4a in most browsers), waveform via WebAudio analyser; server must accept the content type. |
| **Attachment upload** (`/api/attachments`, raw body + `X-Cmux-*` headers, 20 MB cap) | Upload then inline server path into next message | Input bar | **LOW** — fetch with same headers; note security-scoped URL dance is iOS-only. |
| **UserDefaults persistence** (`Infrastructure/Persistence/HarnessSettingsStore.swift`) | Server sources, selected source, Tailscale host, last session, per-session drafts, demo flag | everywhere | **LOW** — localStorage/IndexedDB. Multi-device sync is a product decision. |
| **Haptics** (`HarnessHaptics` in DetailInputBar.swift:11) | Light/medium impact on CTAs and keys | input, cards, recorder | **LOW/none** — no web equivalent; drop or use vibration API (Android only). |
| **Deep links via push payload** | `pendingDeepLink` → open session | Root | **MEDIUM** — web equivalent: URL routing (`/sessions/:id`) + notification click URL. |
| **NavigationSplitView / sheets / swipe actions / context menus / pull-to-refresh** | iOS interaction idioms | all screens | **MEDIUM** — need explicit web UX mapping (responsive sidebar, dialogs, hover menus, refresh buttons). |
| **Dynamic Type / accessibility adaptations** | `isAccessibilitySize` switches card buttons to vertical stacks | interaction cards | **LOW** — responsive CSS. |
| **Local Demo Mode** (in-memory `LocalDemoHarnessStore`) | Simulated server | ServerSetup, banner | **LOW** — optional mock layer. |
| **Terminal text is screen-scraped** (ANSI text, 200 lines, 500 ms) | Renders terminal + drives interaction detector | Terminal tab | **HIGH (architectural)** — the web app inherits the same contract unless the server adds a structured/streaming terminal channel (websocket + xterm.js is the obvious upgrade; detector logic must be ported to JS or replaced by server-side feed events). |

---

## Key Code Paths

- App entry: `App/cmux_harness_iosApp.swift:11` · root: `App/ContentView.swift` · `Views/Root/HarnessRootView.swift:10` (split view at :16)
- Root reducer/state (all app state, ~90 actions): `Feature/HarnessFeature.swift:21`
- Reducer slices: `Feature/Reducers/HarnessFeatureConnectionReducer.swift` (refresh, server sources, demo, discovery, feed replies, notifications) · `HarnessFeatureSessionReducer.swift` (selection, screen polling, send text/keys, auto mode, star, rename) · `HarnessFeatureNewSessionReducer.swift` · `HarnessFeatureGitReducer.swift` (git poll, diff, PR comments, request-fix) · `HarnessFeatureToolsReducer.swift` (skills, file search, Jira) · `HarnessFeatureAttachmentsReducer.swift`
- Polling loops: `Feature/Support/HarnessFeatureEffects.swift:10` (2 s refresh), :57 (500 ms screen), :68 (10 s git)
- Prompt-formatting helpers (Jira/PR/diff blocks): `Feature/Support/HarnessFeatureHelpers.swift` (`formatJiraTicketPrompt`, `formatPRCommentThreadPrompt`, `formatDiffLineReviewPrompt`, `appendPromptToken/Block`)
- REST surface (all endpoints): `Infrastructure/API/HarnessAPI.swift` · transport/timeout/error envelope handling: `Infrastructure/API/HarnessAPITransport.swift` · TCA client + demo store: `Infrastructure/API/HarnessClient.swift`
- Discovery: `Infrastructure/Discovery/HarnessServerDiscovery.swift` · persistence: `Infrastructure/Persistence/HarnessSettingsStore.swift`
- Push: `App/PushNotificationBridge.swift` (+ `Models/NotificationModels.swift`)
- Session grouping/state derivation: `Models/WorkspaceModels.swift` (`Workspace`, `WorkspaceSessionGroup`, `WorkspaceAutoMode`) · `Models/SessionStateModels.swift` ("Needs You" = latest log action contains "human")
- Feed/interactions: `Models/HarnessResponseModels.swift` (`FeedItem`) · `Models/OpenCodeTerminalInteraction.swift` · detector: `Views/Shared/OpenCodeTerminalInteractionDetector.swift:4` · cards: `Views/Workspace/FeedInteractionCard.swift:4`, `Views/Workspace/OpenCodeTerminalFallbackCard.swift:4` (key-sequence submission ~:320)
- Terminal rendering: `Views/Shared/TerminalScrollView.swift:10` · `Views/Shared/TerminalTextStyler.swift` (ANSI parse + highlight)
- Input stack: `Views/Input/DetailInputBar.swift:30` · `EasyModeKeyboard.swift` · `SkillAutocompleteViews.swift:9` · `AttachmentViews.swift` · `PhotoLibraryPicker.swift:33` · `VoiceNoteRecorder.swift:16`/:324
- Git: `Views/Git/GitViews.swift:10` · `Views/Git/DiffViews.swift:8` (diff parser :264)
- Tools: `Views/Tools/ActivitySkillsFileSearchViews.swift` · `Views/Tools/JiraTicketsView.swift:10`
- Setup/settings/new session: `Views/Root/ServerSetupViews.swift:10` · `Views/Root/SettingsNewSessionViews.swift:10`/:118
- UI enums (keys, tabs, segments, filters): `Models/HarnessUIEnums.swift`
