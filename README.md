# cmux-harness

Auto-approve harness for Claude Code permission prompts in cmux workspaces. Built for environments where `--dangerously-skip-permissions` and `--permission-mode auto` are disabled (e.g., corporate managed Claude Code installations).

## What it does

- Monitors cmux workspaces for Claude Code permission prompts
- Auto-approves safe prompts (Yes/No confirmations, tool approvals, proceed dialogs)
- Flags domain-specific choices as "needs human" (menu selections, file/section choices)
- Uses a local LLM (Ollama) as a fallback classifier for unknown prompt formats
- Web dashboard for toggling workspaces, monitoring approvals, and reviewing logs

## Requirements

- [cmux](https://cmux.com) running with socket in Automation mode (Settings > Automation)
- Python 3.9+
- [Ollama](https://ollama.com) with `qwen3.5:2b` model (optional, for LLM fallback)

## Quick Start

```bash
# Pull the LLM model (one-time)
ollama pull qwen3.5:2b

# Start the dashboard
python3 dashboard.py

# Opens http://localhost:9090
# Toggle global switch ON, select workspaces to watch
```

## How it works

1. Polls `list_notifications` to find workspaces with unread notifications (no workspace switching)
2. Uses cmux v2 JSON-RPC API (`surface.read_text`, `surface.send_text`) to read/send to workspaces without changing focus
3. Regex fast-path detects known Claude Code prompt patterns
4. Local LLM (qwen3.5:2b via Ollama) classifies unknown prompts as a fallback
5. Sends `Enter` or `y` to approve, or flags as "needs human"

## Detection Logic

**Auto-approved (Enter):**
- Numbered menus where cursor (❯) is on Yes/Confirm/Approve/Accept/Continue
- Menus with only Yes/No/Allow/Deny variants (permission prompts)

**Auto-approved (y):**
- `(Y/n)` or `(y/n)` text prompts
- `Allow <ToolName>` tool approval prompts
- "Run this command?" / "Apply changes?" prompts

**Needs human:**
- Menus with domain-specific options (file choices, section selections)
- Any prompt the LLM classifies as unsafe or requiring judgment

**Skipped entirely:**
- Claude Code idle REPL (❯ with Model:/Cost: lines)
- Shell prompts
- Active processing (Musing.../Thinking...)

## Files

- `dashboard.py` — Web dashboard + harness engine (single file, no dependencies)
- `auto-approve.sh` — Standalone CLI script (no dashboard, bash only)

## Configuration

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434` | Ollama API endpoint |
| `OLLAMA_MODEL` | `qwen3.5:2b` | Model for LLM classification |
| `USE_LLM` | `1` | Set to `0` to disable LLM, regex only |

## Logs

- Dashboard approval log: `~/.cmux-harness/approval-log.jsonl`
- Debug log (full data dump): `~/.cmux-harness/debug-log.jsonl`
