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

### Known Issues / TODO

- [ ] Workspace index can shift when workspaces are opened/closed mid-session
- [ ] Debug log grows unbounded — needs rotation
- [ ] No macOS native notification when "needs human" is detected
- [ ] Dashboard doesn't show which workspace the "needs human" prompt is in visually enough
- [ ] Should highlight workspaces that need attention in the workspace list
- [ ] Consider adding a "pause for 5 minutes" button
- [ ] The v2 API fallback to v1 still causes tab switching — should warn in the UI
