# cmux orchestrator

> **Stop. Read this first.**
>
> In the words of Steve Yegge and his warning of Gas Town (paraphrasing)...
>
> DON'T INSTALL THIS SOFTWARE!
> 
> This is in active development and has many bugs and sharp edges. 
> 
> Yegge's exact wording is _"'You probably don't want to use it yet.' It needs some Lysol._" and _"You shouldn't be using it now, unless you're either experimenting or you're contributing. Otherwise it's too much of a headache."_
> 
> Now that we've gotten that out of the way. Welcome to my in-progress cmux orchestrator.

A web-based orchestrator for managing parallel Claude Code sessions across [cmux](https://cmux.com) workspaces. Define high-level objectives, and the orchestrator breaks them into tasks, spins up agents, dispatches work across workspaces, and tracks everything from a single browser tab.

## Requirements

- **[cmux](https://cmux.com)** — installed and running, with Automation mode enabled:
  - Open cmux > Settings > Automation
  - Enable the socket API (this exposes the v2 JSON-RPC API that the orchestrator talks to)
- **Python 3.9+** — no pip install, no virtual env, no dependencies. Standard library only.
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** — installed and authenticated (`claude` must be in your PATH)

## Setup

```bash
git clone git@github.com:ronnie3786/cmux-orchestrator.git
cd cmux-orchestrator

# Start the orchestrator directly
python3 dashboard.py
```

### Dashboard control shortcut

If you use the `cmux-dashboard` helper script, it can start, stop, or restart the dashboard process:

```bash
./cmux-dashboard start
./cmux-dashboard stop
./cmux-dashboard restart
```

Optional port:

```bash
./cmux-dashboard start 8080
./cmux-dashboard restart 8080
```

Opens automatically at **http://localhost:9091**. Custom port: `python3 dashboard.py 8080`

## Orchestrator

The core of the app. Define objectives in plain language and the orchestrator handles the rest.

- **Objective-driven workflow** — describe what you want built, and the system uses Claude to decompose it into discrete tasks with dependencies
- **Multi-workspace dispatch** — tasks are assigned to available cmux workspaces and executed in parallel across independent Claude Code sessions
- **Live progress tracking** — real-time status for every task (queued, in progress, completed, failed) with a unified view across all workspaces
- **Sprint contracts** — define acceptance criteria and the orchestrator evaluates task output against them before marking work complete
- **Dependency-aware scheduling** — tasks execute in the right order; dependent tasks wait for their prerequisites to finish

## UI

Single-page web app — no build step, no npm, no framework.

- **Project sidebar** — organize objectives by project, with progress bars and status indicators
- **Streaming conversation** — watch the orchestrator plan, dispatch, and report in real time
- **Plan and contract review** — review the orchestrator's plan and acceptance criteria before execution starts
- **Approval workflow** — tasks below your severity threshold auto-approve; higher-severity actions escalate to you with approve/take-over options
- **Prompt file references** — drag local files into the prompt input to insert their full paths, so Claude/Codex can read the referenced files
- **Git panel** — branch, commits, staged/unstaged changes for the active objective's working directory
- **Diff viewer** — inspect code changes inline as tasks complete
- **Build log viewer** — view build output and errors for the active objective
- **Console log viewer** — stream Claude Code console output with filtering presets

## Configuration

All settings are configurable from the dashboard UI and persist across restarts.

The approval severity threshold is shared by the `/harness` Haiku auto-approval flow and the Claude Code PreToolUse hook flow:

- **Level 1:** read-only project access
- **Level 2:** file edits and safe shell commands
- **Level 3:** known external services such as Jira, GitHub, or Slack
- **Level 4:** ambiguous operations that need human judgment
- **Level 5:** destructive or dangerous operations

Levels at or below the configured threshold are eligible for auto-approval. Levels above it escalate to a human. The `/harness` auto mode also requires Haiku confidence of at least `0.85`, and it remembers repeated escalated approval prompts per session so the same pending human decision is not re-checked every minute.

## License

MIT
