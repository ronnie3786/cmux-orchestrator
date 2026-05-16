# Orchestrator V2 Product And Technical Spec

Date: 2026-05-16

## Product Direction

Orchestrator v2 is Ronnie's personal work command center built on top of cmux. It is not Jira-first and it is not a generic project dashboard.

The source of truth is a local Task model. Jira tickets, GitHub PRs, cmux sessions, git state, notes, goals, and agent activity attach to tasks.

The top-level orchestrator agent can be reached through chat and voice. It reads the same task/session state the UI renders, can inspect active cmux sessions, and can take approved actions through backend tools.

Visual reference lives in `docs/ORCHESTRATOR_V2_DESIGN_GUIDE.md`. The six screenshot assets are bundled under `docs/assets/orchestrator-v2/` and should be treated as the concrete layout target for V2.

## Core Architecture Decisions

- Frontend: React app.
- Dynamic UI: CopilotKit.
- Agent/chat runtime: Vercel AI SDK first.
- Voice path: compatible with GPT Realtime 2 later, but not required for the first build.
- Backend: keep the existing Python harness as the source of local cmux/Jira/GitHub/git operations unless a later Node sidecar proves necessary.
- Storage: SQLite for v2.
- Existing command-center/objective APIs are reference material, not the v2 source of truth.
- v2 starts fresh. No migration from existing objectives.
- Credentials stay backend-only.

## Memory Model

The top-level agent should feel long-running, but it should not depend on one fragile long-running process for memory.

Use stateless agent turns over durable app memory:

- SQLite tasks
- task goal markdown
- task notes
- task-level merged session summary
- global chat transcript
- agent tool runs
- approval requests
- audit log
- activity/toast events

Each chat or voice turn loads the relevant durable state, acts, writes updates back, and streams UI changes.

## Task Model

Tasks are flat for v1. No hierarchy.

Required fields:

- id
- title
- status
- workspaceDir
- priority
- createdAt
- updatedAt

Optional fields:

- description
- featureBranch
- tags
- Jira links
- GitHub PR links
- cmux session links
- goal markdown path
- merged session summary

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

Done and Archived tasks move to a history view and do not clutter the active task board.

## Goal Markdown

Every task gets a local goal markdown document when created.

The goal document should be:

- created from a template
- editable in the UI
- readable by the top-level orchestrator agent
- updateable by the agent when explicitly working through a goal discussion flow

Future UX: **Discuss Goal**.

This is an interview-style chat or voice flow where the agent asks clarifying questions, helps refine scope, and updates the goal document until Ronnie approves the direction.

## Jira

Jira is an attached resource, not the source of truth.

Rules:

- A task can have multiple Jira tickets.
- Attaching Jira copies title/status once into local metadata.
- Jira status remains separate from orchestrator task status.
- Manual resync updates copied Jira metadata.
- Jira transitions are allowed without approval.
- Jira comments require preview and approval.
- Search/list Jira across all projects assigned to Ronnie.
- Local task data does not sync back to Jira labels/comments automatically.

Left rail:

- Shows assigned Jira tickets.
- Read-only for v1.
- Jira items open Jira in a new tab.
- Remove plus buttons from the Jira section.

## GitHub PRs

PRs are attached resources.

Rules:

- A task can have multiple PRs.
- A task can have one primary PR for card display.
- Open authored PRs and draft authored PRs appear separately.
- PRs waiting for review from Ronnie or Ronnie's team appear in their own section.
- Draft PRs are visible by default.
- PR replies/reviews require approval.
- PR checks/status can be refreshed, but deeper checks can be deferred if needed.
- Local task data does not sync back to GitHub labels/comments automatically.

Left rail sections:

- Assigned Jira tickets
- My open PRs
- My draft PRs
- PRs waiting for my/team review

All left-rail sections should be collapsible. The whole left rail should collapse to a mini rail.

## cmux Sessions

cmux control is a first-class v2 capability.

Session identity:

- cmux workspace ID
- surface/pane/session ID

One task can have multiple cmux sessions. One cmux session cannot be attached to multiple tasks.

Orphan sessions:

- active cmux sessions only
- any active cmux session not linked to a task
- closed sessions disappear from the orphan list
- turning an orphan into a task opens the New Task modal prefilled from available data

Session summaries:

- store one merged summary per task
- summary combines all attached cmux sessions
- cache summaries with freshness checks
- agent can refresh summaries manually or during proactive scans

## Task Creation

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

The agent should not silently choose a coding agent. If the user does not specify Codex, Claude Code, or OpenCode, the agent should ask or create an empty shell based on the flow.

No prompt templates in v1. Prompt templates can be added later.

## Agent Control Plane

The top-level orchestrator agent should have curated tools, not raw browser/DOM access.

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

All agent actions are written to the audit log.

## Chat And Voice

There is one global top-level orchestrator conversation.

Rules:

- Voice and chat share the same transcript.
- The transcript is global, not per task.
- The agent can discuss multiple tasks in one conversation.
- A slide-out chat/history view should let Ronnie inspect prior conversation.
- The UI should not try to recreate a multi-chat ChatGPT-style product.

## Proactive Updates

Start with a 10-minute proactive watcher plus manual refresh.

Watcher responsibilities:

- refresh Jira data
- refresh GitHub PR data
- refresh cmux session list
- inspect changed/active sessions
- update task merged session summaries
- detect new orphan sessions
- surface important activity events

Important updates should appear as reusable toast/activity events.

Activity stream rules:

- show all tool calls for now
- group tool calls by user request or proactive watcher run
- refine filtering later once the signal/noise profile is clear

## UI Behavior

Main board:

- grid first
- list view later
- task cards are not generally clickable in v1
- CTAs inside cards navigate to task-specific views/actions

Task card CTAs:

- add/attach Jira
- add/attach PR
- create/attach cmux session
- open git diff
- open cmux sessions
- edit goal
- discuss goal

Git diff:

- full main center view
- maximum space
- Back to Tasks CTA

cmux terminal/session view:

- embedded in orchestrator
- full main center view
- Back to Tasks CTA

Left rail:

- collapsible
- read-only shortcuts for v1
- links open Jira/GitHub in new tabs

## Data Storage Sketch

SQLite tables likely needed:

- tasks
- task_jira_links
- task_pr_links
- task_cmux_session_links
- task_tags
- task_goal_documents
- task_session_summaries
- cmux_session_snapshots
- orphan_session_candidates
- global_chat_messages
- agent_tool_runs
- approval_requests
- audit_events
- activity_events

Goal markdown files can live on disk and be referenced by SQLite.

## Open Follow-Ups

- Final Vercel AI SDK + CopilotKit server topology.
- Exact schema for goal markdown template.
- Exact proactive watcher event thresholds.
- Exact cmux session summary freshness heuristic.
- Whether Node sidecar is needed for Vercel AI SDK or whether Python remains the only backend initially.

## Recommended Implementation Order

1. Add v2 SQLite schema and repository layer.
2. Add task CRUD and linking APIs.
3. Add cmux CLI adapter and session snapshot APIs.
4. Add GitHub/Jira provider clients for v2 left rail.
5. Add React task board route.
6. Add goal markdown creation/editing.
7. Add cmux session attach/orphan flow.
8. Add git diff and embedded session center views.
9. Add Vercel AI SDK chat endpoint and backend tool layer.
10. Add CopilotKit dynamic UI events/tools.
11. Add proactive 10-minute watcher.
12. Add voice path.
