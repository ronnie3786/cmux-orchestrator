# Context Health Spec

## Purpose

The Context stage is not a linear checklist. It is a persistent health layer for every objective.

An objective can be ready today and become unready tomorrow. A Jira comment can answer one question, then a backend change can reopen it. A Design decision can be unnecessary at intake, then become required during review. The orchestrator should track those states continuously and show badges wherever the objective appears.

## Core Principle

Context health is separate from objective status.

```text
Objective status: idea, intake, context, running, review, done
Context health: open questions, Jira, Design, PM, Backend, blocked/waiting
```

The objective can move forward while some context items are optional or deferred, but anything marked required and unresolved should surface as an attention badge.

## Required Context Dimensions

Each objective has these independent dimensions:

1. Open Questions
2. Jira Ticket
3. Design Discussion
4. PM Discussion
5. Backend Discussion
6. Blocked / Waiting

These dimensions are not steps. They can be opened, resolved, waived, deferred, or reopened at any time.

## State Model

Each dimension should use the same base state shape.

```json
{
  "id": "design",
  "label": "Design",
  "state": "unresolved",
  "required": true,
  "severity": "attention",
  "reason": "Need Figma confirmation for empty-state copy.",
  "owner": "Designer name or team",
  "updatedAt": "2026-05-09T21:40:00-05:00",
  "resolvedAt": null,
  "reopenedAt": null,
  "history": [
    {
      "at": "2026-05-09T21:40:00-05:00",
      "actor": "orchestrator",
      "from": "unknown",
      "to": "unresolved",
      "note": "Agent found copy mismatch against existing UI."
    }
  ]
}
```

Allowed states:

- `unknown` — not checked yet.
- `not_needed` — checked and not relevant.
- `needed` — relevant but not blocking yet.
- `unresolved` — required and missing.
- `waiting` — blocked on a person, system, PR, ticket, or decision.
- `resolved` — currently satisfied.
- `waived` — intentionally skipped by Ronnie.
- `reopened` — was resolved/waived, but became needed again.

Severity:

- `none` — no badge.
- `info` — useful context exists.
- `attention` — should be handled before confidence is high.
- `blocked` — do not proceed until resolved or waived.

## Badge Rules

Badges should appear on objective cards, task detail, decision queue, and briefings.

Suggested badge labels:

- `Questions 3`
- `No Jira`
- `Design?`
- `PM?`
- `Backend?`
- `Blocked`
- `Waiting on Alex`
- `Reopened`

Badge color rules:

- Gray: optional or informational.
- Amber: required but not blocking.
- Red: blocked/waiting.
- Green: resolved only when useful in detail view. Avoid green clutter on board cards.

## Context Health Summary

Every objective should expose a computed summary.

```json
{
  "contextHealth": {
    "score": 72,
    "state": "needs_attention",
    "badges": [
      { "label": "Questions 2", "severity": "attention", "dimension": "open_questions" },
      { "label": "Backend?", "severity": "attention", "dimension": "backend" },
      { "label": "Waiting on Sam", "severity": "blocked", "dimension": "blocked" }
    ],
    "dimensions": { }
  }
}
```

Computed states:

- `clear` — no required unresolved items.
- `needs_attention` — at least one required item is unresolved or reopened.
- `blocked` — at least one dimension is waiting/blocking.
- `unknown` — checks have not run yet.

## Lifecycle Rules

Context health can change at any point:

- During idea capture.
- During Jira/pre-flight.
- During planning.
- During worker execution.
- During review/rework.
- After PR creation.

Examples:

- A backend PR lands and resolves `Backend?`.
- QA finds a new edge case and reopens `Open Questions`.
- A designer changes the Figma and reopens `Design?`.
- A Jira ticket is created after work started, changing `No Jira` to resolved.
- A reviewer asks for PM confirmation, changing `PM?` from `not_needed` to `unresolved`.

## UX Requirements

### Board card

Show only compact badges. Do not show the full checklist by default.

Example:

```text
IOSDOX-24739 Auth
Missing offline token behavior.
[Questions 2] [Backend?] [Waiting on Sam]
```

### Detail panel

Show the full Context Health panel with all dimensions. Each row needs:

- Current state.
- Required/optional marker.
- Last update.
- Reason.
- Actions: mark resolved, mark not needed, reopen, add note, assign/waiting on.

### Decision queue

If a dimension is blocked or unresolved and needs Ronnie, create a decision card with a recommendation.

Bad:

```text
Need PM?
```

Good:

```text
PM confirmation needed before launch
Recommendation: ask Maya whether the acceptance criteria include offline refresh behavior.
Why: current implementation plan may miss a product requirement.
Action: approve Jira/Slack comment draft.
```

### Briefing

Summarize only the context items that changed or need action.

Example:

```text
Auth ticket is now blocked on Backend. Design was resolved. PM is still not needed.
```

## Storage

Recommended file layout:

```text
~/.cmux-harness/objectives/{objectiveId}/
  objective.json
  context-health.json
  context-events.jsonl
  open-questions.md
  people.md
  links.md
```

`context-health.json` is the current state. `context-events.jsonl` is the audit trail.

## API Proposal

```http
GET /api/objectives/{id}/context-health
PATCH /api/objectives/{id}/context-health/{dimension}
POST /api/objectives/{id}/context-health/{dimension}/reopen
POST /api/objectives/{id}/context-health/{dimension}/resolve
POST /api/objectives/{id}/context-health/{dimension}/wait
POST /api/objectives/{id}/context-health/check
GET /api/context-health/attention
```

The command-center endpoint should include context badges inline so the home board can render without making N+1 calls.

## Implementation Bias

Start simple:

1. Store context health in JSON per objective.
2. Add badges to objective cards.
3. Add full panel to objective detail.
4. Let Ronnie manually change states.
5. Then add automatic check-ins from Jira, GitHub, worker notes, and review output.

Manual but persistent is better than automatic but invisible.
