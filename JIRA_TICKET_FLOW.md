# Jira Ticket Flow for the Orchestrator

## Why this matters

Ronnie's real Doximity workflow usually starts from a Jira ticket, not from a generic coding task. The orchestrator needs to understand the ticket, gather missing context, ask the right questions, update Jira when useful, then launch the right coding agent with a complete context packet.

This makes the product custom to Ronnie's actual work instead of a generic agent dashboard.

## High-Level Flow

```text
Jira ticket or new work idea
  -> ticket intake
  -> project/repo detection
  -> dox-start/project setup
  -> context gathering
  -> open-question loop with Ronnie
  -> optional Jira comment/update
  -> choose coding agent
  -> launch implementation session
  -> monitor/review/rework
  -> update ticket/brief Ronnie
```

## Ticket Intake

Inputs can be:

- Existing Jira ticket URL/key
- A Slack discussion that should become a ticket
- A vague work idea that needs a ticket created
- A bug report
- A PR follow-up
- A Figma/spec link

The orchestrator should extract:

- Ticket key/title
- Project/repo
- Goal
- Acceptance criteria
- Known links
- Relevant people
- Deadline/priority if available
- Technical area
- Potential dependencies

## Context Health, Not A Linear Checklist

The Context stage should not behave like a wizard where each requirement is checked once and then forgotten.

Context requirements are persistent health states that can open, resolve, and reopen throughout the entire objective lifecycle, including after implementation has started.

Track these independent dimensions for every objective:

- Open Questions
- Jira Ticket, optional
- Design Discussion Needed
- PM Discussion Needed
- Backend Discussion Needed
- Blocked / Waiting on someone or something

These dimensions should show as badges on board cards and detail views when missing, required, blocked, or reopened.

Examples:

- `Questions 3`
- `No Jira`
- `Design?`
- `PM?`
- `Backend?`
- `Waiting on Alex`
- `Blocked`
- `Reopened`

Each dimension can be:

- `unknown`
- `not_needed`
- `needed`
- `unresolved`
- `waiting`
- `resolved`
- `waived`
- `reopened`

The canonical spec for this is `CONTEXT_HEALTH_SPEC.md`.

## Context Gathering Checklist

Before launching a coding agent, the orchestrator should ask whether it has enough information, but this readiness can change later.

Questions to resolve:

- Which project/repo are we working in?
- Is there a Jira ticket, or is Jira intentionally not needed yet?
- Is there a backend PR or related backend ticket?
- Is there a Figma link?
- Is there a Slack discussion that should be linked?
- Are there comments in Jira with hidden context?
- Who is the PM?
- Who is the designer?
- Which developers/reviewers are involved?
- Are there acceptance criteria or edge cases missing?
- Is this frontend-only, backend-only, full stack, test-only, or investigation-first?
- Are we blocked or waiting on any person, PR, design, PM clarification, backend work, CI, access, or decision?
- Should the task start with Claude Code, Codex, or another agent?

## Question Loop

Ronnie described a useful pattern from Codex sessions:

> Keep asking: “Do you have any questions for me before you have 100% of the information needed to implement this task?”

The orchestrator should formalize this.

Loop:

1. Orchestrator summarizes what it knows.
2. Orchestrator lists missing information.
3. Ronnie answers or points to sources.
4. Orchestrator updates the local context packet.
5. Repeat until the orchestrator says implementation readiness is high.

This should produce better task prompts and reduce mid-session intervention.

## Jira Update Loop

The orchestrator should preserve context back into Jira when appropriate.

Possible actions:

- Post open questions as a Jira comment.
- Post refined acceptance criteria.
- Add links to Slack/Figma/backend PRs.
- Add a technical notes section.
- Create a new Jira ticket from a work idea.

Important UX:

- Show a preview before posting.
- Ask who to tag.
- Use a contact directory for common PMs, designers, and developers.
- Let Ronnie approve, edit, or cancel.

## Agent Selection

Once context is ready, the orchestrator should ask or recommend which coding agent to use.

Options:

- Claude Code through cmux
- Codex
- Future agents/harnesses

Selection should consider:

- Project type
- Task complexity
- Need for long-running terminal work
- Ronnie's current preference
- Existing skill/instructions like `dox-start`

## Context Packet

Before launching a worker, write a local context packet. This becomes the source of truth for the session prompt.

Suggested files:

```text
objective/<id>/
  jira.md
  context.md
  open-questions.md
  people.md
  links.md
  implementation-readiness.md
  agent-plan.md
```

## Readiness Gate

Do not launch the coding session until readiness is explicit.

Readiness should answer:

- What are we building/fixing?
- What repo/project is involved?
- What context links matter?
- What open questions remain?
- Who should be tagged or updated?
- Which agent should run?
- What does done look like?

## Product Implication

The orchestrator is not just a session launcher. It is a pre-flight system for work.

The biggest value may come before coding starts: turning messy Jira/Slack/Figma context into a clean implementation packet, then launching the right agent with fewer unknowns.
