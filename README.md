# cmux-harness

Command center for managing Claude Code sessions across cmux workspaces. Auto-approves permission prompts, monitors session status, and gives you a bird's-eye view of all your coding agents from one browser tab.

Built for environments where `--permission-mode auto` is disabled (e.g., corporate Claude Code installations).

## What it does

- **Command center dashboard** with live terminal previews for every workspace
- **Auto-approve** safe prompts (Yes/No confirmations, tool approvals, proceed dialogs)
- **Flag** domain-specific choices as "needs human" (menu selections, file/section choices)
- **Per-workspace auto toggle** — enable/disable auto-approve individually
- **Rename workspaces** — click any name to give it a meaningful label
- **Send input** directly to any workspace from the dashboard
- **Spin up new sessions** — creates a workspace, cd's to your project, and launches Claude Code
- **Browser notifications** with sound when a session needs you or completes
- **Session timer and cost tracking** — parsed from Claude Code's statusline
- **Local LLM fallback** (Ollama) for classifying unknown prompt formats
- **Persistent config** — workspace settings survive restarts

## Requirements

- [cmux](https://cmux.com) with socket in Automation mode (Settings > Automation)
- Python 3.9+ (no pip dependencies)
- [Ollama](https://ollama.com) (optional, for LLM fallback classification)

## Quick Start

```bash
git clone git@github.com:ronnie3786/cmux-harness.git
cd cmux-harness

# (Optional) Pull an LLM model for fallback classification
ollama pull qwen3.5:2b

# Start the dashboard
python3 dashboard.py

# Opens http://localhost:9090
```

Custom port: `python3 dashboard.py 9091`

## Dashboard

The dashboard is a single-page web app served from `dashboard.py`. No build step, no npm, no dependencies.

**Grid view** — each workspace is a card showing:
- Status (active/idle/needs you) with live terminal preview
- Auto-approve toggle
- Session duration and cost (if Claude Code statusline is configured)
- Text input to send messages directly to the terminal

**Expanded view** — click ⤢ on any card for:
- Full scrollable terminal output with syntax highlighting
- Activity feed showing all auto-approvals and flags for that workspace
- Raw/Intent input modes

**Activity feed** — collapsible panel at the bottom showing approval events across all workspaces.

**Settings** — poll interval, Ollama model picker, notifications toggle, default working directory.

## How It Works

1. Reads terminal screens via cmux v2 JSON-RPC API (no workspace switching or focus changes)
2. Regex fast-path detects known Claude Code prompt patterns
3. Local LLM classifies unknown prompts as a fallback
4. Sends `Enter` or `y` to approve, or flags as "needs human"
5. Active sessions (Claude Code running) polled every cycle; idle sessions every 30 seconds

## Detection Logic

**Auto-approved:**
- `(Y/n)` / `(y/n)` text prompts
- `Allow <ToolName>` tool approval prompts
- Numbered menus where all options are Yes/No/Allow/Confirm variants
- "Run this command?" / "Apply changes?" prompts

**Flagged for human:**
- Menus with domain-specific options (file choices, which approach to take)
- Anything the LLM classifies as requiring judgment

**Skipped:**
- Claude Code idle REPL
- Shell prompts
- Active processing (Musing.../Thinking...)

## Configuration

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434` | Ollama API endpoint |
| `OLLAMA_MODEL` | `qwen3.5:2b` | Model for LLM classification |
| `USE_LLM` | `1` | Set to `0` to disable LLM, regex only |

All runtime settings (poll interval, model selection, per-workspace auto-approve, custom names) are configurable from the dashboard UI and persist to `~/.cmux-harness/workspace-config.json`.

## Files

```
dashboard.py              — Everything: web UI + harness engine (single file, no dependencies)
auto-approve.sh           — Standalone CLI script (no dashboard, bash-only)
DEVLOG.md                 — Development history and future ideas
~/.cmux-harness/
  workspace-config.json   — Persistent workspace settings
  approval-log.jsonl      — Approval/flag event log
  debug-log.jsonl         — Full debug data (auto-rotated at 10MB)
```

## Logs

Both log files auto-rotate at 10MB, keeping one `.1.jsonl` backup.

- `~/.cmux-harness/approval-log.jsonl` — approval and flag events
- `~/.cmux-harness/debug-log.jsonl` — full debug data dump
