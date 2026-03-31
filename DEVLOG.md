# Development Log

## How this project was built

### Origin (2026-03-30)

Started from a question: "Can I control cmux workspaces programmatically so an agent can manage my coding sessions?"

Discovered cmux has a full Unix socket API with commands for listing workspaces, reading terminal screens, and sending keystrokes. Combined with the fact that Ronnie's company disables Claude Code's `--permission-mode auto`, this created a real use case: build an external harness that auto-approves Claude Code prompts by reading the terminal and sending the right keystrokes.

### Phase 1: Shell script prototype

Built `auto-approve.sh` as a bash script that:
- Connects to cmux socket via Python (macOS GNU netcat doesn't support Unix sockets)
- Reads terminal screen with `read_screen`
- Pattern-matches for Claude Code prompts
- Sends `y` or Enter to approve

**Key discovery:** cmux's `read_screen` renders Claude Code's `❯` cursor as `)`. This broke all initial regex patterns until we figured it out from debug logs.

### Phase 2: Web dashboard

Replaced the CLI script with `dashboard.py`, a single-file Python web app that serves:
- REST API for status, toggle, workspace management, log retrieval
- Embedded HTML/CSS/JS dashboard (dark theme, auto-refreshing)
- Background polling thread running the harness engine

### Phase 3: Cross-workspace without focus switching

**Problem:** Reading/sending to non-active workspaces required `select_workspace` which visually switched the tab, causing jarring flickering.

**Solution 1 (partial):** Used `list_notifications` to only check workspaces with unread notifications, reducing unnecessary switches.

**Solution 2 (final):** Discovered cmux's v2 JSON-RPC API (`surface.read_text`, `surface.send_text`) accepts `workspace_id` as a parameter, allowing reads and sends without switching the visible workspace.

### Phase 4: LLM classification

**Problem:** Regex pattern matching was a whack-a-mole game. Claude Code has many prompt formats, and new ones appear with each version.

**Solution:** Added a local Ollama model (qwen3.5:2b) as a fallback classifier. Regex handles known patterns (fast, deterministic), LLM handles unknown ones. The LLM gets the last 25 lines of terminal text and returns a JSON classification.

**Key learnings:**
- `"think": false` in the Ollama API disables thinking mode (critical for speed)
- Temperature 0.1 for deterministic classification
- The LLM was incorrectly classifying Claude Code's idle REPL as "waiting for input" — fixed by adding REPL detection before LLM is called
- 0.8B model worked but was inconsistent; 2B model is more reliable

### Prompt Detection Evolution

Started with simple regexes, evolved through several iterations:

1. **v1:** Match `(Y/n)` and `Allow <Tool>` — missed numbered menus entirely
2. **v2:** Added numbered menu detection with `❯` cursor check — didn't account for `❯` rendering as `)`
3. **v3:** Match both `❯` and `)` as cursor indicators — `allow_generic` regex was too broad, caused false matches
4. **v4:** Removed `allow_generic`, added menu option analysis — "3+ options = needs human" was too aggressive, blocked standard Yes/No/Remember prompts
5. **v5 (current):** Smart option analysis. Checks if all options are Yes/No/Allow/Confirm variants (permission menu → auto-approve) vs domain-specific options (needs human). Idle REPL detection prevents false LLM triggers.

### cmux Socket API Notes

- **v1 API:** Plain text commands over Unix socket (`list_workspaces`, `read_screen 0 --lines 30`)
  - `list_workspaces` returns plain text, not JSON
  - `read_screen` resolves against the currently selected workspace
  - `send_surface` uses `resolveTerminalPanel` which only searches the selected workspace
  - Cross-workspace operations require `select_workspace` first (causes visible tab switch)

- **v2 API:** JSON-RPC over the same socket (`{"method": "surface.read_text", "params": {"workspace_id": "..."}}`)
  - `surface.read_text` accepts `workspace_id` parameter (no switching needed)
  - `surface.send_text` and `surface.send_key` also accept `workspace_id`
  - `workspace.list` returns proper JSON

- Socket modes: `off`, `cmuxOnly` (default, checks process ancestry), `automation` (allows external local processes), `allowAll`
- Socket path: `~/Library/Application Support/cmux/cmux.sock` (stable), `/tmp/cmux.sock` (fallback)
- Set automation mode: `defaults write com.cmuxterm.app socketControlMode -string automation` + restart cmux

### Phase 5: Command Center UI (v2)

Replaced the v1 dashboard with a full command center:
- **Card grid layout** (540px min-width) with live terminal previews (syntax-highlighted)
- **Per-workspace auto toggle** — enable/disable auto-approve individually
- **Expand view** — click ⤢ to open full terminal output + activity feed sidebar
- **Workspace rename** — click name to inline-edit, persists across restarts
- **Settings modal** — poll interval, Ollama model picker (pulls from local models), LLM toggle
- **Collapsed idle cards** — plain shell terminals render as compact single row, 30s polling
- **New Session button** — creates cmux workspace, cd's to configurable directory, launches claude
- **Browser notifications** — sound (Web Audio chime) + browser Notification on "needs human" and "session complete" transitions, tab title badge with count
- **Persistent config** — `~/.cmux-harness/workspace-config.json` keyed by UUID (survives index shifts)
- **Claude detection** — classifies workspaces as active/idle based on terminal content, not timing
- **Input focus preservation** — saves cursor position and value across refresh cycles
- **500ms refresh** in expanded view (2s for grid)

**Bug found and fixed:** Socket connection exhaustion. The polling loop opened 3-4 connections per workspace per cycle without calling `sock.shutdown()` before `close()`. After running for a while, cmux accumulated 90+ half-open file descriptors and stopped responding entirely. Fixed by adding `sock.shutdown(socket.SHUT_RDWR)` on all socket paths.

**UI design process:** Built 3 mockup options (Card Grid, Split View, Kanban), iterated on a hybrid: grid layout from Option A with the expanded terminal + activity feed from Option B. Option C (Kanban lanes) was scrapped.

---

## v3 Brainstorm: Session Review Agent

> **Note:** Everything below is brainstorming and early ideas. None of this is final or set in stone. The actual implementation will evolve as we build and learn what works.

### Core idea

Instead of watching every terminal line, what if the harness only paid attention at key moments (like a manager checking in) and ran a lightweight review when a session finishes?

### Possible architecture (rough sketch)

```
Monitoring Loop (lightweight, every poll cycle)
  │
  ├─ State tracking: started → active → waiting → completed
  ├─ Approval log: what was auto-approved / flagged
  └─ Transition events only (no raw terminal ingestion)
  
Completion Trigger (hasClaude: true → false)
  │
  ├─ Grab terminal snapshot: last 50 lines (Claude Code's own summary)
  ├─ Run git commands in worktree:
  │     git diff --stat
  │     git diff
  │     git log --oneline -5
  ├─ Package review context (~2-3K tokens):
  │     { approvalLog, terminalSummary, gitDiff, filesChanged, ticketId }
  │
  └─ Send to local model (8B+ recommended) with review prompt
       │
       └─ Returns structured review:
            {
              summary: "Added retry logic with exponential backoff to token refresh",
              filesChanged: ["TokenManager.swift", "TokenStorage.swift", "APIClient.swift"],
              linesAdded: 45,
              linesRemoved: 12,
              confidence: "high",
              issues: [],
              readyForPR: true,
              recommendation: "Clean change, follows existing patterns. Ready for PR."
            }
```

### What the review agent might see (slim context)

1. **Approval log entries** — what was auto-approved, what was flagged, timestamps
2. **State transitions** — "started", "waiting", "completed" events only
3. **Terminal snapshot at completion** — last ~50 lines where Claude Code summarizes its work
4. **Git diff** — the actual code changes. This is the deliverable.

### What the review agent does NOT see

- Every Read/Edit/Bash action in real-time
- Thinking/Musing output
- File contents being displayed mid-session
- Build output scrolling by
- Raw terminal scrollback during active work

### Review prompt template (draft, needs iteration)

```
You are reviewing code changes made by an AI coding agent (Claude Code).
Given the session summary and git diff, provide a structured review.

Session info:
- Workspace: {name}
- Duration: {duration}
- Actions auto-approved: {count}
- Actions flagged for human: {count}

Claude Code's summary (last 50 lines of terminal):
{terminal_snapshot}

Git diff:
{git_diff}

Respond with JSON:
{
  "summary": "one-line description of what changed",
  "filesChanged": ["list of files"],
  "confidence": "high|medium|low",
  "issues": ["list of concerns, empty if none"],
  "readyForPR": true|false,
  "recommendation": "brief recommendation for the developer"
}
```

### Dashboard integration ideas

- Review card that replaces terminal output with a summary after completion
- Badges: green (ready for PR), yellow (issues), red (needs attention)
- Expandable diff view
- One-click PR creation

### Scaling thoughts

The LLM only runs once per session at completion, not during active work. So even a 35B model taking 30 seconds is fine. Token budget per review would be ~2-3K (approval log + 50-line snapshot + git diff stat).

### Rough implementation order

1. Completion detection (hasClaude transitions)
2. Snapshot + git diff capture on completion
3. Review endpoint + runner
4. Dashboard UI for review results

### Model thoughts

- 2B might work for summaries but could miss subtle code issues
- 8B is probably the sweet spot for code review quality vs speed
- 35B+ for when quality matters more than latency
- Should be configurable (already have the model picker)

### Open questions (lots of these)

- Should the agent auto-run `swift build` / `swift test` after completion to verify the changes compile?
- Should it detect when two sessions are editing the same file and warn about merge conflicts?
- How to handle reviews for sessions that were manually interrupted vs completed naturally?
- Should review history persist to disk (like approval logs)?

---

### Known Issues / TODO

**Done:**
- [x] Workspace index shifting (fixed: UUID-based config)
- [x] Browser notifications on "needs human" and session complete
- [x] Visual highlighting for workspaces needing attention (yellow border + sort to front)
- [x] v2 API as primary (no more tab switching)
- [x] Debug log rotation (10MB cap)
- [x] Session timer and cost display
- [x] Reconnection handling with stale data detection
- [x] Graceful Ollama degradation (rate-limited retries)

**Open:**
- [ ] Auto-scroll lock — stop fighting user when they scroll up
- [ ] Keyboard shortcuts (1-9 jump to workspace, `e` expand, `a` toggle auto)
- [ ] Filter/sort controls (show only active, only needs-you)
- [ ] "Pause for 5 minutes" button
- [ ] Favicon for tab identification
- [ ] Mobile-responsive layout
