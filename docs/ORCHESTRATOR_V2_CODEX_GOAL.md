# Codex Goal: Build Orchestrator V2

## Mission

Build Orchestrator V2 end to end on the `orchestrator-v2` branch.

Orchestrator V2 is Ronnie's personal work command center on top of cmux. It replaces the older objective/command-center mental model with a local Task source of truth. Jira tickets, GitHub PRs, cmux sessions, git state, goal documents, agent activity, approvals, and chat/voice orchestration attach to Tasks.

The goal is not a mockup. The goal is a working local web app backed by real APIs, real SQLite storage, real cmux session control, and a React UI that can become CopilotKit/Vercel-AI driven.

## Repository Context

Repo:

```txt
/Users/ronnierocha/projects/cmux-orchestrator
```

Current branch:

```txt
orchestrator-v2
```

Important existing docs:

- `docs/ORCHESTRATOR_V2_SPEC.md`
- `docs/COPILOTKIT_INTEGRATION.md`
- `docs/API_REFERENCE.md`
- `docs/ORCHESTRATOR_V2_DESIGN_GUIDE.md`

Before touching live APIs, read `docs/API_REFERENCE.md`, especially `Live Dashboard Targets` and `Safe Live Verification Rules`.

Before building UI, read `docs/ORCHESTRATOR_V2_DESIGN_GUIDE.md` and use the six bundled screenshots in `docs/assets/orchestrator-v2/` as the visual reference.

Important existing code:

- `cmux_harness/server.py`
- `cmux_harness/cmux_api.py`
- `cmux_harness/routes/jira.py`
- `cmux_harness/routes/github.py`
- `cmux_harness/routes/workflow.py`
- `cmux_harness/routes/workspaces.py`
- `cmux_harness/static/workflow-orchestrator.html`
- `cmux_harness/static/workflow-orchestrator.js`
- `cmux_harness/static/workflow-orchestrator.css`
- `tests/test_jira_route.py`
- `tests/test_workflow_routes.py`

Existing code may be reused, copied, or replaced where it fits. Do not force v2 into the old command-center/objective model.

## Product Summary

V2 has four main surfaces:

1. Left rail
   - assigned Jira tickets
   - my open PRs
   - my draft PRs
   - PRs waiting for my/team review
   - collapsible sections
   - collapsible rail

2. Task board
   - grid of local Tasks
   - local Task status is source of truth
   - cards expose CTAs to add/attach resources and open detail views
   - Done/Archived are hidden from active board and moved to history

3. Center detail views
   - git diff view
   - embedded cmux session/terminal view
   - goal markdown view/editor
   - back to task board CTA

4. Top-level orchestrator agent
   - one global chat transcript
   - voice-compatible design
   - Vercel AI SDK first
   - CopilotKit for dynamic UI
   - stateless agent turns over durable app memory
   - full cmux control through curated tools

## Hard Requirements

### Storage

Use SQLite for V2.

Create a v2 storage layer that does not depend on the old objective storage.

Required persistent entities:

- Task
- TaskJiraLink
- TaskPullRequestLink
- TaskCmuxSessionLink
- TaskTag
- TaskGoalDocument
- TaskSessionSummary
- CmuxSessionSnapshot
- OrphanSessionCandidate
- GlobalChatMessage
- AgentToolRun
- ApprovalRequest
- AuditEvent
- ActivityEvent

Goal markdown files should live on disk and be referenced from SQLite.

### Task Model

Required Task fields:

- id
- title
- status
- workspaceDir
- priority
- createdAt
- updatedAt

Statuses:

- Backlog
- Investigating
- To Do
- Running
- Blocked
- In Review
- Done
- Archived

Priorities:

- Low
- Medium
- High

Tasks are flat in v1. Do not build hierarchy unless needed internally for a clean future extension.

### Task Creation

Creating a task immediately creates a cmux session.

New task required inputs:

- title
- status
- priority
- workspaceDir
- session launch type

Session launch types:

- Empty shell
- Codex
- Claude Code
- OpenCode

If the user/agent does not specify a coding agent, create an empty shell or ask for clarification depending on context. The system must not silently choose a coding agent.

Every new task creates a local goal markdown file from a template.

### Goal Markdown

Each task has an editable goal markdown document.

The UI must let Ronnie view and edit the goal document.

The agent tool layer must be able to read and update the goal document.

Add the product hook for a future **Discuss Goal** flow:

- chat or voice interview
- agent asks clarifying questions
- agent updates goal markdown
- Ronnie can inspect and edit final result

The full conversational Discuss Goal flow may be implemented later, but the storage and API should not block it.

### Jira

Jira is an attached resource, not the source of truth.

Rules:

- A task may have multiple Jira tickets.
- Attaching a Jira ticket copies title/status once into local metadata.
- Task status and Jira status are separate.
- Add manual resync support for attached Jira ticket metadata.
- Jira transitions are allowed without approval.
- Jira comments require preview and approval.
- Left rail lists all Jira tickets assigned to Ronnie across all assigned projects.
- Left rail Jira items are read-only shortcuts and open Jira in a new tab.
- No plus button in the Jira left-rail section.

### GitHub

PRs are attached resources.

Rules:

- A task may have multiple PRs.
- A task may have one primary PR for card display.
- Left rail has separate collapsible sections:
  - my open PRs
  - my draft PRs
  - PRs waiting for review from me or my team
- Draft PRs are visible by default.
- PR replies/reviews require approval.
- Local task data does not sync back to GitHub labels/comments automatically.

### cmux

cmux control is first-class.

Session identity:

- cmux workspace ID
- surface/pane/session ID

Rules:

- One task can have multiple cmux sessions.
- One cmux session cannot be attached to multiple tasks.
- Orphans are active cmux sessions not attached to a task.
- Closed cmux sessions disappear from orphan list.
- Turning an orphan into a task opens New Task modal prefilled from available session data.
- Store one merged session summary per task.
- Cache session summaries with freshness checks.

Use the cmux CLI where practical:

```txt
/Users/ronnierocha/projects/cmux/build/Build/Products/Release/cmux
```

Implement a `cmux_cli.py` adapter or equivalent so v2 tool/API code does not shell out ad hoc everywhere.

Capabilities needed:

- list sessions/workspaces/surfaces
- read terminal screen/scrollback
- search session text
- create cmux workspace
- send text/prompt
- send key
- launch Codex/Claude Code/OpenCode
- inspect/classify what is running

### Agent Control Plane

Expose curated backend tools for the top-level orchestrator agent.

Read/search tools:

- list_tasks
- get_task
- search_tasks
- list_cmux_sessions
- read_cmux_session
- search_cmux_sessions
- inspect_cmux_session
- summarize_task_sessions
- find_jira_ticket
- list_assigned_jira
- list_my_open_prs
- list_my_draft_prs
- list_prs_waiting_for_review
- get_git_status
- get_git_diff

Create/update tools:

- create_task
- update_task_status
- update_task_priority
- update_task_tags
- attach_jira_to_task
- attach_pr_to_task
- attach_cmux_session_to_task
- detach_cmux_session_from_task
- create_cmux_session
- launch_coding_agent
- send_cmux_prompt
- update_goal_markdown
- create_approval_request

Write tools requiring approval:

- post Jira comment
- post PR reply/review
- destructive git operation
- kill session
- restart session

Write tools not requiring approval:

- update local task status
- update local tags
- transition Jira status
- send follow-up prompt to an existing coding task/session

All agent actions must be written to an audit log.

### Chat, Voice, And Memory

Use one global top-level orchestrator conversation.

Rules:

- Voice and chat share the same transcript.
- Transcript is global, not per task.
- The agent can discuss multiple tasks in one conversation.
- A slide-out chat/history view should let Ronnie inspect the conversation.
- Do not build a multi-chat ChatGPT clone.

Use stateless agent turns over durable app memory:

- SQLite task data
- goal markdown
- notes
- task merged session summaries
- global chat transcript
- tool runs
- approvals
- audit log
- activity events

### Proactive Updates

Add a 10-minute proactive watcher plus manual refresh.

Watcher responsibilities:

- refresh Jira data
- refresh GitHub PR data
- refresh cmux session list
- inspect changed/active sessions
- update merged task session summaries
- detect orphan sessions
- create activity events
- surface important UI updates

Activity stream rules:

- show every tool call for now
- group tool calls by user request or watcher run
- use reusable toast/activity events for automated actions and changes

### UI Requirements

Build a React app for v2.

Use Vercel AI SDK for chat/tool loop first.

Use CopilotKit for dynamic UI once the v2 app shell and data contracts are in place.

Route:

- Prefer `/orchestrator-v2` or `/workflow-orchestrator-v2` during development.
- Do not break the existing workflow orchestrator route until v2 is ready.

Task board:

- grid first
- no list view in initial implementation
- task cards are not globally clickable
- CTAs inside cards open actions/views
- Done/Archived are in history

Center views:

- git diff takes over primary center view
- cmux terminal view takes over primary center view
- goal markdown editor/view takes over primary center view
- each center view has Back to Tasks

Left rail:

- collapsible sections
- whole rail can collapse to mini rail
- no plus buttons for Jira/PR intake sections
- left rail items open external Jira/GitHub links in new tabs

## Non-Goals For Initial Build

Do not spend initial implementation time on:

- task hierarchy UI
- list view
- read-only demo mode
- syncing local task data to Jira/GitHub labels/comments
- prompt templates
- full voice-to-voice production flow
- multi-chat conversation management
- migrating old objective data

## Definition Of Done

This goal is complete when all items below are true.

### Backend Done

- SQLite v2 storage exists and is used by v2 APIs.
- Task CRUD works.
- Tasks require `workspaceDir`.
- Task creation creates a cmux session.
- Task creation creates a goal markdown document from a template.
- Task supports many Jira links.
- Task supports many PR links.
- Task supports many cmux session links.
- cmux session cannot be attached to more than one task.
- Active unlinked cmux sessions are returned as orphans.
- Left rail APIs exist for assigned Jira, open PRs, draft PRs, and PRs waiting for review.
- Git status/diff APIs are available to v2.
- Goal markdown read/update APIs exist.
- Agent tool API surface exists for read/search/control operations.
- Approval request storage and APIs exist.
- Audit log records agent actions.
- Activity/toast event APIs exist.
- Proactive watcher can run manually and on a 10-minute cadence.

### Frontend Done

- React v2 app is served by the Python harness.
- Task board renders live v2 data.
- New Task modal requires workspace dir and session launch type.
- New Task creates task, cmux session, and goal markdown.
- Task cards show status, priority, workspace, branch, Jira/PR links, tags, cmux session count, and CTAs.
- Left rail renders assigned Jira, open PRs, draft PRs, and review-request PRs in collapsible sections.
- Left rail can collapse.
- Orphan sessions render and can prefill the New Task modal.
- Git diff opens in primary center view with Back to Tasks.
- cmux session view opens in primary center view with Back to Tasks.
- Goal markdown view/editor exists.
- Global chat surface exists.
- Activity/toast stream exists and groups tool calls by run.

### Agent Done

- Vercel AI SDK chat endpoint exists.
- Agent can read current tasks.
- Agent can search for a task by keyword/Jira/PR/session.
- Agent can list and inspect cmux sessions.
- Agent can answer status questions using task state plus session summaries.
- Agent can create a task from a Jira ticket or user request.
- Agent can create a cmux session and attach it to a task.
- Agent can launch Codex, Claude Code, OpenCode, or empty shell based on explicit user choice.
- Agent can send follow-up prompts to existing coding task sessions without approval.
- Agent creates approval requests for external posts, PR replies/reviews, destructive git, and kill/restart session.
- Agent actions are audited.

### Quality Gates Done

- Existing tests still pass.
- New backend v2 API tests exist and pass.
- New storage/repository tests exist and pass.
- New cmux adapter tests exist with mocked CLI.
- New frontend build passes.
- At least one end-to-end happy path is covered:
  1. create task
  2. create cmux session
  3. create goal markdown
  4. attach Jira
  5. attach PR
  6. view task on board
  7. inspect session
  8. open git diff
  9. ask agent for status

## Required Verification Commands

Live dashboard/API verification must be read-only unless Ronnie explicitly tests or approves the specific action.

Allowed live checks include static page loads, `GET` status/list/detail endpoints, read-only git status/diff endpoints, and read-only cmux CLI inspection such as `tree`, `read-screen`, `capture-pane`, and `find-window`.

Do not test live mutating behavior yourself. That includes sending terminal prompts, creating/killing/restarting sessions, changing harness config, approving actions, Jira comments/transitions, GitHub comments/reviews, git staging/commits/resets, push notification registration, or external posts.

When a required feature cannot be safely tested by the agent against live data, mark it as `Needs Ronnie live test` in the final report with exact reproduction steps.

Run the repo's available Python tests:

```bash
python3 -m unittest discover tests
```

If frontend tooling is added, also run the relevant frontend gates, for example:

```bash
cd frontend/orchestrator-v2
npm install
npm run build
npm run test -- --run
```

If a dev server is needed for browser QA, start it and verify the Tailscale URL when reporting status.

## Implementation Guidance

Prefer incremental vertical slices.

Recommended order:

1. Add SQLite storage and migrations.
2. Add v2 task repository and tests.
3. Add cmux CLI adapter and mocked tests.
4. Add v2 task/session/Jira/PR linking APIs.
5. Add goal markdown template/read/update.
6. Add React v2 shell and task board.
7. Add New Task modal and cmux session creation.
8. Add left rail data sections.
9. Add orphan session detection/attach flow.
10. Add git diff and cmux center views.
11. Add activity/toast/audit events.
12. Add Vercel AI SDK chat endpoint and tools.
13. Add CopilotKit dynamic UI integration.
14. Add proactive watcher.
15. Add full end-to-end QA.

Keep commits focused. Do not mix large UI work, storage migrations, and agent runtime in one commit if avoidable.

## Reporting Requirements

When reporting progress, include:

- current branch
- changed files
- tests run
- what works now
- what remains
- any decisions or blockers

When the goal is complete, provide:

- final feature summary
- local URL or Tailscale URL
- test results
- known limitations
- suggested next improvements

## Success Statement

This build succeeds when Ronnie can open the v2 orchestrator, see his local task board, create a task that immediately creates a cmux session and goal document, attach Jira/PR/cmux resources, inspect git diff and terminal sessions in the main view, and ask the top-level agent for task/session status with answers grounded in durable task state and live cmux session inspection.
