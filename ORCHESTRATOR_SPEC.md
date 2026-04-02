# Orchestrator Spec — "The Tech Lead"

*Status: Leading candidate, pending Woz's independent review*
*Last updated: 2026-04-02*

---

## Vision

Evolve cmux-harness from a monitoring dashboard into an autonomous orchestrator that manages Claude Code sessions on Ronnie's behalf. Instead of manually opening sessions, typing tasks, reading outputs, and deciding what's next, Ronnie gives the orchestrator a high-level goal and it handles the rest.

### Before (today)
```
Ronnie
  → manually opens cmux workspace
  → manually types task into Claude Code
  → manually reads output
  → manually decides what's next
  → repeat for each session
```

### After (orchestrator)
```
Ronnie
  → types high-level goal into chat UI
  → orchestrator plans, executes, monitors, reviews
  → Ronnie gets summaries and checkpoints
  → approves/redirects as needed
```

---

## Environment Constraints

| Resource | Available | Notes |
|----------|-----------|-------|
| Claude Code | ✅ | v2.1.90, subscription auth, interactive sessions |
| `claude --print` | ✅ | One-shot prompt mode, no API key needed |
| `claude --print --model haiku` | ✅ | Confirmed working on work machine |
| API keys | ❌ | No standalone Anthropic API key |
| OpenClaw | ❌ | Not allowed on work machines |
| Local models | ✅ | Ollama on 48GB work Mac |
| Mac Studio | ✅ | LM Studio via Tailscale (qwen3.5-27b) |
| cmux socket API | ✅ | Full v2 JSON-RPC, automation mode |

---

## Architecture

### Components

```
┌─────────────────────────────────────────────────┐
│                   Dashboard UI                    │
│  ┌───────────┐  ┌──────────┐  ┌──────────────┐  │
│  │ Chat Panel │  │ Task     │  │ Session      │  │
│  │ (input)    │  │ Queue    │  │ Cards        │  │
│  └─────┬─────┘  └────┬─────┘  └──────┬───────┘  │
│        │              │               │           │
│  ┌─────▼──────────────▼───────────────▼────────┐ │
│  │           Orchestrator Engine                │ │
│  │  ┌──────────┐ ┌─────────┐ ┌──────────────┐  │ │
│  │  │ Planner  │ │ Queue   │ │ Monitor      │  │ │
│  │  │ Manager  │ │ Manager │ │ Loop         │  │ │
│  │  └────┬─────┘ └────┬────┘ └──────┬───────┘  │ │
│  └───────┼─────────────┼─────────────┼──────────┘ │
└──────────┼─────────────┼─────────────┼────────────┘
           │             │             │
    ┌──────▼──────┐ ┌────▼────┐ ┌──────▼──────┐
    │ Planner     │ │ Worker  │ │ Worker      │
    │ Session     │ │ Session │ │ Session     │
    │ (Claude     │ │ (Claude │ │ (Claude     │
    │  Code)      │ │  Code)  │ │  Code)      │
    └─────────────┘ └─────────┘ └─────────────┘
          ▲               ▲             ▲
          └───────────────┴─────────────┘
                  cmux socket API
```

### LLM Architecture

| Role | Method | Model | Cost | Job |
|------|--------|-------|------|-----|
| **Orchestrator brain** | `claude --print --model haiku` | Haiku | Cheapest | Parse planner output, manage task queue, detect stuck sessions, progress summaries |
| **Planner** | Claude Code session (interactive) | Sonnet (default) | Subscription | Read codebase, understand structure, decompose goals into task plans |
| **Workers** | Claude Code sessions (interactive) | Sonnet (default) | Subscription | Execute specific coding tasks (the actual implementation) |
| **Session reviews** | `claude --print` | Sonnet (default) | Subscription | Review completed sessions, assess code quality, flag issues |

**Why these choices:**
- Haiku for brain: Task parsing and queue management are structured/mechanical. Haiku handles JSON extraction and simple decisions well. Cheapest option.
- Sonnet for planner: Needs codebase comprehension. Sonnet is excellent at reading code and creating plans. Opus would be overkill.
- Sonnet for reviews: Tested and confirmed — catches real code issues (threading, concurrency, missing methods) that local models miss entirely.
- Upgrade path: If Haiku brain quality is insufficient, bump to Sonnet. Unlikely to need Opus anywhere.

---

## Flow (detailed)

### Phase 1: Input
1. Ronnie types a goal in the dashboard chat panel
   - "Fix the auth token refresh bug in IOSDOX-24739"
   - "Implement notification preferences screen"
   - "Add unit tests for the payment module"

### Phase 2: Planning
2. Orchestrator creates a **Planner** workspace via cmux API
   - `cmux new-workspace --name "Planner: [goal]" --cwd [project-dir] --command "claude"`
3. Sends the goal as context to the Planner session
   - `surface.send_text`: "Read the relevant files for [goal]. Create a numbered plan of discrete tasks needed to accomplish this. Each task should be independently executable by a separate Claude Code session. Output each task with: description, files likely involved, dependencies on other tasks."
4. Monitors Planner via `surface.read_text` until Claude Code exits or produces output
5. Orchestrator brain (Haiku) parses the Planner's output into a structured task queue

### Phase 3: Execution
6. For each task in the queue (respecting dependencies):
   - Create worker workspace: `cmux new-workspace --name "Task N: [description]" --cwd [project-dir] --command "claude"`
   - Send task prompt via `surface.send_text` with:
     - Task description from planner
     - Context from completed dependent tasks (if any)
     - Relevant file paths
   - Auto-approve handles permission prompts (already built)
7. Monitor loop reads worker screens, tracks progress
8. On completion (hasClaude: true → false):
   - Capture snapshot (already built)
   - Run review via `claude --print` (already built)
   - Feed results to orchestrator brain for status update

### Phase 4: Reporting
9. Orchestrator brain summarizes progress
10. Dashboard shows task queue status, completed reviews, any issues
11. Ronnie reviews at checkpoints, approves or redirects

---

## Task Queue Data Model

```json
{
  "objectiveId": "uuid",
  "objective": "Fix auth token refresh bug",
  "status": "executing",
  "createdAt": "ISO timestamp",
  "projectDir": "/path/to/project",
  "plannerSessionId": "workspace-uuid",
  "tasks": [
    {
      "id": "task-1",
      "description": "Fix token expiry check in TokenManager.swift",
      "files": ["TokenManager.swift"],
      "dependsOn": [],
      "status": "completed",
      "workspaceId": "uuid",
      "workspaceName": "Task 1: Fix token expiry",
      "startedAt": "ISO timestamp",
      "completedAt": "ISO timestamp",
      "reviewStatus": "reviewed",
      "reviewSummary": "Added isTokenExpired() check with retry logic"
    },
    {
      "id": "task-2",
      "description": "Add unit tests for token refresh",
      "files": ["TokenManagerTests.swift"],
      "dependsOn": ["task-1"],
      "status": "queued",
      "workspaceId": null,
      "workspaceName": null
    }
  ]
}
```

### Task Status Values
- `queued` — waiting for dependencies or capacity
- `launching` — workspace being created
- `executing` — Claude Code running
- `completed` — session finished, review pending or done
- `failed` — session failed or stuck
- `blocked` — dependency not met

---

## What's Already Built (reusable)

| Component | Location | Reuse |
|-----------|----------|-------|
| Workspace creation | `POST /api/new-session` | Direct reuse for worker/planner sessions |
| Screen reading | `cmux_api.cmux_read_workspace()` | Direct reuse for monitoring |
| Claude detection | `detection.detect_claude_session()` | Direct reuse for completion detection |
| Session completion capture | `engine._capture_completion_snapshot()` | Direct reuse |
| LLM review system | `review.py` (all backends) | Direct reuse, already tested |
| Auto-approve | `engine.check_workspace()` | Direct reuse, keeps sessions unblocked |
| Persistent config | `storage.py` | Extend for objective/task queue storage |
| Dashboard UI framework | `server.py` + `dashboard.html` | Extend with chat panel + task queue view |

### What's New to Build

| Component | Description | Complexity |
|-----------|-------------|-----------|
| Chat UI panel | Text input for goals, conversation history | Medium |
| Planner session manager | Create planner workspace, inject goal, capture plan output | Medium |
| Plan parser | Haiku-powered extraction of tasks from planner text | Medium |
| Task queue engine | Queue data model, dependency resolution, status tracking | Medium |
| Worker lifecycle manager | Create workers, inject tasks, track completion | Low (mostly reuses existing) |
| Context relay | Pass completed task results as context to dependent tasks | Low |
| Objective status view | Dashboard UI for task queue visualization | Medium |
| Cross-session conflict detection | Use `cmux find-window` to detect file overlap | Low (nice-to-have) |

---

## Persistence

- **Objectives:** `~/.cmux-harness/objectives/[uuid].json`
- **Task queue:** Embedded in objective JSON
- **Reviews:** `~/.cmux-harness/reviews/` (already exists)
- **Config:** `~/.cmux-harness/workspace-config.json` (extend existing)

---

## Open Questions

1. **Max concurrent workers?** Need to test how many Claude Code sessions can run simultaneously before subscription throttling kicks in.
2. **Planner output format:** Should we constrain the planner to output a specific format (markdown list? JSON?) or let Haiku parse free-form text?
3. **Failure recovery:** If a worker session fails or gets stuck, auto-retry with the same prompt? Different prompt? Alert Ronnie?
4. **Git branch strategy:** Should each worker get its own branch? Or all work on the same branch with conflict detection?
5. **Build/test gate:** Auto-run `swift build` / `swift test` after each session? (Approach 3 feature, could add later)

---

## Implementation Chunks (for Codex)

*To be finalized after Woz's independent review*

### Chunk 1: Orchestrator Backend Core
- Objective data model + persistence
- Task queue engine with dependency resolution
- `claude --print --model haiku` subprocess wrapper
- Plan parser (Haiku prompt + JSON extraction)

### Chunk 2: Planner Session Manager
- Create planner workspace via cmux API
- Inject goal prompt
- Monitor for completion
- Capture full scrollback output
- Feed to plan parser

### Chunk 3: Worker Lifecycle Manager
- Create worker workspaces from task queue
- Inject task prompts with context from dependencies
- Integrate with existing monitoring loop
- Wire completion → review pipeline

### Chunk 4: Chat UI + Objective View
- Chat panel for goal input
- Objective status display (task list with status badges)
- Active worker cards (reuse existing workspace cards)
- Review results per task

### Chunk 5: Context Relay + Polish
- Pass completed task diffs/summaries as context to dependent workers
- Cross-session file overlap detection
- Progress notifications
- Error handling and retry logic
