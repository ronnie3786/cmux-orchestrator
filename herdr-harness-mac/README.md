# Herdr Harness for Mac

A native macOS companion to the Herdr Harness iOS app — same Catppuccin Mocha aesthetic, same
attention-first workflow, near-complete feature parity, rebuilt around a Mac-native shell: a
persistent sidebar (workspaces → tabs → chats), a resizable chat/terminal detail view, real
keyboard input to terminals, menu-bar fleet pulse, and system keyboard shortcuts.

The shell is the deliberate difference. iOS's workspace *switcher* screen — status filter chips
(all / needs you / active), the inline top-2 attention strip, and the git-worktree sibling rails —
has no Mac counterpart: the always-visible sidebar and the Attention scope (⌘1) replace it, and
those three affordances are dropped rather than reproduced.

Swift 6 · SwiftUI + Observation · strict concurrency · zero third-party dependencies · macOS 26.

## What's in the app

- **Sidebar navigator** — workspaces at the top level, panes grouped by tab beneath them, click a
  chat row to make it the main view. Collapse state persists across launches. Rows are styled in
  a single calm tone (no per-status hues) — the status word and unread count carry the signal.
- **Native Pi chat** — the rich chat timeline (streaming turns, collapsed thinking, tool cards,
  interaction/permission cards, markdown with tables and code blocks, context meter, model +
  thinking-level switching) with the terminal always one toggle away.
- **Live terminal** — the same bounded ANSI grid engine as iOS (full + delta frames over SSE,
  snapshot fallback), plus real Mac keyboard routing: click the terminal to focus it and type;
  arrows/tab/esc/ctrl-C go straight through. The compact key deck stays for parity.
- **Prompt composer** — Mac has the room, so nothing hides: the tool row (attach / voice /
  @file / Jira) and the terminal key deck share one always-visible row directly above the input.
  Status-aware placeholder text, shared drafts between chat and terminal modes. Enter sends,
  Shift+Enter inserts a newline, Cmd+Enter always sends.
- **`$` skills palette** — type `$` at a word boundary to raise a filtering HUD of the
  workspace's skills. Arrow keys move the highlight, Enter/Tab (or click) inserts the skill,
  Esc dismisses, and space dismisses while typing normally — so a stray `$` never gets in your
  way. Zero matches auto-dismisses; only a fresh `$` re-opens it.
- **Voice** — tap the mic for the long-form recorder sheet, press-and-hold to dictate
  (auto-locks after a beat). Recordings are mono 16 kHz WAV, transcribed by your private
  Parakeet endpoint with on-device Speech as fallback.
- **Attention deck** — blocked and done agents rise to the top; alerts sync read-state with the
  server; local notifications deep-link straight into the pane (`herdr://pane/{id}` works too).
- **Workspace overview** — fleet summary, pane topology radar built from Herdr's real split
  geometry, git status/diffs, skills, project file search, Jira tickets, attachments.
- **Herd Pulse in the menu bar** — the iOS Live Activity becomes a menu-bar extra with the same
  privacy-safe aggregate (counts only, never names). Start it from the toolbar's pulse button or
  View ▸ Start Herd Pulse (⇧⌘P); the extra is only inserted while Pulse is on. The event stream
  and the pulse feed outlive the window, so closing it keeps alerts and the menu bar live.

## Requirements

- macOS 26.0+ and Xcode 26.2+ (the project uses Xcode folder-sync groups; new `.swift` files
  are picked up automatically — no pbxproj edits).
- A running Herdr Harness backend (`herdr_dashboard.py`, port 9092) on this Mac or reachable
  over Tailscale. Server prereqs: Herdr 0.8 (protocol 19) and Python 3.9+ — see
  [`HERDR_HARNESS.md`](../HERDR_HARNESS.md) at the repo root for the full runbook.

## Build & run

```bash
cd herdr-harness-mac
xcodebuild -project herdr-harness-mac.xcodeproj -scheme herdr-harness-mac \
  -destination 'platform=macOS' build
```

Or open `herdr-harness-mac.xcodeproj` in Xcode and hit Run. The only shared scheme is
`herdr-harness-mac`.

### Try it instantly (no server): demo mode

Add the launch argument `-HerdrDemoMode` (Xcode: Product → Scheme → Edit Scheme → Arguments) to
load the canned fleet — 3 workspaces, 6 panes, alerts, git, skills — with no backend at all.
`-HerdrResetSidebarState` (DEBUG) clears persisted sidebar collapse state.

### Connect to your real herd

1. Start the backend (once per Mac):

   ```bash
   # Stable token — create ONCE, reuse forever
   mkdir -p "$HOME/.config/herdr-harness"; umask 077
   openssl rand -hex 32 > "$HOME/.config/herdr-harness/api-token"

   export HERDR_SESSION=default   # or your fixture session
   export HERDR_HARNESS_API_TOKEN="$(<"$HOME/.config/herdr-harness/api-token")"
   python3 herdr_dashboard.py --no-browser        # serves 127.0.0.1:9092
   ```

   Optional extras: `python3 scripts/setup_herdr_demo.py --session herdr-ios-fixtures ...` for a
   repeatable fixture topology, and the cmux harness (`python3 dashboard.py`, port 9091) to light
   up Git/Skills/Files/Jira/attachments/voice proxying.

2. Launch the app, enter `http://localhost:9092` and the token from
   `~/.config/herdr-harness/api-token` in onboarding. The token is stored in your Keychain.
   Plain HTTP on loopback is the supported local path; for a remote Mac, use the Tailscale HTTPS
   URL (`tailscale serve --bg --https=8461 9092`).

3. Verify the backend independently at any time:

   ```bash
   curl -sS -H "Authorization: Bearer $HERDR_HARNESS_API_TOKEN" http://127.0.0.1:9092/api/v1/health
   ```

## Tests

```bash
cd herdr-harness-mac
xcodebuild -project herdr-harness-mac.xcodeproj -scheme herdr-harness-mac \
  -destination 'platform=macOS' test -only-testing:herdr-harness-macTests
```

The unit suite is the iOS suite ported (reducers, SSE parsers, markdown, sidebar tree, terminal
grid hardening, policies, timeouts, Herd Pulse privacy) plus mac-specific additions (terminal
keyboard mapping, menu-bar privacy, demo screen renders). UI tests (`herdr-harness-macUITests`)
drive demo mode through XCUITest; run them from Xcode — the runner needs macOS Automation
permission, so they can't run from a headless shell.

Troubleshooting: if `xcodebuild test` hangs for minutes with no output, a stale `testmanagerd`
daemon is usually stuck — `pkill -9 testmanagerd` and rerun.

## Diagnosing a freeze

Before force-quitting a beach-balled app, run `Scripts/capture-hang.sh` from another terminal. It
writes a sample, footprint, vmmap summary, heap summary, and system log to
`~/Library/Logs/Herdr/hang-<timestamp>/`. The live diagnostics can also be inspected directly:

```bash
log show --last 15m --predicate 'subsystem == "dev.ronnierocha.herdr-harness" AND category == "perf"' --style compact
```

## Relationship to the iOS app

The two apps are partners: models, state, networking, the Pi chat pipeline, the terminal engine,
and the design system are ported **verbatim** from `herdr-harness-ios/` (same types, same file
names); only the shell differs (NavigationSplitView window + menu bar instead of stack/split
navigation + Live Activity). When the iOS app gains a feature in a shared layer, the same file
usually drops into this project unchanged.
