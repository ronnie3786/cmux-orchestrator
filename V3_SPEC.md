# V3 Review System — Implementation Spec

## Overview

Two major features shipping together:
1. **LLM Review Runner** — automated code review when Claude Code sessions complete
2. **Review Dashboard UI** — dedicated view for browsing review results

## Architecture

```
Session ends → snapshot captured → JSON saved (reviewStatus: "pending")
                                       ↓
                              review runner thread starts
                                       ↓
                              build context package (~2-4K tokens)
                                       ↓
                              send to review backend (configurable)
                                       ↓
                              parse structured response
                                       ↓
                              update JSON file (reviewStatus: "reviewed" or "flagged")
                                       ↓
                              notify dashboard (browser notification)
```

## Review Model Tiers

| Tier | Backend | Model | Speed | Quality |
|---|---|---|---|---|
| Fast | Ollama (local) | qwen3.5:35b-a3b-nvfp4 | ~5-15s | Good |
| Claude | `claude --print` (Max sub) | Sonnet 4 | ~10-20s | Best |

- LM Studio endpoint: `http://100.89.93.84:1234/v1/chat/completions` (OpenAI-compatible)
- Claude CLI: `claude --print -p "prompt"` via subprocess
- Default: Claude if available, fall back to Ollama

## Review Prompt Template

```
You are reviewing code changes made by an AI coding agent (Claude Code).
A session just completed. Review the changes and provide a structured assessment.

Workspace: {workspaceName}
Branch: {branch}
Working directory: {cwd}
Session duration: {duration} seconds
Session cost: {finalCost}
Actions auto-approved: {approvedCount}
Actions flagged for human: {flaggedCount}

── Claude Code's final output (last 50 lines) ──
{terminalSnapshot}

── Git diff summary ──
{gitDiffStat}

── Recent commits ──
{gitLog}

── Full diff ──
{gitDiff}

Respond with ONLY a JSON object:
{
  "summary": "One-line description of what changed",
  "filesChanged": ["list", "of", "files"],
  "linesAdded": number,
  "linesRemoved": number,
  "confidence": "high" | "medium" | "low",
  "issues": ["list of concerns, empty if none"],
  "readyForPR": true | false,
  "recommendation": "Brief recommendation for the developer",
  "highlights": ["Notable good decisions or patterns worth calling out"]
}
```

## Review JSON Structure (updated)

```json
{
  "sessionId": "uuid_timestamp",
  "workspaceIndex": 0,
  "workspaceUuid": "...",
  "workspaceName": "...",
  "completedAt": "ISO timestamp",
  "duration": 340.2,
  "finalCost": "$1.47",
  "terminalSnapshot": "...",
  "gitDiffStat": "...",
  "gitDiff": "...",
  "gitLog": "...",
  "cwd": "/path/to/project",
  "branch": "feature-branch",
  "approvalLog": [...],
  "reviewStatus": "reviewed",
  "reviewModel": "claude",
  "reviewedAt": "ISO timestamp",
  "reviewDuration": 8.3,
  "review": {
    "summary": "One-line description",
    "filesChanged": ["file1.swift", "file2.swift"],
    "linesAdded": 45,
    "linesRemoved": 12,
    "confidence": "high",
    "issues": [],
    "readyForPR": true,
    "recommendation": "Brief recommendation",
    "highlights": ["Notable patterns"]
  }
}
```

reviewStatus values: "pending", "reviewing", "reviewed", "flagged", "error", "skipped", "dismissed"

## Dashboard UI

### View Switcher
Top bar gets two mode buttons: [Command Center] [Reviews (N)]
- Command Center = existing grid view (unchanged)
- Reviews = new review list view
- Badge count shows unreviewed reviews

### Review Card Layout
Each review is a card with:
- Header: confidence dot + workspace name + timestamp + cost
- Summary: one-line LLM description
- Stats: files changed, lines +/-, branch, duration
- Status: Ready for PR / Has Issues / Needs Attention badge
- Issues list (if any, collapsed if >3)
- Recommendation quote
- Actions: [View Diff] [View Terminal] [Rerun Review] [Dismiss]

### Expanded Overlay
Reuses existing overlay with tabs:
- Diff tab: full git diff with syntax highlighting
- Terminal tab: 50-line terminal snapshot
- Approval Log tab: session approval entries

### Filter Bar
- Status filter: All, Ready for PR, Has Issues, Needs Attention, Pending, Error, Dismissed
- Time filter: Today, Last 24h, Last 7 days, All time
- Sort: Newest, Oldest, Most files, Highest cost

### Colors
- High/Ready: --green (#3fb950)
- Medium/Issues: --yellow (#d29922)  
- Low/Attention: --red (#f85149)
- Pending: --purple (#bc8cff)
- Error: --red
- Dismissed: --text-muted

## Settings Additions
- Review Enabled: on/off toggle
- Review Model: dropdown (Ollama models + "LM Studio (27B)" + "Claude (Sonnet 4)")
- Auto-review on complete: on/off

## API Endpoints
- GET /api/reviews — list reviews (sorted newest, gitDiff truncated)
- GET /api/reviews/{session_id} — full review detail
- POST /api/reviews/{session_id}/rerun — re-trigger review with optional model param
- POST /api/reviews/{session_id}/dismiss — set reviewStatus to "dismissed"

## Implementation Order (chunks for Codex)

### Chunk 1: Review Runner Backend
- Review prompt builder
- Ollama review backend (reuse existing connection)
- LM Studio review backend (OpenAI-compatible HTTP)
- Claude CLI review backend (subprocess)
- _run_review() method on HarnessEngine
- Wire into _capture_completion_snapshot() 
- reviewStatus state machine
- Review config (reviewEnabled, reviewModel) in settings persistence

### Chunk 2: API Endpoints
- POST /api/reviews/{id}/rerun
- POST /api/reviews/{id}/dismiss
- POST /api/config additions for review settings
- GET /api/models updated to include LM Studio and Claude options

### Chunk 3: View Switcher + Review Cards
- Top bar view switcher (Command Center | Reviews)
- Review card HTML generation
- Card states (pending, reviewing, reviewed, flagged, error, skipped, dismissed)
- Confidence badges and colors
- Issues list rendering

### Chunk 4: Filter Bar + Review Card Actions
- Status/time/sort filter dropdowns
- JS-side filtering logic
- Rerun Review button (with model picker)
- Dismiss button
- View Diff / View Terminal buttons (opens expanded overlay)

### Chunk 5: Expanded Overlay Tabs
- Tab switcher (Diff | Terminal | Approval Log)
- Diff view with syntax highlighting (reuse colorize, add diff-specific styling)
- Terminal view (reuse existing colorize)
- Approval log view (table/list of entries)

### Chunk 6: Notifications + Polish
- Browser notification on review complete
- Tab title badge includes review count
- Review count in top bar
- Settings modal: review section (enable, model picker, auto-review toggle)
- Refresh loop for reviews view

---

## Future Enhancements

### Onboarding Flow
First-time setup experience for new users: project directory picker, initial config walkthrough, and a sample objective to demonstrate the review pipeline.

### Async Workspace Open with Loading State

**Problem:** When a user clicks "Open" for a workspace, the sidebar item does not appear until the cmux session has started and Claude Code is running. This can take several seconds and looks like nothing is happening — the UI feels stuck.

**Solution:** Make workspace startup fully async from the UI's perspective.

**Behavior:**
1. User clicks "Open" and submits the form
2. `POST /api/workspaces/<id>/start` is called immediately
3. The workspace item appears in the sidebar right away (no waiting)
4. The chat area shows a loading spinner while the session initializes
5. Frontend polls `GET /api/workspaces/<id>` until `status === "active"`
6. Once active, the spinner is replaced with the ready message: "Workspace ready. Ask about the codebase or make a change."

**Implementation notes:**
- The sidebar render should treat a workspace with `status: "starting"` as a valid, selectable item — just with a loading indicator in the chat panel instead of a message thread
- The "Open" button should enter a submitting state and return to normal after the workspace is persisted (not after Claude is ready)
- No changes needed to the backend start endpoint — this is purely a frontend async/polling change
