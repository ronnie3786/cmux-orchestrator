# Orchestrator V2: Live Updates + Full cmux Session Control

This update closes the two biggest gaps between the Orchestrator V2 scaffold and the
Jarvis-style goal in `ORCHESTRATOR_GOAL.md`: the orchestrator now pushes constant
updates to the UI instead of waiting for a poll, and it can fully manage cmux session
lifecycle (create, prompt, inspect, **kill, restart**) with approval gates for
agent-initiated destructive actions.

## Constant updates

- `GET /api/orchestrator-v2/events/stream` — Server-sent events stream. The backend
  computes a cheap state token over tasks, approvals, activity, audit, tool runs, chat,
  and orphan candidates, and emits an `update` event whenever it changes. Heartbeats
  keep the connection alive.
- `GET /api/orchestrator-v2/events/token` — the current state token (used by tests and
  pollers).
- The React app connects an `EventSource` on load and refetches the bootstrap payload
  on every `update` event. A **Live / Connecting / Polling** indicator in the top bar
  shows the connection state; if SSE drops, the app falls back to 30s polling and
  retries the stream every 15s.
- The watcher now runs every 3 minutes by default (`ORCHESTRATOR_V2_WATCHER_INTERVAL`
  overrides it) and performs **change detection** between passes: session state
  transitions (idle → running_tool → error → completed) and newly detected orphan
  sessions are recorded as grouped, human-readable activity events
  (`session_state_changed`, `orphan_detected`, `watcher_summary`).

## Full cmux session lifecycle

- `CmuxCli.close_session()` closes a workspace through the cmux socket API
  (`workspace.close`) with a CLI fallback; `CmuxCli.restart_session()` closes and
  relaunches with the same title/cwd/launch type.
- Direct human controls (no approval needed, confirm dialog in the UI):
  - `POST /api/orchestrator-v2/cmux/sessions/{workspaceId}/kill`
  - `POST /api/orchestrator-v2/cmux/sessions/{workspaceId}/restart`
  Both detach/relink task session links and record tool runs + activity events.
- Agent tools `kill_cmux_session` and `restart_cmux_session` are no longer
  `not_implemented`. They are **approval-gated**: the agent (text chat, realtime voice,
  or local voice) creates an approval request with the exact reviewed payload; only an
  approved decision executes the stored payload. Denials never execute.
- Approval execution is handled in `execute_approved_payload` alongside Jira comments.
- The UI renders lifecycle approvals with a dedicated `SessionLifecycleApprovalPanel`
  (also allow-listed in the sidecar AG-UI panel registry).
- Still explicitly not implemented: `post_pr_reply`, `submit_pr_review`,
  `run_destructive_git_operation`.

## UI integration (subpages all wired)

- **Rail navigation**: Board / Activity / History replace the dead "All Work" row.
- **Activity view** (new): full activity feed grouped by run (watcher runs, agent runs,
  lifecycle actions) with kind pills and a **Run Watcher Now** button
  (`POST /watcher/run`).
- **History view** (new): all Done/Archived tasks with diff links and one-click
  **Reopen**; the board history strip links to it via "View all".
- **Board list view**: the previously disabled list toggle is now a real list layout
  (persisted per browser).
- **Session view**: Restart Session is enabled, Stop Session added, per-tab close kills
  that session, New Session launches and attaches a fresh session, the terminal
  auto-refreshes every 5 seconds (toggleable) with a manual refresh + last-updated
  time, and the attach command shows the real workspace id. "Explain Output" sends the
  latest screen excerpt to the agent; "Ask Agent" asks for a grounded status check of
  the task's sessions.
- **Task sidebar**: working Task/Activity tabs (activity filtered to the task and its
  sessions), session summary freshness, and wired quick actions. Hardcoded demo
  content (fake PIDs, fake recent commands, fake timer) removed.
- **PR reviews**: "Needs Review" rail cards now have a **Review** button that calls
  `POST /pr-reviews/start` and jumps into the created review session.
- **Error/empty states**: retryable error strip, per-rail-section provider error
  labels, and helpful empty states for board/activity/history/terminal.

## Safety model recap

| Action | Human via UI | Agent |
| --- | --- | --- |
| create/list/read/inspect/send prompt/key | direct | direct (audited) |
| kill / restart session | direct + confirm dialog | approval request, executes on approve |
| Jira transition | direct | direct (audited) |
| Jira comment | n/a | approval request |
| PR reply/review, destructive git | not implemented | explicit `not_implemented` |

All lifecycle executions are recorded to `agent_tool_runs`, `audit_events`, and
`activity_events`, so the Activity view and SSE stream narrate them immediately.
