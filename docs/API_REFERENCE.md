# cmux-harness API Reference

Complete catalog of every API available to this project: the cmux socket/CLI APIs we consume, and the harness HTTP APIs we expose.

---

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
| `cmux new-workspace --name <title> --cwd <path> --command <cmd>` | Creates workspace with full config | No (we use v2 API instead) |
| `cmux notify --title <t> --body <b> --workspace <id>` | Creates notification | No |
| `cmux set-hook <event> <command>` | Registers event hook | No |
| `cmux claude-hook <event>` | Claude Code lifecycle hook | No |
| `cmux find-window --content <query>` | Search across workspaces | No |

---

## Part 2: cmux-harness HTTP APIs (what the dashboard exposes)

Server runs on `http://localhost:9090` (configurable port).

### GET Endpoints

| Endpoint | Returns | Description |
|---|---|---|
| `GET /` | HTML | Dashboard single-page app |
| `GET /api/status` | JSON | Full system state (all workspaces, settings, connection info) |
| `GET /api/log` | JSON | Last 200 approval log entries (newest first) |
| `GET /api/git-status?index=N` | JSON | Parsed git status for workspace N (branch, staged, unstaged, untracked, recent commits) |
| `GET /api/reviews` | JSON | All reviews (sorted newest, diff truncated to 500 chars) |
| `GET /api/reviews/<session_id>` | JSON | Full review detail including complete diff |
| `GET /api/config` | JSON | Current settings (pollInterval, model, review config) |
| `GET /api/models` | JSON | Available Ollama models + LM Studio/Claude availability |

### POST Endpoints

| Endpoint | Body | Returns | Description |
|---|---|---|---|
| `POST /api/toggle` | `{enabled: bool}` | `{ok, enabled}` | Enable/disable global auto-approve |
| `POST /api/workspace` | `{index, enabled}` | `{ok}` | Toggle auto-approve for one workspace |
| `POST /api/config` | `{pollInterval?, model?, reviewEnabled?, reviewModel?, reviewBackend?}` | `{ok, ...settings}` | Update settings |
| `POST /api/rename` | `{index, name}` | `{ok}` | Rename a workspace |
| `POST /api/send` | `{index, text, surfaceId?}` | `{ok}` | Send text input to a workspace terminal |
| `POST /api/new-session` | `{cwd?, command?}` | `{ok, workspace: {index, uuid}}` | Create workspace, cd, launch Claude |
| `POST /api/git-stage` | `{index, file}` | `{ok}` | `git add` a file in workspace's cwd |
| `POST /api/git-unstage` | `{index, file}` | `{ok}` | `git reset HEAD` a file in workspace's cwd |
| `POST /api/git-open-file` | `{index, file}` | `{ok}` | Open a file with macOS `open` command |
| `POST /api/git-diff` | `{index, file, section?}` | `{ok, diff}` | Get diff for a specific file (staged/unstaged/untracked) |
| `POST /api/reviews/<id>/rerun` | `{model?, backend?}` | `{ok}` | Re-trigger review with optional model override |
| `POST /api/reviews/<id>/dismiss` | `{}` | `{ok}` | Set review status to "dismissed" |

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
| **Pipe pane** | `pipe-pane --command <cmd>` | Stream terminal output to a process in real-time |
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

### `cmux pipe-pane` (streaming output)

Pipes terminal output to a shell command in real-time. Could feed a persistent process that logs or analyzes terminal output as it happens, rather than snapshot-based polling.

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
