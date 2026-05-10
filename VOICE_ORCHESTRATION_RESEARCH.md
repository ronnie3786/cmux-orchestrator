# GPT-Realtime-2 Voice Orchestration Research

## Why this is relevant

GPT-Realtime-2 is a strong fit for a future voice layer on top of the orchestrator because it supports live speech-to-speech interaction, tool calling, interruptions, corrections, longer context, and adjustable reasoning. That maps directly to Ronnie's desired workflow: talk through a Jira ticket, answer clarifying questions, approve actions, choose agents, and receive spoken briefings while the orchestrator updates state and takes action.

The key product idea:

```text
Ronnie speaks naturally
  -> voice orchestrator understands intent
  -> calls orchestrator tools
  -> updates shared objective state
  -> asks clarifying questions or confirms writes
  -> launches/monitors coding agents
  -> speaks short progress updates and final briefings
```

## Relevant GPT-Realtime-2 capabilities

### Live voice-to-voice

Realtime sessions keep a connection open while the app sends audio, receives spoken responses, receives events, and updates session state. For browser/mobile voice agents, OpenAI recommends WebRTC. Server-side or media-pipeline use cases can use WebSockets.

### Stronger reasoning for voice agents

GPT-Realtime-2 adds configurable reasoning effort: minimal, low, medium, high, and xhigh. OpenAI recommends starting with low for most production voice agents, then increasing only when task complexity or failure cost justifies the latency/cost.

For this orchestrator:

- `low`: quick status checks, direct answers, simple read-only lookups.
- `medium`: Jira intake, context gathering, deciding which agent to launch.
- `high`: complex replanning, conflicting tasks, risky escalation decisions.

### Tool calling and action execution

Realtime sessions can attach tools at the session level or per-response. Tool options include:

- Function tools: our app executes the business logic and returns results.
- MCP tools: OpenAI calls a remote MCP server or connector.
- Built-in connectors: Google Calendar style connector path, when supported.

For our orchestrator, function tools should be the default because private business logic, Jira access, cmux control, repo access, and approval rules should live on our server.

### Sideband server control

Realtime supports a sideband connection where the client maintains the audio session and the application server joins the same session over WebSocket. The server can monitor events, update instructions, add tools, and respond to tool calls.

This is the right architecture for us:

```text
Mac/iOS/Web microphone
  -> WebRTC audio session with GPT-Realtime-2
  -> sideband server connection
  -> orchestrator backend tools
  -> cmux / Codex / Jira / filesystem / memory
```

This keeps API keys and business logic off the client.

### Preambles

The model can speak short updates before tool calls or longer reasoning, like “I’ll check the Jira ticket now.” This is useful for keeping voice interaction responsive.

For our use:

- Use preambles before actions that take noticeable time.
- Skip preambles for direct answers.
- Avoid filler.
- Keep them one sentence.

### Corrections and interruptions

Realtime voice models are designed for natural corrections and interruptions. This matters when Ronnie changes direction mid-flow:

- “Actually, use Codex for this one.”
- “Wait, don’t post that Jira comment yet.”
- “Add the backend PR link first.”
- “No, tag Sarah, not Sam.”

The voice layer should treat interruption as a first-class control signal.

### Exact entity handling

OpenAI’s prompting guide emphasizes conservative capture of exact identifiers like ticket IDs, emails, order numbers, and codes. For us, that means Jira keys, branch names, PR numbers, Slack links, Figma URLs, and usernames should be confirmed before lookup or write actions if there is ambiguity.

Examples:

- “I heard IOSDOX-24739. Is that right?”
- “Do you mean PR 1284 in the iOS repo?”
- “Should I tag Maya the PM or Maya the engineer?”

### Cost considerations

GPT-Realtime-2 pricing from the docs:

- Text input: $4 / 1M tokens
- Text output: $24 / 1M tokens
- Audio input: $32 / 1M tokens
- Audio output: $64 / 1M tokens
- Image input: $5 / 1M tokens

Audio token roughness from OpenAI cost docs:

- User audio: roughly 1 token per 100ms
- Assistant audio: roughly 1 token per 50ms

Realtime sessions get more expensive over long conversations because the conversation context is sent forward each turn. Prompt caching helps, but we should still summarize and compact session state.

## Recommended architecture for cmux-orchestrator

### Voice Layer

A browser/Mac/iOS voice UI connects to GPT-Realtime-2 with WebRTC.

Responsibilities:

- Capture microphone audio.
- Play model audio.
- Show live transcript and action log.
- Let Ronnie interrupt, mute, confirm, or cancel.

### Voice Session Server

A server endpoint creates Realtime sessions and keeps API keys private.

Responsibilities:

- Create session via `/v1/realtime/calls` or ephemeral client secret endpoint.
- Include safety identifier.
- Start sideband WebSocket to the same call/session.
- Attach tools and monitor events.
- Persist transcripts and tool calls.

### Orchestrator Tool Gateway

Function tools exposed to the voice model.

Candidate tools:

```text
read_objective_state(objective_id)
create_objective_from_jira(ticket_key_or_url)
search_jira(query_or_key)
read_jira_ticket(ticket_key)
draft_jira_comment(ticket_key, intent)
post_jira_comment(ticket_key, comment, tagged_people)
search_slack_context(query_or_url)
read_figma_context(url)
update_context_packet(objective_id, section, content)
list_open_questions(objective_id)
mark_question_answered(objective_id, question_id, answer)
recommend_agent(objective_id)
launch_agent(objective_id, agent_type)
pause_objective(objective_id)
resume_objective(objective_id)
replan_objective(objective_id, feedback)
read_worker_status(objective_id)
create_decision_card(objective_id, summary, options)
```

### Orchestrator State

The voice model should not be the source of truth. It should manipulate the same durable state as the dashboard:

```text
objective.json
messages.jsonl
voice-transcript.jsonl
tool-calls.jsonl
context.md
open-questions.md
jira.md
agent-plan.md
```

### Approval boundaries

Voice is powerful, but risky for writes. Use clear confirmation rules.

Read-only actions:

- Search Jira
- Read ticket
- Read objective status
- Read context packet
- Summarize worker state

These can happen when intent is clear.

Write/external actions require explicit confirmation:

- Post Jira comment
- Create Jira ticket
- Launch coding agent
- Cancel/pause active worker
- Merge/push/create PR
- Message/tag people
- Delete/cleanup worktrees

The model should draft and preview before writing.

## Voice workflows we should support

### 1. Jira intake by voice

Ronnie says:

> Start IOSDOX-24739. Let’s figure out if it’s ready for implementation.

Voice orchestrator:

1. Reads Jira.
2. Summarizes ticket.
3. Detects missing context.
4. Asks one question at a time.
5. Saves answers into context packet.
6. Offers to post unanswered questions to Jira.

### 2. Context readiness loop

Voice orchestrator repeatedly asks:

> Do we have enough to implement this with low intervention?

It should keep a checklist:

- repo/project known
- acceptance criteria known
- backend/Figma/Slack links found
- PM/designer/dev contacts known
- open questions answered or posted
- coding agent chosen

### 3. Agent launch by voice

Ronnie says:

> Use Codex for this one. Start it with the context packet.

Voice orchestrator:

1. Repeats the plan briefly.
2. Confirms launch.
3. Calls `launch_agent`.
4. Announces session created.
5. Watches for first progress update.

### 4. Live status briefing

Ronnie asks:

> What’s happening with the auth ticket?

Voice orchestrator answers:

- current objective state
- active workers
- latest checkpoint
- blockers
- decisions needed
- next expected event

### 5. Decision queue by voice

Ronnie asks:

> What needs me?

Voice orchestrator reads decision cards and presents them one at a time with recommendation and options.

### 6. Replan loop

Ronnie says:

> This is getting too broad. Split the UI cleanup into a separate ticket and keep this one focused on the API behavior.

Voice orchestrator:

1. Updates objective plan.
2. Creates or drafts follow-up ticket.
3. Pauses/reassigns tasks if needed.
4. Briefs Ronnie on the new plan.

## Prompting guidance for our voice orchestrator

Use short sections:

- Role and objective
- Tone
- Reasoning effort rules
- Tool rules
- Confirmation rules
- Jira/entity capture
- Preambles
- Silence/background-noise behavior
- Escalation behavior

Important rules:

- Ask one clarifying question at a time.
- Confirm exact IDs before lookup if ambiguous.
- Confirm all writes before tool calls.
- Never claim a tool action succeeded until the tool result confirms it.
- Use short spoken preambles only when useful.
- If audio is unclear, ask Ronnie to repeat instead of guessing.
- Treat side conversation or background audio as no-op.

## MVP integration path

### Phase 1: Voice read-only cockpit

- Add microphone button to visual/dashboard UI.
- Connect GPT-Realtime-2 over WebRTC.
- Tools are read-only: read objective, list questions, summarize status.
- Persist transcripts.

### Phase 2: Voice context builder

- Add tools for updating local context packet.
- Voice can add notes, mark questions answered, and update readiness checklist.
- Writes are local only.

### Phase 3: Voice Jira assistant

- Add Jira read tools.
- Add Jira comment draft and preview.
- Posting requires explicit confirmation.

### Phase 4: Voice agent launcher

- Add agent recommendation and launch tools.
- Launch requires explicit confirmation.
- Voice follows up with progress status.

### Phase 5: Full voice command center

- Decision queue by voice.
- Replan by voice.
- Pause/resume workers.
- Multi-objective briefings.

## Open questions

- Should the first voice surface be web dashboard, native Mac app, or iOS app?
- Does Doximity/work environment allow OpenAI Realtime API usage for work ticket context?
- Do we need an on-device/local voice fallback for sensitive contexts?
- Which write actions are allowed by default, and which always require confirmation?
- How do we budget/cap long voice sessions?
- Should transcripts be stored forever, summarized, or pruned per objective?

## Recommendation

Use GPT-Realtime-2 as a future interaction layer, not as the core orchestrator brain.

The orchestrator state machine, Jira integration, session management, reviews, and memory should remain deterministic server-side components. GPT-Realtime-2 should be the natural voice interface that reads and updates that state through explicit tools.

That gives us the best of both worlds: natural real-time conversation with safe, auditable action execution.
