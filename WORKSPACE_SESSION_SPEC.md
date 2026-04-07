# Workspace session / ad hoc session spec

_Last updated: 2026-04-07_

## Goal
Add a third orchestrator entry mode: a **workspace session** that lets the user open an existing repo or worktree and start chatting immediately, without creating an objective first.

This should feel native to the current product model:
- **Structured objective** = tracked, planned, reviewed work
- **Direct objective** = tracked, lightweight work
- **Workspace session** = open-ended repo/worktree session

## What exists in the codebase today

### Data model already in place
- **Projects** are first-class records in `cmux_harness/objectives.py`
- **Objectives** are stored under `~/.cmux-harness/objectives/<id>/objective.json`
- Objective creation currently always creates a dedicated worktree via `_create_objective_worktree(...)`
- Workflow modes are currently limited to `structured` and `direct`

### Current UX constraints
- Sidebar is project-grouped and renders only objectives in `static/orchestrator.js`
- Chat, status summary, build logs, console logs, and context strip are all keyed off `activeObjectiveId`
- `routes/objectives.py` and `server.py` only expose objective-oriented endpoints for orchestrator chat
- There is already a persistent **orchestrator session** implementation for objectives in `cmux_harness/orchestrator.py`
- Existing session support is strong enough to reuse for workspace sessions instead of inventing a second terminal/session system

### Important architectural conclusion
The current orchestrator UI is **selection-centric**, but the selected thing is hard-coded to an objective. The cleanest path is:
1. add a new stored entity for workspace sessions
2. add a shared concept of an **active conversation target** in the frontend
3. reuse the existing cmux workspace + persistent chat pattern for workspace sessions

Do **not** fake this as a dummy objective with an empty goal. That would leak bad assumptions all over planning, status, cleanup, and review.

## Recommended product behavior

### User stories
1. As a user, I can add a new project and immediately open a workspace without writing an objective.
2. As a user, I can open an existing repo root or worktree under a project and chat in that context.
3. As a user, I can resume a previous workspace session from the sidebar.
4. As a user, I can later promote workspace work into a formal objective if I decide it needs tracking.

### Scope for first pass
Build the first three user stories now.
Leave **promotion into objective** as a follow-up stub or future endpoint.

## Proposed model

### New entity: workspace session
Persist workspace sessions separately from objectives.

Suggested storage:
- `~/.cmux-harness/workspaces/<workspaceSessionId>/workspace.json`
- `~/.cmux-harness/workspaces/<workspaceSessionId>/messages.jsonl`
- optional `debug.jsonl`

Suggested schema:

```json
{
  "id": "uuid",
  "projectId": "uuid",
  "name": "ios-app main workspace",
  "rootPath": "/repo/root/or/worktree",
  "source": "project-root" | "existing-worktree" | "manual-path",
  "status": "active" | "idle" | "closed" | "failed",
  "cmuxWorkspaceId": "ws-uuid",
  "sessionActive": true,
  "lastActivityAt": "ISO timestamp",
  "createdAt": "ISO timestamp",
  "updatedAt": "ISO timestamp"
}
```

### Why separate storage
Objectives already carry planner/task/review state and worktree lifecycle assumptions.
Workspace sessions should not inherit:
- `goal`
- `workflowMode`
- task arrays
- planner/review state
- objective worktree cleanup rules

Keeping them separate avoids dozens of conditional hacks.

## Backend design

### New module
Add `cmux_harness/workspaces.py` for CRUD and message persistence.

Suggested functions:
- `create_workspace_session(project_id, root_path, name=None, source="manual-path")`
- `read_workspace_session(workspace_session_id)`
- `list_workspace_sessions()`
- `list_workspace_sessions_for_project(project_id)`
- `update_workspace_session(workspace_session_id, updates)`
- `delete_workspace_session(workspace_session_id)`
- `append_workspace_message(workspace_session_id, msg)`
- `get_workspace_messages(workspace_session_id, after=None)`

### Validation rules
- `projectId` required
- `rootPath` required
- path must exist and be a directory
- path must be inside a git repo or be a git repo root
- normalize to canonical absolute path
- do **not** create a git worktree automatically

### New orchestrator methods
Add workspace-session-specific methods to `cmux_harness/orchestrator.py`.

Suggested methods:
- `start_workspace_session(workspace_session_id)`
- `_build_workspace_context_prompt(workspace_session)`
- `handle_workspace_input(workspace_session_id, message)`
- `get_workspace_messages(workspace_session_id, after=None)`
- `close_workspace_session(workspace_session_id, reason="manual")`
- `_capture_workspace_response(...)`
- extend idle sweep to workspace sessions too

### Reuse strategy
Reuse these existing helpers:
- `_create_worker_workspace(...)`
- `_wait_for_repl(...)`
- `_close_workspace(...)`
- `_extract_orchestrator_response(...)` (rename to something more generic or share internally)
- response capture polling pattern

### Workspace context prompt
First-pass prompt should be much simpler than objective context:

```text
You are the workspace assistant for this repo context.

Project: <project root>
Workspace path: <rootPath>
Session name: <name>

You are running inside this workspace path. Help the user inspect the codebase, answer questions, make edits, run git commands, and support open-ended development work.

This is NOT a tracked objective unless the user explicitly creates one later.
Do not refer to objective.json, plan.md, or task files unless they actually exist in this workspace.
Be concise and practical.
```

### Idle behavior
Mirror objective orchestrator session behavior:
- keep session alive while active
- mark inactive after idle timeout, recommended 60 min
- do not delete the workspace-session record when idle shutdown happens
- resume on next user message

## API surface

### New endpoints
Add a new route module, suggested: `cmux_harness/routes/workspaces.py`

Endpoints:
- `GET /api/workspaces`
- `POST /api/workspaces`
- `GET /api/workspaces/<id>`
- `DELETE /api/workspaces/<id>`
- `GET /api/workspaces/<id>/messages`
- `POST /api/workspaces/<id>/start`
- `POST /api/workspaces/<id>/message`
- `POST /api/workspaces/<id>/open-root`

Optional first-pass extra:
- `POST /api/workspaces/pick-root`
  - probably reusable from project picker flow, but not required if UI can reuse project root

### POST /api/workspaces request

```json
{
  "projectId": "uuid",
  "rootPath": "/path/to/repo/or/worktree",
  "name": "main workspace",
  "source": "existing-worktree"
}
```

Behavior:
- create workspace-session record
- do **not** auto-start cmux session unless product wants one-click open

Recommendation:
- create + auto-start in the same UX flow, but keep API split clean

## Frontend design

### Core frontend shift
The frontend needs a shared selection model.

Current state:
- `activeObjectiveId`
- `activeObjective`

Recommended next state:
- `activeTargetType = "objective" | "workspace" | null`
- `activeObjectiveId`
- `activeWorkspaceId`
- `activeObjective`
- `activeWorkspace`

This is the key refactor. Without it, workspace sessions will feel bolted on.

### Sidebar
Under each project, render two sections when expanded:
- **Workspaces**
- **Objectives**

Suggested example:

- Project A
  - Workspaces
    - main workspace
    - feature/auth-debug
  - Objectives
    - Fix login redirect
    - Add audit logging

If that feels too heavy visually, first pass can render one flat mixed list with badges:
- `[WS] main workspace`
- `[OBJ] Fix login redirect`

Recommendation:
Start with **grouped sub-sections** under each project because it keeps the mental model obvious.

### New CTAs
In the sidebar and project rows:
- existing `+` keeps creating objectives
- add `Open workspace`
- optional top-level button: `Open workspace`

### New form mode
Current sidebar form modes:
- `project`
- `objective`

Add:
- `workspace`

Fields:
- Project
- Workspace path
- Browse button or reuse project root shortcut
- Optional name
- Source hint

Smart defaults:
- default rootPath = selected project's `rootPath`
- default name = basename(rootPath)

### Chat panel behavior
When a workspace is active:
- chat input should say something like `Ask about this workspace...`
- no plan approval cards
- no contract approval cards
- no objective complete state copy
- context strip should show workspace name/path and session state

### Context strip
Generalize the top strip to support both target types.

For workspace session:
- title = workspace name
- subtitle = compact path
- session badge = active/idle
- branch badge from git panel if available
- trash button = close/delete workspace session, but wording should be different from objective clear

### Side utilities
For first pass:
- **Git panel** should work for workspace sessions, keyed off active workspace root path
- **Files** button should open workspace root in VS Code
- **Status summary** should remain objective-only for now, disabled for workspace sessions
- **Build log / console log** can be disabled unless the active workspace happens to expose `.build` logs and the code can be generalized cheaply

Recommendation:
Do not block the feature on status-summary parity.

## Suggested implementation phases

### Phase 1, backend foundation
1. Add `workspaces.py` storage module
2. Add route handlers + server wiring
3. Add orchestrator methods for start/resume/chat/idle shutdown
4. Add tests for workspace CRUD and chat routing

### Phase 2, frontend selection refactor
1. Introduce shared target selection state
2. Load `/api/objectives` and `/api/workspaces` together
3. Render workspace items in sidebar under project
4. Support selecting workspace and polling its messages

### Phase 3, workspace creation UX
1. Add sidebar form mode `workspace`
2. Add `Open workspace` CTA on project rows
3. Default to project root, allow path override
4. Auto-start after create

### Phase 4, utility polish
1. Make git panel path/session-aware for workspace sessions
2. Support open-in-VS-Code for workspace roots
3. Disable or hide objective-only actions when workspace selected

## Promotion to objective, follow-up
Not required for first pass, but spec the seam now.

### Future endpoint
`POST /api/workspaces/<id>/promote-to-objective`

Possible request:

```json
{
  "goal": "Turn this exploration into a tracked objective",
  "workflowMode": "structured"
}
```

Possible behavior:
- create objective under same project
- either reuse same rootPath if it is already a worktree, or create a dedicated objective worktree from project root
- optionally link origin workspaceSessionId on the new objective

Recommendation:
Defer implementation. It is conceptually clean, but not needed to unlock the main workflow.

## Test plan

### Backend tests
Add focused tests for:
- create workspace session persists normalized path and project link
- create rejects missing/invalid rootPath
- start_workspace_session creates cmux workspace and stores session fields
- handle_workspace_input routes to active session
- handle_workspace_input resumes inactive session
- idle sweep marks stale workspace sessions inactive
- deleting workspace session closes cmux workspace if active
- workspace messages endpoint returns persisted messages

### Server tests
Add coverage in `tests/test_server.py` for:
- `POST /api/workspaces`
- `GET /api/workspaces`
- `POST /api/workspaces/<id>/start`
- `POST /api/workspaces/<id>/message`
- `DELETE /api/workspaces/<id>`

### Frontend tests
If there is no JS test harness yet, at least keep logic isolated enough for future tests.
Manual smoke checks:
- create project
- open workspace from project root
- send chat message
- reload page and resume workspace from sidebar
- switch between workspace and objective
- open workspace root in VS Code

## Recommended implementation decisions

### Decision 1
**Workspace sessions should be persistent sidebar items.**

Why:
- users will want to return to them
- session resume is already part of the orchestrator model
- ephemeral-only would feel disposable and frustrating

### Decision 2
**Workspace sessions belong to projects.**

Why:
- keeps sidebar organization coherent
- project already carries canonical repo root and naming
- avoids a second top-level navigation concept

### Decision 3
**Workspace sessions should not require a goal.**

Why:
- that is the whole point of the feature
- forcing a pseudo-goal recreates current friction

### Decision 4
**Do not reuse objective storage.**

Why:
- current objective model is deeply tied to planning/execution/review
- separate storage is cleaner and faster to maintain

## Concrete ask for implementation
Build the first pass of workspace sessions as a first-class entity with:
- backend CRUD + message persistence
- persistent cmux chat session with resume behavior
- sidebar rendering under each project
- create/open flow from a project without requiring an objective
- shared active-target frontend state
- git/files utilities working for workspace roots
- objective-only features hidden or disabled when a workspace is selected

That gets the product where Ronnie wants it without corrupting the objective model.