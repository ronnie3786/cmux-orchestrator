# Integration Layer Spec — Wiring It All Together

*The final piece: an `Orchestrator` class that connects the building blocks into an end-to-end pipeline.*
*Created: 2026-04-02*

---

## Overview

We have 7 new modules (claude_cli, objectives, planner, approval, workspace_mutex, worker, monitor) but nothing connecting them. The integration layer is a single new file (`cmux_harness/orchestrator.py`) plus API endpoints and modifications to `engine.py` to hook the orchestrator into the existing polling loop.

**The goal:** Ronnie sends a POST to `/api/objectives` with a goal → the system plans, executes, monitors, reviews, reworks, and reports back. All coordinated through the orchestrator.

---

## Architecture

```
                                    ┌─────────────┐
                                    │  Dashboard   │
                                    │  (UI/API)    │
                                    └──────┬───────┘
                                           │ POST /api/objectives/{id}/start
                                           │ GET  /api/objectives/{id}/messages
                                           ▼
┌──────────────────────────────────────────────────────────────────┐
│                        Orchestrator                               │
│                                                                   │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────────┐  │
│  │ Planner  │──▶│ Launcher │──▶│ Monitor  │──▶│ Review/Rework│  │
│  │ Pipeline │   │ (Worker) │   │ Loop     │   │ Cycle        │  │
│  └──────────┘   └──────────┘   └──────────┘   └──────────────┘  │
│       │              │              │                │            │
│       ▼              ▼              ▼                ▼            │
│  planner.py    worker.py      monitor.py       review.py        │
│  claude_cli.py  cmux_api.py   approval.py      claude_cli.py   │
│  objectives.py  workspace_    objectives.py     worker.py       │
│                 mutex.py                                         │
└──────────────────────────────────────────────────────────────────┘
                                           │
                                           ▼
                                    ┌─────────────┐
                                    │  Engine      │
                                    │  (poll loop) │
                                    └─────────────┘
```

---

## New File: `cmux_harness/orchestrator.py`

### Class: `Orchestrator`

```python
class Orchestrator:
    """Manages the full lifecycle of objectives: plan → execute → monitor → review → report."""
    
    def __init__(self, engine: HarnessEngine):
        self.engine = engine
        self.mutex = WorkspaceMutex()
        self._active_objective_id: str | None = None  # single objective for MVP
        self._messages: list[dict] = []  # chat message log for the UI
        self._task_screen_cache: dict[str, str] = {}  # task_id -> last screen text
        self._task_last_progress: dict[str, float] = {}  # task_id -> last progress.md mtime
        self._lock = threading.Lock()
```

### State Machine

The orchestrator drives each objective through a linear state machine:

```
planning → parsing → launching → executing → completed
                                     │
                                     ├── (per-task) executing → reviewing → completed
                                     │                              │
                                     │                              └── rework → executing (loop)
                                     │
                                     └── failed (if unrecoverable)
```

### Core Methods

#### `start_objective(objective_id: str) -> bool`
Entry point. Called when Ronnie hits "Start" on a created objective.

1. Read objective from disk via `objectives.read_objective()`
2. Validate it has a goal and projectDir
3. Set `_active_objective_id`
4. Append a system message: "Starting objective: {goal}"
5. Update objective status to "planning"
6. Launch the planning phase in a daemon thread: `threading.Thread(target=self._run_planning, ...)`
7. Return True

#### `_run_planning(objective_id: str)`
Runs the planner Claude Code session and parses the result.

1. Append message: "🧠 Planning: analyzing codebase and decomposing goal..."
2. Read objective for projectDir
3. **Create a cmux workspace for the planner:**
   - Use `cmux_api._v2_request("workspace.create", {})` (same pattern as new-session in server.py)
   - Rename it to "Planner: {goal[:40]}"
   - Send `cd {projectDir} && claude` to open Claude Code
   - Wait for Claude Code REPL readiness (reuse the polling pattern from server.py `_deliver_prompt`)
   - Send the planning prompt via `cmux_api.send_prompt_to_workspace(uuid, planner.build_planning_prompt(goal))`
   - Set cooldown on the workspace mutex: `self.mutex.set_cooldown(ws_uuid, 5.0)`
4. **Wait for plan.md to appear:**
   - Poll filesystem: check `{projectDir}/plan.md` every 5 seconds
   - Timeout after 5 minutes
   - Also monitor for Claude Code exit (hasClaude → false) as a completion signal
5. **Parse the plan:**
   - Read `{projectDir}/plan.md`
   - Call `planner.parse_plan(plan_text)`
   - If parse succeeded: call `planner.plan_to_tasks(parsed, objective_id)`
   - If parse failed (error dict with raw_plan): append message with raw plan for manual review, set status to "failed"
6. **Update objective:**
   - Write tasks to `objective.json` via `objectives.update_objective()`
   - Update status to "launching"
   - Append message: "📋 Plan ready: {N} tasks identified. Launching workers..."
7. **Clean up planner workspace** (close it, don't need it anymore)
8. **Kick off execution:** call `self._launch_ready_tasks(objective_id)`

#### `_launch_ready_tasks(objective_id: str)`
Find tasks that are `queued` and have all dependencies `completed`, then launch them.

For each launchable task:
1. Create worktree: `worker.create_worktree(projectDir, objective_id, task_id, task_slug, baseBranch)`
2. Create cmux workspace pointing to the worktree
3. Set cooldown: `self.mutex.set_cooldown(ws_uuid, 5.0)`
4. Copy `spec.md` and `context.md` into the worktree root (so Claude Code can read them)
5. Launch Claude Code in the workspace: `cd {worktree_path} && claude`
6. Wait for REPL ready, then send `worker.build_task_prompt(task_id)`
7. Update task status to `executing`, record `workspaceId`, `worktreePath`, `worktreeBranch`, `startedAt`
8. Append message: "🚀 Task {id}: {title} — launched in workspace {name}"

**Parallelism:** Launch ALL ready tasks, not just one. Multiple workers run simultaneously.

**Context assembly for dependent tasks:**
Before launching a task with dependencies, build its `context.md`:
- For each dependency: read its `result.md` and `review.json`
- Call Haiku to summarize: "Summarize the following completed task results for a developer about to start a dependent task"
- Write the summary to `context.md` in the task directory AND the worktree

#### `poll_tasks(objective_id: str)`
Called by the engine polling loop (every cycle). This is the monitoring heartbeat.

For each task in `executing` status:

1. **Check for approval prompts first** (highest priority):
   - Read terminal screen via `cmux_api.cmux_read_workspace()`
   - If screen shows a prompt (use `detection.detect_prompt()` as pre-filter):
     - Read task's `spec.md` for context
     - Call `approval.classify_approval(screen_text, spec_text)`
     - If APPROVE: send keystroke via mutex-protected `cmux_api.cmux_send_to_workspace()`
     - If ESCALATE: append message with the approval card for human action
     - Log the decision
   - **Don't wait for stuck timer. Catch prompts immediately every poll cycle.**

2. **Check completion:**
   - Call `monitor.check_progress(objective_id, task_id, last_check_ts)`
   - If `has_result` is True AND Claude Code exited (hasClaude false):
     - Task is done. Trigger review: `self._run_review(objective_id, task_id)`

3. **Check progress updates:**
   - If `has_progress_update`: update checkpoint statuses in `objective.json`, append message with progress
   - Update `_task_last_progress[task_id]`

4. **Stuck detection** (only if no completion and no progress):
   - Get `has_git_activity` via `monitor.check_git_activity(worktree_path, since_ts)`
   - Compare current screen to `_task_screen_cache[task_id]` for terminal activity
   - Call `monitor.assess_stuck_status(task_state)`
   - If `stalled`: append message alerting Ronnie, include terminal snapshot

#### `_run_review(objective_id: str, task_id: str)`
Runs in a daemon thread after task completion.

1. Update task status to `reviewing`
2. Append message: "🔍 Reviewing Task {id}..."
3. Capture snapshot: terminal last 200 lines + git diff from worktree
4. Build review prompt (reuse `review.build_review_prompt()`)
5. Run review via `claude_cli.run_sonnet()` with the review prompt
6. Parse review result into `review.json`, save to task directory
7. Check `monitor.should_trigger_rework(review_json)`:

   **If review passes:**
   - Increment `reviewCycles`
   - Update task status to `completed`, set `completedAt`
   - Append message: "✅ Task {id}: {title} — review passed"
   - Call `self._launch_ready_tasks(objective_id)` to unblock dependents
   - Check if ALL tasks are completed → if so, run `self._complete_objective(objective_id)`

   **If review finds issues:**
   - Increment `reviewCycles`
   - Check `monitor.can_retry_review(task)`:
     - **Can retry:** Update status to `rework`, extract issues via `monitor.build_review_rework_summary()`, send rework prompt to worker, append message: "🔄 Task {id} review found issues → sending back (cycle {n}/{max})"
     - **Max retries reached:** Update status to `failed`, append message with issues and "Take Over" action

#### `_complete_objective(objective_id: str)`
Called when all tasks are completed.

1. Update objective status to "completed"
2. Generate final summary via Haiku: read all `result.md` files, produce a combined summary
3. Append message: "🎉 Objective complete! {N} tasks done, {M} required rework cycles."
4. Include review cycle stats
5. Leave worktrees in place for Ronnie to merge at his discretion

#### `handle_human_input(objective_id: str, message: str, context: dict | None = None)`
Called when Ronnie sends a message through the chat UI.

Context can include:
- `task_id`: if responding to a specific task's approval card
- `approval_action`: "approve" or specific text to send
- `take_over`: True if claiming a failed task

Actions:
- **Approval response:** Send the keystroke/text to the worker workspace
- **Take over:** Mark task as human-owned, don't auto-monitor anymore
- **General message:** Log it but no automated action (future: could steer the planner)

### Messages Schema

Messages are the chat log that the UI renders. Stored in memory + persisted to `~/.cmux-harness/objectives/{id}/messages.jsonl`.

```python
{
    "id": str,           # UUID
    "timestamp": str,    # ISO
    "type": str,         # "system" | "user" | "plan" | "progress" | "review" | "approval" | "alert" | "completion"
    "content": str,      # Markdown text
    "metadata": dict,    # Type-specific data (task_id, review_json, approval details, etc.)
}
```

Message types:
- **system**: Orchestrator status updates ("Planning...", "Launching workers...")
- **user**: Ronnie's input messages
- **plan**: The parsed plan (rendered as task cards in the UI)
- **progress**: Checkpoint updates from workers
- **review**: Review results (pass/fail, with details)
- **approval**: Escalated approval prompt needing human input (includes terminal context + action buttons)
- **alert**: Stuck detection warnings, errors
- **completion**: Final summary when objective finishes

---

## Engine Integration: `engine.py` Changes

### New State in `HarnessEngine.__init__`:

```python
from .orchestrator import Orchestrator

self.orchestrator = Orchestrator(self)
```

### Hook into the Polling Loop (`run` method):

After the existing workspace read + detection logic, add:

```python
# --- Orchestrator monitoring ---
if self.orchestrator._active_objective_id:
    try:
        self.orchestrator.poll_tasks(self.orchestrator._active_objective_id)
    except Exception as exc:
        storage.debug_log({"event": "orchestrator_poll_error", "error": str(exc)})
```

This runs every poll cycle (every `poll_interval` seconds, default 5s). The orchestrator's `poll_tasks` handles its own internal timing for stuck detection.

### Approval Integration

When the orchestrator is active, approval classification for orchestrated workspaces should go through Haiku (the orchestrator's `poll_tasks` handles this). The existing regex + local model path in `check_workspace` continues to handle non-orchestrated workspaces.

Add a check at the top of `check_workspace`:

```python
# Skip orchestrated workspaces — handled by orchestrator.poll_tasks
if self.orchestrator.is_orchestrated_workspace(ws.get("uuid", "")):
    return
```

And add to Orchestrator:

```python
def is_orchestrated_workspace(self, workspace_uuid: str) -> bool:
    """Check if a workspace UUID belongs to an orchestrated task."""
    if not self._active_objective_id:
        return False
    objective = objectives.read_objective(self._active_objective_id)
    if not objective:
        return False
    for task in objective.get("tasks", []):
        if task.get("workspaceId") == workspace_uuid:
            return True
    return False
```

---

## New API Endpoints in `server.py`

### `POST /api/objectives/{id}/start`
Triggers the orchestrator to begin working on an objective.

```python
# Request: empty body or {}
# Response: {"ok": True, "status": "planning"}
```

Calls `engine.orchestrator.start_objective(objective_id)`.

### `GET /api/objectives/{id}/messages`
Returns the chat message log for an objective.

```python
# Query params: ?after=<timestamp> (optional, for polling)
# Response: [{"id": "...", "timestamp": "...", "type": "system", "content": "...", "metadata": {}}, ...]
```

If `after` is provided, only returns messages with timestamp > after (for incremental polling).

### `POST /api/objectives/{id}/message`
Ronnie sends a message (approval response, take-over, general input).

```python
# Request: {"message": "approve", "context": {"task_id": "task-1", "approval_action": "approve"}}
# Response: {"ok": True}
```

Calls `engine.orchestrator.handle_human_input(objective_id, message, context)`.

### `POST /api/objectives/{id}/tasks/{task_id}/approve`
Quick-action endpoint for approval cards. Sends the appropriate keystroke to the worker.

```python
# Request: {"action": "y"} or {"action": "enter"} or {"action": "text", "value": "some input"}
# Response: {"ok": True}
```

### `GET /api/objectives/{id}/tasks/{task_id}/screen`
Returns the current terminal screen for a specific task's worker.

```python
# Response: {"ok": True, "screen": "...", "lines": 200}
```

---

## Implementation Chunks (for Codex)

### Chunk A: Orchestrator Core + Message System
- `Orchestrator` class with `__init__`, message append/persistence, `is_orchestrated_workspace`
- `start_objective` method (just sets state + kicks off planning thread)
- `messages.jsonl` read/write
- `_append_message` helper
- Tests: message persistence, start_objective state changes, is_orchestrated_workspace

### Chunk B: Planning Pipeline Integration
- `_run_planning` method: create cmux workspace, send planning prompt, poll for plan.md, parse, update objective
- Planner workspace lifecycle (create, wait, parse, cleanup)
- Integration with existing `cmux_api` for workspace creation + prompt delivery
- Tests: mock cmux_api + filesystem to verify planning flow

### Chunk C: Task Launcher
- `_launch_ready_tasks`: dependency resolution, worktree creation, workspace creation, prompt delivery
- Context assembly for dependent tasks (Haiku summarization of prior results)
- Parallelism: launch all ready tasks simultaneously
- Tests: dependency resolution logic, context assembly, mock workspace creation

### Chunk D: Monitoring + Approval Integration
- `poll_tasks`: approval detection (Haiku classifier), completion detection, progress tracking, stuck detection
- Engine integration: hook `poll_tasks` into the run loop, skip orchestrated workspaces in `check_workspace`
- Tests: mock poll cycles, verify approval routing, stuck detection escalation

### Chunk E: Review-Rework Cycle + Completion
- `_run_review`: trigger review, route result (pass vs rework vs escalate)
- Rework prompt delivery back to worker
- `_complete_objective`: final summary generation
- `handle_human_input`: approval responses, take-over
- Tests: review routing logic, rework cycle counting, completion flow

### Chunk F: API Endpoints
- All new endpoints in server.py
- Wire to orchestrator methods
- Tests: HTTP-level tests for each endpoint

---

## Implementation Order

**Chunk A → B → C → D → E → F**

Each chunk builds on the previous. A is the foundation (message system + state management). B adds planning. C adds workers. D adds monitoring. E adds the review loop. F exposes it all to the UI.

---

## What This Spec Does NOT Cover (future work)

- **Chat UI** — The frontend HTML/JS for rendering messages, plan cards, approval cards, progress bars. That's a separate spec (likely a big dashboard.html rewrite or a new page).
- **SSE/WebSocket for real-time updates** — MVP uses polling `/api/objectives/{id}/messages`. SSE is P1 polish.
- **Multiple concurrent objectives** — MVP supports one active objective at a time.
- **Objective cancellation** — Stop an in-progress objective, kill workers, clean up worktrees.
- **Plan editing** — Let Ronnie modify the parsed plan before execution starts.
- **Planner workspace reuse** — Currently creates a new workspace per planning session. Could reuse one.

---

## Testing Strategy

All orchestrator tests should:
- Mock `cmux_api` calls (no real socket needed)
- Mock `claude_cli` calls (no real Claude needed)
- Use `tmp_path` / `tempfile` for filesystem operations (never write to real `~/.cmux-harness/`)
- Mock `threading.Thread` to run synchronously where needed
- Test state transitions, message generation, and error handling

The existing 146 tests must continue to pass unchanged.

---

## Risk Notes

1. **Planner workspace creation** is the most complex part. It reuses patterns from `server.py`'s `new-session` endpoint, but the orchestrator needs to do it programmatically rather than via HTTP. Consider extracting the workspace creation logic into a shared helper.

2. **Thread safety.** The orchestrator is called from the engine's polling loop (one thread) but also spawns daemon threads for planning and review. The `_lock` must protect `_messages`, `_active_objective_id`, and `_task_*` caches. Message persistence (JSONL append) should be atomic.

3. **Planner waiting for plan.md** has a race condition: the planner Claude Code session might write plan.md incrementally (partial writes). The orchestrator should check for both file existence AND Claude Code exit (hasClaude → false) before reading.

4. **Worktree path collisions.** If the same objective is restarted, worktree paths might already exist. `worker.create_worktree` should handle the `--force` case or clean up first.
