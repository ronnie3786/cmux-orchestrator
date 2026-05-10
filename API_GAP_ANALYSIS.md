# Orchestrator API Gap Analysis

## Goal

Map the production mock UX to what the current cmux-orchestrator/cmux-harness backend can actually do today, then identify the missing API surface needed to make the full app feasible.

The good news: the repo is much farther along than a remote cmux viewer. It already has objective/project/workspace APIs, cmux session spawning, planner/worker orchestration, messages, status summaries, Jira read endpoints, GitHub PR comments, action buttons, build/console logs, reviews, and a filesystem-backed objective model.

The gap is mostly product-level aggregation and workflow APIs: idea capture, decision queue, bird's-eye check-ins, Jira pre-flight context packets, richer Jira writes, agent selection, and cross-objective dashboard state.

---

## Current API Inventory

### cmux APIs available underneath

The harness can talk to cmux through JSON-RPC over the cmux socket.

Available and already used:

- `workspace.list` — discover all cmux workspaces.
- `workspace.create` — create a workspace/session.
- `workspace.rename` — name created workspaces.
- `surface.read_text` — read terminal screen.
- `surface.send_text` — send terminal input.
- `surface.send_key` — send keystrokes.
- `system.tree` via CLI — workspace/pane/surface hierarchy.
- notifications via legacy fallback.

Available but underused and useful for orchestrator:

- `debug.terminals` — rich workspace/session metadata: age, title, git dirty, frames, surface IDs.
- `cmux read-screen --scrollback` / `capture-pane --scrollback` — fuller session history.
- `cmux find-window --content <query>` — search across session text.
- `cmux claude-hook` / `set-hook` — event-driven lifecycle hooks.
- `notification.create` — push notifications back into cmux/workspaces.
- `pipe-pane` — stream terminal output to a watcher process.

### Harness HTTP APIs already exposed

#### System and legacy dashboard

- `GET /api/status` — full current harness state and workspace poll data.
- `GET /api/log` — approval log.
- `GET /api/feed` and `POST /api/feed/reply` — activity/reply surfaces.
- `GET/POST /api/config` — settings.
- `GET /api/models` — model availability.
- `GET/POST /api/network` — LAN/Tailscale setup.

#### Projects

- `GET /api/projects`
- `GET /api/projects/{id}`
- `POST /api/projects`
- `PATCH /api/projects/{id}`
- `DELETE /api/projects/{id}`
- `POST /api/projects/pick-root`

This supports known project roots and default branches.

#### Objectives

- `GET /api/objectives`
- `GET /api/objectives/{id}`
- `POST /api/objectives`
- `PATCH /api/objectives/{id}`
- `DELETE /api/objectives/{id}`
- `POST /api/objectives/{id}/start`
- `POST /api/objectives/{id}/approve-plan`
- `POST /api/objectives/{id}/approve-contracts`
- `POST /api/objectives/{id}/message`
- `GET /api/objectives/{id}/messages`
- `GET /api/objectives/{id}/debug`
- `GET /api/objectives/{id}/screen`
- `GET /api/objectives/{id}/tasks/{taskId}/screen`
- `POST /api/objectives/{id}/tasks/{taskId}/approve`
- `POST /api/objectives/{id}/approve-hook`
- `POST /api/objectives/{id}/open-worktree`
- `GET /api/objectives/{id}/status-summary`
- build log / console log endpoints per objective.

Current objective engine supports:

- Creating objective worktrees.
- Planning via Claude Code planner session.
- Planner writes `plan.md`.
- Plan parsing and validation.
- Plan review and approval.
- Task files: `spec.md`, `context.md`, `progress.md`, `result.md`, `review.json`.
- Launching worker sessions.
- Monitoring `progress.md`, git activity, and terminal changes.
- Stuck/amber detection.
- Review/rework loop.
- Completion summary.
- Persistent objective messages/debug logs.

Important limitation: `_launch_ready_tasks` currently launches only one active task at a time because it returns if any task is already `executing`, `reviewing`, or `rework`. Parallelism is designed conceptually, but not currently enabled.

#### Workspace sessions

- `GET /api/workspaces`
- `GET /api/workspaces/{id}`
- `POST /api/workspaces`
- `PATCH /api/workspaces/{id}`
- `DELETE /api/workspaces/{id}`
- `POST /api/workspaces/{id}/start`
- `POST /api/workspaces/{id}/message`
- `GET /api/workspaces/{id}/messages`
- `GET /api/workspaces/{id}/active-turn`
- `POST /api/workspaces/{id}/turns/{turnId}/finalize`
- `GET /api/workspaces/{id}/screen`
- `GET /api/workspaces/{id}/debug`
- `GET /api/workspaces/{id}/status-summary`
- build log / console log endpoints per workspace.

Workspace sessions are useful for non-objective direct sessions and persistent chat/control flows.

#### Action buttons

- `GET/POST/DELETE /api/objectives/{id}/action-buttons`
- `POST /api/objectives/{id}/action-inject`
- `GET/POST/DELETE /api/workspaces/{id}/action-buttons`
- `POST /api/workspaces/{id}/action-inject`

This already supports user-defined quick actions that spawn Claude Code sessions with custom prompts.

#### Jira

- `GET /api/jira/assigned`
- `GET /api/jira/issue?q=KEY_OR_URL`

Current Jira support is read-only and shallow:

- Uses `acli jira workitem search`.
- Fetches fields: key, status, summary, issue type, priority.
- Normalizes URL/title/status/priority.

Missing: descriptions, comments, links, attachments, assignee/reporter, labels, custom fields, write/comment/create/update APIs.

#### GitHub/Git

- `GET /api/github/pr-comments`
- `GET /api/git-status`
- `POST /api/git-diff`, `git-stage`, `git-unstage`, commits, file content/open endpoints.

Useful for review packet and PR pipeline, but still workspace-centric rather than objective-centric.

---

## Product Flow Mapping

### 1. Home Command Board

Mock needs:

- Bird's-eye status across all work.
- Top recommended action.
- Counts: watched objectives, active sessions, review-ready, last sweep.
- Work board lanes.
- Latest check-ins.

Current support:

- `GET /api/objectives` gives raw objectives.
- `GET /api/workspaces` gives workspace sessions.
- `GET /api/status` gives current cmux workspace state.
- `GET /api/objectives/{id}/messages` gives timeline per objective.
- `GET /api/objectives/{id}/status-summary` exists per objective.

Missing:

- Aggregated command-center endpoint.
- Unified lane classification.
- Cross-objective top recommendation.
- Check-in sweep endpoint.
- Attention scoring.
- A way to mark which objective/task is “needs Ronnie” in a first-class, typed way.

Recommended new API:

```http
GET /api/command-center
POST /api/command-center/check-in
```

`GET /api/command-center` should return one payload optimized for the home screen:

```json
{
  "topPriority": {
    "title": "Post the Jira clarification before launching Codex.",
    "objectiveId": "...",
    "decisionId": "...",
    "severity": "attention",
    "recommendedAction": "review_decision"
  },
  "summary": {
    "objectivesWatched": 12,
    "activeSessions": 7,
    "needsRonnie": 2,
    "reviewReady": 1,
    "lastSweepAt": "..."
  },
  "lanes": [
    {"id": "ideas", "title": "Ideas / Pre-Jira", "cards": [...]},
    {"id": "intake", "title": "Intake", "cards": [...]},
    {"id": "context", "title": "Context", "cards": [...]},
    {"id": "running", "title": "Ready / Running", "cards": [...]},
    {"id": "review", "title": "Review / PR", "cards": [...]}
  ],
  "latestCheckIns": [...],
  "decisionPreview": [...]
}
```

### 2. Ideas / Pre-Jira

Mock needs:

- Capture idea.
- Store ideas before Jira exists.
- Transition idea to Brainstorm, Investigate/Research, Ready for Jira, Converted.
- Create Jira ticket from idea.

Current support:

- None as a first-class API. Could hack it as objectives with `workflowMode`, but that would pollute objectives and force projectDir/worktree too early.

Missing:

- Idea store.
- Idea status/lane transitions.
- Idea notes/messages.
- Convert idea to Jira ticket draft or objective.

Recommended new APIs:

```http
GET /api/ideas
POST /api/ideas
GET /api/ideas/{id}
PATCH /api/ideas/{id}
DELETE /api/ideas/{id}
POST /api/ideas/{id}/transition
POST /api/ideas/{id}/brainstorm
POST /api/ideas/{id}/research
POST /api/ideas/{id}/create-jira-draft
POST /api/ideas/{id}/convert-to-objective
```

Storage:

```text
~/.cmux-harness/ideas/{id}/idea.json
~/.cmux-harness/ideas/{id}/messages.jsonl
~/.cmux-harness/ideas/{id}/research.md
~/.cmux-harness/ideas/{id}/jira-draft.md
```

Idea status values:

- `inbox`
- `brainstorming`
- `researching`
- `ready_for_jira`
- `converted`
- `archived`

### 3. Jira Intake / Pre-flight

Mock needs:

- Import Jira ticket.
- Read full ticket context.
- Detect project/repo.
- Run/use `dox-start` style project setup.
- Ask open questions.
- Build local context packet.
- Preview Jira comment.
- Post Jira comment after approval.
- Tag PM/designer/devs via contact directory.

Current support:

- `GET /api/jira/issue` reads shallow issue data.
- `GET /api/jira/assigned` lists assigned work.
- `POST /api/objectives` can create objective once project is known.
- Objective messages can hold discussion.

Missing:

- Full Jira issue read: description, comments, links, custom fields, assignee/reporter.
- Jira issue creation.
- Jira comment draft/preview/post.
- Jira update/edit operations.
- Contact directory.
- Context packet API.
- Open question tracking.
- Readiness scoring.
- Project detection/recommendation from ticket text.
- Dox-specific setup hook (`dox-start`) as a server action.

Recommended new APIs:

```http
GET /api/jira/issue-full?q=KEY_OR_URL
POST /api/jira/issues
POST /api/jira/issues/{key}/comment/preview
POST /api/jira/issues/{key}/comments
PATCH /api/jira/issues/{key}
GET /api/contacts
POST /api/contacts
PATCH /api/contacts/{id}
POST /api/intake/from-jira
POST /api/intake/from-slack
GET /api/intake/{id}
PATCH /api/intake/{id}
POST /api/intake/{id}/questions
PATCH /api/intake/{id}/questions/{questionId}
POST /api/intake/{id}/build-context-packet
POST /api/intake/{id}/convert-to-objective
```

Context packet storage:

```text
~/.cmux-harness/intake/{id}/intake.json
~/.cmux-harness/intake/{id}/jira.md
~/.cmux-harness/intake/{id}/links.md
~/.cmux-harness/intake/{id}/people.md
~/.cmux-harness/intake/{id}/open-questions.md
~/.cmux-harness/intake/{id}/readiness.json
~/.cmux-harness/intake/{id}/context.md
```

Readiness model:

```json
{
  "score": 72,
  "state": "needs_context",
  "missing": ["offline expired-token behavior", "Figma source of truth"],
  "known": ["backend PR", "Slack thread", "PM"],
  "recommendedNextQuestion": "For expired tokens while offline, should the app show retry, keep stale session, or force login when back online?"
}
```

### 4. Agent Selection / Launch

Mock needs:

- Recommend Claude Code vs Codex.
- Launch selected agent.
- Use complete context packet.
- Track session as an objective/task card.

Current support:

- cmux + Claude Code session spawning exists.
- Objective planner/worker pipeline launches Claude Code.
- Workspace session pipeline launches Claude Code sessions.
- Action buttons inject prompts into new Claude Code workspaces.

Missing:

- Codex support.
- Generic coding-agent provider abstraction.
- Agent recommendation API.
- Explicit `agentType` field on objective/task/workspace.
- Ability to launch non-Claude Code workers.
- Agent capability/default preference memory.

Recommended new APIs:

```http
GET /api/agents
POST /api/agents/recommend
POST /api/objectives/{id}/launch-agent
POST /api/tasks/{id}/launch-agent
```

Potential agent registry:

```json
{
  "id": "codex",
  "label": "Codex",
  "supports": ["repo_edit", "tests", "long_context"],
  "launchMode": "external_cli_or_acp",
  "available": true
}
```

Backend design:

- Keep Claude Code through cmux as current provider.
- Add `AgentProvider` interface:
  - `create_session(contextPacket, taskSpec)`
  - `send_message(sessionId, message)`
  - `read_status(sessionId)`
  - `stop(sessionId)`
  - `collect_result(sessionId)`
- Implement `ClaudeCodeCmuxProvider` first using existing functions.
- Implement `CodexProvider` second, depending on how Codex is controlled on the work machine.

### 5. Active Execution / Check-ins

Mock needs:

- Check in on all work.
- Check in on one objective.
- Fresh status summary from objective/session.
- Stale detection.
- Conflict watch.

Current support:

- Objective `poll_tasks` monitors progress/stuck state.
- Workspace status summaries exist per objective/workspace.
- Debug logs and messages exist.
- `GET /api/status` has raw cmux state.
- `monitor.assess_stuck_status` exists.

Missing:

- One-shot check-in endpoint for all work.
- One-shot check-in endpoint for one objective/task/workspace.
- Persisted check-in records.
- Typed health summary per objective/card.
- Cross-session conflict detector.
- File overlap tracking across tasks/objectives.
- Parallel task capacity controls.

Recommended new APIs:

```http
POST /api/check-ins
POST /api/objectives/{id}/check-in
POST /api/workspaces/{id}/check-in
GET /api/check-ins?limit=50
GET /api/conflicts
POST /api/conflicts/scan
```

Check-in record:

```json
{
  "id": "...",
  "targetType": "objective|workspace|all",
  "targetId": "...",
  "createdAt": "...",
  "summary": "UI cleanup worker is active but has a watched overlap.",
  "health": "green|amber|red|needs_human",
  "signals": {
    "progressUpdated": true,
    "gitActivity": true,
    "terminalActivity": true,
    "waitingForApproval": false,
    "conflicts": 1
  },
  "recommendedAction": "continue_watching"
}
```

### 6. Decision Queue

Mock needs:

- First-class decisions.
- Recommendation, options, consequence, preview.
- Approve/edit/skip.
- Link decision to objective/task/Jira write/agent launch.

Current support:

- Objective messages include `alert`, `plan_review`, `review`, etc.
- Plan approval endpoints exist.
- Hook approval endpoints exist.
- Task approval endpoint exists.

Missing:

- Persistent typed decisions independent of chat messages.
- Decision status lifecycle.
- Decision actions that execute registered callbacks.
- Decision preview payloads.
- Decision queue aggregate endpoint.

Recommended new APIs:

```http
GET /api/decisions
POST /api/decisions
GET /api/decisions/{id}
POST /api/decisions/{id}/approve
POST /api/decisions/{id}/reject
POST /api/decisions/{id}/edit
POST /api/decisions/{id}/snooze
```

Decision model:

```json
{
  "id": "...",
  "status": "open|approved|rejected|snoozed|resolved",
  "kind": "jira_comment|agent_launch|plan_approval|scope_split|risky_action|review_failure",
  "title": "Post Jira clarification comment?",
  "summary": "Auth refresh is missing offline behavior.",
  "recommendation": "Approve and tag PM + designer.",
  "risk": "Launching now risks rework.",
  "options": [
    {"id": "approve", "label": "Approve + post"},
    {"id": "edit", "label": "Edit preview"},
    {"id": "skip", "label": "Skip"}
  ],
  "preview": {...},
  "target": {"type": "objective", "id": "..."}
}
```

### 7. Review / PR Pipeline

Mock needs:

- Review-ready lane.
- Review packet.
- Quality gates.
- PR creation/update.
- Jira final update.
- Learning capture.

Current support:

- Generic reviews exist.
- Objective task review/rework loop exists.
- Git diff/status endpoints exist.
- GitHub PR comment lookup exists.
- Objective completion summary exists.

Missing:

- Objective-level review packet endpoint.
- Build/test gate API as a first-class operation.
- PR create/draft/open/update API.
- Jira transition/update on completion.
- Learning/memory capture API.

Recommended new APIs:

```http
GET /api/objectives/{id}/review-packet
POST /api/objectives/{id}/run-quality-gates
POST /api/objectives/{id}/create-pr
POST /api/objectives/{id}/update-jira-completion
POST /api/memory/lessons
GET /api/memory/lessons
```

### 8. Voice Layer

Mock needs:

- Floating mic.
- Voice overlay.
- Voice can call orchestrator tools.

Current support:

- None in harness.
- Research doc says GPT-Realtime-2 should be an interaction layer, not source of truth.

Missing:

- Realtime session creation endpoint.
- Sideband server connection.
- Tool gateway to orchestrator APIs.
- Transcript persistence.
- Voice confirmation rules.

Recommended future APIs:

```http
POST /api/voice/sessions
GET /api/voice/sessions/{id}
POST /api/voice/sessions/{id}/end
GET /api/voice/sessions/{id}/transcript
```

Keep this later. Do not block MVP on voice.

---

## Most Important Feasibility Findings

### 1. The core Objective engine already exists

The hardest backend idea, goal → plan → tasks → worker → monitor → review/rework → completion, is already present.

The production UI can plug into:

- `POST /api/objectives`
- `POST /api/objectives/{id}/start`
- `GET /api/objectives/{id}/messages`
- `POST /api/objectives/{id}/approve-plan`
- `POST /api/objectives/{id}/message`
- task screen/debug/status/build/console endpoints.

This is not greenfield.

### 2. The UX wants an aggregate API, not many tiny calls

The home screen should not call 40 endpoints and reason client-side. The backend should produce a command-center view model.

Build `GET /api/command-center` early.

### 3. Ideas and Pre-Jira are missing entirely

This is a product-defining gap. Add `ideas` and `intake` as first-class resources instead of cramming them into objectives.

### 4. Jira is only read-only and shallow

Current Jira API can bootstrap assignment/ticket lookup, but real pre-flight needs full ticket context and write/comment support.

### 5. Decision Queue should become first-class

Right now decisions are scattered as messages/approvals/plan states. The CEO dashboard needs durable decision objects.

### 6. Parallel task orchestration is not actually enabled yet

Docs describe parallel workers, but `_launch_ready_tasks` currently blocks if any task is active and launches only the first ready task. That is fine for MVP reliability, but the product should represent it honestly or add capacity controls.

Add later:

```json
"maxConcurrentTasks": 1 | 2 | 3
```

### 7. Codex needs a provider abstraction

Current implementation is Claude Code/cmux-first. Codex support should not be bolted into random branches. Add an agent provider abstraction.

---

## Recommended Build Order

### Phase 1: Make the mock real with current APIs

Add only the minimum aggregate API needed by the new UI.

1. `GET /api/command-center`
2. `POST /api/check-ins`
3. Use existing objectives/workspaces/messages/status summaries.
4. Render current real objectives into lanes.
5. Link cards to existing objective/workspace detail.

This proves the new home screen against live harness data.

### Phase 2: Add Ideas / Pre-Jira

1. `GET/POST/PATCH/DELETE /api/ideas`
2. Idea lanes/status transitions.
3. Convert idea to intake or objective.
4. Keep storage filesystem-backed.

### Phase 3: Add Jira Intake

1. Full Jira read.
2. Intake resource and context packet storage.
3. Open questions/readiness scoring.
4. Jira comment preview.
5. Jira comment post after approval.
6. Contact directory.

### Phase 4: Add Decision Queue

1. Decision store and endpoints.
2. Convert plan approvals, hook approvals, Jira previews, launch confirmations into decision objects.
3. Home top priority comes from decision ranking.

### Phase 5: Agent Provider abstraction

1. Wrap Claude Code/cmux as provider.
2. Add Codex provider.
3. Agent recommendation endpoint.
4. Launch selected provider from objective/task/intake.

### Phase 6: Quality/PR/Learning polish

1. Review packet endpoint.
2. Quality gates endpoint.
3. PR creation/update.
4. Jira completion update.
5. Lessons/preferences memory.

### Phase 7: Voice layer

1. Realtime session endpoint.
2. Sideband tool gateway.
3. Voice transcript persistence.
4. Confirmation rules for writes.

---

## MVP API Set

If we want the smallest API set that makes the new app feel real:

```http
GET  /api/command-center
POST /api/check-ins
GET  /api/ideas
POST /api/ideas
PATCH /api/ideas/{id}
POST /api/ideas/{id}/transition
GET  /api/decisions
POST /api/decisions/{id}/approve
POST /api/decisions/{id}/reject
GET  /api/intake/{id}
POST /api/intake/from-jira
POST /api/intake/{id}/questions
POST /api/intake/{id}/build-context-packet
```

Everything else can reuse current objective/workspace APIs temporarily.

---

## Backend Resources to Add

```text
~/.cmux-harness/
  ideas/
    {id}/idea.json
    {id}/messages.jsonl
    {id}/research.md
    {id}/jira-draft.md
  intake/
    {id}/intake.json
    {id}/messages.jsonl
    {id}/jira.md
    {id}/links.md
    {id}/people.md
    {id}/open-questions.md
    {id}/readiness.json
    {id}/context.md
  decisions/
    {id}.json
  check-ins/
    YYYY-MM-DD.jsonl
  contacts/
    contacts.json
  memory/
    preferences.json
    lessons.jsonl
```

---

## Final Recommendation

Do not start by rewriting the orchestrator engine. Keep the current objective engine and build the missing product shell around it.

The next real implementation target should be:

**Command Center API + Ideas API + Decision Queue API.**

That unlocks the new home screen and gives Ronnie the bird's-eye workflow without touching the riskiest planner/worker internals yet.
