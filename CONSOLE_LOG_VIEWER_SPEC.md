# Console Log Viewer — Implementation Spec

## Overview

Add a console/runtime log viewer to the orchestrator UI that lets the user browse and filter live simulator logs from the app. When `exp-project-run --console` runs (e.g. via the "Build & Run" action button), it streams logs to `.build/logs/<sim-name>.log` on disk — always **unfiltered**. This viewer reads those files and applies server-side filtering so the user can slice through thousands of log lines from the browser.

This is distinct from the **build log viewer** (which shows xcodebuild output from `.build/build.log`). The console log viewer shows **runtime app logs** — analytics events, network requests, errors, messaging activity, etc.

## How the log files work (context from exp-project-run)

- **Source:** `xcrun simctl spawn {udid} log stream --level info --style compact --predicate 'subsystem contains "doxx"'`
- **Disk path:** `.build/logs/<sim-name>.log` (e.g. `.build/logs/IOSDOX-25080-sdui-list-iphone-dox-run.log`)
- **Reset behavior:** File is truncated on each app launch (not appended)
- **Content:** One line per log entry, compact style — can grow to thousands of lines quickly
- **Always unfiltered on disk** — filtering only happens at display time

## Backend

### New endpoint: `GET /api/objectives/{id}/console-logs`

**Query params:**
- `lines` (int, default 500, max 2000) — number of lines to return from the tail
- `filter` (string, optional) — regex pattern applied server-side via `re.search()` (same semantics as `grep -E`)
- `file` (string, optional) — specific log filename to read (if multiple sims exist). Default: auto-pick the first/only `.log` file found.

**Logic:**
1. Read the objective to get `worktreePath`
2. Scan `{worktreePath}/.build/logs/` for `*.log` files
3. If no log files exist: return `{ "exists": false, "files": [], "lines": [], ... }`
4. If `file` param given, use that filename (validate it exists in the directory and ends with `.log` — no path traversal). Otherwise use the first file found.
5. Read using `deque(maxlen=lines)` approach (same as build-log endpoint — don't load full file into memory)
6. If `filter` param is present and non-empty:
   - Compile with `re.compile(pattern, re.IGNORECASE)` inside a try/except (return 400 on invalid regex)
   - Apply `pattern.search(line)` to each line, only keep matches
   - The deque should operate on the **filtered** output (tail of matches, not matches from tail)
   - Implementation: iterate all lines, apply filter, append matches to deque — so we get the last N *matching* lines
7. Return:
```json
{
  "exists": true,
  "files": ["IOSDOX-25080-iphone-dox-run.log", "IOSDOX-25080-ipad-dox-run.log"],
  "activeFile": "IOSDOX-25080-iphone-dox-run.log",
  "lines": ["line1", "line2", ...],
  "totalLines": 18432,
  "matchedLines": 342,
  "fileSize": 4521984,
  "fileSizeHuman": "4.3 MB",
  "truncated": true,
  "filter": "analytics event:"
}
```

**Important notes:**
- `totalLines` = total lines in file (before filter)
- `matchedLines` = lines matching the filter (omit or set equal to totalLines when no filter)
- The `files` array lets the frontend build a file picker when multiple simulators ran
- Filename validation: must end with `.log`, must exist in `.build/logs/`, no `..` or `/` allowed

**Placement in `server.py`:** Add as a new `elif` branch in `do_GET`, near the build-log handler. Follow identical patterns.

### Filter performance note

Console log files can be large but not enormous (the app resets them on each launch). A single-pass iterate-and-filter into a deque is fine. No need for indexing or caching for v1.

## Frontend

### Console Log Button

Add a **console icon** (📟 or a `>_` terminal prompt SVG) to the **objective header area**, next to the existing build log button. This button:
- Toggles the console log panel open/closed
- Shows a green indicator dot when console log files exist
- Distinct from the build log button (different icon, different panel)

### Console Log Panel

A **slide-out drawer from the bottom** (same position/pattern as the build log panel). Only one bottom panel should be open at a time — opening the console log panel closes the build log panel and vice versa.

```
┌──────────────────────────────────────────────────────────────────┐
│ Console Logs — IOSDOX-25080-iphone-dox-run.log (4.3 MB)        │
│ [iphone-dox-run.log ▾] [Filter: ▾ Analytics] [Custom: ______] │
│ [Auto ● ] [✕]                                                   │
├──────────────────────────────────────────────────────────────────┤
│ 2026-04-04 13:05:22 Track analytics event: screen_view {...}    │
│ 2026-04-04 13:05:23 Screen analytics event: home_feed {...}     │
│ 2026-04-04 13:05:25 Track analytics event: tap_message {...}    │
│ 2026-04-04 13:05:26 Starting fetch conversations_list           │
│ 2026-04-04 13:05:27 Result of fetch conversations_list (200)    │
│                                                        ▼ pinned │
└──────────────────────────────────────────────────────────────────┘
```

### Filter Presets (the key feature)

A **dropdown or chip/pill bar** with these pre-built filter patterns:

| Label | Filter Pattern | Description |
|-------|---------------|-------------|
| All | *(empty/no filter)* | Show everything |
| Analytics | `analytics event:` | All track + screen analytics events |
| Analytics (names only) | `Track analytics event:\|Screen analytics event:` | Event names without JSON payloads |
| Network | `Starting fetch\|Starting mutation\|Result of fetch\|Result of mutation` | All network requests |
| Errors | ` E ` | Error-level entries |
| GraphQL | `\(doxx:GraphQL\)` | GraphQL category |
| Messaging | `MessagingConversation:` | Messaging activity |

**Custom filter input:** A text input field where the user can type an arbitrary regex pattern. Hitting Enter or a "Go" button applies it. The custom input and preset dropdown work together — selecting a preset populates the custom input, and typing a custom pattern sets the dropdown to "Custom".

### File Picker

If multiple `.log` files exist (iPhone + iPad), show a dropdown to switch between them. The `files` array from the API response populates this.

### Styling

- Match the build log panel exactly (same background, font, header style, max-height 40vh)
- Log lines: monospace, 12px, `var(--muted)` color
- Filter bar: sits in the header area, compact, uses same select/input styling as existing UI elements
- **Highlight matched text:** When a filter is active, highlight the matched portion of each line with a subtle background color (e.g. `rgba(59, 130, 246, 0.2)`) so the user can scan quickly

### Auto-refresh

- Same toggle pattern as build log viewer: "Auto" toggle with green dot
- When ON: polls every **3 seconds** with the current filter applied
- When OFF: manual refresh via refresh icon
- Default: OFF
- Stops when panel closes

### Smart Scrolling

Same as build log viewer:
- Auto-pin to bottom when user is at bottom
- "⬇ New output" floating badge when scrolled up
- Badge click scrolls to bottom

### JavaScript

Add to existing orchestrator.html script:

```javascript
// State
state.consoleLogOpen = false;
state.consoleLogAuto = false;
state.consoleLogFile = null;       // auto-selected from API response
state.consoleLogFilter = '';       // current active filter pattern
state.consoleLogPreset = 'all';   // current preset name
state.consoleLogData = null;
state.consoleLogInterval = null;

// Functions:
// toggleConsoleLog()        — open/close panel (close build log if open)
// fetchConsoleLog()         — GET with current file + filter, update state, render
// renderConsoleLog()        — update DOM: header, filter bar, log lines, scroll
// startConsoleLogPoll() / stopConsoleLogPoll()
// setConsoleLogFile(filename)
// setConsoleLogFilter(pattern, presetName)
// applyConsoleLogPreset(presetName) — look up pattern, call setConsoleLogFilter
```

### Mutual exclusion with build log panel

Only one bottom panel open at a time. When `toggleConsoleLog()` opens:
- If build log panel is open, close it (`state.buildLogOpen = false`, stop its polling)
- Vice versa for `toggleBuildLog()`

## File Changes Summary

| File | Changes |
|------|---------|
| `server.py` | Add `GET /api/objectives/{id}/console-logs` endpoint (~80 lines) |
| `orchestrator.html` | Add CSS for console log panel + filter UI, HTML container, JS logic (~600 lines) |

**Do NOT modify:** `objectives.py`, `orchestrator.py`, `engine.py`, `cmux_api.py`

## Testing

After implementation, verify:
1. Endpoint returns `exists: false` when no `.build/logs/` directory or no `.log` files exist
2. Endpoint returns unfiltered tail correctly
3. Endpoint filters correctly with `filter=analytics event:` (should only return analytics lines)
4. Endpoint returns 400 on invalid regex (e.g. `filter=[invalid`)
5. Multiple log files show up in the `files` array and file picker works
6. Filter presets apply the correct patterns
7. Custom filter input works (type pattern, hit Enter)
8. Switching presets updates the custom input field
9. Match highlighting works when filter is active
10. Panel opens/closes, mutual exclusion with build log panel works
11. Auto-refresh polls with filter applied
12. Smart scroll behavior (same as build log)
13. No path traversal via `file` param (reject `..`, `/`, non-`.log` files)
