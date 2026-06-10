# cmux-harness API Reference

Complete catalog of every API available to this project: the cmux socket/CLI APIs we consume, and the harness HTTP APIs we expose.

This document is also the safety contract for agents testing against Ronnie's real cmux dashboard. Read-only probes are allowed. Mutating calls against live Jira, GitHub, git workspaces, cmux sessions, terminal panes, approvals, notifications, or local config are not allowed unless Ronnie explicitly performs or approves that specific test.

---

## Live Dashboard Targets

Known dashboard targets:

- Static orchestrator mock: `http://100.89.93.84:8788/orchestrator-app-mock.html`
- Local harness default: `http://localhost:9091/harness`
- Tailscale harness default if running on the Mac Studio: `http://100.89.93.84:9091/harness`

These URLs are runtime targets, not guaranteed always-on services. Before relying on any live target, run a read-only health check:

```bash
curl -fsS --max-time 5 http://100.89.93.84:8788/orchestrator-app-mock.html >/dev/null
curl -fsS --max-time 5 http://100.89.93.84:8788/api/status | python3 -m json.tool | head -n 80
```

If the live dashboard is not reachable, continue with local tests and mocked adapters. Do not start, stop, rename, close, or modify real cmux sessions just to make a test pass.

### Safe Live Verification Rules

Allowed against the live dashboard:

- `GET` HTML/static pages.
- `GET /api/status`
- `GET /api/network`
- `GET /api/log`
- `GET /api/feed`
- `GET /api/config`
- `GET /api/models`
- `GET /api/workspaces`
- `GET /api/command-center`
- `GET /api/briefing`
- `GET /api/objectives`
- `GET /api/projects`
- `GET /api/ideas`
- `GET /api/preflights`
- `GET /api/decisions`
- `GET /api/check-ins`
- `GET /api/context-health/attention`
- `GET /api/skills`
- `GET /api/file-search` with narrow, harmless queries.
- `GET /api/jira/assigned`
- `GET /api/jira/issue`
- `GET /api/github/pr-comments`
- `GET /api/git-status?index=N`
- `GET /api/git-status-path?path=<absolute-path>`
- `GET /api/screen?index=N` when needed for read-only inspection.
- `POST /api/git-diff` and `POST /api/git-diff-path` because these return diff text and do not mutate git state.
- cmux CLI read-only commands such as `cmux tree --all --json`, `cmux read-screen --scrollback --lines N`, `cmux capture-pane --scrollback --lines N`, and `cmux find-window --content <query>`.

Not allowed against live data without Ronnie testing manually or giving explicit permission:

- Sending terminal input or prompts.
- Creating, closing, killing, restarting, renaming, selecting, or modifying cmux sessions/workspaces/surfaces.
- Toggling auto-approve or changing harness config.
- Starting objectives, sessions, workspaces, or coding agents.
- Approving plans, hooks, contracts, or task prompts.
- Posting Jira comments, transitioning Jira tickets, or editing Jira data.
- Posting GitHub comments/reviews, changing PR state, or pushing commits.
- Staging, unstaging, committing, resetting, deleting, opening files in native apps, or any destructive git/file action.
- Registering/clearing push notifications.
- Mutating projects, objectives, ideas, preflights, decisions, check-ins, context-health, action buttons, attachments, or dropped files.

### Remaining Functionality Ronnie Should Test Manually

These should be implemented with mocked/unit tests first, then verified by Ronnie in the real dashboard:

- New task creates a real cmux workspace/session.
- Launching Codex, Claude Code, or OpenCode in a session.
- Sending follow-up prompts into an active cmux session.
- Attaching an orphan live cmux pane to a task.
- Killing or restarting a cmux session.
- Jira ticket transitions.
- Jira comment preview and post flow.
- GitHub PR reply/review preview and post flow.
- Git staging, unstaging, commits, or any branch-changing operation.
- Approval flows that would submit external or terminal actions.
- Proactive watcher behavior over a 10-minute interval against live accounts.

Agents should report this list, plus anything newly discovered during implementation, as `Needs Ronnie live test` instead of testing it themselves.

## Part 1: cmux APIs (what we can read from cmux)

### Socket Protocol

- **Path:** `~/Library/Application Support/cmux/cmux.sock` (primary), `/tmp/cmux.sock` (fallback)
- **Protocol:** Unix domain socket, JSON-RPC v2
- **Auth mode:** `automation` (set via `defaults write com.cmuxterm.app socketControlMode -string automation`)

### v2 JSON-RPC Methods (full list from `cmux capabilities`)

Format: `{"id": "...", "method": "<method>", "params": {...}}` over the socket.

#### Workspace Methods

| Method | Params | Returns | Used by harness? |
|---|---|---|---|
| `workspace.list` | `{}` | `{workspaces: [...]}` | **Yes** - primary workspace discovery |
| `workspace.create` | `{}` | `{uuid, index, ...}` | **Yes** - new session creation |
| `workspace.rename` | `{workspace_id, title}` | `{ok}` | **Yes** - naming new sessions |
| `workspace.select` | `{workspace_id}` | `{ok}` | No |
| `workspace.close` | `{workspace_id}` | `{ok}` | No |
| `workspace.current` | `{}` | workspace object | No |
| `workspace.next` | `{}` | - | No |
| `workspace.previous` | `{}` | - | No |
| `workspace.last` | `{}` | - | No |
| `workspace.reorder` | `{workspace_id, index}` | - | No |
| `workspace.move_to_window` | `{workspace_id, window_id}` | - | No |
| `workspace.action` | `{action, workspace_id, title, color}` | - | No |
| `workspace.equalize_splits` | `{workspace_id}` | - | No |
| `workspace.remote.*` | various | various | No (remote SSH) |

**`workspace.list` response fields per workspace:**
```json
{
  "ref": "workspace:9",
  "id": "9A696D23-...",           // UUID
  "title": "Doximity-Claude",
  "current_directory": "/Users/.../project",
  "pinned": false,
  "index": 0,
  "selected": false,
  "custom_color": "#1A5276",
  "listening_ports": [],
  "remote": { ... }              // SSH remote state (unused)
}
```

#### Surface Methods (terminal read/write)

| Method | Params | Returns | Used by harness? |
|---|---|---|---|
| `surface.read_text` | `{workspace_id, surface_id?, lines?}` | `{text}` or `{base64}` | **Yes** - primary screen reader |
| `surface.send_text` | `{workspace_id, surface_id?, text}` | `{ok}` | **Yes** - sending approvals + input |
| `surface.send_key` | `{workspace_id, surface_id?, key}` | `{ok}` | **Yes** - sending Enter key |
| `surface.health` | `{workspace_id}` | `{surfaces: [{ref, id, index, type}]}` | No |
| `surface.list` | `{workspace_id?}` | list of surfaces | No |
| `surface.current` | `{}` | current surface info | No |
| `surface.create` | `{type, pane_id?, workspace_id?, url?}` | surface object | No |
| `surface.close` | `{surface_id?, workspace_id?}` | - | No |
| `surface.split` | `{direction, workspace_id?, surface_id?}` | - | No |
| `surface.move` | `{surface_id, pane_id?, ...}` | - | No |
| `surface.reorder` | `{surface_id, index}` | - | No |
| `surface.focus` | `{surface_id?, workspace_id?}` | - | No |
| `surface.refresh` | `{}` | - | No |
| `surface.clear_history` | `{workspace_id?, surface_id?}` | - | No |
| `surface.drag_to_split` | `{surface_id, direction}` | - | No |
| `surface.trigger_flash` | `{workspace_id?, surface_id?}` | - | No |
| `surface.action` | `{action, surface_id?, ...}` | - | No |

**`surface.read_text` key details:**
- `lines` param controls how many lines to read (default: visible viewport)
- `--scrollback` flag (CLI) / scrollback behavior reads full history
- Returns `{text: "..."}` or `{base64: "..."}` (base64 for binary content)
- Does NOT require switching workspaces (reads any workspace by UUID)

#### Notification Methods

| Method | Params | Returns | Used by harness? |
|---|---|---|---|
| `notification.list` | `{}` | `{notifications: [...]}` | **Yes** (v1 fallback via `list_notifications`) |
| `notification.create` | `{title, subtitle?, body?, workspace_id?, surface_id?}` | - | No |
| `notification.create_for_surface` | `{title, surface_id, ...}` | - | No |
| `notification.create_for_target` | `{title, ...}` | - | No |
| `notification.clear` | `{}` | - | No |

**Notification object fields:**
```json
{
  "id": "89B3B9B3-...",
  "workspace_id": "9A696D23-...",
  "surface_id": "4CBF2F37-...",
  "title": "Claude Code",
  "subtitle": "Waiting",
  "body": "Claude is waiting for your input",
  "is_read": true
}
```

#### Pane/Window/Layout Methods

| Method | Params | Returns | Used by harness? |
|---|---|---|---|
| `pane.create` | `{type?, direction?, workspace_id?, url?}` | - | No |
| `pane.list` | `{workspace_id?}` | pane list | No |
| `pane.surfaces` | `{workspace_id?, pane_id?}` | surface list | No |
| `pane.focus` | `{pane_id, workspace_id?}` | - | No |
| `pane.resize` | `{pane_id, direction, amount?}` | - | No |
| `pane.swap` | `{pane_id, target_pane_id}` | - | No |
| `pane.break` | `{workspace_id?, pane_id?}` | - | No |
| `pane.join` | `{target_pane_id, ...}` | - | No |
| `pane.last` | `{workspace_id?}` | - | No |
| `window.create` | `{}` | - | No |
| `window.list` | `{}` | - | No |
| `window.close` | `{window_id}` | - | No |
| `window.focus` | `{window_id}` | - | No |
| `window.current` | `{}` | - | No |
| `tab.action` | `{action, tab_id?, ...}` | - | No |

#### Debug/System Methods

| Method | Params | Returns | Used by harness? |
|---|---|---|---|
| `debug.terminals` | `{}` | `{terminals: [...]}` | No |
| `system.tree` | `{all?}` | full workspace/pane/surface hierarchy | **Yes** (via CLI `cmux tree --all --json`) |
| `system.ping` | `{}` | pong | No |
| `system.capabilities` | `{}` | version, methods list, access_mode | No |
| `system.identify` | `{workspace_id?, surface_id?}` | caller context | No |

**`debug.terminals` response fields per terminal (rich data):**
```json
{
  "workspace_ref": "workspace:13",
  "workspace_title": "QA Testrail Testing",
  "workspace_index": 11,
  "workspace_selected": false,
  "surface_id": "0B4DA28E-...",
  "surface_title": ".../rr/task/IOSDOX-24739-...",
  "surface_created_at": "2026-04-01T16:13:19Z",
  "surface_pinned": false,
  "surface_focused": true,
  "surface_context": "split",
  "surface_index_in_pane": 0,
  "pane_ref": "pane:13",
  "window_ref": "window:1",
  "window_title": "Doximity-Claude",
  "current_directory": "/Users/.../project",
  "git_dirty": true,
  "runtime_surface_age_seconds": 31465.247,
  "initial_command": null,
  "tty": null,
  "hosted_view_frame": {"width": 833.5, "height": 642, "x": 335.5, "y": 0},
  "window_frame": {"width": 1459, "height": 1051, "x": 2682, "y": 113}
}
```

#### Browser Methods (not used by harness, available in cmux)

cmux has a full browser automation API (`browser.*`) with 60+ methods covering navigation, DOM interaction, screenshots, cookies, storage, console, network, etc. Not relevant to the harness unless we add a browser-based feature.

#### Hook Methods

| Method | Params | Notes |
|---|---|---|
| `set-hook` (CLI) | `<event> <command>` | Run shell commands on cmux events |
| `claude-hook` (CLI) | `session-start\|stop\|notification` | Claude Code lifecycle events |

**Available hook events:** Not fully documented, but includes workspace creation, selection, close, and Claude Code session lifecycle. `claude-hook session-start` and `claude-hook stop` fire when Claude Code sessions begin/end in a workspace.

### v1 Plain Text Commands (legacy, used as fallback)

| Command | Returns | Used by harness? |
|---|---|---|
| `list_workspaces` | Plain text list | **Yes** (fallback when v2 fails) |
| `select_workspace <index>` | - | **Yes** (v1 fallback for read/send) |
| `read_screen <surface> --lines <n>` | Terminal text | **Yes** (v1 fallback) |
| `send_surface <surface> <text>` | - | **Yes** (v1 fallback) |
| `send_key_surface <surface> <key>` | - | **Yes** (v1 fallback) |
| `list_notifications` | Plain text | **Yes** (attention detection) |

### cmux CLI Commands (subprocess)

| Command | Returns | Used by harness? |
|---|---|---|
| `cmux tree --all --json` | Full hierarchy JSON | **Yes** - surface map for multi-pane |
| `cmux read-screen --scrollback --lines N` | Terminal text with scrollback | No (could use for full history) |
| `cmux capture-pane --scrollback --lines N` | Same as read-screen (tmux compat) | No |
| `cmux pipe-pane --command <cmd>` | Pipes pane output to a shell command | No |
| `cmux new-workspace --name <title> --cwd <path> --command <cmd>` | Creates workspace with full config | **Yes** - PR review launcher and Orchestrator V2 custom-command sessions |
| `cmux notify --title <t> --body <b> --workspace <id>` | Creates notification | No |
| `cmux set-hook <event> <command>` | Registers event hook | No |
| `cmux claude-hook <event>` | Claude Code lifecycle hook | No |
| `cmux find-window --content <query>` | Search across workspaces | No |

---

## Part 2: cmux-harness HTTP APIs (what the dashboard exposes)

Server runs on `http://localhost:9091` (configurable port).

### Complete HTTP Endpoint Catalog

This catalog is generated from `cmux_harness.api_discovery.ENDPOINTS`, the same source used by `GET /api/discovery` and `GET /api/help`. Keep detailed examples below for high-traffic endpoints, but use this catalog as the complete index of supported HTTP APIs.

Runtime discovery supports filters:

```bash
curl 'http://localhost:9091/api/discovery'
curl 'http://localhost:9091/api/discovery?method=POST'
curl 'http://localhost:9091/api/discovery?category=PR%20Reviews'
curl 'http://localhost:9091/api/discovery?prefix=/api/orchestrator-v2/pr-reviews'
curl 'http://localhost:9091/api/discovery?q=pr-reviews'
```

Current catalog size: `185` HTTP endpoint entries.

#### Static Pages

| Method | Path | Category | Safety | Description |
|---|---|---|---|---|
| `GET` | `/` | Static | read | Dashboard/home single-page app. |
| `GET` | `/harness` | Static | read | Main cmux harness dashboard. |
| `GET` | `/orchestrator` | Static | read | Legacy orchestrator dashboard page. |
| `GET` | `/workflow-orchestrator` | Static | read | Workflow orchestrator page. |
| `GET` | `/orchestrator-v2` | Static | read | Orchestrator V2 frontend app. |

#### GET Endpoints

| Endpoint | Category | Safety | Description |
|---|---|---|---|
| `GET /api/auto-policy-costs` | Config | `read` | Return auto-policy cost dashboard data. |
| `GET /api/briefing` | Workflow | `read` | Read workflow briefing. |
| `GET /api/check-ins` | Workflow | `read` | List check-ins. |
| `GET /api/command-center` | Workflow | `read` | Read command-center payload. |
| `GET /api/config` | Config | `read` | Read harness configuration. |
| `GET /api/context-health/attention` | Workflow | `read` | List context-health items needing attention. |
| `GET /api/decisions` | Workflow | `read` | List decisions. |
| `GET /api/decisions/{decisionId}` | Workflow | `read` | Read a decision. |
| `GET /api/discovery` | Discovery | `read` | Discover harness HTTP endpoints and Orchestrator V2 agent tools. |
| `GET /api/feed` | Cmux | `read` | Read cmux feed items. |
| `GET /api/file-search` | Files | `read` | Search files/skills. |
| `GET /api/git-status` | Git | `read` | Read git status by workspace index. |
| `GET /api/git-status-path` | Git | `read` | Read git status by path. |
| `GET /api/github/pr-comments` | External Read | `read` | Read GitHub PR review threads for a workspace path or index. |
| `GET /api/help` | Discovery | `read` | Alias for /api/discovery. |
| `GET /api/ideas` | Workflow | `read` | List ideas. |
| `GET /api/ideas/{ideaId}` | Workflow | `read` | Read an idea. |
| `GET /api/jira/assigned` | External Read | `read` | List assigned Jira tickets through local acli. |
| `GET /api/jira/issue` | External Read | `read` | Read a Jira issue through local acli. |
| `GET /api/log` | Health | `read` | Return harness event log entries. |
| `GET /api/models` | Config | `read` | List available local/review models. |
| `GET /api/network` | Health | `read` | Return network URLs, Tailscale state, cmux state, and local CLI requirements. |
| `GET /api/objectives` | Objectives | `read` | List legacy objectives. |
| `GET /api/objectives/{objectiveId}` | Objectives | `read` | Read a legacy objective. |
| `GET /api/objectives/{objectiveId}/action-buttons` | Action Buttons | `read` | List objective action buttons. |
| `GET /api/objectives/{objectiveId}/build-log` | Logs | `read` | Read objective build log. |
| `GET /api/objectives/{objectiveId}/console-logs` | Logs | `read` | Read objective console logs. |
| `GET /api/objectives/{objectiveId}/context-health` | Workflow | `read` | Read objective context-health state. |
| `GET /api/objectives/{objectiveId}/debug` | Objectives | `read` | Read objective debug logs. |
| `GET /api/objectives/{objectiveId}/messages` | Objectives | `read` | Read objective messages. |
| `GET /api/objectives/{objectiveId}/screen` | Objectives | `read` | Read objective screen output. |
| `GET /api/objectives/{objectiveId}/status-summary` | Logs | `read` | Read objective status summary. |
| `GET /api/objectives/{objectiveId}/tasks/{taskId}/screen` | Objectives | `read` | Read task screen output. |
| `GET /api/orchestrator-v2/activity` | Orchestrator V2 | `read` | List Orchestrator V2 activity events. |
| `GET /api/orchestrator-v2/agent/tool-runs` | Orchestrator V2 | `read` | List agent tool runs. |
| `GET /api/orchestrator-v2/agent/tools` | Orchestrator V2 | `read` | List Orchestrator V2 agent tools. |
| `GET /api/orchestrator-v2/agui/runs/{runId}/events` | Orchestrator V2 | `read` | Read AG-UI events for a run. |
| `GET /api/orchestrator-v2/ai/capabilities` | Orchestrator V2 | `read` | Read AI/voice/tool capabilities. |
| `GET /api/orchestrator-v2/approvals` | Approvals | `read` | List approval requests. |
| `GET /api/orchestrator-v2/audit` | Orchestrator V2 | `read` | List Orchestrator V2 audit events. |
| `GET /api/orchestrator-v2/bootstrap` | Orchestrator V2 | `read` | Read Orchestrator V2 bootstrap payload. |
| `GET /api/orchestrator-v2/chat/messages` | Orchestrator V2 | `read` | Read global chat messages. |
| `GET /api/orchestrator-v2/cmux/sessions` | Cmux | `read` | List cmux sessions through the cmux CLI. |
| `GET /api/orchestrator-v2/cmux/sessions/{workspaceId}/screen` | Cmux | `read` | Read a cmux session screen. |
| `GET /api/orchestrator-v2/copilotkit/info` | Orchestrator V2 | `read` | Read CopilotKit capability metadata. |
| `GET /api/orchestrator-v2/git/status` | Git | `read` | Read git status for a path. |
| `GET /api/orchestrator-v2/health` | Orchestrator V2 | `read` | Read Orchestrator V2 runtime health. |
| `GET /api/orchestrator-v2/left-rail` | Orchestrator V2 | `read` | Read left-rail Jira/PR data. |
| `GET /api/orchestrator-v2/left-rail/draft-prs` | External Read | `read` | Read left-rail draft PRs authored by me. |
| `GET /api/orchestrator-v2/left-rail/jira` | External Read | `read` | Read left-rail assigned Jira tickets. |
| `GET /api/orchestrator-v2/left-rail/open-prs` | External Read | `read` | Read left-rail open PRs authored by me. |
| `GET /api/orchestrator-v2/left-rail/review-requests` | External Read | `read` | Read left-rail PRs requesting my review. |
| `GET /api/orchestrator-v2/orphans` | Cmux | `read` | List active unlinked cmux sessions. |
| `GET /api/orchestrator-v2/pr-reviews/review-requests` | PR Reviews | `read` | List PRs requesting my review for a repository. |
| `GET /api/orchestrator-v2/tasks` | Tasks | `read` | List Orchestrator V2 tasks. |
| `GET /api/orchestrator-v2/tasks/{taskId}` | Tasks | `read` | Read an Orchestrator V2 task. |
| `GET /api/orchestrator-v2/tasks/{taskId}/goal` | Tasks | `read` | Read task goal markdown. |
| `GET /api/preflights` | Workflow | `read` | List preflights. |
| `GET /api/preflights/{preflightId}` | Workflow | `read` | Read a preflight. |
| `GET /api/projects` | Projects | `read` | List configured projects. |
| `GET /api/projects/{projectId}` | Projects | `read` | Read one project. |
| `GET /api/reviews` | Reviews | `read` | List stored review records. |
| `GET /api/reviews/{sessionId}` | Reviews | `read` | Read one stored review. |
| `GET /api/screen` | Cmux | `read` | Read live cmux screen by workspace index. |
| `GET /api/skills` | Files | `read` | List available local skills. |
| `GET /api/status` | Health | `read` | Return current harness engine status. |
| `GET /api/workspace-build-log` | Logs | `read` | Read build log by workspace index or path. |
| `GET /api/workspace-console-logs` | Logs | `read` | Read console logs by workspace index or path. |
| `GET /api/workspaces` | Workspaces | `read` | List workspace sessions tracked by the harness. |
| `GET /api/workspaces/{workspaceId}` | Workspaces | `read` | Read a workspace session. |
| `GET /api/workspaces/{workspaceId}/action-buttons` | Action Buttons | `read` | List workspace action buttons. |
| `GET /api/workspaces/{workspaceId}/active-turn` | Workspaces | `read` | Read active workspace turn metadata. |
| `GET /api/workspaces/{workspaceId}/build-log` | Logs | `read` | Read workspace build log. |
| `GET /api/workspaces/{workspaceId}/console-logs` | Logs | `read` | Read workspace console logs. |
| `GET /api/workspaces/{workspaceId}/debug` | Workspaces | `read` | Read workspace debug logs. |
| `GET /api/workspaces/{workspaceId}/messages` | Workspaces | `read` | Read workspace messages. |
| `GET /api/workspaces/{workspaceId}/screen` | Workspaces | `read` | Read workspace screen output. |
| `GET /api/workspaces/{workspaceId}/status-summary` | Logs | `read` | Read workspace status summary. |

#### POST Endpoints

| Endpoint | Category | Safety | Description |
|---|---|---|---|
| `POST /api/attachments` | Files | `file_write` | Upload an attachment body. |
| `POST /api/check-ins` | Workflow | `local_write` | Create a check-in. |
| `POST /api/config` | Config | `local_write` | Update harness configuration. |
| `POST /api/decisions` | Workflow | `local_write` | Create a decision. |
| `POST /api/decisions/{decisionId}/{action}` | Workflow | `local_write` | Apply a decision action. |
| `POST /api/feed/reply` | Cmux | `terminal_write` | Reply to a cmux feed request. |
| `POST /api/file-content` | Files | `file_read` | Read a small file from a workspace path. |
| `POST /api/git-commit-diff` | Git | `read` | Read file diff for a commit. |
| `POST /api/git-commit-files` | Git | `read` | List files changed by a commit. |
| `POST /api/git-diff` | Git | `read` | Read git diff by workspace index. |
| `POST /api/git-diff-path` | Git | `read` | Read git diff by path. |
| `POST /api/git-open-file` | Git | `native_ui` | Open a git file in the native app. |
| `POST /api/git-stage` | Git | `git_write` | Stage a file by workspace index. |
| `POST /api/git-stage-path` | Git | `git_write` | Stage a file by path. |
| `POST /api/git-unstage` | Git | `git_write` | Unstage a file by workspace index. |
| `POST /api/git-unstage-path` | Git | `git_write` | Unstage a file by path. |
| `POST /api/hooks/pre-tool-use` | Hooks | `local_write` | Handle a pre-tool-use hook callback. |
| `POST /api/ideas` | Workflow | `local_write` | Create an idea. |
| `POST /api/network` | Health | `local_write` | Save network settings such as a Tailscale host. |
| `POST /api/new-session` | Cmux | `terminal_write` | Create a legacy cmux session/worktree and optionally deliver a prompt. |
| `POST /api/objectives` | Objectives | `local_write` | Create a legacy objective. |
| `POST /api/objectives/{objectiveId}/action-buttons` | Action Buttons | `local_write` | Create objective action buttons. |
| `POST /api/objectives/{objectiveId}/action-inject` | Action Buttons | `terminal_write` | Inject an objective action into a session. |
| `POST /api/objectives/{objectiveId}/approve-contracts` | Objectives | `terminal_write` | Approve objective contracts. |
| `POST /api/objectives/{objectiveId}/approve-hook` | Objectives | `terminal_write` | Approve a hook request. |
| `POST /api/objectives/{objectiveId}/approve-plan` | Objectives | `terminal_write` | Approve an objective plan. |
| `POST /api/objectives/{objectiveId}/check-in` | Workflow | `local_write` | Create a check-in linked to an objective. |
| `POST /api/objectives/{objectiveId}/context-health/{dimensionId}/{action}` | Workflow | `local_write` | Apply a context-health action. |
| `POST /api/objectives/{objectiveId}/message` | Objectives | `terminal_write` | Send input to a legacy objective. |
| `POST /api/objectives/{objectiveId}/open-worktree` | Files | `native_ui` | Open an objective worktree in a native editor. |
| `POST /api/objectives/{objectiveId}/start` | Objectives | `terminal_write` | Start a legacy objective session. |
| `POST /api/objectives/{objectiveId}/tasks/{taskId}/approve` | Objectives | `terminal_write` | Approve a task step. |
| `POST /api/open-in-native` | Files | `native_ui` | Open a file/path in the native app. |
| `POST /api/orchestrator-v2/agent/agui-events` | Orchestrator V2 | `local_write` | Record AG-UI events. |
| `POST /api/orchestrator-v2/agent/context` | Orchestrator V2 | `read` | Read context for an agent. |
| `POST /api/orchestrator-v2/agent/runs` | Orchestrator V2 | `local_write` | Create an agent run record. |
| `POST /api/orchestrator-v2/agent/runs/{runId}/finish` | Orchestrator V2 | `local_write` | Finish an agent run record. |
| `POST /api/orchestrator-v2/agent/tools/{toolName}` | Orchestrator V2 | `tool_dependent` | Invoke an Orchestrator V2 agent tool. |
| `POST /api/orchestrator-v2/agent/transcript` | Orchestrator V2 | `local_write` | Append an agent transcript message. |
| `POST /api/orchestrator-v2/agui/run` | Orchestrator V2 | `external_write` | Proxy an AG-UI run request to the sidecar. |
| `POST /api/orchestrator-v2/ai/chat` | Orchestrator V2 | `external_write` | Proxy an AI chat request to the sidecar. |
| `POST /api/orchestrator-v2/approvals` | Approvals | `local_write` | Create an approval request. |
| `POST /api/orchestrator-v2/approvals/{requestId}/decision` | Approvals | `external_write` | Decide an approval request. |
| `POST /api/orchestrator-v2/chat` | Orchestrator V2 | `local_write` | Run a local Orchestrator V2 chat turn. |
| `POST /api/orchestrator-v2/cmux/sessions` | Cmux | `terminal_write` | Create a cmux session. |
| `POST /api/orchestrator-v2/cmux/sessions/{workspaceId}/input` | Cmux | `terminal_write` | Send text or key input to a cmux session. |
| `POST /api/orchestrator-v2/copilotkit` | Orchestrator V2 | `tool_dependent` | Proxy a CopilotKit request. |
| `POST /api/orchestrator-v2/folder-picker` | Files | `native_ui` | Open native folder picker. |
| `POST /api/orchestrator-v2/git/commit-diff` | Git | `read` | Read file diff for a commit. |
| `POST /api/orchestrator-v2/git/commit-files` | Git | `read` | List files changed by a commit. |
| `POST /api/orchestrator-v2/git/diff` | Git | `read` | Read git diff for a path/file. |
| `POST /api/orchestrator-v2/git/stage` | Git | `git_write` | Stage a file. |
| `POST /api/orchestrator-v2/git/unstage` | Git | `git_write` | Unstage a file. |
| `POST /api/orchestrator-v2/open-in-native` | Files | `native_ui` | Open a file/path in the native app. |
| `POST /api/orchestrator-v2/pr-reviews/start` | PR Reviews | `terminal_write` | Start a remote PR code review in a new cmux workspace and create/link an Orchestrator V2 task. |
| `POST /api/orchestrator-v2/realtime/session` | Voice | `external_write` | Create realtime voice session credentials. |
| `POST /api/orchestrator-v2/realtime/tool` | Voice | `tool_dependent` | Run a realtime tool call. |
| `POST /api/orchestrator-v2/tasks` | Tasks | `terminal_write` | Create an Orchestrator V2 task and optionally cmux session. |
| `POST /api/orchestrator-v2/tasks/{taskId}/cmux-sessions` | Tasks | `local_write` | Attach a cmux session to a task. |
| `POST /api/orchestrator-v2/tasks/{taskId}/goal` | Tasks | `file_write` | Update task goal markdown. |
| `POST /api/orchestrator-v2/tasks/{taskId}/jira-links` | Tasks | `local_write` | Attach Jira metadata to a task. |
| `POST /api/orchestrator-v2/tasks/{taskId}/jira-links/{linkId}/resync` | Tasks | `external_read` | Refresh task Jira metadata. |
| `POST /api/orchestrator-v2/tasks/{taskId}/pr-links` | Tasks | `local_write` | Attach PR metadata to a task. |
| `POST /api/orchestrator-v2/tasks/{taskId}/summarize-sessions` | Tasks | `local_write` | Summarize task cmux session output. |
| `POST /api/orchestrator-v2/voice/local/speak` | Voice | `file_write` | Generate local speech audio. |
| `POST /api/orchestrator-v2/voice/local/transcribe` | Voice | `file_read` | Transcribe local audio. |
| `POST /api/orchestrator-v2/watcher/run` | Orchestrator V2 | `external_read` | Run Orchestrator V2 watcher once. |
| `POST /api/preflights` | Workflow | `local_write` | Create a preflight. |
| `POST /api/preflights/{preflightId}/launch-objective` | Workflow | `terminal_write` | Launch a preflight as an objective. |
| `POST /api/projects` | Projects | `local_write` | Create a project. |
| `POST /api/projects/pick-root` | Projects | `native_ui` | Open native folder picker for a project root. |
| `POST /api/push/clear` | Notifications | `local_write` | Clear pending push notifications for a workspace. |
| `POST /api/push/register` | Notifications | `local_write` | Register a push notification device. |
| `POST /api/rename` | Cmux | `local_write` | Rename a live workspace by index. |
| `POST /api/resolve-dropped-files` | Files | `file_read` | Resolve dropped file references. |
| `POST /api/reviews/{sessionId}/dismiss` | Reviews | `local_write` | Dismiss a stored review. |
| `POST /api/reviews/{sessionId}/rerun` | Reviews | `local_write` | Rerun a stored review. |
| `POST /api/send` | Cmux | `terminal_write` | Send text or an allowed key to a live workspace. |
| `POST /api/toggle` | Config | `local_write` | Enable or disable the harness engine. |
| `POST /api/workspace` | Cmux | `local_write` | Enable/disable a workspace by index. |
| `POST /api/workspace-open-root` | Cmux | `native_ui` | Open workspace root by index or path. |
| `POST /api/workspace-star` | Cmux | `local_write` | Star/unstar a workspace by index. |
| `POST /api/workspaces` | Workspaces | `local_write` | Create a workspace session record. |
| `POST /api/workspaces/{workspaceId}/action-buttons` | Action Buttons | `local_write` | Create workspace action buttons. |
| `POST /api/workspaces/{workspaceId}/action-inject` | Action Buttons | `terminal_write` | Inject a workspace action into a session. |
| `POST /api/workspaces/{workspaceId}/message` | Workspaces | `terminal_write` | Send input to a workspace session. |
| `POST /api/workspaces/{workspaceId}/open-root` | Files | `native_ui` | Open a workspace root in a native editor. |
| `POST /api/workspaces/{workspaceId}/start` | Workspaces | `terminal_write` | Start a workspace session. |
| `POST /api/workspaces/{workspaceId}/turns/{turnId}/finalize` | Workspaces | `local_write` | Finalize a workspace turn. |

#### PATCH Endpoints

| Endpoint | Category | Safety | Description |
|---|---|---|---|
| `PATCH /api/decisions/{decisionId}` | Workflow | `local_write` | Patch a decision. |
| `PATCH /api/ideas/{ideaId}` | Workflow | `local_write` | Update an idea. |
| `PATCH /api/objectives/{objectiveId}` | Objectives | `local_write` | Update a legacy objective. |
| `PATCH /api/objectives/{objectiveId}/context-health/{dimensionId}` | Workflow | `local_write` | Patch a context-health dimension. |
| `PATCH /api/orchestrator-v2/approvals/{requestId}` | Approvals | `external_write` | Patch/decide an approval request. |
| `PATCH /api/orchestrator-v2/tasks/{taskId}` | Tasks | `local_write` | Update an Orchestrator V2 task. |
| `PATCH /api/preflights/{preflightId}` | Workflow | `local_write` | Update a preflight. |
| `PATCH /api/projects/{projectId}` | Projects | `local_write` | Update one project. |
| `PATCH /api/workspaces/{workspaceId}` | Workspaces | `local_write` | Rename a workspace session. |

#### DELETE Endpoints

| Endpoint | Category | Safety | Description |
|---|---|---|---|
| `DELETE /api/ideas/{ideaId}` | Workflow | `local_write` | Delete an idea. |
| `DELETE /api/objectives/{objectiveId}` | Objectives | `local_write` | Delete a legacy objective. |
| `DELETE /api/objectives/{objectiveId}/action-buttons/{buttonId}` | Action Buttons | `local_write` | Delete an objective action button. |
| `DELETE /api/orchestrator-v2/tasks/{taskId}` | Tasks | `local_write` | Delete an Orchestrator V2 task. |
| `DELETE /api/orchestrator-v2/tasks/{taskId}/cmux-sessions/{linkId}` | Tasks | `local_write` | Detach a cmux session from a task. |
| `DELETE /api/preflights/{preflightId}` | Workflow | `local_write` | Delete a preflight. |
| `DELETE /api/projects/{projectId}` | Projects | `local_write` | Delete one project. |
| `DELETE /api/workspaces/{workspaceId}` | Workspaces | `terminal_write` | Delete a workspace session. |
| `DELETE /api/workspaces/{workspaceId}/action-buttons/{buttonId}` | Action Buttons | `local_write` | Delete a workspace action button. |

### `/api/status` Response Shape

This is the main polling endpoint. Called every 2s (grid) or 500ms (expanded).

```json
{
  "enabled": true,
  "pollInterval": 5,
  "model": "qwen3.5:35b-a3b-nvfp4",
  "reviewEnabled": true,
  "reviewModel": "qwen3.5:35b-a3b-nvfp4",
  "reviewBackend": "ollama",
  "connected": true,
  "lastSuccessfulPoll": 1711990000.0,
  "connectionLostAt": 0,
  "staleData": false,
  "socketFound": true,
  "ollamaAvailable": true,
  "workspaces": [
    {
      "index": 0,
      "uuid": "9A696D23-...",
      "name": "Doximity-Claude",
      "customName": "My Custom Name",
      "hasClaude": true,
      "enabled": true,
      "lastCheck": "2026-04-01T18:00:00Z",
      "screenTail": "... last 25 lines ...",
      "screenFull": "... full cached screen ...",
      "cwd": "/Users/.../project",
      "branch": "feature-branch",
      "sessionStart": 1711989000.0,
      "sessionCost": "$1.47",
      "surfaceId": "surface:9",
      "surfaceLabel": null
    }
  ]
}
```

### `/api/git-status` Response Shape

```json
{
  "ok": true,
  "branch": "main",
  "cwd": "/Users/.../project",
  "staged": [{"status": "M", "file": "engine.py"}],
  "unstaged": [{"status": "M", "file": "dashboard.html"}],
  "untracked": ["docs/new-file.md"],
  "commits": [
    {"hash": "dabbf52", "message": "style: update button icon"},
    {"hash": "9282d43", "message": "fix: workspace rename"}
  ]
}
```

### `/api/github/pr-comments` Response Shape

Uses `gh pr view` to detect the PR for the current branch, then GitHub GraphQL review threads so resolved threads can be hidden by default.

```json
{
  "ok": true,
  "pullRequest": {"number": 42, "title": "Ship comments", "url": "https://github.com/org/repo/pull/42"},
  "includeResolved": false,
  "hiddenResolvedCount": 2,
  "files": [
    {
      "path": "Sources/App.swift",
      "threadCount": 1,
      "threads": [
        {
          "id": "PRRT_...",
          "path": "Sources/App.swift",
          "line": 18,
          "isResolved": false,
          "codeContext": {
            "source": "workspace",
            "startLine": 18,
            "endLine": 18,
            "lines": [
              {"number": 16, "text": "let previous = value", "isTarget": false},
              {"number": 18, "text": "let value = helper()", "isTarget": true}
            ]
          },
          "comments": [{"author": "octocat", "body": "Use the helper.", "url": "https://github.com/..."}]
        }
      ]
    }
  ]
}
```

### PR Review API

The PR Review API launches the remote iOS PR review workflow that was previously run manually from the local `pr-reviews/orchestrator.py` script.

It uses:

- GitHub CLI (`gh`) to list or fetch PR metadata.
- cmux CLI to create a new workspace.
- Codex by default to run `$ios-review-remote-pr <number>` inside that workspace.
- Orchestrator V2 storage to create or update a task linked to the PR and cmux session.

#### Discover PR Review API Endpoints

Agents should discover the API before calling it:

```bash
curl 'http://localhost:9091/api/discovery?q=pr-reviews'
```

Useful filters:

```bash
curl 'http://localhost:9091/api/discovery?category=PR%20Reviews'
curl 'http://localhost:9091/api/discovery?prefix=/api/orchestrator-v2/pr-reviews'
```

The discovery response includes required fields, optional fields, examples, safety metadata, and related Orchestrator V2 tools.

#### `GET /api/orchestrator-v2/pr-reviews/review-requests`

Lists PRs requesting Ronnie's review for a repository.

Query parameters:

| Param | Required | Default | Description |
|---|---:|---|---|
| `repo` | No | `doximity/iOS-Doximity` | GitHub repository in `owner/name` form |
| `limit` | No | `20` | Maximum PRs to return |

Example:

```bash
curl 'http://localhost:9091/api/orchestrator-v2/pr-reviews/review-requests?repo=doximity/iOS-Doximity&limit=20'
```

Response shape:

```json
{
  "ok": true,
  "repository": "doximity/iOS-Doximity",
  "items": [
    {
      "number": 11244,
      "title": "Review target",
      "url": "https://github.com/doximity/iOS-Doximity/pull/11244",
      "branch": "feature/review-target",
      "isDraft": false,
      "state": "OPEN",
      "owner": "doximity",
      "repo": "iOS-Doximity",
      "author": "teammate",
      "raw": {}
    }
  ],
  "pullRequests": [
    {
      "number": 11244,
      "title": "Review target",
      "url": "https://github.com/doximity/iOS-Doximity/pull/11244"
    }
  ]
}
```

`items` and `pullRequests` contain the same list. `items` is the canonical field; `pullRequests` is included for callers that expect PR-specific naming.

#### `POST /api/orchestrator-v2/pr-reviews/start`

Starts a remote PR code review in a new cmux workspace and creates or updates an Orchestrator V2 task.

Request body:

| Field | Required | Default | Description |
|---|---:|---|---|
| `number` | Yes | - | Pull request number to review |
| `repo` | No | `doximity/iOS-Doximity` | GitHub repository in `owner/name` form |
| `projectDir` | No | `~/Documents/Development/Doximity-Claude` | Local project directory where the review agent runs |
| `reviewCli` | No | `codex` | `codex` or `claude` |
| `pullRequest` | No | - | Already-discovered PR metadata; avoids an extra GitHub lookup |
| `taskId` | No | - | Existing Orchestrator V2 task to attach the PR review session to |
| `title` | No | `PR-Review-<number>` | cmux workspace title override |
| `priority` | No | `Medium` | New task priority when creating a task |
| `tags` | No | `PR Review`, `<reviewCli>` | New task tags when creating a task |

Minimal example:

```bash
curl -X POST 'http://localhost:9091/api/orchestrator-v2/pr-reviews/start' \
  -H 'Content-Type: application/json' \
  -d '{"repo":"doximity/iOS-Doximity","number":11244}'
```

Example using PR metadata from the review-requests response:

```json
{
  "repo": "doximity/iOS-Doximity",
  "number": 11244,
  "reviewCli": "codex",
  "pullRequest": {
    "number": 11244,
    "title": "Review target",
    "url": "https://github.com/doximity/iOS-Doximity/pull/11244",
    "branch": "feature/review-target",
    "state": "OPEN"
  }
}
```

Response shape:

```json
{
  "ok": true,
  "task": {
    "id": "task_...",
    "title": "PR Review #11244: Review target",
    "status": "Running",
    "workspaceDir": "/Users/ronnierocha/Documents/Development/Doximity-Claude",
    "pullRequestLinks": [
      {
        "owner": "doximity",
        "repo": "iOS-Doximity",
        "number": 11244,
        "url": "https://github.com/doximity/iOS-Doximity/pull/11244",
        "isPrimary": true
      }
    ],
    "cmuxSessionLinks": [
      {
        "workspaceId": "workspace-uuid",
        "surfaceId": "surface-uuid",
        "title": "PR-Review-11244",
        "launchType": "Codex"
      }
    ]
  },
  "cmuxSession": {
    "workspaceId": "workspace-uuid",
    "surfaceId": "surface-uuid",
    "title": "PR-Review-11244",
    "cwd": "/Users/ronnierocha/Documents/Development/Doximity-Claude",
    "launchType": "Codex"
  },
  "pullRequest": {
    "number": 11244,
    "title": "Review target",
    "url": "https://github.com/doximity/iOS-Doximity/pull/11244"
  },
  "repository": "doximity/iOS-Doximity",
  "reviewCli": "codex",
  "launchType": "Codex",
  "projectDir": "/Users/ronnierocha/Documents/Development/Doximity-Claude",
  "prompt": "$ios-review-remote-pr 11244",
  "command": "codex --cd /Users/... --sandbox workspace-write --ask-for-approval on-request --no-alt-screen '$ios-review-remote-pr 11244'"
}
```

Safety: this endpoint is `terminal_write`. It creates a cmux workspace and launches an interactive review agent. Agents should call discovery first and should only call this endpoint when the user explicitly asks to start a PR review.

#### Agent Tool Equivalents

Agents can also use the Orchestrator V2 tool layer:

```http
POST /api/orchestrator-v2/agent/tools/list_pr_review_requests
POST /api/orchestrator-v2/agent/tools/start_pr_review
```

Tool invocation body:

```json
{
  "runId": "optional-run-id",
  "args": {
    "repo": "doximity/iOS-Doximity",
    "number": 11244,
    "reviewCli": "codex"
  }
}
```

The tool layer records the invocation in Orchestrator V2 tool-run history and returns the tool result under `result`.

### Review JSON Shape (stored in `~/.cmux-harness/reviews/*.json`)

```json
{
  "sessionId": "uuid_timestamp",
  "workspaceIndex": 0,
  "workspaceUuid": "9A696D23-...",
  "workspaceName": "Doximity-Claude",
  "completedAt": "2026-04-01T18:30:00+00:00",
  "duration": 340.2,
  "finalCost": "$1.47",
  "terminalSnapshot": "... last 50 lines ...",
  "gitDiffStat": " 3 files changed, 45 insertions(+), 12 deletions(-)",
  "gitDiff": "... full diff (capped at 50KB) ...",
  "gitLog": "dabbf52 style: update button icon\n9282d43 fix: workspace rename",
  "cwd": "/Users/.../project",
  "branch": "feature-branch",
  "approvalLog": [
    {
      "timestamp": "2026-04-01T18:00:00Z",
      "workspace": 0,
      "workspaceName": "Doximity-Claude",
      "promptType": "llm:permission prompt",
      "action": "sent y"
    }
  ],
  "reviewStatus": "reviewed",
  "reviewModel": "claude",
  "reviewedAt": "2026-04-01T18:30:10+00:00",
  "reviewDuration": 8.3,
  "review": {
    "summary": "One-line description",
    "whatHappened": "2-4 sentence description of session activity",
    "nextSteps": "Actionable next step",
    "filesChanged": ["file1.swift", "file2.swift"],
    "linesAdded": 45,
    "linesRemoved": 12,
    "confidence": "high",
    "issues": [],
    "readyForPR": true,
    "recommendation": "Brief recommendation",
    "highlights": ["Notable patterns"]
  }
}
```

---

## Part 3: Internal Engine APIs (Python, not HTTP-exposed)

These are methods on `HarnessEngine` and helper modules that run server-side.

### Engine Methods

| Method | What it does |
|---|---|
| `refresh_workspaces()` | Fetches workspace list from cmux (v2, falls back to v1) |
| `check_workspace(ws)` | Reads screen, detects prompts, sends approvals |
| `get_status()` | Builds full status response for dashboard |
| `get_log(limit=200)` | Returns recent approval log entries |
| `get_git_status(ws_index)` | Runs git status/log in workspace cwd |
| `_run_git_command(cwd, args, max_bytes?)` | Runs any git command in a directory |
| `_get_workspace_cwd(ws_index)` | Resolves cwd for a workspace (cached or fetched) |
| `_capture_completion_snapshot_async(ws, idx)` | Fires when Claude exits, captures session data |
| `_capture_completion_snapshot(snapshot)` | Saves review JSON + triggers LLM review |
| `_get_session_approval_log(idx, session_id, start_ts, end_ts)` | Filters approval log for a session |
| `_build_virtual_workspaces()` | Expands multi-surface workspaces into virtual entries |
| `_check_ollama()` | Rate-limited Ollama health check |
| `get_workspaces_needing_attention()` | Checks cmux notifications for unread items |

### Detection Module (`detection.py`)

| Function | What it does |
|---|---|
| `detect_claude_session(screen_text)` | Returns True if Claude Code is running in this terminal |
| `detect_prompt(screen_text, model?, checker?)` | Returns `(pattern_name, action)` or None |
| `llm_classify(screen_text, model?, checker?)` | Sends screen to Ollama for classification |
| `is_permission_menu(options_text)` | Checks if menu options are all Yes/No variants |
| `fingerprint(screen_text)` | MD5 of last 5 lines (dedup) |

### Review Module (`review.py`)

| Function | What it does |
|---|---|
| `build_review_prompt(review_data)` | Constructs LLM prompt from session snapshot |
| `parse_review_json(raw)` | Extracts JSON from LLM response |
| `run_review_ollama(prompt, model?)` | Sends review to local Ollama |
| `run_review_lmstudio(prompt, model?, endpoint?)` | Sends review to LM Studio (Mac Studio) |
| `run_review_claude(prompt, model_override?)` | Sends review via `claude --print` CLI |
| `run_review(review_path, model, backend, ...)` | Orchestrates review: load, prompt, call backend, save |

### Storage Module (`storage.py`)

| Function | What it does |
|---|---|
| `load_config()` | Reads `~/.cmux-harness/workspace-config.json` |
| `save_config(ws_config, review_enabled, model, backend)` | Writes config |
| `debug_log(entry)` | Appends to `~/.cmux-harness/debug-log.jsonl` |
| `rotate_log_file(path, max_size)` | Rotates log at 10MB |
| `parse_session_cost(screen_text)` | Extracts `$X.XX` from terminal status line |
| `read_review_file(path)` | Reads review JSON |
| `write_review_file(path, data)` | Writes review JSON |
| `list_reviews()` | Lists all reviews sorted by date |
| `get_review(session_id)` | Finds review by session ID |
| `get_review_path(session_id)` | Finds review file path by session ID |

---

## Part 4: Data we currently capture vs what's available but unused

### Currently captured per workspace (every poll cycle)

| Data | Source | Stored where |
|---|---|---|
| Terminal screen (last 40 lines) | `surface.read_text` | `screen_cache` (memory) |
| Has Claude running (bool) | `detect_claude_session()` on screen text | `ws_has_claude` (memory) |
| Session start time | Timestamp when hasClaude goes True | `session_start` (memory) |
| Session cost | Regex parse of status line | `session_cost` (memory) |
| Session ID | workspace UUID + start timestamp | `session_ids` (memory) |
| Working directory | `workspace.list` → `current_directory` | `workspaces[].cwd` (memory) |
| Branch name | Parsed from terminal or git rev-parse | `workspaces[].branch` (memory) |
| Workspace name/title | `workspace.list` → `title` | `workspaces[].name` (memory) |
| Custom name | User-set via UI | `ws_config` (disk) |
| Auto-approve enabled | User-set via UI | `ws_config` (disk) |
| Screen fingerprint (MD5) | Last 5 lines hash | `fingerprints` (memory) |
| Surface map | `cmux tree --all --json` | `surface_map` (memory, refreshed every 15s) |

### Currently captured on session completion

| Data | Source | Stored where |
|---|---|---|
| Terminal snapshot (last 50 lines) | `screen_cache` at completion | Review JSON (disk) |
| Git diff (uncommitted) | `git diff` in workspace cwd | Review JSON (disk) |
| Git diff stat | `git diff --stat` | Review JSON (disk) |
| Git log (last 5 commits) | `git log --oneline -5` | Review JSON (disk) |
| Session duration | end - start timestamp | Review JSON (disk) |
| Final cost | Last parsed cost | Review JSON (disk) |
| Approval log for session | Filtered from approval-log.jsonl | Review JSON (disk) |
| LLM review | Ollama/LM Studio/Claude response | Review JSON (disk) |

### Available from cmux but NOT currently used

| Data | Source | Could provide |
|---|---|---|
| **Full scrollback** | `read-screen --scrollback --lines N` or `capture-pane --scrollback` | Complete session history, not just last 40/50 lines |
| **Surface creation time** | `debug.terminals` → `surface_created_at` | True session age (vs our hasClaude tracking) |
| **Surface age in seconds** | `debug.terminals` → `runtime_surface_age_seconds` | How long this terminal has been alive |
| **Git dirty flag** | `debug.terminals` → `git_dirty` | cmux already tracks this natively |
| **Surface title** | `debug.terminals` or tree → `surface_title` | Claude Code sets this to the current task description |
| **Workspace custom color** | `workspace.list` → `custom_color` | Visual workspace identification |
| **Listening ports** | `workspace.list` → `listening_ports` | Detect if workspace is running a server |
| **Pinned status** | `workspace.list` → `pinned` | User intent signal |
| **Notifications** | `notification.list` | Claude Code "Waiting" notifications with structured data |
| **Hooks** | `set-hook` / `claude-hook` | Event-driven triggers instead of polling |
| **Pipe pane** | `pipe-pane --command <cmd>` | Send terminal output to a process as it changes |
| **find-window** | `cmux find-window --content <query>` | Search terminal content across all workspaces |
| **Workspace creation** | `cmux new-workspace --name <t> --cwd <p> --command <c>` | One-shot workspace creation with full config (vs our multi-step v2 flow) |
| **Notifications (create)** | `notification.create` | Push notifications to specific workspaces |
| **Browser automation** | `browser.*` (60+ methods) | Full browser control within cmux |
| **Window management** | `window.*` methods | Multi-window orchestration |

---

## Part 5: Interesting unused capabilities worth noting

### `cmux claude-hook` (lifecycle events)

```bash
cmux claude-hook session-start --workspace <id>
cmux claude-hook stop --workspace <id>
cmux claude-hook notification --workspace <id>
```

These fire on Claude Code lifecycle events. Could replace our polling-based `hasClaude` detection with event-driven triggers.

### `cmux set-hook` (event hooks)

Register shell commands to run on cmux events. Could trigger harness actions without polling.

### `cmux pipe-pane` (live output)

Pipes terminal output to a shell command as it happens. Could feed a persistent process that logs or analyzes terminal output, rather than snapshot-based polling.

### `cmux read-screen --scrollback --lines N`

We currently read 40 lines (visible viewport). With `--scrollback`, we can read the full terminal history (hundreds or thousands of lines). This is the complete record of everything that happened in a session.

### `debug.terminals` (rich metadata)

Returns data we don't get from `workspace.list`:
- `surface_created_at` - when the terminal was created
- `runtime_surface_age_seconds` - how long it's been running
- `git_dirty` - cmux's own dirty flag (no need to run git ourselves for this)
- `surface_title` - Claude Code sets this to the current task/operation
- View frame dimensions - terminal size info

### `notification.create` (push to workspace)

We could push notifications TO workspaces, not just read them. Possible use: notify a Claude Code session about context from another session.

### `cmux find-window --content <query>`

Search terminal content across ALL workspaces without reading each one individually. Could be used for cross-session awareness ("is anyone else working on AuthManager.swift?").
