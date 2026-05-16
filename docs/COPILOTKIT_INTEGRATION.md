# CopilotKit Integration Plan

Date: 2026-05-16

## Executive Recommendation

Use CopilotKit as a React agent UI layer on top of the existing Python harness. Do not move the whole orchestrator to Next.js just to adopt CopilotKit.

The best path is:

1. Add a Vite React app for the workflow orchestrator view.
2. Build it to static assets served by `cmux_harness/server.py`.
3. Add a Python AG-UI endpoint for the top-level orchestration agent.
4. Keep the existing REST endpoints as the durable source of truth for objectives, projects, decisions, preflights, reviews, and workspace state.
5. Let CopilotKit handle shared agent context, frontend tools, human approval UI, and dynamic rendered panels.

This preserves the current Python-first harness while giving the orchestrator a proper agent-driven UI surface.

## Current Repo Shape

The current orchestrator is mostly a Python stdlib HTTP server plus static frontend files:

- `cmux_harness/server.py` serves routes and static assets.
- `cmux_harness/static/workflow-orchestrator.html`
- `cmux_harness/static/workflow-orchestrator.js`
- `cmux_harness/static/workflow-orchestrator.css`
- `cmux_harness/routes/workflow.py` owns command center and workflow data routes.
- `cmux_harness/orchestrator.py` owns higher-level worker orchestration.

That matters because CopilotKit is React-native. The clean integration is a route-level React replacement for the workflow UI, not a partial rewrite inside the current DOM-string frontend.

## What CopilotKit Gives Us

CopilotKit is useful here for four things:

- Shared app context: expose current command center, selected task, active approvals, and visible panels to the agent.
- Frontend tools: allow the agent to trigger deterministic UI actions such as selecting a task, opening a decision, adding a panel, or refreshing a view.
- Generative UI: render structured agent outputs as first-class React components, not chat text.
- Human-in-the-loop: show approval cards before writes such as launching workers, approving decisions, posting Jira comments, or changing task status.

The important product shift is that the agent should not manipulate DOM directly. It should emit typed state and typed actions. React renders the result.

## Integration Options

### Option 1: React Static App Plus Python AG-UI Endpoint

Recommended.

Architecture:

```txt
Browser
  React workflow app
  CopilotKit provider
  AG-UI client connection
    |
    | POST /api/agui/orchestrator
    | Server-sent event stream back
    v
Python harness
  cmux_harness/routes/agui.py
  workflow state projector
  approval/action guard
    |
    v
Existing REST/storage/orchestrator modules
```

Why this fits:

- Keeps one backend process.
- Keeps Python as the owner of orchestration state.
- Lets the top-level orchestrator stream UI updates directly.
- Avoids adding Node as a server dependency on day one.

Tradeoffs:

- We must implement enough AG-UI event streaming in Python.
- Long-lived SSE needs care in the current `BaseHTTPRequestHandler` server.
- The frontend build adds Node tooling to a Python-first repo.

### Option 2: React Static App Plus Node Copilot Runtime Sidecar

Good fallback if direct Python AG-UI gets annoying.

Architecture:

```txt
React app
  |
  v
Node Copilot Runtime
  |
  v
Python harness REST APIs and AG-UI-ish adapter
```

Why use it:

- More standard CopilotKit runtime setup.
- Less custom protocol code in Python.
- Easier if we later want CopilotKit runtime service adapters.

Tradeoffs:

- Adds a second server process.
- Adds local process supervision.
- The repo currently has no top-level frontend package structure.

### Option 3: Keep Vanilla JS And Add EventSource

Useful bridge, not a real CopilotKit integration.

This would stream orchestrator events into the existing `workflow-orchestrator.js` via SSE. It is cheap, but it misses most of CopilotKit: frontend tools, readable context, render tools, and human-in-the-loop helpers.

Use this only if we need a tiny interim demo.

## Proposed State Contract

Use one shared agent/UI state object. REST resources remain authoritative; this object is the live UI projection.

```json
{
  "version": 1,
  "run": {
    "runId": "uuid",
    "status": "idle|thinking|working|waiting_for_user|failed",
    "headline": "Checking active objectives",
    "currentStep": "Reading command center"
  },
  "view": {
    "mode": "command|ideas|decisions|briefing|objective",
    "selectedEntity": {
      "type": "objective|preflight|decision|jira|idea",
      "id": "..."
    }
  },
  "commandCenter": {},
  "briefing": {},
  "panels": [
    {
      "id": "panel_...",
      "kind": "workspace_status|jira_summary|pr_review|decision|approval",
      "title": "...",
      "summary": "...",
      "data": {},
      "createdAt": "iso"
    }
  ],
  "pendingApprovals": [
    {
      "id": "approval_...",
      "kind": "launch_objective|approve_decision|post_jira_comment",
      "title": "...",
      "preview": {},
      "required": true
    }
  ],
  "activity": []
}
```

State rules:

- Send a full snapshot on run start and reconnect.
- Send deltas for incremental panel, activity, selected view, and approval updates.
- Keep stable IDs for every entity.
- Never stream secrets, raw credentials, or private full transcripts.
- Treat approval state as durable backend state, not React-only state.

## Backend Plan

Add:

- `cmux_harness/routes/agui.py`
- `POST /api/agui/orchestrator`
- Optional `GET /api/agui/orchestrator/capabilities`

The route should:

1. Parse the agent request: messages, context, current state, thread ID, and run ID.
2. Start or continue a top-level orchestration turn.
3. Emit an event stream with:
   - run started
   - progress text or activity events
   - state snapshot
   - state deltas
   - tool or approval requests
   - run finished
4. Reuse the existing workflow data builders instead of duplicating aggregation.
5. Route writes through existing persistence paths.

Likely backend helpers:

- A state projector that turns existing command-center data into the shared UI state.
- An approval store or approval section in existing workflow/objective storage.
- A small event writer that formats AG-UI-compatible SSE.

Write operations should still go through existing endpoints or their underlying functions:

- `POST /api/preflights/{id}/launch-objective`
- `POST /api/objectives/{id}/check-in`
- `POST /api/objectives/{id}/message`
- decision approval endpoints
- Jira comment/status endpoints if added later

## Frontend Plan

Add a dedicated React frontend:

```txt
frontend/workflow/
  package.json
  vite.config.ts
  src/App.tsx
  src/api/client.ts
  src/agent/state.ts
  src/agent/tools.tsx
  src/components/
  src/views/
```

Build output:

```txt
cmux_harness/static/workflow-app/
```

`server.py` should serve the built app at either:

- `/workflow-orchestrator`, replacing the current static page after parity
- `/workflow-orchestrator-next`, during migration

Recommended migration route: start with `/workflow-orchestrator-next`, then switch once parity is acceptable.

CopilotKit usage:

- Wrap the app with the CopilotKit provider.
- Expose readable state for command center, selected entity, visible panels, pending approvals, and activity.
- Register frontend tools for:
  - select view
  - select objective
  - add panel
  - refresh command center
  - show Jira summary
  - show PR review summary
  - stage approval
- Use renderable tools for:
  - Jira ticket summary card
  - PR review pressure card
  - decision preview
  - worker launch preview
  - task detail card
- Use human-in-the-loop for:
  - launch worker/objective
  - approve decision
  - post Jira comment
  - destructive workspace changes

The default Copilot sidebar is probably not the right primary UI. Ronnie’s orchestrator should feel like a command surface with an optional compact chat or voice input, not a generic assistant pane bolted to the side.

## External Top-Level Agent Pattern

The top-level orchestration agent should update the UI by emitting structured events, not by calling browser DOM actions.

Good pattern:

1. Agent reads current state and backend resources.
2. Agent emits `run.status = working`.
3. Agent emits panels or deltas as it discovers useful information.
4. Agent emits `pendingApprovals[]` for risky writes.
5. UI renders approval cards.
6. User approves.
7. Backend performs write using existing route/function.
8. Backend emits a new state snapshot or delta.

This preserves a clean audit trail and keeps writes deterministic.

## Implementation Phases

### Phase 1: React Shell

- Add `frontend/workflow` Vite app.
- Render current command center using existing `/api/command-center`.
- No CopilotKit behavior yet.
- Serve as `/workflow-orchestrator-next`.

### Phase 2: Typed Frontend State

- Move current workflow data shapes into TypeScript types.
- Add reducers for panels, selected entity, activity, and pending approvals.
- Keep REST polling/refresh working.

### Phase 3: CopilotKit Readable Context And Tools

- Add CopilotKit provider.
- Expose app state as readable context.
- Register safe frontend tools:
  - navigate/select
  - refresh
  - render summary panel
  - open detail panel

### Phase 4: AG-UI Endpoint

- Add `cmux_harness/routes/agui.py`.
- Implement read-only agent run streaming.
- Support full state snapshot first.
- Add deltas after the snapshot path is solid.

### Phase 5: Human Approvals

- Add durable approval objects.
- Render approval cards.
- Wire approved actions to existing backend operations.
- Require approvals for launches, external posts, destructive operations, and broad workspace changes.

### Phase 6: Replace Current Workflow UI

- Validate parity with the existing static page.
- Move `/workflow-orchestrator` to React build.
- Keep old static page around briefly as `/workflow-orchestrator-legacy`.

## Risks And Open Questions

- CopilotKit APIs are moving quickly. The older `useCopilotAction` and `useCopilotReadable` concepts map to newer frontend-tool and agent-context patterns.
- Direct Python AG-UI streaming needs careful protocol handling.
- The current server is stdlib HTTP. Long-running SSE may be fine for local use, but it is not as ergonomic as FastAPI or Node.
- Approval state must survive refreshes.
- Mixing React into the current vanilla page will get messy. Prefer a route-level replacement.
- We need to decide whether the top-level orchestrator agent lives inside the Python process, as a subprocess, or behind another local API.

## Files Likely To Change

Backend:

- `cmux_harness/server.py`
- `cmux_harness/routes/agui.py`
- `cmux_harness/routes/workflow.py`
- `cmux_harness/orchestrator.py`
- `cmux_harness/storage.py` or a new approval storage helper
- `tests/test_agui_route.py`
- `tests/test_workflow_routes.py`

Frontend:

- `frontend/workflow/package.json`
- `frontend/workflow/vite.config.ts`
- `frontend/workflow/src/App.tsx`
- `frontend/workflow/src/agent/*`
- `frontend/workflow/src/components/*`
- `frontend/workflow/src/views/*`
- `cmux_harness/static/workflow-app/*` generated build assets

Migration support:

- `cmux_harness/static/workflow-orchestrator.html`
- `cmux_harness/static/workflow-orchestrator.js`
- `cmux_harness/static/workflow-orchestrator.css`

## Recommendation For The Next Build Step

Start with Phase 1 and Phase 2 in one branch:

- Add `frontend/workflow`.
- Recreate the current workflow command center in React.
- Serve it at `/workflow-orchestrator-next`.
- Keep all writes and persistence unchanged.

After that, add CopilotKit read-only context and safe frontend tools. Only then add the AG-UI streaming endpoint. That sequencing keeps the work testable and avoids trying to change UI framework, agent protocol, and write safety all at once.
