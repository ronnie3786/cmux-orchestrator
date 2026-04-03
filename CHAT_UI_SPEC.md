# Chat UI Spec — cmux Orchestrator Frontend

*The "cowork" interface layer on top of the orchestrator engine*

---

## Overview

Replace the current `dashboard.html` (2363-line session monitoring view) with a **chat-first orchestrator UI**. The user gives goals in natural language, sees live progress as structured cards in a chat timeline, and can intervene at any point. Think "ChatGPT meets CI dashboard" — conversational input, structured output.

**Design reference:** `mockups/option-e-cowork.html` — this is the approved visual direction. Match its layout, colors, typography, and card designs exactly.

---

## Architecture

**Single-file SPA** served from `cmux_harness/static/dashboard.html`. No build step, no React, no npm. Vanilla JS + CSS in one HTML file (matching the current approach). The backend is already running at `http://localhost:4280` with all needed API endpoints.

**Why single-file:** cmux-harness is a Python project with no JS toolchain. The current dashboard is a single HTML file and that works well. Keep it that way.

---

## Layout (3 regions)

Matches `option-e-cowork.html` exactly:

```
┌──────────┬────────────────────────────────────────────────┐
│          │  Context Strip (42px)                          │
│ Sidebar  ├────────────────────────────────────────────────│
│ (240px)  │                                                │
│          │              Messages Area                     │
│ Objective│         (scrollable, centered 720px)           │
│   List   │                                                │
│          │                                                │
│          ├────────────────────────────────────────────────│
│          │  Input Area (textarea + send button)           │
└──────────┴────────────────────────────────────────────────┘
```

### Sidebar
- **Logo:** `⌘ cmux` (top left)
- **"New objective" button:** Opens inline form (project dir selector + goal textarea)
- **Objective list:** Scrollable. Each item shows:
  - Status dot (pulsing blue = running, green = done, gray = queued, red = failed)
  - Goal text (2-line clamp)
  - Progress bar + "N of M done" text
  - Click to select → loads that objective's messages in the main area
- **Bottom:** "⬡ Terminal sessions" link (opens existing session view, or just a placeholder for now)

### Context Strip
- Shows the currently selected objective's status dot, goal text, elapsed time, task count, and status badge

### Messages Area
- Centered column (max-width 720px), scrolls vertically
- Messages are displayed as a chat timeline with user messages on the right and system messages on the left
- Auto-scrolls to bottom on new messages (unless user has scrolled up)

### Input Area
- Textarea with placeholder "Give it a goal, ask what's happening, or just wait…"
- Send button (arrow up icon)
- Hint text below: "cmux will update you as tasks complete"
- **When no objective is selected:** Input creates a new objective (needs project dir, or uses a default)
- **When an objective is running:** Input sends a message to the orchestrator via `POST /api/objectives/{id}/message`

---

## Message Types → Card Rendering

The orchestrator emits messages via `GET /api/objectives/{id}/messages`. Each message has a `type` field. Render each type as a distinct card:

### `user` → User bubble
- Right-aligned, blue background (`var(--blue-d)`, border `var(--blue-b)`)
- Avatar: circle with user initial, purple gradient background
- Shows timestamp

### `system` → System message (text)
- Left-aligned, dark raised background
- Avatar: `⌘` in a circle
- Plain text bubble
- **Filtering:** Skip noisy auto-approval messages in the chat view. Only show the first auto-approval for each task, then collapse subsequent ones into a count badge: "Task task-2: 8 permissions auto-approved"

### `plan` → Plan card
- Structured card showing all tasks with status icons:
  - ✓ green circle = completed
  - ● blue pulsing circle = executing
  - – gray circle = queued
  - ✕ red circle = failed
- Each row shows: icon, task title, status text (time for done, "cp N/M" for executing, "waiting" for queued)
- **This card is LIVE** — it updates in place as task statuses change (re-render when new data arrives)
- Header: "📋 Plan · N tasks"

### `progress` → Progress update card
- Left-bordered card (3px blue left border, rounded right corners)
- Shows: task label, checkpoint badge ("checkpoint N of M"), elapsed time
- Description line in monospace font
- Checkpoint pip dots (green = done, blue = active, gray = pending)

### `review` → Review card
- If review passed: green border, "✓ Review passed" badge
  - Shows summary, file stats (+lines / -lines), files changed count
  - Buttons: "Accept & merge" (green), "View diff" (outline)
- If review failed/rework: amber border, "⚠ Issues found" badge
  - Shows issues list
  - Shows "Sending back for fixes (cycle N/M)"

### `alert` → Alert card
- Red-tinted background, red left border
- Shows alert content prominently
- Used for: stuck tasks, failed tasks, planning errors

### `completion` → Completion card
- Green background tint, green border
- Checkmark icon
- Title: "Objective complete!"
- Body: summary text, task count, rework count

### `approval` → Approval request card
- Amber background tint
- Shows the screen preview of what needs approval
- Two buttons: "Approve" (sends Enter via API) and "Deny" / "Take over"

---

## Data Flow

### Polling
- Poll `GET /api/objectives` every 5 seconds to update sidebar
- Poll `GET /api/objectives/{id}/messages?after={lastTimestamp}` every 3 seconds for the active objective
- Poll `GET /api/objectives/{id}` every 5 seconds for task status updates (to update the live plan card)

### Creating an Objective
When user types a goal and hits send with no active objective:
1. Show a project directory picker (dropdown of recent projects, or text input)
2. `POST /api/objectives` with `{ goal, projectDir, baseBranch }`
3. Then `POST /api/objectives/{id}/start` to kick off the pipeline
4. Add it to sidebar, select it, start polling messages

### Sending Messages During Execution
When user types while an objective is running:
- `POST /api/objectives/{id}/message` with `{ message }`
- Show as a user bubble immediately (optimistic)

### Approval Actions
- "Approve" button → `POST /api/objectives/{id}/tasks/{taskId}/approve` with `{ action: "y\n" }`
- "Take over" button → `POST /api/objectives/{id}/message` with `{ message: "take over", context: { task_id, take_over: true } }`

---

## Auto-Approval Message Collapsing

The orchestrator generates a LOT of "auto-approved permission prompt" messages (20-40 per run). These are noisy in a chat view. Implement collapsing:

1. When rendering messages, group consecutive auto-approval messages for the same task
2. Show the first one as a small inline badge: "🔓 Task task-2: auto-approved 1 permission"
3. As more approvals come in for the same task, update the count in-place: "🔓 Task task-2: auto-approved 8 permissions"
4. Only show this badge once per task per "burst" (reset when a non-approval message for that task appears)
5. Style: very compact, monospace, muted color (`var(--t3)`), no avatar — just an inline annotation

---

## New Objective Flow

When user clicks "New objective" or types in the input with no active objective:

### Step 1: Project Selection
Show a modal or inline form with:
- **Project directory** text input with autocomplete (or just a text field that accepts a path)
- **Base branch** dropdown/text (default: "main")
- Hint: "Paste a project path, e.g. ~/projects/my-app"

### Step 2: Goal Input
- Auto-focus the main chat input
- User types their goal and hits send
- This creates the objective and starts the pipeline

### Shortcut
If user has already worked on a project recently, pre-fill the project dir from the most recent objective's `projectDir`.

---

## Styles

Copy ALL CSS from `mockups/option-e-cowork.html` directly. The color system, typography, spacing, card designs, and animations are already defined there. Key tokens:

```css
--bg:      #111118;
--sidebar: #0d0d13;
--raised:  #1a1a24;
--hover:   #20202e;
--b:       rgba(255,255,255,0.07);
--b2:      rgba(255,255,255,0.12);
--t1:      #eaeaf8;  /* primary text */
--t2:      #7878a0;  /* secondary text */
--t3:      #3e3e58;  /* muted text */
--blue:    #4f8ef7;  /* active/running */
--green:   #34d399;  /* success/done */
--amber:   #fbbf24;  /* warning/review */
--red:     #f87171;  /* error/failed */
```

Fonts: Inter (UI) + JetBrains Mono (code/status)

---

## API Endpoints (already exist)

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/objectives` | List all objectives |
| `GET` | `/api/objectives/{id}` | Get single objective with tasks |
| `GET` | `/api/objectives/{id}/messages` | Get message stream (supports `?after=` for incremental) |
| `GET` | `/api/objectives/{id}/tasks/{taskId}/screen` | Get worker terminal screen |
| `POST` | `/api/objectives` | Create objective `{ goal, projectDir, baseBranch }` |
| `POST` | `/api/objectives/{id}/start` | Start the pipeline |
| `POST` | `/api/objectives/{id}/message` | Send user message / human input |
| `POST` | `/api/objectives/{id}/tasks/{taskId}/approve` | Approve a permission prompt |

---

## Implementation Notes

1. **No framework.** Vanilla JS, template literals for rendering, `fetch()` for API calls. This matches the existing codebase.

2. **State management.** Keep it simple — a few top-level variables:
   ```js
   let objectives = [];           // sidebar list
   let activeObjectiveId = null;  // currently selected
   let activeObjective = null;    // full objective data with tasks
   let messages = [];             // messages for active objective
   let lastMessageTimestamp = null; // for incremental polling
   ```

3. **Rendering.** Use a `render()` function that rebuilds the DOM from state. For performance, only re-render sections that changed (sidebar, messages, plan card).

4. **Auto-scroll.** Track whether user has scrolled up. If they're at the bottom (within 100px), auto-scroll on new messages. If they've scrolled up, don't.

5. **Textarea auto-resize.** Grow the textarea as user types (up to max-height 140px), shrink when cleared.

6. **Keyboard shortcuts.** Enter to send (Shift+Enter for newline). Cmd+N for new objective.

7. **Plan card updates.** The plan card should update in-place when task statuses change. Don't add a new plan card message — update the existing one. Read task statuses from `activeObjective.tasks`.

8. **Timestamps.** Show relative times ("just now", "2m ago", "1h ago"). Update every 30s.

9. **Empty state.** When no objectives exist, show a centered welcome message: "Give me a goal and a codebase — I'll break it down and build it." with a prominent input field.

10. **File size target:** Under 3000 lines. The mockup CSS is ~400 lines, so budget ~400 CSS + ~2600 JS/HTML.

---

## What NOT to Build (out of scope)

- Terminal session viewer (the "⬡ Terminal sessions" link can be a dead link for now)
- Settings/config panel
- Diff viewer (the "View diff" button can open in a new tab or be a placeholder)
- Authentication
- Multiple simultaneous users
- Mobile/responsive layout
- Dark/light theme toggle (it's always dark)

---

## Testing

After building, verify with the smoke test workflow:
1. Start the server: `cd ~/.openclaw/workspace/cmux-harness && python3 -m cmux_harness`
2. Open `http://localhost:4280` in Chrome
3. Click "New objective"
4. Enter project: `~/projects/ai-101-landing`
5. Enter goal: "Add a dark mode toggle button to the navigation bar"
6. Watch the chat timeline populate with plan → progress → review → completion cards
7. Verify auto-scroll works, approval collapsing works, and the plan card updates live

---

## File to Create

`cmux_harness/static/orchestrator.html` — new file for the orchestrator chat UI.

The server serves this at `/orchestrator` (already wired up). The existing dashboard at `/` is untouched.

**Do NOT modify `dashboard.html` or `server.py`** — they are already set up correctly.
