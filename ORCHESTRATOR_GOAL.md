# Orchestrator Goal

## North Star

Turn cmux-orchestrator from a remote cmux control surface into an autonomous tech-lead layer for Ronnie's Doximity work.

Ronnie should give it a goal, then manage outcomes instead of managing individual Claude/cmux sessions.

## Product Direction: Web First

Build and iterate the orchestrator as a web app first.

Native Mac and iOS apps are explicitly later. The web app is the fastest path because it is easier to test, ship, inspect, screenshot, and change while the product shape is still evolving. Do not let implementation drift into native app work until the web experience proves the workflow.

Current priority:

1. Web app shell for the Hybrid B / Command Center direction.
2. ADHD-friendly, light/simple UI.
3. Real product APIs wired into the UI.
4. One end-to-end workflow that feels alive.
5. Native Mac and iOS apps after the web app is validated.

```text
Current:
Ronnie -> opens sessions -> writes prompts -> watches terminals -> reviews output -> decides next step

Target:
Ronnie -> states objective -> approves plan/decisions -> receives briefings -> reviews finished work
```

The product wins when Ronnie can stay in the CEO/tech-lead seat:

- What are we trying to accomplish?
- What is running now?
- What is blocked?
- What needs my judgment?
- What is ready to review or merge?
- What should happen next?

Everything else should be handled by the orchestrator.

## Current Foundation

The repo is already more than a remote terminal viewer. It has useful building blocks:

- cmux workspace/session control
- remote web dashboard
- web dashboard/API surfaces
- iOS companion app, useful later but not the current product target
- session monitoring
- auto-approval mechanics
- review capture/review files
- objective/task concepts
- action buttons/FAB rail
- build log viewer
- filesystem-based orchestration design docs

The missing product shift is not “more remote control.” The missing shift is ownership of the workflow.

## Product Definition

The orchestrator is a local work coordinator that sits above cmux and Claude Code.

It should:

1. Convert a high-level goal into an objective.
2. Plan the work using a planner Claude Code session.
3. Convert the plan into a structured task queue.
4. Launch worker sessions in isolated git worktrees.
5. Monitor progress through files and session state.
6. Keep workers moving with safe approvals.
7. Escalate only meaningful human decisions.
8. Review completed work.
9. Send failed work back for rework.
10. Produce high-level updates, summaries, and next-step recommendations.

## Operating Model

```text
Ronnie
  ↕ goals, approvals, decisions, briefings
Orchestrator
  ↕ planning, queue management, progress monitoring, reviews, rework
cmux Harness
  ↕ workspace creation, terminal control, session state, logs
Claude Code Sessions
  ↕ planner + workers in git worktrees
Repo Filesystem
  ↕ objective.json, plan.md, spec.md, progress.md, result.md, review.json
```

The filesystem is the source of truth. Terminals are execution surfaces, not the database.

## Core UX Promise

The UI should feel less like “remote cmux” and more like “mission control for work.”

Primary surfaces:

### 1. Objective Chat

A cowork-style chat where Ronnie gives the goal and gets useful updates.

Messages should include:

- plan created
- task launched
- checkpoint completed
- review failed/passed
- decision needed
- objective completed

### 2. Objective Sidebar

A compact list of active/recent objectives.

Each objective shows:

- status
- progress
- active worker count
- needs-human indicator
- completion/readiness signal

### 3. Decision Queue

Human judgment gets pulled into one focused surface.

Decision cards should show:

- what happened
- why it matters
- recommended action
- options
- risk

The default should be “orchestrator recommends X,” not “please read this terminal and figure it out.”

### 4. Context Health

A persistent, reopenable context layer that follows every objective from idea through review.

This is not a linear intake checklist. These states can change at any time and should show as compact badges wherever the objective appears.

Tracked dimensions:

- Open Questions
- Jira Ticket, optional
- Design Discussion Needed
- PM Discussion Needed
- Backend Discussion Needed
- Blocked / Waiting on someone or something

The orchestrator should let Ronnie or an agent mark each dimension resolved, not needed, waiting, waived, or reopened. Required unresolved items should create attention badges and, when needed, decision cards with recommendations.

### 5. Task Detail

For drilling in only when needed.

Shows:

- task spec
- context health badges
- checkpoints
- progress history
- files touched
- review result
- worker session link
- git diff/log summary

## MVP Goal

Build one reliable end-to-end objective flow before chasing broad autonomy.

MVP scope:

1. One active objective at a time.
2. Planner writes `plan.md` directly to disk.
3. Orchestrator parses `plan.md` into tasks with validation.
4. Launch one or two worker tasks in worktrees.
5. Workers update `progress.md` and `result.md`.
6. Orchestrator watches files, not just terminal text.
7. Review completed work with `claude --print`.
8. Rework loop for failed review.
9. Chat feed persists to `messages.jsonl`.
10. Discord or dashboard summary at completion.

MVP success looks like this:

> Ronnie says: “Fix this Jira bug.”
> Orchestrator plans it, starts the right sessions, posts meaningful progress, catches blocked/review-failed work, and comes back with a clean summary plus exactly what Ronnie needs to decide.

## What To Avoid

- Building a prettier terminal dashboard without changing the workflow.
- Surfacing raw logs as “updates.”
- Asking Ronnie vague questions like “what should I do?”
- Running many sessions before one-session reliability is excellent.
- Depending on terminal scraping when a file-based contract is possible.
- Treating every approval prompt as a human decision.

## Design Biases

- File contracts over screen scraping.
- Structured tasks over freeform terminal state.
- One reliable objective flow over many half-working features.
- Human decisions should be rare, specific, and recommendation-backed.
- The orchestrator should narrate outcomes, not implementation noise.
- Every session should have a plan, progress checkpoints, result, and review.

## First Refinement Target

The existing docs already identify the right hard problems. The next product goal should be:

**Make objective execution trustworthy.**

That means:

1. Planner file-based output, no planner scrollback dependency.
2. Strong plan parsing validation and retry/escalation ladder.
3. Worker progress contract with fallback signals.
4. Persistent chat/event log.
5. Clean decision cards.
6. Review-rework loop that actually improves output.

Once that works in the web app, the native Mac/iOS apps can become true orchestration cockpits instead of remote cmux viewers.
