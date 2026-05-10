# Workflow Orchestrator Spec

## Route

Build the new workflow as a separate subpage:

```text
/workflow-orchestrator
/workflow-orchestrator.css
/workflow-orchestrator.js
```

Do not overwrite `/orchestrator`. The existing page remains available while this new workflow matures.

## Product Goal

The Workflow Orchestrator is Ronnie's CEO/tech-lead cockpit for Doximity work.

Ronnie should state objectives, review context health, approve decisions, hear briefings, and launch/review agents without manually babysitting individual cmux sessions.

## UI Style

Match `ronnierocha.dev` direction:

- Light/white base
- Polished gray depth
- Navy/deep ink for primary structure
- Purple/blue/pink accent gradient used sparingly
- Plus Jakarta Sans style typography where available
- JetBrains Mono for IDs, Jira keys, and code-like labels
- Minimal, ADHD-friendly hierarchy
- One obvious top priority
- Progressive disclosure
- Focus mode

Theme tokens:

```css
--primary: #9C2CF3;
--secondary: #3A8FFE;
--accent: #FF2D55;
--navy: #111827;
--muted: #667085;
--bg: #f6f7fb;
--paper: #ffffff;
```

## Sidebar

Sidebar sections:

1. Navigation
   - Command Center
   - Ideas + Assigned Jira
   - Decisions
   - Briefing
2. Ideas
   - quick list of local ideas
3. Assigned Jira
   - tickets assigned to Ronnie from `/api/jira/assigned`
   - if Jira fails, show a calm unavailable state

## Command Center

The Command Center uses `GET /api/command-center` and should show:

- One top priority
- Small metrics
- Compact board lanes
- Context health badges
- Recent check-ins
- Decision preview

Board lanes:

- Ideas / Pre-Jira
- Intake
- Context
- Running
- Review / PR

## Context Health

Context Health is persistent and reopenable. It is not a linear wizard step.

Dimensions:

- Open Questions
- Jira Ticket, optional
- Design Discussion
- PM Discussion
- Backend Discussion
- Blocked / Waiting

Each dimension can be resolved, not needed, waiting, waived, or reopened at any time. Required unresolved dimensions show badges on objective cards.

Backend APIs:

```http
GET /api/objectives/{id}/context-health
PATCH /api/objectives/{id}/context-health/{dimension}
POST /api/objectives/{id}/context-health/{dimension}/resolve
POST /api/objectives/{id}/context-health/{dimension}/reopen
POST /api/objectives/{id}/context-health/{dimension}/wait
POST /api/objectives/{id}/context-health/check
GET /api/context-health/attention
```

## Ideas

Ideas are local pre-Jira records. They can later become Jira tickets, research tasks, brainstorm threads, or objectives.

Initial APIs:

```http
GET /api/ideas
POST /api/ideas
GET /api/ideas/{id}
PATCH /api/ideas/{id}
DELETE /api/ideas/{id}
```

Idea statuses:

- inbox
- brainstorming
- researching
- ready_for_jira
- converted
- archived

## Decisions

Decisions are first-class objects, not just chat messages.

Initial APIs:

```http
GET /api/decisions
POST /api/decisions
GET /api/decisions/{id}
PATCH /api/decisions/{id}
POST /api/decisions/{id}/approve
POST /api/decisions/{id}/reject
POST /api/decisions/{id}/snooze
```

Decision fields:

- title
- summary
- recommendation
- options
- risk
- status
- target
- preview
- audit history

## Check-ins

Check-ins are durable status snapshots used by the dashboard and future voice briefings.

Initial APIs:

```http
POST /api/check-ins
GET /api/check-ins?limit=50
POST /api/objectives/{id}/check-in
```

## Voice Readiness

Every action that can later be triggered by OpenAI Realtime 2 voice should be exposed as a deterministic HTTP endpoint with clear approval rules.

Read-only voice actions can execute when intent is clear.

Write actions must require explicit confirmation:

- Jira comment/post/create/update
- Launch agent
- Pause/cancel work
- Create PR
- Merge
- Message/tag someone
- Delete/archive destructive state

The voice model is not the source of truth. It calls tools against server state.

## Build Order

1. Add route/static page for `/workflow-orchestrator`.
2. Add command-center aggregate API.
3. Add context health persistence and APIs.
4. Add ideas persistence and APIs.
5. Add decisions persistence and APIs.
6. Add check-in persistence and APIs.
7. Wire UI to real API state.
8. Add Realtime 2 voice tool gateway later.
