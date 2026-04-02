# Orchestrator Spec V2 — "The Tech Lead" + Filesystem Coordination

*Combined approach: Woz's filesystem coordination core + Ashley's orchestration layer*
*Approved by Ronnie: 2026-04-02*

---

## Vision

An orchestrator layer on top of cmux-harness that manages Claude Code sessions autonomously. Ronnie gives it a high-level goal, it plans the work, spins up parallel Claude Code workers in git worktrees, monitors progress, and reports back. All coordination happens through the filesystem, not terminal scraping.

---

## Environment Constraints

| Resource | Available | Notes |
|----------|-----------|-------|
| Claude Code | ✅ | v2.1.90, subscription auth |
| `claude --print --model haiku` | ✅ | Confirmed working, cheap one-shot prompts |
| `claude --print` (Sonnet) | ✅ | Higher quality for reviews |
| API keys | ❌ | Not available |
| OpenClaw | ❌ | Not allowed on work machines |
| Local models | ✅ | Ollama (48GB work Mac) + Mac Studio (Tailscale) |
| cmux socket API | ✅ | Full v2 JSON-RPC, automation mode |
| Git worktrees | ✅ | Already part of Ronnie's workflow |

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                      Dashboard UI                         │
│  ┌───────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Chat Panel │  │ Objective    │  │ Session Cards     │  │
│  │ (input)    │  │ Status Board │  │ (existing)        │  │
│  └─────┬─────┘  └──────┬───────┘  └───────┬───────────┘  │
│        └────────────────┼──────────────────┘              │
│                    ┌────▼─────────────────┐               │
│                    │  Orchestrator Engine  │               │
│                    │  ┌────────────────┐  │               │
│                    │  │ State Machine  │  │               │
│                    │  │ + Safety Loop  │  │               │
│                    │  └───────┬────────┘  │               │
│                    └──────────┼───────────┘               │
└───────────────────────────────┼───────────────────────────┘
                                │
         ┌──────────────────────┼──────────────────────┐
         │                      │                      │
    ┌────▼──────┐    ┌─────────▼────────┐    ┌───────▼───────┐
    │ Planner   │    │ Worker Session 1 │    │ Worker Sess 2 │
    │ (Claude   │    │ (Claude Code in  │    │ (Claude Code  │
    │  Code)    │    │  git worktree)   │    │  in worktree) │
    └───────────┘    └──────────────────┘    └───────────────┘
         │                    │                       │
         ▼                    ▼                       ▼
    ~/.cmux-harness/objectives/<uuid>/
    ├── objective.json
    ├── plan.md
    └── tasks/
        ├── task-1/
        │   ├── spec.md
        │   ├── context.md
        │   ├── progress.md    ← live progress updates
        │   ├── result.md
        │   └── review.json
        └── task-2/
            ├── spec.md
            ├── context.md
            ├── progress.md
            ├── result.md
            └── review.json
```

---

## LLM Architecture

| Role | Method | Model | Job |
|------|--------|-------|-----|
| **Orchestrator brain** | `claude --print --model haiku` | Haiku | Parse plans, manage queue, generate progress summaries |
| **Planner** | Claude Code session (interactive) | Sonnet (default) | Read codebase, decompose goals into task plans with checkpoints |
| **Workers** | Claude Code sessions (interactive) | Sonnet (default) | Execute coding tasks, write progress updates, produce results |
| **Session reviews** | `claude --print` | Sonnet (default) | Review completed work, assess quality, flag issues |

---

## Filesystem Structure

Every objective gets a self-contained directory. This is the source of truth for all orchestration state. Everything is human-readable, debuggable, and survives harness restarts.

```
~/.cmux-harness/objectives/
└── <uuid>/
    ├── objective.json          # Goal, status, metadata, task index
    ├── plan.md                 # Raw planner output
    └── tasks/
        └── <task-id>/
            ├── spec.md         # What to do (written by orchestrator from plan)
            ├── context.md      # Context from dependencies (assembled by orchestrator)
            ├── progress.md     # Live progress log (written by worker incrementally)
            ├── result.md       # Final summary (written by worker on completion)
            ├── review.json     # LLM review output
            └── worktree/       # Git worktree path reference
```

### objective.json

```json
{
  "id": "uuid",
  "goal": "Fix the auth token refresh bug in IOSDOX-24739",
  "status": "executing",
  "projectDir": "/Users/ronnie/Doximity/ios-app",
  "baseBranch": "main",
  "createdAt": "ISO timestamp",
  "updatedAt": "ISO timestamp",
  "plannerWorkspaceId": "cmux-workspace-uuid",
  "tasks": [
    {
      "id": "task-1",
      "title": "Fix token expiry check in TokenManager.swift",
      "status": "completed",
      "dependsOn": [],
      "workspaceId": "cmux-workspace-uuid",
      "worktreePath": "/path/to/worktree",
      "worktreeBranch": "orchestrator/task-1-token-expiry",
      "checkpoints": [
        { "name": "Read and understand current implementation", "status": "done" },
        { "name": "Implement expiry check", "status": "done" },
        { "name": "Add retry logic", "status": "done" },
        { "name": "Run tests", "status": "done" }
      ],
      "startedAt": "ISO timestamp",
      "completedAt": "ISO timestamp",
      "lastProgressAt": "ISO timestamp"
    },
    {
      "id": "task-2",
      "title": "Add unit tests for token refresh",
      "status": "executing",
      "dependsOn": ["task-1"],
      "checkpoints": [
        { "name": "Review task-1 changes", "status": "done" },
        { "name": "Write test cases for happy path", "status": "in-progress" },
        { "name": "Write test cases for error paths", "status": "pending" },
        { "name": "Verify all tests pass", "status": "pending" }
      ],
      "lastProgressAt": "ISO timestamp"
    }
  ]
}
```

### Task Status Values
- `queued` — waiting for dependencies or capacity
- `launching` — workspace + worktree being created
- `executing` — Claude Code running
- `completed` — finished, review pending or done
- `failed` — session died or stuck, needs intervention
- `blocked` — dependency not met

### Checkpoint Status Values
- `pending` — not started
- `in-progress` — currently working on this
- `done` — completed
- `skipped` — determined unnecessary during execution

---

## Flow (detailed)

### Phase 1: Goal Input
1. Ronnie types a goal in the dashboard chat panel
2. Orchestrator creates objective directory: `~/.cmux-harness/objectives/<uuid>/`
3. Writes `objective.json` with status `planning`

### Phase 2: Planning
4. Orchestrator creates a Planner workspace:
   ```
   cmux new-workspace --name "Plan: [goal summary]" --cwd [project-dir] --command "claude"
   ```
5. Sends the planning prompt via `surface.send_text`:
   ```
   I need you to create a detailed implementation plan for this goal:

   [goal text]

   For each task in the plan, provide:
   1. A clear title
   2. What files will likely be involved
   3. Which other tasks it depends on (by number), or "none" if independent
   4. A list of 3-5 checkpoints (milestones within the task) that represent
      meaningful progress. These should be ordered steps where each one
      produces a verifiable result.

   Format each task as:

   ## Task N: [title]
   - Files: [list]
   - Depends on: [task numbers or "none"]
   - Checkpoints:
     1. [checkpoint description]
     2. [checkpoint description]
     ...

   Important: Tasks that don't depend on each other CAN run in parallel.
   Design the plan to maximize parallelism where safe.
   ```
6. Monitor planner via `surface.read_text` until Claude Code exits
7. Save raw output to `plan.md`
8. Orchestrator brain (Haiku) parses `plan.md` into structured tasks:
   ```
   claude --print --model haiku -p "Parse this plan into JSON: [plan.md contents]
   Return: {tasks: [{id, title, files, dependsOn, checkpoints}]}"
   ```
9. For each task, create `tasks/<task-id>/spec.md` with the task details
10. Update `objective.json` with the full task list

### Phase 3: Execution
11. Orchestrator evaluates which tasks are ready (dependencies met, capacity available)
12. For each ready task:

    **a. Create git worktree:**
    ```bash
    cd [project-dir]
    git worktree add [objectives-dir]/tasks/[task-id]/worktree orchestrator/[task-id]-[slug]
    ```

    **b. Create cmux workspace:**
    ```
    cmux new-workspace --name "Task: [title]" --cwd [worktree-path] --command "claude"
    ```

    **c. Send task prompt via `surface.send_text`:**
    ```
    You have a specific task to complete. Here are your instructions:

    Read ./spec.md for your full task description.
    Read ./context.md for relevant context from prior completed tasks (if it exists).

    IMPORTANT — Progress tracking:
    As you work, update ./progress.md after completing each major step.
    Use this format:

    ## Checkpoint: [name]
    **Status:** Done
    **What I did:** [2-3 sentence summary]
    **Files touched:** [list]

    This lets the orchestrator track your progress. Update progress.md
    BEFORE moving to the next checkpoint, not all at the end.

    When you are completely finished with everything in spec.md:
    1. Make sure all changes are committed to your branch
    2. Write a final summary to ./result.md covering:
       - What was accomplished
       - Files changed and why
       - Any issues encountered
       - Suggestions for follow-up work
    3. Then you can exit
    ```

    **d. Update task status to `executing`**

### Phase 4: Monitoring (Safety Loop)

The existing harness polling loop continues running. On top of Claude detection and auto-approve, it now also checks orchestrated tasks:

**Every 30 seconds for executing tasks:**
1. Read `progress.md` via filesystem (NOT terminal scraping)
2. Compare last checkpoint timestamp to now
3. If progress.md was updated recently → worker is making progress, all good
4. If progress.md hasn't been updated in >5 minutes:
   - Read terminal screen via `surface.read_text`
   - Check if Claude Code is stuck on a prompt (waiting for user input)
   - If stuck on prompt → auto-approve handles it (already built)
   - If idle/no Claude → session may have crashed, mark as `failed`
   - If actively processing → just slow, extend the timer
5. Parse checkpoints from progress.md, update `objective.json` checkpoint statuses
6. Push status updates to dashboard UI

**Stuck detection thresholds:**
- 5 min no progress update → yellow warning in dashboard
- 10 min no progress update → check terminal for stuck prompt
- 15 min no progress update + no terminal activity → mark failed, alert Ronnie

### Phase 5: Completion + Review
13. Worker completes → writes `result.md` → exits Claude Code
14. Harness detects `hasClaude: true → false` (existing detection)
15. Orchestrator checks for `result.md` existence as confirmation
16. Run review via `claude --print`:
    - Input: `spec.md` + `result.md` + `git diff` from worktree
    - Output: `review.json`
17. Update task status to `completed`
18. Assemble `context.md` for dependent tasks:
    - Haiku reads `result.md` + `review.json` from completed dependency
    - Writes a summary into dependent task's `context.md`
19. Check if newly unblocked tasks exist → launch them (back to Phase 3)

### Phase 6: Reporting
20. Dashboard shows objective status board:
    - Task list with checkpoint progress bars
    - Active worker session cards (existing UI)
    - Completed task reviews
    - Overall objective progress
21. When all tasks complete:
    - Final summary generated by Haiku from all `result.md` files
    - Notification to Ronnie: "Objective complete. N tasks done. Review pending."
    - Ronnie merges worktree branches at his discretion

---

## Incremental Progress Tracking (Critical Feature)

### The Problem
A worker could run for 30+ minutes on a complex task. If it crashes at 75% progress, we lose everything. We also can't tell Ronnie what's happening during long tasks.

### The Solution: Checkpoint-Based Progress

The planner breaks each task into 3-5 checkpoints. These aren't arbitrary progress markers — they're meaningful milestones where the worker has produced a verifiable result.

Example for "Fix token refresh bug":
1. ✅ Read and understand current implementation
2. ✅ Implement expiry check and retry logic
3. 🔄 Write unit tests for new behavior
4. ⬜ Run full test suite and fix failures

The worker writes to `progress.md` after each checkpoint. The orchestrator reads this file to:
- Show real-time progress in the dashboard
- Detect stuck workers (no update in >5 min)
- Know where to resume if a worker crashes (re-launch with "continue from checkpoint 3")

### Crash Recovery

If a worker dies mid-task:
1. Orchestrator reads `progress.md` to see which checkpoints are done
2. The git worktree still has all committed changes up to the crash point
3. Orchestrator creates a new worker session in the same worktree
4. Sends a recovery prompt:
   ```
   You are resuming a task that was interrupted. 
   Read ./spec.md for the full task.
   Read ./progress.md to see what was already completed.
   Continue from where the previous session left off.
   Do NOT redo completed checkpoints.
   Continue updating ./progress.md as you work.
   ```
5. Worker picks up where it left off, no work lost

---

## What's Already Built (reuse map)

| Component | Status | Reuse |
|-----------|--------|-------|
| Workspace creation | ✅ Built | Direct — `POST /api/new-session` creates cmux workspace |
| Claude detection | ✅ Built | Direct — `detect_claude_session()` for completion |
| Auto-approve | ✅ Built | Direct — keeps workers unblocked |
| Session completion capture | ✅ Built | Adapt — trigger review from `result.md` instead of screen |
| Review system | ✅ Built | Direct — `claude --print` backend confirmed working |
| Monitoring loop | ✅ Built | Extend — add progress.md file watching + stuck detection |
| Dashboard UI framework | ✅ Built | Extend — add chat panel + objective status board |
| Persistent config | ✅ Built | Extend — add objective storage |

## What's New to Build

| Component | Description | Complexity | Priority |
|-----------|-------------|-----------|----------|
| Objective manager | Create/track objectives, filesystem structure | Medium | P0 |
| Planner session manager | Launch planner, capture output to plan.md | Medium | P0 |
| Plan parser | Haiku prompt to extract structured tasks from plan.md | Medium | P0 |
| Task launcher | Create worktree + workspace, send task prompt | Medium | P0 |
| Progress watcher | Poll progress.md files, update objective.json | Low | P0 |
| Stuck detection | Timer-based alerts when progress stalls | Low | P0 |
| Context assembler | Build context.md from completed dependency results | Low | P1 |
| Crash recovery | Detect failed tasks, relaunch with progress context | Medium | P1 |
| Chat UI | Goal input panel in dashboard | Medium | P1 |
| Objective status board | Task list with progress bars in dashboard | Medium | P1 |
| Worktree cleanup | Remove worktrees after objective completes | Low | P2 |

---

## Implementation Chunks (for Codex)

### Chunk 1: Objective + Filesystem Foundation
- Objective data model (objective.json schema)
- Filesystem structure creation (`objectives/<uuid>/tasks/<id>/`)
- Objective CRUD (create, read, update, list)
- `claude --print --model haiku` subprocess wrapper with JSON parsing
- New API endpoints: `POST /api/objectives`, `GET /api/objectives`, `GET /api/objectives/<id>`

### Chunk 2: Planner Pipeline
- Create planner cmux workspace
- Send planning prompt via `surface.send_text`
- Monitor planner until completion (reuse existing detection)
- Capture planner output to `plan.md` (via `surface.read_text --scrollback`)
- Parse plan.md → structured tasks via Haiku
- Write `spec.md` for each task
- Update objective.json with task list

### Chunk 3: Worker Lifecycle + Worktrees
- Git worktree creation per task (`git worktree add`)
- Create worker cmux workspace pointed at worktree
- Send task prompt with spec.md/context.md/progress.md instructions
- Integrate with existing monitoring loop
- Detect completion via hasClaude transition + result.md existence
- Wire into existing review pipeline

### Chunk 4: Progress Monitoring + Stuck Detection
- Filesystem watcher for progress.md changes (polling-based, every 30s)
- Parse checkpoint status from progress.md
- Update objective.json checkpoint statuses
- Stuck detection timer (5/10/15 min thresholds)
- Dashboard status for progress (new API fields in objective response)

### Chunk 5: Context Assembly + Dependency Resolution
- Build context.md from completed dependency result.md + review.json
- Dependency graph evaluation (which tasks are unblocked?)
- Auto-launch newly unblocked tasks
- Crash recovery: detect failed tasks, relaunch with progress context

### Chunk 6: Dashboard UI
- Chat panel for goal input
- Objective status board (task list with checkpoint progress bars)
- Active worker cards linked to objectives
- Review results per task
- Notification on objective completion or stuck worker

---

## Open Questions

1. **Max concurrent workers:** How many parallel Claude Code sessions before subscription throttling? Need to test empirically. Start with 2-3 and increase.
2. **Planner quality:** Does the planner consistently produce parseable output with the checkpoint format? May need prompt iteration.
3. **progress.md compliance:** Will Claude Code reliably update progress.md after each checkpoint? Needs testing. Fallback: orchestrator watches git commits as a secondary progress signal.
4. **Worktree branch naming:** Convention `orchestrator/task-N-[slug]`? Need to avoid conflicts with existing branches.
5. **Objective lifecycle:** When does an objective "expire"? Auto-cleanup after merge? Manual dismissal?
