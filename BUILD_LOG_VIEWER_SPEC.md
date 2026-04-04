# Build Log Viewer — Implementation Spec

## Overview

Add a build log viewer panel to the orchestrator UI that shows the contents of `.build/build.log` from the objective's worktree. The log file is created when the user triggers a build command (e.g. via the "Build & Run" action button). The viewer should handle files that don't exist yet, and provide a toggle to auto-poll for updates.

## Backend

### New endpoint: `GET /api/objectives/{id}/build-log`

**Query params:**
- `lines` (int, default 200, max 1000) — number of lines to return from the **tail** of the file
- `offset` (int, optional, default 0) — if > 0, return lines starting from this byte offset (for "load more" / full view)

**Logic:**
1. Read the objective to get `worktreePath`
2. Construct path: `{worktreePath}/.build/build.log`
3. If the file doesn't exist: return `{ "exists": false, "lines": [], "fileSize": 0, "totalLines": 0 }`
4. If it exists: efficiently read the last N lines using a `collections.deque(maxlen=N)` approach — iterate the file line by line, keeping only the last N. Do NOT read the entire file into memory at once for the default tail mode.
5. Return:
```json
{
  "exists": true,
  "lines": ["line1", "line2", ...],
  "fileSize": 2457600,
  "fileSizeHuman": "2.4 MB",
  "totalLines": 45832,
  "truncated": true
}
```

**Important:** The file can be 2.4MB+. The endpoint MUST NOT load the full file into a list. Use `deque(maxlen=lines)` to stream through the file keeping only the tail.

**File location in `server.py`:** Add as a new `elif` branch in `do_GET`, right after the action-buttons GET handler. Follow the same pattern (extract objective_id from URL, read objective, 404 if not found).

### Also support: `prebuild.log`

The `.build/` directory also contains `prebuild.log` (much smaller, ~1KB). Add support for an optional `file` query param:
- `file=build.log` (default)
- `file=prebuild.log`

Validate the filename is one of these two — no path traversal.

## Frontend

### Build Log Button

Add a **terminal icon button** (🖥 or use `⎔` or a `<svg>` terminal icon) to the **objective header area** (near the objective title/status). This button:
- Toggles the build log panel open/closed
- Shows a subtle green dot indicator when the log file exists and is being polled
- Is always visible when an objective is active (even before the build starts)

### Build Log Panel

A **slide-out drawer** that appears from the **bottom** of the main content area (not a modal — it shares space with the task list). Design:

```
┌─────────────────────────────────────────────┐
│ Build Log — build.log (2.4 MB, 45832 lines) │  [prebuild.log ▾]  [Auto ● ] [✕]
├─────────────────────────────────────────────┤
│ CompileSwift normal arm64 ...               │
│ CompileSwift normal arm64 ...               │
│ Linking DoximityX                           │
│ Build Succeeded                             │
│                                    ▼ pinned │
└─────────────────────────────────────────────┘
```

**Styling (match existing theme exactly):**
- Background: `var(--card)` or slightly darker (`#16181d`)
- Font: `monospace`, 12px, `var(--muted)` color for log lines
- Header: same style as other panel headers
- Max height: 40vh (with resize handle? — optional, skip for v1)
- Scrollable content area with `overflow-y: auto`
- Auto-scroll to bottom when new content arrives AND user is already at bottom (don't scroll if they scrolled up to read)

**States:**
1. **No file** — Show: "No build log yet. Run a build to see output here." with a subtle terminal icon
2. **Loading** — Brief spinner/skeleton
3. **Content** — Log lines rendered, auto-scroll pinned to bottom
4. **Error** — "Failed to read build log" with retry button

**Auto-refresh toggle:**
- Toggle switch labeled "Auto" with a green dot when active
- When ON: polls `GET /api/objectives/{id}/build-log?lines=200` every **3 seconds**
- When OFF: no polling (manual refresh via a small refresh icon button)
- Default: OFF (user turns it on when they start a build)
- Polling STOPS automatically when the panel is closed
- Use `setInterval` / `clearInterval`, nothing fancy

**File switcher:**
- Small dropdown or tab buttons to switch between `build.log` and `prebuild.log`
- Default to `build.log`

**Smart scrolling:**
- Track if user has scrolled up: `el.scrollTop + el.clientHeight < el.scrollHeight - 20`
- If at bottom: auto-scroll on new content
- If scrolled up: don't auto-scroll, show a "⬇ New output" floating badge that scrolls to bottom on click

### JavaScript

Add to the existing orchestrator.html script:

```javascript
// State
state.buildLogOpen = false;
state.buildLogAuto = false;
state.buildLogFile = 'build.log';
state.buildLogData = null;
state.buildLogInterval = null;

// Functions needed:
// toggleBuildLog() — open/close panel
// fetchBuildLog() — GET request, update state.buildLogData, call renderBuildLog()
// renderBuildLog() — update DOM: header info, log lines, scroll behavior
// startBuildLogPoll() / stopBuildLogPoll() — manage setInterval
// setBuildLogFile(filename) — switch between build.log and prebuild.log
```

Keep it consistent with existing patterns in the file (vanilla JS, no frameworks, fetch API, same naming conventions).

## File Changes Summary

| File | Changes |
|------|---------|
| `server.py` | Add `GET /api/objectives/{id}/build-log` endpoint |
| `orchestrator.html` | Add CSS for build log panel, HTML container, JS logic |

**Do NOT modify:** `objectives.py`, `orchestrator.py`, `engine.py`, `cmux_api.py`

## Testing

After implementation, verify:
1. Endpoint returns `exists: false` when no `.build/build.log` exists
2. Endpoint returns tail lines correctly for a large file
3. Panel opens/closes smoothly
4. Auto-refresh toggle starts/stops polling
5. File switcher works between build.log and prebuild.log
6. No path traversal possible (reject filenames other than the two allowed)
7. Smart scroll: doesn't jump when user scrolled up, shows "new output" badge
