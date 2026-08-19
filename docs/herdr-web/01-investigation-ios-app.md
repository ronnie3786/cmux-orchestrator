# 01 — Herdr iOS App Feature & UI Inventory (for Web App Replication)

**Investigator:** planner subagent (local qwen3.8-27b), read-only. Orchestrator spot-verified
file:line refs, dead-code claims, and file counts on 2026-08-18 (all checks passed).
**Source:** `cmux-herdr-harness` worktree @ `78a6548` (branch `codex/herdr-harness`) →
`herdr-harness-ios/` — Swift 6, SwiftUI, `@Observable` (Observation framework), structured
concurrency, **zero third-party dependencies**. 180 Swift files total; 160 excl. tests,
~15,900 LOC; 20 test files.
**Companion spec:** `HERDR_HARNESS.md` at worktree root (product spec, read in full).
**Path convention:** unless prefixed, Swift paths are relative to
`herdr-harness-ios/herdr-harness-ios/` (the Xcode project nests the app folder).
Python paths are worktree-root relative.
**Worktree hygiene note:** uncommitted changes exist in `herdr_harness/client.py`,
`herdr_harness/service.py`, `project.pbxproj`, `xcscheme` (a protocol-<19 subscription
compat shim in `client.py` — see doc 02). Noted only — untouched.

---

## 1. What the product is meant to be (from `HERDR_HARNESS.md`)

Herdr Harness is the **Herdr-native companion** to the cmux harness. It keeps Herdr's own
**workspace / tab / pane / layout / agent** model intact (backend speaks newline-delimited
JSON over Herdr's Unix socket — **not tmux** — agent messages via `agent.prompt`, shell via
`pane.send_input`, keys via `pane.send_keys`) and exposes it to a polished SwiftUI app over
**authenticated HTTPS + Server-Sent Events** (port 9092, Tailscale Serve as the remote
boundary).

The deliberate navigation path is: **attention-aware workspace deck → workspace topology and
pane list → live terminal and agent session**. The home screen answers *"where do I need to
look?"* before navigation: blocked agents and unseen completions rank above active/idle.
**iPhone = typed stack navigation; iPad = balanced three-column split.**

Four capabilities beyond the cmux version:
1. **Attention Deck** — transition-aware blocked/done alerts, ranked panes, unread state, deep navigation, optional APNs.
2. **Pane Topology Radar** — compact spatial preview from Herdr's real layout rectangles/split geometry.
3. **Command Lens** — status-aware prompt suggestions, agent-aware composer, Esc/arrow/Tab/Ctrl-C key deck.
4. **Native Pi Chat** — a semantic projection of a live Pi session (message turns, collapsed thinking, structured tool cards, streaming status, prompt/steer/follow-up/stop). The stock Pi TUI keeps running in the same pane and remains available as a sibling **Terminal** view, fed by the optional `pi-semantic-bridge` Pi extension (pane-scoped Unix socket; never replaces the TUI).

Terminal contract: the selected pane consumes **base64 ANSI full + delta frames** over SSE
directly; a **bounded Swift terminal grid** applies cursor movement/erasure/dimensions/colors
without a second HTTP request per frame; on observer loss it **keeps the last good frame**,
falls back to the low-cost text snapshot, and auto-reconnects.

Git status/diff, Skills, project file search, Jira, and attachments **reuse the cmux harness
API** — the app never opens cmux's plain-HTTP port; every request goes through the
authenticated Herdr HTTPS API which resolves the checkout and proxies to cmux (server-side
`HERDR_HARNESS_CMUX_URL`, default `http://127.0.0.1:9091`).

Security posture (spec): long bearer token; Tailscale Serve recommended; token in Keychain;
APNs inert until `.p8` credentials set; alert journal + APNs tokens mode `0600`; terminal
observation read-only (input only via explicit action routes); observers concurrency-limited
and periodically renewed; Pi semantic sockets mode `0700`/`0600`; Pi system
prompts/provider internals never copied into the semantic stream. Fixtures:
`scripts/setup_herdr_demo.py` builds a 3-workspace × 3-pane topology in isolated session
`herdr-ios-fixtures`.

---

## 2. App architecture & state (contrast with Phase 1)

- Entry: `App/HerdrHarnessApp.swift:1-18` → `@State model = HerdrAppModel()`,
  `@State herdPulse = HerdPulseCoordinator()`; `.preferredColorScheme(.dark)`,
  `.tint(HerdrTheme.accent)`.
- **No TCA.** State is one `@MainActor @Observable` `HerdrAppModel`
  (`State/HerdrAppModel.swift`, ~700 lines) + a per-pane `PiConversationStore` +
  `HerdPulseCoordinator` (ActivityKit). Phase 1's TCA reducer/store mapping in the web app
  does not carry over one-to-one; the *topology* (one app model, one pane-conversation
  store, one pulse coordinator) does.
- `HerdrAppModel` key state (`State/HerdrAppModel.swift:8-40`): `workspaces`, `alerts`,
  `connectionState` (`.disconnected/.connecting/.live/.demo/.failed`,
  `Models/ConnectionState.swift`), `selectedTab: AppTab` (`.workspaces/.attention/.settings`,
  `Models/AppTab.swift`), `selectedWorkspaceID`, `selectedPaneID`,
  `workspacePath: [WorkspaceRoute]` (typed nav stack: `.workspace(id)` / `.pane(id)`,
  `Models/WorkspaceRoute.swift`), `isSidebarPresented`, `collapsedSidebarWorkspaceIDs`
  (persisted), `searchText`, `filter: WorkspaceFilter` (`.all/.attention/.active` with labels
  `All`/`Needs you`/`Active`, `Models/WorkspaceFilter.swift`), `errorMessage`→alert,
  `toastMessage`, `lastUpdated`, `isRefreshing`, `isSending`, `connectionGeneration` (epoch
  token for stale-task protection), `serverURLString`/`apiToken`, `isDemoMode`,
  `hasCompletedSetup`, `smartAlertsEnabled`, `preferPrivateTranscription`, push status fields.
- Derived: `visibleWorkspaces` (filter+search, sorted by `number`); **`attentionPanes`** =
  all panes where `agentStatus.needsAttention`, sorted by `attentionRank` (blocked 0, done 1,
  working 2, idle 3, unknown 4 — `Models/AgentStatus.swift:66-74`) then `revision` desc;
  `unreadAlertCount`; `workingCount`; `paneCount`;
  **`canControl = isDemoMode || connectionState == .live`** (gates every mutation UI).
- Persistence: `UserDefaults` keys `herdr.serverURL`, `herdr.demoMode`,
  `herdr.completedSetup`, `herdr.smartAlerts`, `herdr.preferPrivateTranscription`,
  `herdr.sidebar.collapsedWorkspaces`, `herdr.herdPulse.enabled`; token in **Keychain**
  (`Infrastructure/KeychainStore.swift`, service `dev.ronnierocha.herdr-harness`, account
  `api-token`).
- `runConnection()` loop (`State/HerdrAppModel.swift:150-195`): connect → sync push device →
  `refresh()` (GET workspaces) → consume `/api/v1/events` SSE; on `snapshot.updated` or
  Pi-capability events (`pi.bridge.connection`, `pi.session_start`, `pi.session_shutdown`,
  `pi.session_info_changed`, `pi.session_tree` — `State/HerdrAppModel.swift:655-661`)
  re-refresh with spinner hidden; on `push.delivery` event verify APNs or fall back to local
  notification; on error back off 2 s → ×2 capped 15 s, `connectionState = .failed` with
  error banner.
- **Navigation repair** on every refresh (`repairNavigation`, `State/HerdrAppModel.swift:663-683`):
  prunes `workspacePath` to valid IDs, reselects first workspace if selection vanished,
  clears stale pane selection, prunes collapsed set. Web app needs the equivalent of this to
  survive workspaces closing under it.
- **Deep navigation**: `openPane(id:)` (`State/HerdrAppModel.swift:388-397`) builds
  `[.workspace, .pane]` path and closes sidebar; pending-pane queue resolved after next
  refresh (for notification taps arriving before data). URL scheme handler `open(url:)`
  accepts `herdr://` with `pane`/`paneId`/`pane_id` query or `herdr://pane/<id>` host form
  (`State/HerdrAppModel.swift:408-421`). Foreground notification taps and launch-queued
  tokens flow through `App/HerdrAppDelegate.swift` (`.herdrOpenPane`, `.herdrPushToken`
  notifications).
- Toast system: single top-of-screen `ToastView` (auto-dismiss 2.2 s,
  `Views/Shared/ToastView.swift`); errors surface as a full-screen `.alert("Connection
  issue")` with Dismiss (`Views/Root/AppRootView.swift:57-62`).
- Demo mode: `useDemo()` / `-HerdrDemoMode` launch arg / `Bundle.main HerdrDemoServerURL`;
  `Models/DemoData.swift` seeds 3 workspaces ("iOS Doximity", "Member API", "Release Train"),
  4 agent panes (Codex/Claude, mixed statuses), 2 alerts, git/skills/jira/file-search data;
  every client method has a demo branch.

---

## 3. Views inventory by cluster

### `Views/Root/`
- **`AppRootView.swift`** — `hasCompletedSetup ? (tabs + SidebarDrawer) : OnboardingView`.
  Three tabs: **Workspaces** (75), **Attention** (79, badge = unread alerts, 82),
  **Settings** (84). Hosts: connection task keyed on `connectionGeneration`, pending-pane
  task, push-token task, smart-alerts prep task, HerdPulse `synchronize` task keyed on
  aggregate context, `.onOpenURL`, toast overlay, error alert.
- **`OnboardingView.swift`** — dark scroll page: brand mark + `herdr` + "Your agents, within
  reach"; promise block "Know where to look." + subtitle; `GlassCard` connection form (URL
  field, **SecureField "Pairing token"**, Connect button, lock.shield footnote about
  localhost/Tailscale + Keychain); "Explore with live-looking demo data" bordered button.

### `Views/Attention/`
- **`AttentionNavigationView.swift`** — own `NavigationStack`; tapping an alert/pane sets
  selection, appends `.pane(id)`, and (for alerts) fires `markAlertRead`.
- **`AttentionView.swift`** — header ("Attention deck" + one-line philosophy),
  **"Recent signals"** section (alert journal, `AlertCardView` per alert; dimmed if pane
  gone), **"Live queue"** section (ranked `AttentionPaneCard`s), empty state "Nothing needs
  you". Pull-to-refresh.
- **`AlertCardView.swift`** — status rail + compact status badge + "NEW" capsule when unread
  + title + message (3 lines) + agent label or "Closed pane · <paneID>" + chevron when
  navigable.
- **`AttentionPaneCard.swift`** — status icon circle, pane title, "workspace · agent" line,
  compact badge.

### `Views/Workspace/`
- **`WorkspaceNavigationView.swift`** — the platform split: `horizontalSizeClass == .regular`
  → **balanced 3-column NavigationSplitView** (list 330/390/460 pt, content 320/390/480 pt,
  detail), else **compact NavigationStack** with `workspacePath` destinations (list →
  `WorkspacePaneListView` → `PaneSessionView`). Empty states: "Choose a workspace" /
  "Choose a pane".
- **`WorkspaceListView.swift`** — header, search, **AttentionStrip** (only when
  `attentionPanes` non-empty), filter bar, "spaces" section label with "n / total" detail,
  "new workspace" button, workspace cards, empty states ("No Herdr workspaces" / search).
  Agent-status **haptic transitions** tracked here via `AgentStatusHapticTracker` (blocked →
  warning haptic, done → success; armed only on foreground refresh,
  `Design/AgentStatusHapticTracker.swift`).
- **`WorkspaceHeader.swift`** — brand ("herdr" / "switch"), "Open navigator" sidebar button,
  **HerdPulse waveform button**, Refresh button; "choose a workspace" line +
  `ConnectionPill`; demo banner "Demo data is active".
- **`WorkspaceSearchField.swift`** — mono field, placeholder "filter spaces", clear button.
- **`AttentionStrip.swift`** — "attention" section label + count, "open queue" button (jumps
  to Attention tab), **top 2** attention panes as compact rows (dot, title, workspace,
  lowercase status).
- **`WorkspaceFilterBar.swift`** — segmented All / Needs you / Active (rawValue lowercased
  rendering, checkmark on selected).
- **`WorkspaceCardView.swift`** — status dot, optional **worktree connector glyph**
  (`├─`/`└─` when multiple linked worktrees share a `repoRoot`,
  `Views/Workspace/WorkspaceListView.swift:141-159`), mono label + "active" when focused +
  lowercase compact status; detail line `branch · N tab(s)` (branch from
  `workspace.tokens["branch"]`, fallback "shell").
- **`WorkspaceHeroView.swift`** — workspace detail header: label, display path, full
  `AgentStatusBadge`, **PaneTopologyView** (height 94), stat row `N tabs / N panes / branch`
  (SwiftUI automatic grammatical inflection).
- **`WorkspacePaneListView.swift`** — hero + per-**tab** sections (`tab.label` + pane count,
  `HerdrTab` from snapshot) each listing `PaneCardView`s (tab-less panes fall back to one
  flat list). Toolbar: sidebar toggle (compact), **"Workspace actions" menu**: Focus on Mac
  / Rename workspace / New tab / Refresh / Close workspace (destructive, confirm dialog
  "All N pane processes in this workspace will stop."). Rename alert: "The new label appears
  in Herdr on every connected client."
- **`PaneCardView.swift`** — status rail, title, compact badge, agent icon (terminal vs cpu
  by status), mono path, `pane.id` + "rev N" footer, chevron; selected = accent border.
- **`PaneTopologyView.swift`** — **Canvas** spatial preview: scales `HerdrLayout.area` to
  canvas, draws each pane rect offset by area origin, rounded 4 pt, highlight = selected
  pane (or focused pane when nothing selected) with accent fill/stroke; empty-state dashed
  box. (See §4.2.)
- **`CreateWorkspaceView.swift`** — medium sheet: Name + "Folder path" fields, info label
  "Herdr opens one shell pane in this folder. Split panes or start an agent after it
  appears.", Cancel/Create.
- **`HerdPulseButton.swift`** — 48 pt waveform button (Start/Stop Herd Pulse) with running
  dot; disabled while busy; hint = coordinator's `backgroundUpdatesText`.
- **`FleetSummaryView.swift`** — ⚠️ defined but **referenced nowhere** (verified: 0 refs) —
  dead code in the app; parity is optional.

### `Views/Pane/` (the largest cluster, 31 files)
- **`PaneSessionView.swift`** — the pane screen: mode switcher state
  (`PaneDetailMode`: **Chat / Terminal / Git / Skills**, `Models/PaneDetailMode.swift`),
  terminal state (output text, `TerminalGrid(100×32)`, `TerminalSource`, frame/snapshot
  sequences, `isFollowing`), Pi `PiConversationStore`, shared composer draft/attachments.
  Chat **auto-select** when pane supports Pi semantic chat and user hasn't chosen Terminal
  (`autoSelectChatIfNeeded`, lines 76-94, 237-244); manual choice of Terminal suppresses
  future auto-select (`modeSelection` binding, lines 118-126). `followOutput` runs snapshot
  + frame-stream + 850 ms poll in a task group (see §4.5).
- **`PaneSessionHeader.swift`** — ⚠️ defined but **referenced nowhere** (verified: 0 refs) —
  dead code; parity optional.
- **`PaneTerminalView.swift`** — toolbar (status dot, **source label** with pulse symbol,
  metadata `W×H · fN` for stream / `rN` for snapshot, Pause/Resume follow, manual refresh) +
  scrollable selectable output (attributed grid text when streaming, mono text when
  snapshot; follow = auto-scroll bottom after 150 ms; horizontal+vertical scroll for wide
  content).
- **`TerminalKeyDeck.swift`** — see §4.3 (key rows + `TerminalPresetKey`).
- **`PromptComposerView.swift`** — see §4.3 (the Command Lens composer).
- **`ComposerAuxiliaryBar.swift`** — expandable utility row: **attach** (paperclip → Photo
  Library / Files confirmation dialog), **voice** (mic: tap = recorder sheet, **long-press
  hold = quick dictate** via `HerdrQuickVoiceCapture`), **@ file** (workspace file search
  sheet), **jira** (ticket picker sheet); `ViewThatFits` collapses titles to icons.
- **`ComposerAttachmentViews.swift`** — horizontal chip tray: icon by extension, name,
  status (`uploading`/`attached`/error text), retry ↻ on failure, remove ✕.
- **`PaneActionsMenu.swift`** — "Pane actions" menu: **View** section (Chat — only when
  `supportsPiSemanticChat`, Terminal, Git, Skills with checkmarks), Focus on Mac,
  **Interrupt** (sends `ctrl+c`), Rename pane, **Split pane** (Split right / Split down,
  ratio 0.5), **Start agent** (only when `agentStatus == .unknown`: Codex / Claude /
  OpenCode), Close pane (confirm: "This stops the process running in <title>."). Rename
  alert message "This label is shared with Herdr on your Mac."
- **Pi chat views (19 files)** — see §4.4: `PiChatView` (composition + haptics on phase
  change), `PiChatTimelineView` (scroll, auto-follow, "Jump to latest", truncation header,
  empty state), `PiConversationTurnView` + `PiTurnActivityRail`, `PiUserMessageView`,
  `PiAssistantMessageView`, `PiThinkingDisclosureView`, `PiToolCardView`,
  `PiConversationNoticeView`, `PiInteractionCardView`, `PiConnectionBanner`,
  `PiContextMeterView`, `PiModelPickerChip`, `PiThinkingLevelChip`,
  `PiPromptComposerStatusBar`, `PiMarkdown*` (custom markdown → SwiftUI: text/headers/
  lists/tables/code blocks), `PiChatMotion`/`PiChatTimelineStructure`/`PiChatTurnStructure`
  (reduce-motion-aware animation structs).
- **Tool views (cmux-proxied):** `WorkspaceGitView.swift` (503 lines: repository header
  branch + "N changed"/"clean" + path, staged/unstaged/untracked sections with per-file
  Stage/Unstage + diff tap, "recent commits" rows, diff sheet with line-colored unified
  diff, loading "Reading workspace Git state…", error "Git unavailable" + Try again, empty
  "No Git data" / "Working tree clean"), `WorkspaceSkillsView.swift` (project/user skill
  sections, per-skill menu **Claude Code → `/name`**, **Codex CLI → `$name`**,
  **Skill file path → `` `path` ``**, insert appends to composer + focuses + switches to
  Terminal), `WorkspaceFileSearchSheet.swift` ("WORKSPACE FILES" title, MATCHES count, tap
  inserts `` `path` ``), `JiraTicketPickerSheet.swift` ("JIRA CONTEXT" title, "EXACT
  LOOKUP" field "Paste a ticket key or browse URL from any project.", assigned tickets
  grouped by project, per-row open/insert; insert block `Jira: KEY · Title` /
  `Status: … · Priority: …` / URL).
- **Voice:** `HerdrVoiceRecorder.swift` (AVAudioRecorder → converts to **16 kHz mono 16-bit
  PCM WAV**, `Models/VoiceTranscription.swift:39-45`, 20 MB / 10 min caps),
  `HerdrVoiceNoteRecorderSheet.swift` ("VOICE NOTE" sheet: RECORD/STOP, waveform, PREVIEW,
  "Transcribe" vs attach-raw, discard confirm "The temporary recording will be deleted."),
  `HerdrQuickVoiceCapture.swift` (hold-to-dictate: too short → "Hold the mic to dictate").

### `Views/Sidebar/`
- **`SidebarDrawer.swift`** — overlay drawer (≤340 pt or 86 % width), dimmed backdrop,
  drag-to-dismiss, resigns first responder on open.
- **`HerdrSidebarView.swift`** — the "chats" navigator: brand + close, search ("filter
  chats"), "new workspace", "chats" section with "N total shown", `SidebarTree` rows;
  per-workspace context menu (Open workspace / Focus on Mac / Rename workspace / New tab /
  Close workspace); per-pane context menu (Focus on Mac / **Interrupt** / Rename pane /
  Split pane → right/down / **Start agent** Codex|Claude|OpenCode when shell / Close pane);
  empty: "no panes yet" under a workspace, "No Herdr workspaces" overall.
- **`SidebarRowViews.swift`** — `SidebarProjectRow` (chevron, dot, label, "active",
  attention count capsule), `SidebarSectionRow` (tab label + pane count), `SidebarChatRow`
  (dot, title, lowercase status, selected bar).
- **`Models/SidebarTree.swift`** — builds workspace → tab sections → chats + `looseChats`
  (panes whose `tabID` matches no tab); query filters workspaces by label/path, tabs by
  label, chats by display title; collapsed set honored only when unfiltered.

### `Views/Settings/`
- **`SettingsView.swift`** — Form: **Connection** (Server pill, Workspaces count, Live
  panes, Last update; Server URL + SecureField token + "Save and reconnect"; demo toggle
  buttons "Connect a real server"/"Use demo data"; footer about Tailscale + Keychain),
  **Voice to prompt** ("Prefer Private Parakeet" toggle, Fallback "Apple Speech", privacy
  footer), **Attention** ("Smart agent alerts" toggle, Delivery status line, "Test this
  iPhone locally", footer explaining transition-only alerts), **Private by design** (three
  lock labels), About ("Herdr", "Remote command deck · 0.1").

### `Views/Shared/`
`GlassCard`, `HerdrBackground` (dark gradient), `HerdrBrandMark` (custom shape),
`HerdrStatusDot` (colored dot, working = pulse), `AgentStatusBadge` (capsule,
full/compact), `ConnectionPill`, `HerdrSectionLabel` (underlined mono label + detail),
`StatusRail` (4 pt glowing capsule, animated for working), `ToastView`.
**`Design/HerdrTheme.swift`** — Catppuccin Mocha palette (`ink`, `graphite`, `elevated`,
`surface`, `mist`, `muted`, `text`, `accent` blue, `mauve`, `signal` teal, `success` green,
`working` yellow, `alert` red, `warning` orange) + radii/paddings. The web app should adopt
this exact palette for parity.

### `HerdPulseWidgets/` + `HerdrPulseShared/`
Separate widget extension target: `HerdPulseLiveActivity` (Dynamic Island + lock screen),
`HerdPulseLockScreenView`, `HerdPulseStatusRail`, `HerdPulseTheme`; shared
`HerdPulseAttributes` with **aggregate-only** `ContentState` (counts + connection + phase +
updatedAt — no names/paths/prompts, privacy rule from the spec).

---

## 4. Signature features — behavior, files, state, transitions

### 4.1 Attention Deck
- **Data:** alerts arrive inside `GET /api/v1/workspaces`
  (`WorkspacesResponse.alerts`, `Models/APIResponses.swift:3-25`; tolerant decoding of
  snake/camel + `is_read`/`isRead`/`read` + `status`/`kind`, `Models/HerdrAlert.swift`).
  `HerdrAlert` = id, workspaceID, paneID, status, title (fallback `status.title`), message,
  createdAt, isRead.
- **Journal UI:** AttentionView "Recent signals" (all alerts, tap → pane + mark read);
  mark-read is `POST /api/v1/alerts/{id}/read` then silent refresh
  (`State/HerdrAppModel.swift:466-492`; demo branch mutates locally).
- **Ranking:** `attentionPanes` = panes with `needsAttention` (blocked || done), sorted by
  `attentionRank` then `revision` desc (`State/HerdrAppModel.swift:110-118`,
  `Models/AgentStatus.swift:66-74`). Same ranking drives `Workspace.sortedPanes`
  (`Models/HerdrWorkspace.swift:27-33`) and the `attentionCount` badges (sidebar capsule,
  workspace card).
- **Ambient:** `AttentionStrip` (top 2) in the list; unread count = tab badge;
  **local notifications** for new unread alerts each refresh (time-sensitive interruption
  for blocked, `Infrastructure/NotificationManager.swift:18-31`); badge = unread count
  (`State/HerdrAppModel.swift:545`).
- **Deep navigation:** alert tap → `selectPane(pane, alert)` → stack append + `markAlertRead`
  (`Views/Attention/AttentionNavigationView.swift:8-15`); notification tap / APNs
  `push.delivery` → `openPane(id:)` with pending-pane queue
  (`State/HerdrAppModel.swift:388-397`, `resolvePendingPaneRoute`).
- **APNs:** device token → `POST /api/v1/push/devices` (bundleID + sandbox/production env)
  then `GET /api/v1/push/status` → `remotePushConfigured`; server `push.delivery` SSE event
  carries `{sent, alertId}` — delivered APNs suppress local posts, failures fall back to
  local notification with status text ("Background delivery verified" / "Registered,
  awaiting a delivery check" / "Local alerts while the app is connected" / "APNs delivery
  failed, local alerts remain active", `State/HerdrAppModel.swift:96-103`, `700-724`).

### 4.2 Pane Topology Radar
- **Data:** `HerdrWorkspace.layouts: [HerdrLayout]` — per-tab `area` rect +
  `panes: [{paneID, focused, rect}]` + `splits: [{path, direction, ratio}]` +
  `focusedPaneID` + `zoomed` (`Models/HerdrLayout.swift`).
- **Render:** `PaneTopologyView` (Canvas, `Views/Workspace/PaneTopologyView.swift:9-40`)
  maps pane rects into the view via area-relative scaling; highlight =
  `highlightedPaneID` else layout-focused pane; empty layout = dashed outline. Used only in
  `WorkspaceHeroView` at 94 pt (`Views/Workspace/WorkspaceHeroView.swift:24-27`).
- **Web parity note:** it's pure rect math — an SVG/CSS port is trivial; the interesting part
  is keeping it in sync with live `snapshot.updated` refreshes (it is, since it renders from
  workspace state).

### 4.3 Command Lens
- **Composer** (`Views/Pane/PromptComposerView.swift`): chevron toggles the auxiliary bar;
  mono 1–5-line `TextField` with **status-aware placeholder**: shell pane →
  `run or type into this shell`, agent pane → `message <displayAgentName>` (301-302); Pi
  pane → disposition-dependent `Message Pi` / `Steer this turn` / `Queue a follow-up` /
  `Pi is offline` (`Models/PiPromptComposerConfiguration.swift:69-74`).
- **Agent-aware send** (`State/HerdrAppModel.swift:497-519`): if `agentStatus == .unknown`
  → `sendText` → `POST /panes/{id}/run` (shell command, submit); else →
  `POST /panes/{id}/prompt` (`agent.prompt`). Success toast `Sent to <agent>`; blocked
  while `isSending`.
- **Pi disposition logic** (`Models/PiPromptComposerConfiguration.swift:31-67`): when phase
  = working → `steer`+`followUp` if capable (fallback `prompt`); when idle → `prompt` only;
  `canAbort` when working + capable. `PiPromptComposerStatusBar` shows "Pi is working" +
  disposition chip (Send/Steer/Next short labels, `Models/PiPromptDisposition.swift:20-22`)
  + destructive **Stop**.
- **Key deck** (`Views/Pane/TerminalKeyDeck.swift`): row 1 always = **Up, Down, Tab, Enter**
  (labels 73-76); row 2 on expand = **Left, Right, Esc, Bkspc** (77-80). Raw values are
  `up/down/tab/enter/left/right/escape/backspace` sent as `POST /panes/{id}/send-keys
  {keys: [...]}`. Haptics on each key + expand/collapse. (Ctrl-C reaches panes via the menu
  **Interrupt** action, `Views/Pane/PaneActionsMenu.swift:37-40` and sidebar context menu.)
- **Attachments** (`Models/AttachmentPolicy.swift:4-6`): max 10, 20 MB each, 40 MB
  aggregate; PhotosPicker (images) or fileImporter (any type); upload = **base64 JSON body**
  to `POST /workspaces/{id}/attachments` (not multipart); on send, message = draft +
  `Attachment: `<path>`` lines joined by blank line (`Views/Pane/PromptComposerView.swift:405-412`).
- **Voice to prompt:** private-first pipeline (`State/HerdrAppModel.swift:352-388`): server
  Parakeet (`POST /api/v1/voice/transcriptions`, WAV base64) when
  `preferPrivateTranscription && canControl`, else on-device Apple Speech; toasts
  `Transcribed with <provider>` / `Parakeet unavailable · transcribed with Apple Speech`;
  transcript appended to draft (editable, never auto-sent).
- **Skill/Jira/file inserts** append tokens to the draft, force Terminal mode, and refocus
  (see §3 tool views).

### 4.4 Native Pi Chat
- **Capability gate:** `HerdrPane.piSemantic: PiSemanticCapability?` from the workspace
  snapshot — `available && protocolVersion == 1` → `supportsPiSemanticChat`
  (`Models/HerdrPane.swift:52-54`, `Models/PiSemanticCapability.swift`). Chat mode appears
  in the pane menu only then; **auto-selected on first open** of a supporting pane unless
  the user explicitly chose Terminal.
- **Connection state machine** (`State/PiConversationStore.swift:66-147`): `follow()` → GET
  `pi/snapshot` → verify protocol `herdr.pi.semantic` v1 + `available` (else
  `.unavailable`, "This Pi session does not expose a compatible native transcript.") →
  `reducer.replace(snapshot)` → if snapshot lacks `state.context` (legacy bridge) or is
  disconnected → **2 s snapshot polling** loop (content-change detection, backoff ×1.7 cap
  8 s) that auto-upgrades when a new bridge appears; else open SSE
  `pi/events?after=<cursor>` (also sets `Last-Event-ID` header). Retry: backoff 0.65 s ×1.7
  cap 6 s, connection `.reconnecting(attempt:)`, banner "Live updates paused.
  Reconnecting…".
- **Protocol envelope** (`Models/PiConversationEnvelope.swift`):
  `{protocol:{name,version}, paneId, sessionId, cursor, connected, event:{...}}`;
  `event.type` normalized (strips `pi.` prefix, `State/PiConversationReducer.swift:476-478`).
  Parser (`Infrastructure/PiConversationSSEParser.swift`) handles `id:` lines (cursor
  fallback), `ready`/`pi.ready`/`pi.heartbeat` → activity, `pi.error`/`pi.stream.closed` →
  stream end, and dispatches as soon as accumulated `data:` forms a complete JSON envelope
  (URLSession line-sequence quirk).
- **Reducer** (`State/PiConversationReducer.swift`) — the semantic projection the web app
  must replicate:
  - Cursor de-dup with 2048-entry LRU (`remember`, 442-447); `ready` and `stream.reset`
    bypass dedup (server may reuse cursor) and `stream.reset` → **needsSnapshot**
    (authoritative reload); `session_tree`/`session_compact` → needsSnapshot (context
    replaced); `session_start`/`session_switch` → needsSnapshot only when session ID
    changes.
  - Phase: `agent_start`/`turn_start` → working; `agent_settled` → idle + settle all turns
    (streaming→complete); `message_end`/`tool_execution_end` with `isError` or
    `stopReason` error/aborted → `.failed`.
  - Turns: user message starts a turn (`turn:<messageID>`); assistant content parts keyed
    `<messageID>:text|thinking:<contentIndex>` (streaming deltas append,
    `text_end`/`thinking_end` finalize); **tools keyed by `callID`** across
    `toolcall_start` (placeholder "Preparing tool") → `toolcall_end` (real id/name/args) →
    `tool_execution_*` → `toolResult` message (result + succeeded/failed).
  - Notices (in-transcript): "Context compacted", "Branch context summarized", "Model
    changed", custom messages, "Pi reported an error", and failure notices "Response
    stopped" / "Pi could not finish" with detail fallbacks.
  - `pendingInteractions` upserted from `extension_ui_request`/`interaction_request`
    (kinds `select/confirm/input/editor/unknown`; title fallback "Pi needs your input") and
    removed on `interaction_response`/`interaction_cancelled` or successful respond.
  - Telemetry: `contextUsage` from `state.context` / per-turn `turn_end` context (nulls
    tolerated post-compaction, `Models/PiContextUsage.swift`); `currentModel` from
    `state.model` / `model_select`; `thinkingLevel` from `state.thinkingLevel` /
    `thinking_level_select`.
- **UI** (`Views/Pane/PiChatView.swift`): connection banner (Loading native transcript… /
  Pi is offline. Transcript preserved. / Reconnecting to Pi… / Native transcript
  unavailable) → context meter (bar + "12.3k / 192k" + %, color by fraction <0.6/<0.85/
  else) → timeline (truncation header "Older context was omitted by Pi"; turns with
  activity rail — dot/gradient/end-dot encodes has-tool, failed, active; user bubble right;
  assistant markdown left; **thinking = collapsed DisclosureGroup** "Thinking" (streaming,
  with relative timer) / "Thought process"; **tool cards** QUEUED / RUNNING (spinner) /
  DONE / FAILED + elapsed + Input/Result disclosure, presentation mapped by tool name →
  Command/Read/Write/Edit/Search/Web cards, `Models/PiToolPresentation.swift`) → pending
  interaction cards (option buttons / No-Yes / text+Submit / Cancel) → shared composer with
  Pi status bar. Command notices: "Follow-up queued", "Stop requested", "Model set to
  <name>", "Thinking set to <level>" (auto-clear 2.5 s). Model picker chip (grouped by
  provider; errors: "Loading models…", "No models available", "Couldn't load models",
  501 → "Model switching isn't supported by this Pi session"); thinking-level chip
  (Off/Minimal/Low/Medium/High/Extra High/Max, 501 → "Thinking control isn't supported by
  this Pi session").
- **Commands** (all `POST`, response `{ok|success: bool}` must be `accepted`):
  `pi/prompt`, `pi/steer`, `pi/follow-up` (body `{text}`), `pi/abort`, `pi/model`
  (`{provider,id}`), `pi/thinking-level` (`{level}`), `pi/interactions/{id}/respond`
  (`{value?|confirmed?|cancelled?}`).

### 4.5 Terminal (full + delta frames)
- **Wiring** (`Views/Pane/PaneSessionView.swift:246-330`): on appear/pane change →
  `resetTerminal()` ("Connecting to terminal…") → `refreshOutput(forceSnapshot: true)`
  (initial GET) → task group of **`followFrames()`** (SSE
  `GET /panes/{id}/stream?cols=100&rows=32`; `.ready`/`.activity` keep-alives; each
  `terminal.frame` → `terminalGrid.apply(frame)` → `frameSequence = frame.sequence`, source
  `.stream`; on failure → source `.snapshot`, snapshot fallback, reconnect backoff
  0.65 s ×1.7 cap 5 s) and **`pollSnapshots()`** (GET every **850 ms**,
  `?source=recent_unwrapped&lines=160`, `Infrastructure/HerdrAPIClient.swift:18-26`).
- **Arbitration** (`Models/TerminalRefreshPolicy.swift`): a snapshot only replaces the grid
  when (forced) OR (grid didn't advance during the request) OR (snapshot text changed
  without frames) OR (stream silent ≥ **25 s**); a failed snapshot marks `.disconnected` +
  error pill only when the stream is already stale. Net effect: grid wins when live;
  snapshot fills gaps and is the fallback.
- **Grid semantics** (`Models/TerminalGrid.swift`, `apply` at :103): `full` frame → resize
  grid to frame width/height + full reset + parse; delta frame → reject if
  `sequence <= lastSequence`, resize (copy overlap, clamp cursor) + parse. Parser: ESC CSI
  (`H f A B C D G d J K m`, private `?25h/l` cursor visibility), OSC consumed and ignored,
  `\r \n \b \t` (8-col tabs), pending auto-wrap at last column, scroll-on-linefeed at
  bottom, SGR: reset/bold/italic/underline/inverse + 30-37/39/40-47/49/90-97/100-107 +
  **38/48 with 2;r;g;b and 5;n**; 16-color base palette hardcoded
  (Herdr/Catppuccin-aligned), 216-color cube, 24-step gray ramp; `visibleRows` trims
  trailing blank rows (cursor extends); `attributedText` builds run-merged
  `AttributedString` with inverse-rendered cursor.
- **Source states** (`Models/TerminalSource.swift:10-16`): `connecting` / `live` /
  `watching` / `offline` (labels verified) — these exact lowercase labels show in the
  terminal toolbar with colored dots.
- **Frame payload** (decoded by `TerminalFrame`, `Models/APIResponses.swift:120-141`;
  CodingKey `seq` → Swift `sequence`, verified):
  `{type: "terminal.frame", bytes: <base64>, encoding: "ansi", full: bool, height, seq,
  width}` — `encoding` value **live-verified** by the orchestrator running the herdr
  observer CLI directly (doc 02 §3.2); the app ignores the value and decodes bytes as
  base64 → UTF-8 (`TerminalGrid.swift:108`). Server side: `herdr_harness/terminal.py` spawns `herdr terminal session observe
  <pane> --cols --rows` and re-emits its NDJSON records as SSE (`event: terminal.frame`,
  `: heartbeat` comments every 10 s, `terminal.error`, `terminal.closed` incl.
  `lifetime_limit` at `terminal_max_seconds`, `herdr_harness/server.py:865-896`,
  verified).

### 4.6 HerdPulse (Live Activities)
- **Coordinator** (`Infrastructure/HerdPulseCoordinator.swift`, ~250 lines): single-activity
  invariant (duplicates unregistered + ended), `herdr.herdPulse.enabled` persisted,
  `HerdPulseOperationGate` serializes operations, registration retry policy, ActivityKit
  push-token observation → server registration.
- **Aggregate** (`Models/HerdPulseAggregate.swift`): workspace/pane/working/**attention=
  blocked**/**ready=done** counts + connection mapping; phase priority **offline >
  attention > ready > working > resting**; content state is **counts only** (spec privacy
  rule).
- **Server endpoints** (`Infrastructure/HerdPulseRegistrationClient.swift:23,37,49`):
  `POST /api/v1/live-activities` (register ActivityKit push token),
  `POST /api/v1/live-activities/unregister`, `GET /api/v1/push/status`. Server push type
  `push.live_activity` (`herdr_harness/service.py:140`).
- **UI strings** (widget): "HERD PULSE", "Last known herd" (stale), titles "Needs you" /
  "Ready to review" / "Herd working" / "All quiet" / "Herd offline"; details "N blocked ·
  N working" / "N ready · N working" / "N spaces · N working"; DI labels "needs you" /
  "ready" / "working" + pane count. In-app: button "Start Herd Pulse"/"Stop Herd Pulse",
  status "Off"/"Couldn't start"/"Unavailable"/"Enable Live Activities in iOS Settings".

### 4.7 Navigation (iPhone typed stack / iPad 3-column)
- **iPhone:** `NavigationStack(path: workspacePath)` — list → `.workspace` → pane list →
  `.pane` → `PaneSessionView` (`Views/Workspace/WorkspaceNavigationView.swift:21-49`).
  Attention tab has its own stack rooted at the deck
  (`Views/Attention/AttentionNavigationView.swift`). Selection semantics: workspace select
  also preselects first sorted pane; pane select rewrites the whole path `[workspace, pane]`
  (AttentionStrip deep links).
- **iPad:** `NavigationSplitView(.balanced)` 3 columns — workspaces | panes (of selected
  workspace) | live session (`Views/Workspace/WorkspaceNavigationView.swift:51-85`);
  selection drives all three, no path.
- **Sidebar drawer** (both platforms): the "chats" navigator (§3) — this is the app's
  *second* navigation surface; web needs an equivalent (collapsible left rail vs overlay).
- **Collapse persistence:** collapsed workspace IDs in UserDefaults;
  `-HerdrResetSidebarState` launch arg clears them.
- **Stale-state repair** on refresh (§2). Web equivalent: route guards + hash routing
  (Phase 1's `hashRoute.ts` pattern) with pane-deep-link param (`#pane=<id>`).

---

## 5. API usage from the app side

**Auth:** every request carries `Authorization: Bearer <token>` when token non-empty
(`Infrastructure/HerdrAPIClient.swift:~470-481`). Token stored in Keychain; **URL policy**
(`Models/ServerConfiguration.swift`): `https` anywhere, **`http` only for
`localhost`/`127.0.0.1`/`::1`** — otherwise `connect()` fails with `Use HTTPS, or HTTP only
when connecting to localhost.` (web corollary: mixed-content rules make the iOS
loopback-bypass story moot for remote, but the loopback case mirrors Phase 1's P0). Server
enforces Bearer via `hmac.compare_digest` and accepts **header only — no query-param token**
(`herdr_harness/server.py:290-310`, verified) → see §7 decision 1.
**Envelope:** success `{ok: true, ...}`; failure `{ok: false, error: {code, message}}`
(client decodes `ServerErrorEnvelope` on non-2xx).

**Endpoints called by the app** (all under `/api/v1`):

| Purpose | Call |
|---|---|
| Workspace + alerts state | `GET /workspaces` (on connect, on SSE `snapshot.updated`/pi-capability events, on-demand refresh, after every mutation) |
| Topology/lifecycle SSE | `GET /events` (long-lived; `Last-Event-ID` replay, `ready`/`stream.reset` handled server-side; events seen: `snapshot.updated`, `connection.changed`, `pane.agent_status_changed`, `pane.read`, `alert.created`, `alert.updated`, `push.delivery`, `push.live_activity`, `herdr.event`, plus `pi.*`) |
| Terminal snapshot | `GET /panes/{id}/output?source=recent_unwrapped&lines=160` (every 850 ms while pane open) |
| Terminal frames | `GET /panes/{id}/stream?cols=100&rows=32` (SSE: `ready`, `terminal.frame`, heartbeat comments, `terminal.error`, `terminal.closed`) |
| Pi | `GET /panes/{id}/pi/snapshot`; `GET /panes/{id}/pi/events?after=<cursor>` (+`Last-Event-ID`); `GET /panes/{id}/pi/models`; `POST /panes/{id}/pi/{prompt,steer,follow-up,abort,model,thinking-level}`; `POST /panes/{id}/pi/interactions/{id}/respond` |
| Pane actions | `POST /panes/{id}/{split,ratio 0.5 / focus / send-text / send-keys / run / prompt / start-agent}`; `PATCH /panes/{id}` (label); `DELETE /panes/{id}` |
| Workspace actions | `POST /workspaces {label,cwd}`; `PATCH /workspaces/{id}`; `DELETE /workspaces/{id}`; `POST /workspaces/{id}/focus`; `POST /workspaces/{id}/tabs` (label auto "Tab N") |
| Git (cmux-proxied) | `GET /workspaces/{id}/git`; `GET /workspaces/{id}/git/diff?file&section`; `POST /workspaces/{id}/git/{stage,unstage} {file}` |
| Skills / files / Jira / attachments / voice (cmux-proxied) | `GET /workspaces/{id}/skills`; `GET /workspaces/{id}/files?q&limit=80`; `GET /jira/assigned?limit=50`; `GET /jira/issue?q`; `POST /workspaces/{id}/attachments` (**base64 JSON**); `POST /voice/transcriptions` (WAV base64, 120 s timeout) |
| Alerts | `POST /alerts/{id}/read` (also `POST /alerts/read-all` exists server-side, unused by app) |
| Push | `POST /push/devices {deviceToken,bundleId,environment}`; `GET /push/status` |
| HerdPulse | `POST /live-activities`; `POST /live-activities/unregister` |

**Cadences (there is NO global polling loop — unlike Phase 1):**
- One app-level SSE (`/events`) + one terminal SSE per open pane + one Pi SSE per open Pi
  pane (all 24 h timeout for `*events`/`*stream` GETs, `HerdrAPIClient.timeoutInterval`).
- Terminal snapshot poll **850 ms** (arbitrated, §4.5); legacy-Pi snapshot poll **2 s**;
  reconnect backoffs: connection 2 s ×2 cap 15 s, terminal 0.65 s ×1.7 cap 5 s,
  Pi 0.65 s ×1.7 cap 6 s.
- Everything else is on-demand (`task(id:)` on view appear) or post-mutation silent refresh.
- Timeouts: 15 s default · 30 s git/skills/files/jira · 90 s attachments · 120 s voice ·
  24 h SSE.

---

## 6. Byte-exact user-facing strings (web must match)

**Status vocabulary** (`Models/AgentStatus.swift`): titles 17-21 `Needs you` / `Ready` /
`Working` / `Idle` / `Shell`; compact 27-31 `Blocked` / `Done` / `Working` / `Idle` /
`Unknown`; UI often renders `compactTitle.lowercased()`.
**Connection** (`Models/ConnectionState.swift:15-21`): `Offline` / `Connecting` / `Live` /
`Demo` / `Unavailable`.
**Terminal sources** (`Models/TerminalSource.swift:10-16`): `connecting` / `live` /
`watching` / `offline`; empty output `No terminal output yet.`
(`Views/Pane/PaneSessionView.swift:262`), initial `Connecting to terminal…`
(`Views/Pane/PaneSessionView.swift:10`).
**Tabs** (`Views/Root/AppRootView.swift:75-86`): `Workspaces` / `Attention` / `Settings`.
**Command Lens** (`Views/Pane/PromptComposerView.swift:299-302`): `run or type into this
shell` · `message <agent>`; Pi (`Models/PiPromptComposerConfiguration.swift:69-74`):
`Pi is offline` · `Message Pi` · `Steer this turn` · `Queue a follow-up`; dispositions
(`Models/PiPromptDisposition.swift:12-14,20-22`): `Send`/`Steer`/`Follow up`, short
`Send`/`Steer`/`Next`; key deck (`Views/Pane/TerminalKeyDeck.swift:73-80`, verified):
`Up` `Down` `Tab` `Enter` `Left` `Right` `Esc` `Bkspc`; aux bar
(`Views/Pane/ComposerAuxiliaryBar.swift:29,37,44`): `attach` `voice` `@ file` `jira`;
status bar `Pi is working` + `Stop` (`Views/Pane/PiPromptComposerStatusBar.swift:17,41`);
toasts `Sent to <agent>`, `Staged <file>`, `Unstaged <file>`, `Pane split`, `Focused on
Mac`, `Pane closed`, `Pane renamed`, `Workspace focused on Mac`, `Workspace renamed`,
`Workspace closed`, `Workspace created`, `Tab created`, `<Kind> started` (e.g. `Codex
started`), `Reconnect before controlling Herdr` (`State/HerdrAppModel.swift` `perform` +
call sites).
**Attention** (`Views/Attention/AttentionView.swift`): `Attention` (title), `Attention deck`
(64), `Blocked first, then unseen completions. The queue stays quiet until there's a
decision worth making.`, `Recent signals` (16), `Live queue` (32), `Nothing needs you` (35),
`Working agents will surface here when they finish or need a decision.` (37), `NEW`
capsule (`Views/Attention/AlertCardView.swift:24`), `Closed pane · <paneID>`; `open queue`
(`Views/Workspace/AttentionStrip.swift:12`).
**Workspace list**: `Workspaces` (title), `choose a workspace`
(`Views/Workspace/WorkspaceHeader.swift:66`), `herdr`/`switch` (56-59), `Demo data is
active` (70), `spaces` + `n / total` (`Views/Workspace/WorkspaceListView.swift:47-49`),
`new workspace` (51), filter labels `All`/`Needs you`/`Active` (lowercased render),
`active` (focused, `Views/Workspace/WorkspaceCardView.swift:33`), branch fallback `shell`
(`Views/Workspace/WorkspaceCardView.swift:60`), `No Herdr workspaces` / `Create a workspace
here or on your Mac to begin.` (`Views/Workspace/WorkspaceListView.swift:121-124`),
`Choose a workspace` / `Its tabs and panes will appear here.` / `Choose a pane` / `Open a
terminal or agent session.` (`Views/Workspace/WorkspaceNavigationView.swift:73-84`).
**Menus/confirmations**: `Workspace actions`, `Pane actions`, `View`, `Focus on Mac`,
`Interrupt`, `Rename workspace`/`Workspace name`, `Rename pane`/`Pane name`, `New tab`,
`Refresh`, `Close workspace`, `Close pane`, `Split pane`, `Split right`, `Split down`,
`Start agent` → `Codex`/`Claude`/`OpenCode`, `Open workspace`; confirm copy: `Close this
workspace?` + `All N pane processes in this workspace will stop.`; `Close this pane?` +
`This stops the process running in <title>.`; rename copy: `The new label appears in Herdr
on every connected client.` / `This label is shared with Herdr on your Mac.`.
**Git view**: `detached`, `clean`, `N changed`, `staged`/`unstaged`/`untracked`, `recent
commits`, `Working tree clean` + `Everything in this workspace is committed.`, `No Git
data` + `This workspace does not have a Git repository yet.`, `Reading workspace Git
state…`, `Git unavailable`, `Try again`, `Stage`/`Unstage`, `Refresh Git`, `Diff
unavailable`, `Loading diff…`, `Done`, `(empty diff)` (`Views/Pane/WorkspaceGitView.swift`).
**Skills**: `workspace skills`, `N found`, `Refresh skills`, `Add to terminal`, `Choose a
skill, then insert it as a Claude command, Codex invocation, or file reference.`, `Indexing
project and user skills…`, `Skills unavailable`, `No skills found`, `Add project skills
under .claude/skills or user skills under your configured skills directory.`, styles
`Claude Code`/`Codex CLI`/`Skill file path` (tokens `/name`, `$name`, `` `path` ``,
`Models/WorkspaceToolModels.swift:126-146`).
**File search / Jira**: `WORKSPACE FILES`, `MATCHES`, `Done`, `Retry`; `JIRA CONTEXT`,
`EXACT LOOKUP`, `LOOKUP RESULT`, `Paste a ticket key or browse URL from any project.`,
`loading assigned tickets`, `Jira unavailable`, `no assigned tickets`, `Use exact lookup
for another ticket.`; Jira insert block `Jira: <key> · <title>` / `Status: <s> · Priority:
<p>` / `<url>` (`Views/Pane/PromptComposerView.swift` `appendJira`).
**Pi chat**: `Start a conversation` + `Messages, thinking, and tool activity will appear
here. The terminal remains available from the pane menu.`; `Jump to latest`; `Older context
was omitted by Pi`; `Pi is starting…`; `Thinking` / `Thought process`; `Reasoning details
are unavailable for this response.` / `Pi is working through the request…` / `No reasoning
text was provided.`; tool statuses `QUEUED`/`RUNNING`/`DONE`/`FAILED`, `Waiting for tool
details…`, sections `INPUT`/`RESULT`/`ERROR`; `Pi needs your input`, `Response`
(placeholder), `Submit`, `Cancel`, `No`/`Yes`; banners `Loading native transcript…` / `Pi
is offline. Transcript preserved.` / `Reconnecting to Pi…` / `Native transcript
unavailable`; errors `This Pi session does not expose a compatible native transcript.` /
`Live updates paused. Reconnecting…` / `Pi is offline. Reconnect before sending a message.`
/ `Model switching isn't supported by this Pi session` / `Thinking control isn't supported
by this Pi session` / `Couldn't load models` / `No models available` / `Loading models…`;
notices `Follow-up queued` / `Stop requested` / `Model set to <name>` / `Thinking set to
<level>`; thinking levels `Off`/`Minimal`/`Low`/`Medium`/`High`/`Extra High`/`Max`
(`Models/PiThinkingLevel.swift:16-24`); transcript notices `Context compacted` / `Branch
context summarized` / `Model changed` / `Response stopped` / `Pi could not finish` / `Pi
reported an error` / `The response was interrupted.` / `No error details were provided.` /
`Preparing tool` (`State/PiConversationReducer.swift`); `Response stopped with an error`
(`Views/Pane/PiAssistantMessageView.swift:13`).
**Onboarding/Settings**: `herdr`, `Your agents, within reach`, `Know where to look.`,
`Move from workspace to pane to live agent in seconds. Herdr keeps the terminals real;
this app keeps the decisions close.`, `Connect to your Mac`,
`https://your-mac.tailnet.ts.net` (URL placeholder), `Pairing token`, `Connect`, `Use
localhost in Simulator or the private HTTPS URL from tailscale serve status on iPhone. The
token stays in Keychain.`, `Explore with live-looking demo data`; Settings: `Connection` /
`Server`/`Workspaces`/`Live panes`/`Last update`/`Server URL`/`Save and reconnect`/`Connect
a real server`/`Use demo data`/`Attention`/`Smart agent alerts`/`Delivery`/`Test this
iPhone locally`/`Voice to prompt`/`Prefer Private Parakeet`/`Fallback`/`Apple Speech`/
`Private by design`/`The raw Herdr socket never leaves your Mac`/`Terminal control
requires your pairing token`/`Tailscale keeps the server inside your tailnet`/`Remote
command deck · 0.1`; delivery texts `Background delivery verified` / `Registered, awaiting
a delivery check` / `Local alerts while the app is connected`
(`State/HerdrAppModel.swift:96-103`); test alert `Herdr alerts are ready` + `You'll hear
when an agent needs you or finishes in the background.`
(`Infrastructure/NotificationManager.postTest`); `Connection issue` + `Dismiss` (error
alert); `Use HTTPS, or HTTP only when connecting to localhost.`
(`State/HerdrAppModel.swift` `connect`).
**Sidebar drawer**: `filter chats`, `new workspace`, `chats`, `N total shown`, `no panes
yet`, `Close navigator`.
**HerdPulse**: `Start Herd Pulse`/`Stop Herd Pulse`, `Off`, `Start Pulse to monitor your
herd`, `Couldn't start`, `Unavailable`, `Enable Live Activities in iOS Settings`; widget
`HERD PULSE`, `Last known herd`, `Needs you`/`Ready to review`/`Herd working`/`All
quiet`/`Herd offline`, `panes`, `needs you`/`ready`/`working`, `N blocked · N working` /
`N ready · N working` / `N spaces · N working`.
**Voice**: `VOICE NOTE`, `RECORD`/`STOP`, `PREVIEW`, `Transcribe`, `Transcribing`,
`Discard`, `Discard Recording`/`Keep Recording`, `The temporary recording will be deleted.`,
`Hold the mic to dictate`, `Transcribed with <provider>`, `Parakeet unavailable ·
transcribed with Apple Speech`.
**Attachments**: `uploading`/`attached`/`upload failed`.

---

## 7. Decisions the architect must make (NOT decided here)

1. **SSE auth transport.** Browser `EventSource` **cannot set the `Authorization` header**,
   and the server accepts the Bearer token header-only (no `?token=` query support,
   `herdr_harness/server.py:290-310`, verified). Either (a) implement fetch-based streaming
   SSE in the web client (full header control, manual `retry`/`Last-Event-ID` handling for
   all three streams), or (b) add a query/token-fragment auth path to `herdr_harness`. This
   is the highest-leverage call.
2. **Terminal renderer.** Port `TerminalGrid.swift`'s bounded grid to TS (deterministic,
   small, matches the app's exact trim/color behavior) **vs** adopt xterm.js (mature ANSI,
   but heavier and its viewport/scrollback semantics differ from the app's "last non-blank
   row" rendering and `W×H · fN` toolbar). Delta `seq` handling and the 850 ms snapshot
   arbitration (`TerminalRefreshPolicy`) must be preserved either way.
3. **Static hosting.** Serve from 9092 at `/herdr-web` (same-origin, no CORS, small
   `herdr_harness` change) vs separate port — same shape of the Phase-1 P0 decision.
4. **Pi Chat depth in v1** — full semantic conversation (turns, thinking collapse, tool
   cards, interaction cards, model/thinking chips) vs terminal-first with Pi Chat as a
   fast-follow (handoff §10.4). Note the reducer is self-contained and unit-tested; a port
   is bounded but non-trivial.
5. **HerdPulse equivalent** — skip in v1 / browser Notifications API degraded equivalent /
   service-worker live-ish indicator. The aggregate-only content contract makes a
   notifications-only version cheap.
6. **Web Push / APNs replacement** — v1 skip vs VAPID service-worker push (server would
   need new endpoints; none exist).
7. **Deep-link + notification routing.** Map `herdr://?pane=<id>` + notification-tap
   semantics to hash routes (`#pane=<id>`) and the notification click URL; decide whether
   the web app owns the "pending pane until data arrives" queue (iOS does,
   `pendingPaneID`).
8. **Layout mapping.** iPad 3-column ↔ desktop wide layout: which columns, whether the
   sidebar "chats" drawer becomes a persistent left rail on desktop, and how the compact
   stack maps to narrow mobile.
9. **Demo mode parity.** Port `DemoData` as a mock adapter (useful for offline
   development/CI) or drop it.
10. **Voice pipeline.** MediaRecorder produces webm/opus, but the app's contract is 16 kHz
    mono **WAV** base64 JSON (`Models/VoiceTranscription.swift:39-45`); decide whether to
    resample client-side (WebAudio) or treat voice as out-of-v1.
11. **Haptics** — confirm skip (no meaningful Web equivalent on Mac).
12. **Dead code** — `FleetSummaryView` and `PaneSessionHeader` are unused in the app
    (verified: 0 references each); exclude from parity scope (flagged, no decision needed
    beyond confirming).

## 8. Unknowns / risks

- **`pi-semantic-bridge` runtime state**: Chat availability depends on the bridge being
  loaded per Pi session (`--extension`); must be verified at runtime in whatever panes QA
  uses (doc 02 covers the server/bridge side). The 2 s snapshot-poll fallback keeps
  legacy/offline transcripts readable, so the web app should implement the same
  degradation.
- **Live 9092 probing still required** (doc 02): envelope shapes here are decoded
  tolerantly (snake+camel fallbacks everywhere) — confirm actual field spellings on the
  wire before freezing the web client.
- **Both servers must be up** for git/skills/files/jira/attachments parity
  (`HERDR_HARNESS_CMUX_URL` default `http://127.0.0.1:9091`); the web app inherits this
  dependency silently (errors surface as per-tool error cards).
- **Terminal frame payload** is produced by Herdr's `terminal session observe` CLI
  (protocol 19, Herdr ≥ 0.8.0) — the app decodes `{type,bytes,encoding,full,height,seq,
  width}`; the architect should confirm the CLI's `encoding` values and whether
  non-`terminal.frame` records ever arrive.
- **Uncommitted `client.py`/`service.py` changes** in the worktree may have shifted
  socket-level behavior (not yet committed at `78a6548`); treat `git show 78a6548` as the
  reviewed baseline.
- **Event name normalization**: server sanitizes SSE `event:` names
  (`_EVENT_NAME_RE.sub("_", …)`), app normalizes Pi types by stripping `pi.` — the web
  client must replicate both normalizations or it will miss events.
- **Cursor semantics differ per stream**: top-level events use integer `id:` +
  `Last-Event-ID`; Pi uses opaque string cursors in the payload *and* as `id:` fallback;
  terminal uses per-frame `seq`. Three distinct replay models in one app.
