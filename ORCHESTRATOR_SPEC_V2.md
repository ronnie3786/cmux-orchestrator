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

## UI Design

**Chosen layout: Cowork-style minimal chat** (Option E)
- Mockup: `mockups/option-e-cowork.html`
- Narrow left sidebar (~240px) with objective list + progress indicators
- Big centered chat (max-width ~720px) as the primary interface
- No right panel, no dashboard grid, no stats
- Everything shows inline in the chat: plan cards, progress updates, review results
- Terminal sessions accessible via a link at the bottom of the sidebar

**How the UI maps to the backend:**
- Chat input → creates objective, launches planner
- Inline plan card → rendered from `objective.json` task list after Haiku parses `plan.md`
- Inline progress updates → derived from `progress.md` file changes detected by monitoring loop
- Inline review cards → rendered from `review.json` after `claude --print` review completes
- Sidebar objective list → reads from `~/.cmux-harness/objectives/` directory listing
- Completion summary → Haiku-generated summary from all `result.md` files

---

## Known Implementation Challenges

### Challenge 1: Streaming progress to the chat in real-time

The chat needs new messages to appear as they happen, not on page refresh. The current harness HTTP server only handles simple request/response polling. For a chat UI, we need either Server-Sent Events (SSE) or WebSocket to push updates to the browser. SSE is simpler and sufficient for one-directional updates (server → browser). This is new plumbing that doesn't exist in the current server.

**Mitigation:** SSE endpoint (`GET /api/events`) that streams new chat messages as they're generated. Browser JS opens an EventSource connection and appends messages to the chat. Fallback: polling `/api/objective/<id>/messages` every 2s for MVP.

### Challenge 2: Parsing planner output reliably

The entire pipeline depends on Haiku correctly parsing Claude Code's free-form conversational text into structured JSON (task titles, dependencies, checkpoint lists, file lists). Claude Code doesn't output structured data — it outputs markdown with natural language. If the parse fails or misinterprets dependencies, the execution order is wrong.

**Mitigation:** 
- Constrain the planner prompt to request a specific output format (numbered tasks with structured fields)
- Haiku parsing prompt should include few-shot examples of expected input/output
- Add a validation step: check that all dependency references are valid, checkpoint counts are reasonable (3-5), file lists are non-empty
- If parse fails, retry once with a "reformat this plan" prompt before alerting the user
- Test against 10+ real-world plans before shipping

### Challenge 3: Workers actually updating progress.md

The progress tracking system depends on Claude Code following the instruction to "update progress.md after each checkpoint." Claude Code is good at following instructions but not 100% reliable. It may get deep into coding and skip the update, causing false stuck-detection alarms and a silent chat.

**Mitigation:**
- Primary signal: `progress.md` file changes (filesystem watch)
- Secondary signal: git commit activity in the worktree (new commits = progress even if progress.md wasn't updated)
- Tertiary signal: `surface.read_text` screen content changes (terminal activity = not stuck)
- Stuck detection should require ALL THREE signals to be absent before flagging, not just progress.md
- Consider reinforcing the instruction: include "IMPORTANT: Update progress.md NOW before proceeding" at each checkpoint boundary in spec.md

### Challenge 4: Chat history persistence

If the browser is closed and reopened, the chat conversation needs to be reconstructable. The filesystem state (objective.json, progress.md, result.md, review.json) is all persisted, but the conversational messages ("Got it, analyzing codebase...", "Task 2 reached checkpoint 3/4") are not stored.

**Mitigation:** Two options:
- **Option A (reconstruct):** Derive chat messages from filesystem state on load. Walk through objective.json task statuses, progress.md checkpoints, and review.json results to rebuild the conversation timeline. Cleaner (single source of truth) but harder to implement.
- **Option B (persist):** Store chat messages in a separate `messages.jsonl` file per objective. Append-only log of all messages with timestamps. Simpler but adds a second source of truth.
- **Recommendation:** Start with Option B for MVP (simpler), migrate to Option A later if the dual-source-of-truth causes issues.

### Challenge 5: Multiple objectives running simultaneously

The sidebar shows a list of objectives. Clicking between them switches the chat view while workers continue running in the background. The orchestrator engine needs to manage multiple objectives with independent task queues, worker sessions, and monitoring states. The current harness engine is single-threaded with one poll loop.

**Mitigation:**
- Each objective is self-contained in its filesystem directory — this is already designed correctly
- The monitoring loop iterates over all active objectives (not just one)
- Chat view switching is purely frontend — load messages for the selected objective, keep all objectives updating in the background
- MVP: support 1 active objective at a time, queue additional ones. Add parallelism later.

### Challenge 6: Planner session screen-scraping

The planner is a Claude Code session where we inject a prompt via `surface.send_text` and capture output via `surface.read_text --scrollback`. This is screen-scraping — the most fragile step. If the planner's output exceeds the scrollback buffer, we lose the end of the plan.

**Mitigation:** Make the planner file-based, same as workers. The planner prompt should include: "Write your complete plan to ./plan.md when finished." The orchestrator watches for `plan.md` to appear instead of scraping the terminal. This eliminates the scrollback buffer risk entirely and makes the planner consistent with the worker pattern.

### Challenge 7: Auto-approve and orchestrator input race condition

Auto-approve sends keystrokes to worker terminals. The orchestrator also sends the initial task prompt via `surface.send_text`. If auto-approve fires at the exact moment the orchestrator is sending the task prompt, keystrokes can interleave and corrupt the input.

**Mitigation:**
- Add a per-workspace mutex in the engine that serializes all `surface.send_text` and `surface.send_key` calls to the same workspace
- After workspace creation, add a 3-5 second delay before enabling auto-approve for that workspace (let Claude Code fully initialize)
- The monitoring loop should skip newly-created workspaces for one poll cycle

---

## Implementation Priority Order

Ordered by risk reduction — tackle the hardest/most fragile pieces first:

| Priority | Challenge | Why first | Effort |
|----------|-----------|-----------|--------|
| **P0** | #6 — Planner file-based | Eliminates the most fragile part of the pipeline (screen-scraping planner output). Makes planner consistent with worker pattern. | Low |
| **P0** | #2 — Plan parsing reliability | Everything downstream depends on this. If parsing is unreliable, nothing works. Need prompt engineering + validation + testing. | Medium |
| **P0** | #3 — progress.md compliance | Core progress tracking depends on this. Need fallback signals (git commits, screen activity) for when workers don't update the file. | Medium |
| **P1** | #7 — Race condition fix | Easy mutex. Prevents rare but hard-to-debug input corruption. | Low |
| **P1** | #1 — SSE for live chat updates | Required for the chat UI to feel responsive. Can use polling as interim. | Medium |
| **P2** | #4 — Chat history persistence | Nice-to-have for MVP. Can start with messages.jsonl append log. | Low |
| **P2** | #5 — Multi-objective support | MVP works with 1 objective at a time. Add parallelism after core pipeline is proven. | Medium |

**MVP scope:** P0 items + polling-based chat (skip SSE). Get the pipeline working end-to-end with one objective, prove it's reliable, then add polish.

---

## Open Questions

1. **Max concurrent workers:** How many parallel Claude Code sessions before subscription throttling? Need to test empirically. Start with 2-3 and increase.
2. **Planner prompt iteration:** What format produces the most consistently parseable output from Claude Code? Need to test structured markdown, numbered lists, and explicit JSON blocks.
3. **Worktree branch naming:** Convention `orchestrator/task-N-[slug]`? Need to avoid conflicts with existing branches.
4. **Objective lifecycle:** When does an objective "expire"? Auto-cleanup after merge? Manual dismissal?
5. **Chat message format:** What's the JSON schema for persisted chat messages? Need: timestamp, sender (user/orchestrator/system), type (text/plan-card/progress/review/error), and payload.
6. **Error recovery UX:** When a task fails, what does the chat show? Options: auto-retry silently, show error and ask user, show error with "Retry" button.
