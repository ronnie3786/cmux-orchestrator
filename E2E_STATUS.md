# cmux-harness E2E Status — April 2, 2026

## Current State: NOT WORKING END-TO-END

The orchestrator pipeline has never completed a full objective from start to finish. Individual stages work, but the pipeline breaks before reaching completion.

## What Works

- **Planning:** Claude Code analyzes codebase, writes plan.md (~3 min). Reliable.
- **Plan Parsing:** Sonnet extracts structured tasks from plan.md. Reliable after switching from Haiku.
- **Worker Launch:** Workers get cmux workspaces, git worktrees, spec files. Reliable after atomic update_task fix.
- **Permission Auto-Approve:** Fast-path regex detects Claude Code permission prompts and sends Enter. Handles 20-50 prompts per run without issues.
- **Task Completion Detection:** Checks result.md in both worktree and task directory. Works.
- **Review Cycle Counter:** Increments correctly 1→2→3→4→5→failed. No resets.
- **Review Dedup:** _review_in_progress set prevents duplicate review threads.

## What's Broken

### 1. Workers Scope-Creep Beyond Their Spec
**Severity: Blocking**

Workers assigned a narrow task (e.g., "Enable Tailwind class-based dark mode") expand their scope to build the entire feature. The reviewer then catches that claimed work wasn't committed. Rework loop can't fix this because the worker repeats the same pattern.

**Evidence:** task-1 was assigned Tailwind config only. Worker claimed 9 files changed (153 additions) but git diff showed 7 files (39 additions). ThemeToggle.tsx and layout.tsx changes were claimed in result.md but missing from commits.

**Possible fixes:**
- Stronger spec constraints ("ONLY modify files listed below")
- Worker prompt includes explicit scope boundary
- Review prompt distinguishes "code quality issues" (reworkable) from "scope/completeness issues" (needs human or task redesign)
- Reduce review strictness for intermediate tasks (not every task needs to be PR-ready in isolation)

### 2. Sequential Dependencies Block Progress
**Severity: High**

When Claude Code generates a plan with mostly sequential dependencies (task-2 depends on task-1, task-3 depends on task-2, etc.), only 1-2 tasks run in parallel. If the first task fails after 5 review cycles, the entire objective stalls with 7/8 tasks never launched.

**Evidence:** Final E2E run had 8 tasks. Only task-1 launched. It burned through 5 review cycles and failed. Tasks 2-8 never executed.

**Possible fixes:**
- Planning prompt should emphasize parallelizable task decomposition
- Allow "soft" dependencies (context sharing without hard blocking)
- On task failure, attempt to launch dependent tasks anyway with a warning
- Lower the bar for what counts as "passing review" for intermediate tasks

### 3. 40 Minutes Not Enough
**Severity: Medium**

Planning takes ~3 min. Each worker needs ~3-5 min. Review + rework adds ~2 min per cycle. With 5 review cycles on sequential tasks, 40 minutes is tight for 8 tasks even if everything goes well.

**No fix needed** — just needs longer timeout or the pipeline needs to be faster (fewer review cycles, parallel execution).

## Bugs Fixed Today (10 commits on feature/orchestrator-v2)

| # | Bug | Root Cause | Fix |
|---|-----|-----------|-----|
| 1 | Trust folder prompt blocks REPL | Claude Code shows "Do you trust?" before REPL | Auto-dismiss with Enter in _wait_for_repl |
| 2 | False exit detection (30s) | detect_claude_session flickers False during transitions | Grace period: 180s before treating False as exit |
| 3 | Workers stuck on permission prompts | poll_tasks relied on Ollama for classification | Fast-path regex + Enter key via surface.send_key |
| 4 | Wrong key for approval | Sent "y\n" but Claude Code expects Enter | Changed to surface.send_key → Enter |
| 5 | result.md path mismatch | Workers write to worktree, orchestrator checked task dir | check_progress checks both, copies to task dir |
| 6 | Duplicate review threads | poll_tasks spawned new review before previous finished | _review_in_progress set guards against duplicates |
| 7 | result.md triggers re-review after rework | Old result.md detected as new completion | Clear result.md on rework entry |
| 8 | Review counter resets | Lost-update race: threads overwrite each other's state | Atomic update_task with per-objective threading.Lock |
| 9 | workspaceId not persisted | _launch_ready_tasks used stale snapshot for update | Atomic update_task per launched task |
| 10 | Parse "fails" on valid plans | validate_plan rejected >5 checkpoints per task | Raised limit to 10 |
| 11 | Haiku parse unreliable for 9KB plans | Was Haiku-first; turned out to be checkpoint validation | Sonnet-first (also fixed the real cause: checkpoint limit) |

## Branch State

- **Branch:** `feature/orchestrator-v2`
- **Commits ahead of main:** ~22
- **Tests:** 177/177 passing
- **Last commit:** `e4ae243` (extend timeout to 40 min)

## Files Changed

### Core modules (cmux_harness/)
- `orchestrator.py` — Main engine: planning, task launch, poll_tasks, review-rework cycle
- `planner.py` — Plan parsing with Sonnet→Haiku fallback, validation
- `monitor.py` — check_progress (with worktree fallback), stuck detection, review helpers
- `objectives.py` — CRUD with per-objective locks, atomic update_task
- `approval.py` — Haiku approval classification (fallback path)
- `claude_cli.py` — subprocess wrapper for claude --print
- `detection.py` — Claude Code session/prompt detection
- `worker.py` — Git worktree management, task/rework prompts
- `workspace_mutex.py` — Per-workspace locks for cmux API calls

### Test files (tests/)
- 177 tests across 10 test files
- All passing

### Smoke test
- `smoke_test.py` — End-to-end runner with configurable timeout (currently 40 min)
- `SMOKE_TEST_REPORT.md` — Auto-generated after each run

## What Needs to Happen for E2E Success

1. **Fix scope creep** — Workers must stay within their spec boundaries
2. **Fix dependency chain** — Plans need more parallelism, or first task can't be a single point of failure
3. **Review calibration** — Reviewer may be too strict for intermediate tasks that will be integrated later
4. **Longer run or faster pipeline** — 40 min may not be enough; reducing review cycles from 5 to 3 could help

## Smoke Test History

| Time | Session | Result | Got To |
|------|---------|--------|--------|
| 3:30 PM | ember-ro | FAIL | Planning: trust prompt blocked REPL |
| 3:50 PM | young-tr | FAIL | Planning: false exit detection |
| 4:01 PM | dawn-tid | PARTIAL | Planning OK, parse failed (checkpoint limit) |
| 4:41 PM | tender-gulf | PARTIAL | Planning OK, 3 workers launched, permission prompts blocked |
| 5:11 PM | briny-river | FAIL | Planning: false exit detection (30s too short) |
| 5:24 PM | delta-canyon | PARTIAL | Workers launched, completed, but result.md path mismatch |
| 5:44 PM | nova-basil | TIMEOUT | Review cycle ran but duplicate reviews + counter resets |
| 6:09 PM | lucky-zephyr | TIMEOUT | Review dedup helped but counter still resetting |
| 6:23 PM | marine-breeze | FAIL | Parse failed (checkpoint validation, not Haiku) |
| 6:49 PM | faint-meadow | FAIL | Same parse failure (checkpoint limit still at 5) |
| 7:07 PM | clear-crest | PARTIAL | Parse OK! Workers + reviews working, 20-min timeout hit |
| 8:07 PM | wild-shore | RUNNING | task-1 hit 5 review cycles, failed. Tasks 2-8 never launched. |
