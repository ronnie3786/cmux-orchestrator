# Codex Goal: Orchestrator V2 Production Agent Runtime

## Mission

Build on the current Orchestrator V2 scaffold and finish the production-ready agent system that was missing from the first implementation.

The current implementation provides SQLite-backed task storage, a React V2 UI, basic cmux/Jira/GitHub/git APIs, approval storage, activity/audit storage, a basic watcher, and a deterministic chat/status responder. This goal replaces the deterministic responder with a real top-level orchestrator agent using Vercel AI SDK, Fireworks, MiniMax M2.7, CopilotKit dynamic UI, and two selectable voice modes.

This goal is not complete until Ronnie can choose between text chat, GPT Realtime 2 voice, and the low-cost local voice pipeline, and all three modes can use the same audited backend tool layer to inspect tasks, control cmux, update goals, create approvals, and answer status questions from durable Orchestrator V2 state.

## Current Baseline

Branch:

```txt
orchestrator-v2
```

Current committed scaffold:

- SQLite V2 repository and migrations.
- Task CRUD, Jira/PR/cmux links, goal markdown, approvals, audit events, activity events.
- cmux CLI adapter for list/read/search/create/send text/send key/basic inspect.
- Python V2 REST APIs.
- React Vite app served at `/orchestrator-v2`.
- CopilotKit shell wiring with readable task context and one frontend action.
- Deterministic `/api/orchestrator-v2/chat` status responder.
- Basic 10-minute watcher thread.

Known missing items from the original goal:

- Real Vercel AI SDK endpoint.
- Model-backed tool loop.
- Streaming chat.
- Real top-level orchestrator agent.
- GPT Realtime 2 voice.
- Local STT/LLM/TTS voice path.
- CopilotKit dynamic UI integration.
- Approval-gated external write execution.
- Deep watcher refresh and grouped activity.
- cmux kill/restart/session lifecycle tools.
- Production-level browser and design QA.

## External References

Use current official docs during implementation. Known researched identifiers as of 2026-05-17:

- Fireworks MiniMax M2.7 model: `accounts/fireworks/models/minimax-m2p7`
- OpenAI Realtime 2 model: `gpt-realtime-2`
- Vercel AI SDK Fireworks provider should use the Fireworks provider package and `FIREWORKS_API_KEY`.
- CopilotKit/AG-UI should be used as the agent-to-application interaction layer, not merely a generic chat widget.

## Secret Storage

Secrets must never be pasted into chat, committed, logged, or stored in SQLite.

Use a local ignored env file at the repository root:

```txt
/Users/ronnierocha/projects/cmux-orchestrator/.env.local
```

Required initial keys:

```bash
FIREWORKS_API_KEY=...
ORCHESTRATOR_V2_AGENT_PROVIDER=fireworks
ORCHESTRATOR_V2_AGENT_MODEL=accounts/fireworks/models/minimax-m2p7
OPENAI_API_KEY=...
OPENAI_REALTIME_MODEL=gpt-realtime-2
REALTIME_VOICE=marin
ELEVENLABS_API_KEY=...
```

Optional local voice keys/config:

```bash
ORCHESTRATOR_V2_VOICE_MODE=local
ORCHESTRATOR_V2_STT_BACKEND=faster-whisper
ORCHESTRATOR_V2_STT_MODEL=base.en
ORCHESTRATOR_V2_TTS_BACKEND=piper
ORCHESTRATOR_V2_PIPER_VOICE=en_US-amy-medium.onnx
ORCHESTRATOR_V2_PIPER_VOICE_PATH=...
ORCHESTRATOR_V2_PIPER_LENGTH_SCALE=0.67
ORCHESTRATOR_V2_ELEVENLABS_VOICE_ID=cgSgspJ2msm6clMCkdW9
ORCHESTRATOR_V2_ELEVENLABS_VOICE_NAME=Jessica
```

The app must load `.env.local` in local development without exposing secret values to the browser. Browser clients may receive only ephemeral OpenAI Realtime session credentials minted by the local backend.

## Logging And Redaction

Logs, audit events, activity events, test output, browser console output, and screenshots must never include API keys, bearer tokens, Realtime ephemeral credentials, provider authorization headers, or raw `.env.local` contents.

Transcript content does not need special sensitive-data handling for this goal. It may be stored in the global transcript and shown in UI history. Still redact any credential-shaped values if they appear inside user or model messages.

## Architecture

### Deployment Target

The production target for this iteration is Tailscale-accessible local hosting.

Requirements:

- Localhost remains the default bind target for development.
- Tailscale access is allowed when explicitly configured.
- No unauthenticated public internet exposure.
- CORS should be locked down to local/Tailscale origins used by the app.
- Secrets remain server-side only.
- Browser clients receive only short-lived ephemeral credentials where required, such as OpenAI Realtime session credentials.

### System Of Record

The Python harness remains the source of truth for:

- SQLite storage.
- Task/Jira/PR/cmux/goal APIs.
- Approval requests and decisions.
- Audit log.
- Activity stream.
- Safety gating.
- cmux CLI execution.

### Memory Model

Use one global transcript as the source of truth, plus task-linked excerpts/summaries for retrieval.

Requirements:

- All text chat, GPT Realtime 2 voice turns, and local voice turns append to the same global transcript.
- The agent may create task-linked excerpts, status summaries, and goal-discussion notes for retrieval.
- Task-linked memory must be derived from the global transcript or task state and must not become a separate competing chat product.
- Agent turns should load a compact global recent-window plus relevant task-linked summaries.

### Agent Runtime

Add a separate Node/TypeScript Vercel AI SDK sidecar as the top-level orchestrator agent service.

Recommendation and decision:

- Use a Node sidecar because Vercel AI SDK is Node-native and the existing Python harness already owns storage, cmux, git, Jira, GitHub, approval, audit, and activity APIs.
- Keep Python as the local system-of-record and safety boundary.
- Do not move the whole harness to Next.js for this iteration.

Responsibilities:

- Use Fireworks as the primary provider.
- Use MiniMax M2.7 as the default top-level orchestrator model.
- Use MiniMax M2.7 as the only top-level model for the initial production pass.
- Stream responses to the React app.
- Execute tools through the Python V2 backend, not by direct shelling out.
- Share one global transcript with the existing `global_chat_messages` table.
- Write every tool call to `agent_tool_runs`, `audit_events`, and `activity_events`.
- Create approval requests instead of performing risky external writes directly.
- Expose compatible endpoints for CopilotKit.

Proposed endpoints:

- `POST /api/orchestrator-v2/ai/chat`
- `GET /api/orchestrator-v2/ai/chat/stream/:runId` if needed
- `GET /api/orchestrator-v2/ai/capabilities`
- `POST /api/orchestrator-v2/realtime/session`
- `POST /api/orchestrator-v2/voice/local/transcribe`
- `POST /api/orchestrator-v2/voice/local/speak`
- `POST /api/orchestrator-v2/agui/run`
- `GET /api/orchestrator-v2/agui/runs/:runId/events`

### Process Supervision

The Python harness should supervise the production runtime processes where practical:

- Python harness: owns storage, cmux, git, Jira, GitHub, approvals, audit, activity, static app serving, and local STT/TTS orchestration.
- Node sidecar: owns Vercel AI SDK model/tool loop, streaming chat, AG-UI event streaming, and CopilotKit integration endpoints.
- Local voice service: may be in-process Python or a Python-managed subprocess for `faster-whisper` and Piper, depending on dependency constraints.

Developer ergonomics:

- Provide one command or script to start the complete production-local stack.
- Health checks must report Python API, Node sidecar, Fireworks config, OpenAI Realtime config, ElevenLabs optional config, cmux CLI, `faster-whisper`, Piper binary, Piper voice model, SQLite storage, and Tailscale URL/config.
- If an optional provider is missing, the UI must show that provider as unavailable rather than failing the whole app.

### Setup And Dependency Checks

Add setup checks before runtime work is considered complete:

- Node version and package install.
- Python dependencies.
- `faster-whisper` import/model availability.
- Piper binary availability.
- Piper `en_US-amy-medium.onnx` voice file availability.
- ElevenLabs API key availability when ElevenLabs TTS is selected.
- Fireworks API key availability.
- OpenAI API key availability for Realtime mode.
- cmux CLI path and version.
- Tailscale host/URL readiness when Tailscale mode is enabled.

The setup/health check output must redact keys and tokens.

### Tool Registry

The agent must use a typed tool registry covering:

Read/search:

- `list_tasks`
- `get_task`
- `search_tasks`
- `list_cmux_sessions`
- `read_cmux_session`
- `search_cmux_sessions`
- `inspect_cmux_session`
- `summarize_task_sessions`
- `read_goal_markdown`
- `find_jira_ticket`
- `list_assigned_jira`
- `list_my_open_prs`
- `list_my_draft_prs`
- `list_prs_waiting_for_review`
- `get_git_status`
- `get_git_diff`

Local create/update:

- `create_task`
- `update_task_status`
- `update_task_priority`
- `update_task_tags`
- `attach_jira_to_task`
- `attach_pr_to_task`
- `attach_cmux_session_to_task`
- `detach_cmux_session_from_task`
- `create_cmux_session`
- `launch_coding_agent`
- `send_cmux_prompt`
- `send_cmux_key`
- `update_goal_markdown`
- `create_approval_request`

Implemented approval-gated external actions for this goal:

- `post_jira_comment`
- `transition_jira_status`

Explicitly not implemented in this goal:

- `post_pr_reply`
- `submit_pr_review`
- `run_destructive_git_operation`
- `kill_cmux_session`
- `restart_cmux_session`

These future tools must be visible as unavailable/not implemented if referenced by the UI or agent. Do not mock them, do not pretend they work, and do not silently create fake success responses.

The model may propose approval-gated actions, but execution must stop at an approval request until Ronnie approves.

## Voice Mode A: GPT Realtime 2

Implement a first-class voice mode powered by OpenAI Realtime 2.

Requirements:

- Browser microphone capture.
- Backend endpoint mints ephemeral Realtime credentials.
- Use `gpt-realtime-2`.
- Use `REALTIME_VOICE=marin` as the default Realtime voice.
- Use server-side VAD as the default turn-detection mode.
- Enable barge-in/interruption by default.
- Provide push-to-talk as an optional UI mode.
- Voice and chat share the same global transcript.
- Realtime tool calling directly uses the same typed tool registry and approval gates as text chat. It must not hand off to a separate server-side planning agent before tool execution.
- Browser-side Realtime tool calls must still execute through the local backend so Python can enforce approval, audit, and secret boundaries.
- Tool results update the same activity/audit streams.
- UI shows voice connection state, transcript, tool activity, interruptions, and errors.
- Ronnie can switch between text and voice without creating a separate conversation.
- Secrets stay server-side.

## Voice Mode B: Low-Cost Local Voice

Implement a selectable local voice pipeline:

```txt
browser microphone
  -> local STT service
  -> Vercel AI SDK Fireworks text/tool loop
  -> local Piper TTS
  -> browser audio output
```

Default STT:

- `faster-whisper`

Default local TTS:

- Piper TTS
- Voice model: `en_US-amy-medium.onnx`
- Speed wrapper/default: `--length-scale 0.67`

Alternate network TTS:

- ElevenLabs
- Voice name: `Jessica`
- Voice ID: `cgSgspJ2msm6clMCkdW9`
- Requires `ELEVENLABS_API_KEY` in `.env.local`

Implementation decision:

- Run STT/TTS inside the Python harness or a small Python-managed local service, whichever is simpler after dependency probing.
- Keep the Vercel AI SDK reasoning/tool loop in the Node sidecar.

Requirements:

- No OpenAI voice cost for this mode.
- Fireworks still drives reasoning/tool use through MiniMax M2.7.
- Audio transcripts are stored in the same global chat transcript.
- TTS output is generated by Piper locally by default and streamed or returned to the browser.
- ElevenLabs can be selected as an alternate TTS provider when the API key is configured.
- The UI can switch between Realtime 2 and local voice modes.
- Include fixture-audio tests and at least one live microphone manual test path.

## CopilotKit Dynamic UI

Upgrade the current light CopilotKit wiring into real dynamic UI integration:

- Agent readable context includes current tasks, selected task, approvals, visible panel, cmux sessions, git status, and recent activity.
- Frontend tools can open task detail, open goal, open cmux session, open diff, focus approval, refresh data, and switch voice modes.
- Generative/dynamic UI panels render structured agent outputs, not only text.
- CopilotKit endpoint delegates to the same Vercel AI SDK runtime and tool registry.

Use CopilotKit/AG-UI as the main UI interaction contract:

- The Node sidecar streams typed AG-UI events for agent messages, tool calls, tool results, state patches, generative UI panels, approval requests, and errors.
- The React app consumes those events through CopilotKit/AG-UI hooks and renders them into the existing Orchestrator V2 layout.
- The app owns final rendering and styling. The agent may select from approved UI components and pass structured props, but it must not generate arbitrary raw DOM, unsafe HTML, or unreviewed executable frontend code.
- Persist enough run/event metadata to replay recent agent interactions after refresh.

Controlled generative UI components to build first:

- `TaskStatusPanel`: grounded status answer with task cards, linked Jira/PR/cmux resources, and freshness markers.
- `CmuxSessionInspectorPanel`: live session screen excerpt, running tool classification, suggested safe actions, and explicit stale/error states.
- `GitDiffSummaryPanel`: changed files, staged/unstaged grouping, risk summary, and CTA to open the full diff view.
- `GoalDraftPanel`: proposed goal markdown changes with accept/reject/edit controls.
- `JiraCommentApprovalPanel`: exact Jira comment preview, target issue, approval status, and post-after-approval state.
- `JiraTransitionPanel`: proposed or completed Jira transition with source/target status and audit link.
- `VoiceModePanel`: current voice mode, Realtime/local connection state, selected voice/TTS provider, and fallback state.
- `ToolRunTimeline`: grouped tool calls for one user request or watcher run.
- `NotImplementedCapabilityPanel`: explicit unsupported capability response for PR replies/reviews, destructive git, cmux kill, and cmux restart.

Frontend tools the agent can call:

- `openTask`
- `openTaskGoal`
- `openTaskSession`
- `openTaskDiff`
- `focusApproval`
- `showGeneratedPanel`
- `replaceGeneratedPanel`
- `dismissGeneratedPanel`
- `setBoardFilter`
- `refreshOrchestratorData`
- `switchVoiceMode`
- `startVoiceSession`
- `stopVoiceSession`

Human-in-the-loop UI requirements:

- Approval requests render as first-class CopilotKit/AG-UI panels with exact reviewed payloads.
- Approval UI must show what will happen, what API/tool will run, what target will be mutated, and whether the action is reversible.
- Approval decisions must call the Python backend and execute only the stored reviewed payload.
- Approval UI must never be a plain free-form chat confirmation.

Declarative/open generative UI policy:

- Controlled generative UI is required first.
- Declarative UI specs such as A2UI/Open-JSON-UI may be added only behind a renderer allowlist.
- Allowed declarative components must map to the local design system and pass accessibility, layout, and screenshot tests.
- Open-ended generated UI/MCP Apps are future work unless explicitly approved in a later goal.

Dynamic UI QA requirements:

- Add contract tests for every AG-UI event shape emitted by the sidecar.
- Add frontend tests for every controlled generative UI panel.
- Browser QA must verify streamed tool lifecycle states: pending, running, completed, requires approval, approved, denied, error, and not implemented.
- Screenshot QA must include at least three agent-generated panels in the main layout and at least one approval panel.

## Watcher And Activity

Replace the shallow watcher with a production watcher:

- Refresh assigned Jira.
- Refresh open/draft/review-request PRs.
- Refresh cmux sessions and orphan candidates.
- Inspect changed active sessions.
- Refresh merged task session summaries with freshness checks.
- Detect important state changes.
- Create grouped activity events by watcher run.
- Never perform risky external writes.

The activity UI must group tool calls by user request or watcher run.

## cmux Lifecycle

Complete only the cmux controls required for the current production pass:

- Expose `send_cmux_key`.
- Improve `inspect_cmux_session` beyond title heuristics.
- Confirm launch commands for Codex, Claude Code, OpenCode, and Empty shell.
- Mark live mutating cmux launch tests as Ronnie-approved tests.
- Do not implement cmux kill/restart in this goal. If the agent or UI references kill/restart, return a clear `not_implemented` result and suggest a future update.

## Jira And GitHub Writes

Implement safe external write flows:

- Jira transition may execute without approval.
- Jira comments require preview and approval.
- PR replies are not implemented in this goal.
- PR reviews are not implemented in this goal.
- All external write payloads must be visible before approval.
- All approved writes must record audit/activity/tool events.
- Not-implemented write flows must never appear successful.

Not-implemented UX requirements:

- If Ronnie asks for PR replies/reviews, destructive git operations, cmux kill, or cmux restart, the agent must answer with a clear unsupported-capability result.
- The UI must render `NotImplementedCapabilityPanel` instead of hiding the limitation or simulating success.
- Tests must assert these unsupported capabilities cannot call backend mutating endpoints accidentally.

## Frontend Product Gaps

Finish the UI gaps:

- New Task default launch type should be Empty shell unless explicitly selected.
- History UI for Done/Archived tasks.
- Remove or disable list-view affordance unless implemented.
- Full chat/history slide-out or equivalent inspectable global transcript.
- Proper grouped activity stream.
- Voice mode picker and connection UI.
- Better empty/loading/error states for live data.
- Re-run design QA against the six reference screenshots.

## Definition Of Done

### Agent Runtime Done

- Vercel AI SDK runtime exists and is used by chat.
- Fireworks provider is configured via `FIREWORKS_API_KEY`.
- Default model is `accounts/fireworks/models/minimax-m2p7`.
- Chat streams model responses.
- Model can call typed tools.
- Tool calls are routed through Python V2 APIs.
- Tool calls are audited and shown in activity.
- Agent answers task/session status using durable task state and live cmux inspection.
- Agent can create tasks, attach resources, update goals, and send cmux follow-up prompts.
- Approval-gated actions create approval requests instead of executing directly.

### GPT Realtime 2 Voice Done

- Browser can start a Realtime 2 voice session.
- Backend mints ephemeral credentials using server-side `OPENAI_API_KEY`.
- Realtime model is `gpt-realtime-2`.
- Default Realtime voice is loaded from `REALTIME_VOICE`, initially `marin`.
- Server-side VAD is the default turn-detection mode.
- Barge-in/interruption is enabled by default.
- Push-to-talk is available as an optional UI mode.
- Realtime voice can call the same tools as chat.
- Realtime tool calls execute through the local backend safety/audit layer.
- Voice transcript is stored with global chat.
- Approval-gated actions still require Ronnie approval.

### CopilotKit Dynamic UI Done

- CopilotKit/AG-UI consumes streamed agent events from the Node sidecar.
- The app supports controlled generative UI panels for task status, cmux inspection, git diff summaries, goal drafts, Jira approvals, Jira transitions, voice state, grouped tool timelines, and not-implemented capabilities.
- Frontend tools can navigate and update the Orchestrator V2 UI without direct DOM manipulation.
- Approval requests render as structured human-in-the-loop UI with exact reviewed payloads.
- AG-UI event contract tests and panel rendering tests pass.

### Local Voice Done

- Browser can record audio for local voice mode.
- `faster-whisper` transcribes audio.
- Transcribed request runs through the same Fireworks/Vercel AI SDK tool loop.
- Piper TTS returns spoken output using `en_US-amy-medium.onnx` and `--length-scale 0.67`.
- ElevenLabs Jessica voice can be selected when `ELEVENLABS_API_KEY` is configured.
- Transcript and tool activity are stored in the same durable state.
- The UI can switch between Realtime 2 and local voice mode.

### Safety Done

- Secrets are loaded only server-side.
- `.env.local` is ignored by git.
- No API keys, bearer tokens, ephemeral Realtime credentials, provider authorization headers, or raw `.env.local` values appear in frontend bundles, logs, test snapshots, screenshots, activity events, audit payloads, or browser console output.
- Transcript content may be stored and displayed, but credential-shaped values inside transcripts must be redacted before logging or audit persistence.
- Jira comments require approval.
- Jira transitions do not require approval.
- PR replies/reviews, destructive git operations, and cmux kill/restart are explicitly not implemented in this goal.
- Approval decisions execute only the exact reviewed payload.

### Quality Gates Done

- Python unit tests pass.
- Node/Vercel AI SDK tests pass.
- Frontend build and tests pass.
- Tool registry tests cover every tool.
- Voice pipeline tests cover fixture audio and TTS output generation.
- Setup/health checks verify Python API, Node sidecar, Fireworks, OpenAI Realtime, optional ElevenLabs, cmux CLI, `faster-whisper`, Piper, SQLite, and Tailscale readiness with redacted output.
- Not-implemented capability tests prove PR replies/reviews, destructive git, cmux kill, and cmux restart return explicit unsupported results and cannot silently execute.
- Browser QA covers text chat, Realtime voice, local voice, approvals, task creation, cmux session view, git diff, goal editing, history, grouped activity, desktop, and one narrow viewport.
- Browser/device QA matrix is desktop plus one narrow viewport for this goal. Broader browser/device coverage is future work.
- Live-mutating tests are either Ronnie-approved and executed or explicitly reported as `Needs Ronnie live test`.

## Decisions From Ronnie

1. Use the recommended Node sidecar architecture for Vercel AI SDK.
2. Use only MiniMax M2.7 for the initial top-level agent runtime.
3. Use MiniMax M2.7 for the low-cost voice text/tool loop too.
4. GPT Realtime 2 should call tools directly, routed through the local backend safety/audit layer.
5. Use OpenAI Realtime voice `marin` via `REALTIME_VOICE=marin`.
6. Use `faster-whisper` for local STT.
7. Use Piper `en_US-amy-medium.onnx` with `--length-scale 0.67` as the local TTS default.
8. Also support ElevenLabs Jessica, voice ID `cgSgspJ2msm6clMCkdW9`, via `ELEVENLABS_API_KEY`.
9. Run local voice wherever setup is easiest; prefer Python harness/Python-managed service for STT/TTS after dependency probing.
10. Implement Jira comments and Jira transitions only for external writes in this goal.
11. PR replies/reviews, destructive git, cmux kill, and cmux restart are future work and must be explicit `not implemented` capabilities.
12. Production target is Tailscale-accessible.
13. Realtime defaults are server-side VAD, barge-in/interruption enabled, and push-to-talk available as an optional UI mode.
14. Memory remains one global transcript as source of truth, with task-linked excerpts/summaries for retrieval.
15. Python should supervise the full local production stack where practical, with a single start command and health checks.
16. Dependency checks must cover Node, Python, `faster-whisper`, Piper, ElevenLabs optional config, Fireworks, OpenAI Realtime, cmux, SQLite, and Tailscale readiness.
17. Logs must never include API keys, bearer tokens, provider authorization headers, Realtime ephemeral credentials, or raw env contents. Transcript text does not require special sensitive-data handling except credential-shaped values must be redacted.
18. Not-implemented capabilities must be explicit in the agent and UI and covered by tests.
19. Browser/device QA matrix is desktop plus one narrow viewport for this goal.
20. Stop at local commits and a final report. Do not push or create a PR unless Ronnie explicitly asks later.

## Remaining Open Questions

None. This goal is ready for implementation.
