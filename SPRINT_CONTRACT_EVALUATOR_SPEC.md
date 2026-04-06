# Sprint Contract & Evaluator Upgrade Spec

## Overview

Implement the GAN-inspired findings from Anthropic's harness research, adapted for iOS development. Four changes to the orchestrator's planning and review pipeline. No new agents, no new architecture, just sharpening what we have.

## Change 1: Sprint Contract Negotiation

### What
After the planner creates the plan and the human approves it, but BEFORE tasks start executing, a new "contract negotiation" phase runs. For each task, the system generates a sprint contract that defines specific, testable acceptance criteria.

### Where
- New file: `cmux_harness/contracts.py` — contract generation and parsing logic
- Modified: `cmux_harness/orchestrator.py` — new `_negotiate_contracts()` method, new `contract_review` status, new `approve_contracts()` method
- Modified: `cmux_harness/objectives.py` — store contract data on tasks
- Modified: `cmux_harness/routes/objectives.py` — expose approve_contracts endpoint

### Flow
1. Human approves plan (existing `approve_plan()`)
2. Instead of immediately launching tasks, status transitions to `"negotiating_contracts"`
3. `_negotiate_contracts()` runs: for each task, uses Claude (via `claude_cli.run_sonnet()`) to generate a contract from the task spec
4. Contract includes:
   - **Acceptance criteria**: Specific, testable behaviors (e.g., "Settings screen shows a Dark Mode toggle")
   - **Maestro test hints**: Suggested UI elements and flows the evaluator should test
   - **Build verification**: Whether `/exp-project-run` should be run (yes for all iOS tasks)
   - **Expected outcomes**: What success looks like for each criterion
5. All contracts saved as `contract.md` in each task directory
6. Status transitions to `"contract_review"` — human sees all contracts in the chat panel
7. Human approves (new `approve_contracts()`) or requests revisions
8. After approval, status transitions to `"executing"` and tasks launch

### Contract Format (contract.md)
```markdown
# Sprint Contract: [Task Title]

## Acceptance Criteria
1. [Specific testable behavior]
2. [Specific testable behavior]
3. [Specific testable behavior]

## Build Verification
- Run `/exp-project-run` after implementation
- Expected: Clean build, app deploys to simulator

## Functional Tests (Maestro)
- appId: [bundle identifier]
- Test 1: [description]
  - tapOn: [element]
  - assertVisible: [element]
- Test 2: [description]
  - [steps]

## Pass/Fail Threshold
- Build must succeed (Tier 1 — mandatory)
- All acceptance criteria must pass (Tier 2 — each tested via Maestro)
- Any single criterion failure = task fails and goes to rework
```

## Change 2: Two-Tier Evaluator

### What
Replace the current `_build_task_review_prompt()` (which only checks scope compliance, checkpoint completion, and git diff) with a two-tier evaluation system.

### Where
- Modified: `cmux_harness/orchestrator.py` — rewrite `_run_review()` method
- New file: `cmux_harness/evaluator.py` — Tier 1 and Tier 2 evaluation logic
- New: Maestro YAML generation and execution in evaluator

### Tier 1: Build Verification
1. Evaluator sends `/exp-project-run` command to the worker's Claude Code session
2. This builds the project and deploys to the iOS simulator
3. Binary outcome: build succeeds or fails
4. If build fails: task immediately fails, build errors sent back to worker for rework
5. No further evaluation needed on build failure

### Tier 2: Functional QA via Maestro CLI
1. Only runs if Tier 1 passes
2. Evaluator reads the task's `contract.md`
3. Generates Maestro YAML flow file(s) from the acceptance criteria
4. Runs `maestro test <flow.yaml> --platform ios` via CLI
5. Parses Maestro output: which steps passed, which failed
6. Grades each acceptance criterion as pass/fail
7. If any criterion fails: task fails with specific feedback (which criterion, what Maestro saw)
8. If all pass: task passes

### Fallback
- If Maestro is not installed or the simulator is not running, Tier 2 is skipped and the evaluator falls back to the existing code review approach (but with the upgraded skeptical prompt from Change 3)
- The evaluator should detect Maestro availability at the start of each review

## Change 3: Skeptical Evaluator Prompt

### What
Rewrite the review prompt to be explicitly anti-lenient. The current prompt is too narrow (only checks 3 things) and too forgiving.

### Where
- Modified: `cmux_harness/orchestrator.py` — rewrite `_build_task_review_prompt()`

### Key changes to the prompt
- Add explicit anti-leniency instructions: "If a feature is stubbed, UI-only, or non-functional, it FAILS"
- Add few-shot examples showing what FAIL verdicts look like
- Grade against the sprint contract acceptance criteria, not just scope/checkpoints
- Include Maestro test results in the review context
- Require the evaluator to cite specific evidence for pass/fail decisions
- Hard rule: "Do not give credit for partial implementations. If the contract says 'user can toggle dark mode' and the toggle exists but doesn't persist, that's a FAIL."

### Updated review JSON format
```json
{
  "verdict": "pass" | "fail",
  "tier1_build": "pass" | "fail" | "skipped",
  "tier2_maestro": "pass" | "fail" | "skipped",
  "criteria_results": [
    {"criterion": "Settings shows Dark Mode toggle", "result": "pass", "evidence": "Maestro assertVisible passed"},
    {"criterion": "Toggle persists after app restart", "result": "fail", "evidence": "Maestro assertVisible failed after launchApp"}
  ],
  "issues": ["list of SPECIFIC problems"],
  "recommendation": "What needs to change"
}
```

## Change 4: Planner Stays High-Level

### What
Adjust the planning prompt to focus on product scope and user stories. Stop specifying file paths and implementation details.

### Where
- Modified: `cmux_harness/planner.py` — rewrite `build_planning_prompt()`

### Key changes
- Remove "Files: [list of files to modify]" from the task format
- Replace with "User Story: [what the user can do after this task]"
- Keep: Task title, dependencies, checkpoints
- Add: "Deliverables: [what artifacts this task produces]"
- Add instruction: "Stay focused on WHAT should be built, not HOW. Do not specify file paths, function names, or implementation details. The worker will figure out the implementation."
- Keep the parallelism rules (they're good)
- Keep the 3-6 tasks target

### Updated task format in plan.md
```markdown
## Task N: [title]
- User Story: [what the user can do after this task]
- Deliverables: [screens, features, behaviors this task produces]
- Depends on: [task numbers or "none"]
- Checkpoints:
  1. [checkpoint — focused on WHAT, not HOW]
  2. [checkpoint]
```

### Impact on downstream
- `parse_plan()` and `_build_parsing_prompt()` need to handle the new format (user story + deliverables instead of files)
- `_build_spec_content()` generates spec.md from the new format — scope boundary section changes from file list to deliverable list
- Worker prompt stays mostly the same but references deliverables instead of file boundaries

## Implementation Order

1. **Change 4** (planner prompt) — standalone, no dependencies
2. **Change 1** (sprint contracts) — depends on updated plan format
3. **Change 3** (skeptical evaluator prompt) — standalone, but benefits from contract format
4. **Change 2** (two-tier evaluator) — depends on contracts (reads contract.md) and needs Maestro integration

## Test Impact

- Update planner tests for new task format
- New tests for contract generation and parsing
- New tests for contract approval flow (new status: `negotiating_contracts`, `contract_review`)
- Update review tests for new prompt format and two-tier evaluation
- New tests for Maestro YAML generation
- New tests for evaluator Maestro CLI execution (mocked)
- All existing tests must continue to pass

## Files Summary

| File | Action |
|------|--------|
| `cmux_harness/contracts.py` | **NEW** — contract generation, parsing, validation |
| `cmux_harness/evaluator.py` | **NEW** — Tier 1 + Tier 2 evaluation logic, Maestro integration |
| `cmux_harness/planner.py` | **EDIT** — high-level planning prompt, new task format |
| `cmux_harness/orchestrator.py` | **EDIT** — contract negotiation phase, approve_contracts(), updated review flow |
| `cmux_harness/objectives.py` | **EDIT** — contract storage on tasks |
| `cmux_harness/worker.py` | **EDIT** — reference deliverables instead of file boundaries |
| `cmux_harness/routes/objectives.py` | **EDIT** — approve_contracts endpoint |
| `cmux_harness/static/orchestrator.js` | **EDIT** — contract review UI in chat panel, approve button |
| `tests/test_contracts.py` | **NEW** |
| `tests/test_evaluator.py` | **NEW** |
| `tests/test_planner.py` | **EDIT** |
| `tests/test_orchestrator.py` | **EDIT** |
