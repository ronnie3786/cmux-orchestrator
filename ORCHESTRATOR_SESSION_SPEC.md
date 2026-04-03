# Orchestrator Session Spec: Persistent Claude Code Session per Objective

## Overview

Replace the stateless `claude --print` chat fallback with a persistent Claude Code session per objective. This session lives from objective creation through completion and beyond (with idle timeout), giving the user a stateful, tool-capable assistant that can answer questions, run commands, open folders, check diffs, commit/push code, etc.

## Lifecycle

### 1. Objective Created
- Create a Claude Code workspace via `_create_worker_workspace()` with title like `"Orchestrator: <goal[:40]>"`
- CWD = objective's worktree path
- Wait for REPL ready via `_wait_for_repl()`
- Send an initial system prompt (see below) to give Claude Code context
- Store `orchestratorSessionId` (workspace UUID) on the objective JSON
- Log event: `orchestrator_session_started`

### 2. During Planning & Execution
- Session stays alive, idle in the background
- User messages route to it via `send_prompt_to_workspace()`
- Session can read files in the worktree: `objective.json`, `plan.md`, task dirs, `progress.md`, `result.md`
- Python engine continues driving the pipeline (planning, task launching, monitoring, reviews) - no change there

### 3. On Objective Completion
- 60-minute idle timer starts (tracked via `orchestratorLastActivityAt` on objective JSON)
- User messages reset the timer
- Session can handle follow-ups: questions, commits, pushes, opening folders, checking diffs

### 4. Idle Timeout (60 min)
- Background sweep thread checks all objectives every 60 seconds
- If `orchestratorSessionId` exists AND `orchestratorLastActivityAt` is older than 60 minutes AND status is `completed` or `failed`:
  - Send `/exit` to the session
  - Close workspace via `workspace.close`
  - Set `orchestratorSessionActive` to `false` on objective (keep `orchestratorSessionId` for resume)
  - Log event: `orchestrator_session_idle_shutdown`

### 5. User Returns After Shutdown
- `handle_human_input` checks if `orchestratorSessionActive` is `false`
- Append system message: "Resuming orchestrator session..."
- Create new workspace, wait for REPL, send context prompt
- Update `orchestratorSessionId` with new workspace UUID, set `orchestratorSessionActive` to `true`
- Then send the user's message
- Log event: `orchestrator_session_resumed`

## Implementation Details

### New fields on objective JSON
```json
{
  "orchestratorSessionId": "<workspace-uuid>",
  "orchestratorSessionActive": true,
  "orchestratorLastActivityAt": "<iso-timestamp>"
}
```

### Initial Context Prompt
When the orchestrator session starts (or resumes), send this prompt:
```
You are the orchestrator assistant for this objective. Your role is to help the user understand and interact with the work being done.

Objective: <goal>
Status: <status>
Project: <projectDir>
Branch: <branchName>
Worktree: <worktreePath>

You are running inside the objective's worktree. You can:
- Read files to answer questions about the code and work done
- Check objective.json for task statuses
- Run git commands (status, diff, log, commit, push)
- Open folders in Finder (open .)
- Check task progress in tasks/*/progress.md and tasks/*/result.md

The objective has these tasks:
<for each task: "- task.id: task.title [task.status] (reviewCycles: N)">

When answering questions, be concise and helpful. If the user asks about status, read objective.json for the latest state.
```

### Changes to handle_human_input (orchestrator.py)

Replace the current Haiku fallback (the block we just added) with:

```python
# Route to orchestrator session
orchestrator_ws = objective.get("orchestratorSessionId")
is_active = objective.get("orchestratorSessionActive", False)

if not orchestrator_ws or not is_active:
    # Need to start/resume the session
    self._append_message(objective_id, "system", "Resuming orchestrator session...")
    orchestrator_ws = self._start_orchestrator_session(objective_id)
    if not orchestrator_ws:
        self._append_message(objective_id, "alert", "Could not start orchestrator session.")
        return

# Send user message to the session
cmux_api.send_prompt_to_workspace(orchestrator_ws, message)

# Update last activity timestamp
objectives.update_objective(objective_id, {
    "orchestratorLastActivityAt": _utc_now_iso()
})

# Start response capture thread
threading.Thread(
    target=self._capture_orchestrator_response,
    args=(objective_id, orchestrator_ws),
    daemon=True,
).start()
```

### New method: _start_orchestrator_session(objective_id)
1. Read objective for goal, status, tasks, worktree path
2. Create workspace via `_create_worker_workspace("Orchestrator: <goal[:40]>", worktree_path, ...)`
3. Wait for REPL via `_wait_for_repl()`
4. Send initial context prompt via `send_prompt_to_workspace()`
5. Wait for Claude Code to process the context (poll for REPL idle)
6. Update objective: `orchestratorSessionId`, `orchestratorSessionActive=True`, `orchestratorLastActivityAt`
7. Return workspace UUID

### New method: _capture_orchestrator_response(objective_id, workspace_uuid)
This polls the workspace screen to detect when Claude Code finishes responding:
1. Wait 2 seconds for response to start
2. Poll every 2 seconds, read workspace screen via `cmux_read_workspace()`
3. Look for the REPL prompt pattern (❯) at the end - means Claude Code finished responding
4. Extract the response text (everything between the user's prompt and the next ❯)
5. Append as assistant message via `_append_message(objective_id, "assistant", response_text)`
6. Log event: `orchestrator_chat_response`

### New method: _idle_sweep() (background thread)
Started once in `__init__` or when first objective is created:
```python
def _idle_sweep(self):
    while True:
        time.sleep(60)
        for obj in objectives.list_objectives():
            if not obj.get("orchestratorSessionActive"):
                continue
            if obj.get("status") not in ("completed", "failed"):
                continue
            last_activity = obj.get("orchestratorLastActivityAt")
            if not last_activity:
                continue
            elapsed = (datetime.now(timezone.utc) - datetime.fromisoformat(last_activity)).total_seconds()
            if elapsed > 3600:  # 60 minutes
                ws = obj.get("orchestratorSessionId")
                if ws:
                    self._close_workspace(obj["id"], ws, "idle_timeout")
                objectives.update_objective(obj["id"], {
                    "orchestratorSessionActive": False
                })
```

### Frontend Changes (orchestrator.html)

1. The typing indicator already works (from previous commit)
2. No major frontend changes needed - assistant messages already render with markdown
3. The "Resuming orchestrator session..." system message will show naturally
4. Consider: add a small session status indicator near the context strip (green dot = session alive, gray = idle/shutdown)

### What NOT to change
- Planning pipeline (stays as-is, uses its own Claude Code session)
- Worker task execution (stays as-is)
- Review system (stays as-is, uses `claude --print`)
- Approval classification (stays as-is)
- Progress monitoring (stays as-is)

## Testing
- Test `_start_orchestrator_session` creates workspace and sets fields
- Test `handle_human_input` routes to orchestrator session when active
- Test `handle_human_input` resumes session when inactive
- Test `_idle_sweep` shuts down sessions after 60 min
- Test `_idle_sweep` does NOT shut down sessions during execution
- Test activity timestamp gets updated on each message
- All existing tests must continue passing
