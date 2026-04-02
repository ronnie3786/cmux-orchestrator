# Orchestrator Design Notes

## Ronnie's Work Machine Environment
- **Claude Code:** v2.1.90, subscription auth (no API key)
- **`claude --print`:** Works for one-shot prompts
- **`claude --print --model haiku`:** Confirmed working (cheap, fast)
- **Local models:** Ollama available, 48GB Mac
- **Mac Studio:** Reachable via Tailscale (LM Studio, qwen3.5-27b)
- **No OpenClaw, no standalone API keys**

## LLM Architecture (confirmed 2026-04-02)

| Role | Method | Model | Why |
|------|--------|-------|-----|
| Orchestrator brain | `claude --print --model haiku` | Haiku | Task parsing, queue mgmt, progress checks. Fast + cheap. |
| Session reviews | `claude --print` | Default (Sonnet) | Code review quality matters. Caught 3 issues local model missed. |
| Planner | Claude Code session (interactive) | Default | Needs codebase access, reads files, creates plans. |
| Workers | Claude Code sessions (interactive) | Default | Execute specific tasks. |

## Chosen Approach: "The Tech Lead" (Approach 2)

### Flow
1. Ronnie types high-level request in chat UI
2. Orchestrator spins up Planner session (Claude Code)
3. Planner reads codebase, creates task plan
4. Orchestrator (Haiku) parses plan into task queue
5. Workers launched for each task (Claude Code sessions)
6. On completion, reviews run via `claude --print`
7. Results reported back to Ronnie in dashboard

### Key APIs
- `workspace.create` / `cmux new-workspace` — spin up sessions
- `surface.send_text` / `surface.read_text` — control + monitor
- `surface.send_key` — approvals
- `cmux find-window --content <query>` — cross-session conflict detection
- `debug.terminals` — metadata enrichment

## Review System Test Results (2026-04-02)

| Backend | Time | Quality | Issues Found |
|---------|------|---------|-------------|
| Claude CLI (`--print`) | 13.5s | Excellent | 3 real code concerns |
| LM Studio (27B local) | 57.1s | Good summaries | 0 issues (rubber stamp) |
| Ollama (needs model pull) | N/A | Untested | N/A |

## Open Questions
- Max concurrent Claude Code sessions before subscription throttling?
- How to parse planner output reliably (structured format? markers?)
- Task dependency graph complexity (linear? DAG?)
