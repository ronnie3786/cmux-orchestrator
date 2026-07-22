# Orchestrator V2 — Voice Visual Mode ("Talking Orchestrator")

*Spec approved via Ronnie's voice memo, 2026-07-06 ("Orchestrated visual view").*
*This document is the binding contract for the implementation. It extends — and where noted, supersedes — the local-voice decisions in `docs/ORCHESTRATOR_V2_PRODUCTION_GOAL.md`.*

## Vision (from the voice memo)

A full-screen, voice-interactive "visual mode" that lives on top of the V2 orchestrator dashboard. A persona (face/orb) sits in the middle of the screen with a big **Talk** CTA. Starting a session plays a short greeting ("Hey — what are we doing today?"). Ronnie asks things like *"What sessions do I have running in cmux? List them out"*; the agent checks cmux and the other tools it has, **speaks the answer**, shows **live captions**, and renders a **rich HTML visual response** generated on the fly (same idea as the Echo phone-card enrichment) that swaps in over the instant markdown render. He can **interrupt with his voice** (barge-in), ask **follow-ups** without re-tapping, **manually end the session**, and open **chat history** to read previous conversations. A button toggles between visual mode and the full V2 dashboard, both directions.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | STT backend: **Parakeet** hot service via Mac tunnel `http://127.0.0.1:18793` (`POST /transcribe`, multipart field `audio`, WAV; returns `{"text": ...}`). Fallback: faster-whisper if Parakeet is unreachable and faster-whisper is importable. | ~0.15 s per utterance; replaces faster-whisper default (supersedes PRODUCTION_GOAL Decision 6). |
| 2 | Browser records **16 kHz mono PCM16 WAV client-side** (AudioWorklet, ScriptProcessor fallback). No webm, no server-side ffmpeg. | Removes the ffmpeg dependency; Parakeet wants 16 kHz WAV anyway. |
| 3 | TTS provider: **Kokoro** on `http://127.0.0.1:8898` (OpenAI-compatible `POST /v1/audio/speech`, payload `{"model":"kokoro","voice":...,"input":...,"response_format":"wav","speed":1.0}`, 24 kHz WAV back). Default voice **`bm_daniel`**. Piper/ElevenLabs remain as fallback providers. | Local, fast, already serving the Echo (supersedes Decision 7 as default). British male = the "Jarvis-style goal". |
| 4 | Agent brain: the existing **Node sidecar** (`/api/orchestrator-v2/ai/chat`, Fireworks MiniMax M2.7, full audited tool registry) with a new `mode: "voice"` prompt variant. | Only streaming + tool-calling path; keeps voice on the same audited tool layer (Decision 4 in PRODUCTION_GOAL). |
| 5 | Rich visual answers: instant client-side markdown render of the streamed answer, then an async **HTML enrichment** pass (Fireworks chat-completions from Python) swapped into a `sandbox=""` iframe after server-side validation. | Mirrors the proven Echo basic→enriched card flow while honoring the "no arbitrary unsandboxed agent HTML" rule (PRODUCTION_GOAL L334): validated, script-free, sandboxed. |
| 6 | One global transcript (Decision 14) holds voice turns too, tagged `metadata.mode = "voice"`. Voice-mode History reads `GET /chat/messages`. No separate voice chat store. | Hard prior decision. |
| 7 | Interruption: client-side barge-in (mic RMS while TTS plays: threshold 0.018, sustain 220 ms, 700 ms cooldown after playback starts, echoCancellation on) + tap-to-interrupt + Esc. Aborts the answer fetch and stops audio. Sidecar aborts its LLM stream when the client disconnects. | Lux-web recipe, adapted; PTT design sidesteps most self-trigger risk. |
| 8 | Follow-up listening: after answer audio ends, the mic auto-opens for a 6 s window; speech starts the next turn, silence returns to idle. Session runs until **End session**. | Echo follow-up pattern, explicit in the memo. |
| 9 | Perceived latency: a short deterministic acknowledgement ("Checking your sessions…") is TTS'd and played as soon as the agent's first tool call starts, never overlapping the final answer audio. | Quick-ack pattern from echo-openclaw, minus the LLM dependency. |
| 10 | Answer style in voice mode: conversational, ≤ 4 short sentences; the rich panel (built from the question, answer, and tool results) carries the detail. No dual VISUAL/SPOKEN output format. | Simpler than the Echo dual-output contract; the enrichment panel is the visual channel. |

## Architecture

```
Browser (Visual Mode view, React)
 ├─ AudioWorklet 16k WAV capture ──► POST /voice/local/transcribe (parakeet) ──► Parakeet :18793
 ├─ POST /ai/chat {mode:"voice"} ──► Python proxy ──► Node sidecar (Fireworks + 38 tools)
 │        ◄── SSE AG-UI: TEXT_MESSAGE_CONTENT (captions), TOOL_CALL_*, RUN_FINISHED
 ├─ POST /voice/local/speak (kokoro) ──► Kokoro :8898 ──► base64 WAV ──► WebAudio playback
 │        └─ analyser drives the persona orb; barge-in monitor runs while playing
 └─ POST /voice/enrich {question, answer, toolResults} ──► Fireworks chat-completions
          ◄── validated script-free HTML ──► sandboxed iframe swap
```

## API contracts

### `POST /api/orchestrator-v2/voice/local/transcribe` (extended)

Request: `{"audioBase64": str, "filename"?: str, "mimeType"?: str, "backend"?: "parakeet"|"faster-whisper", "partial"?: bool, "appendChat"?: bool}`

- Backend default: `ORCHESTRATOR_V2_STT_BACKEND` (new default **`parakeet`**). Parakeet call: multipart `audio` field to `{ORCHESTRATOR_V2_PARAKEET_URL}/transcribe`, 15 s timeout. On connection failure, fall back to faster-whisper when importable; report which backend answered.
- `partial: true` → never appends to chat, used for live captions while recording.
- `appendChat` default `true` (backward compatible). The Visual Mode flow sends `false` and lets the sidecar's transcript append be the single write (fixes the existing double-append).
- Response: `{"ok": true, "text": str, "backend": str, "elapsedS": float}`.
- `CMUX_ORCHESTRATOR_V2_FAKE_VOICE=1` keeps returning fixture text.

### `POST /api/orchestrator-v2/voice/local/speak` (extended)

Request: `{"text": str, "provider"?: "kokoro"|"piper"|"elevenlabs", "voice"?: str, "speed"?: float}`

- Provider default: `ORCHESTRATOR_V2_TTS_BACKEND` (new default **`kokoro`**). Kokoro: `POST {ORCHESTRATOR_V2_KOKORO_URL}/v1/audio/speech`, 60 s timeout, voice default `ORCHESTRATOR_V2_KOKORO_VOICE` (`bm_daniel`).
- Response: `{"ok": true, "provider": str, "mimeType": "audio/wav", "audioBase64": str, "voice": str, "elapsedS": float}`.
- Text capped at 1,200 chars (raise `ValueError` beyond).

### `POST /api/orchestrator-v2/voice/enrich` (new)

Request: `{"question": str, "answer": str, "toolResults"?: [{"name": str, "preview": str}], "title"?: str}`

- Calls Fireworks `POST https://api.fireworks.ai/inference/v1/chat/completions` (model `ORCHESTRATOR_V2_ENRICH_MODEL`, default = agent model; `FIREWORKS_API_KEY`), 90 s timeout, max_tokens ≈ 6000, temperature ≈ 0.5.
- System prompt: adapted from the Echo enrichment prompt for a **desktop dark panel** (~920 px wide, self-contained single `<style>`, **no `<script>`**, no external resources, transparent-friendly dark background, lead with the hero fact, 2–4 compact modules, data tables/status chips where the tool results warrant them).
- Validation before returning: strip ``` fences; require `<html`… `</html>`; ≥ 400 chars; reject any `<script`, `javascript:`, `srcdoc=`, `on*=` handler attributes (case-insensitive). Invalid → `OrchestratorV2RouteError` 502.
- Response: `{"ok": true, "html": str, "model": str, "elapsedS": float}`.
- Tool result previews truncated server-side (~2,000 chars each, max 8 entries).
- Fake mode returns a fixture HTML document.

### Capabilities & health

- `health_payload` gains non-required checks `parakeet` (`GET {PARAKEET_URL}/health`, 2 s) and `kokoro` (`GET {KOKORO_URL}/health`, 2 s).
- `agent_capabilities_payload().voiceModes.local` reports `{stt: {backend, available}, tts: {provider, available}, enrich: bool}`; new `voiceModes.visual = parakeet_ok && kokoro_ok` (fallbacks may still let the mode run degraded).
- Register new/changed endpoints in `cmux_harness/api_discovery.py`.

### Env (`.env.local`)

```
ORCHESTRATOR_V2_STT_BACKEND=parakeet
ORCHESTRATOR_V2_PARAKEET_URL=http://127.0.0.1:18793
ORCHESTRATOR_V2_TTS_BACKEND=kokoro
ORCHESTRATOR_V2_KOKORO_URL=http://127.0.0.1:8898
ORCHESTRATOR_V2_KOKORO_VOICE=bm_daniel
# ORCHESTRATOR_V2_ENRICH_MODEL=accounts/fireworks/models/minimax-m2p7   (optional override)
```

## Node sidecar changes (`agent/orchestrator-v2/src/`)

1. **Voice prompt variant** — when `mode === "voice"`, `buildSystemPrompt` appends: answer conversationally in ≤ 4 short sentences (~45 words); no tables, code blocks, URLs, or emoji; round numbers; always call tools before answering questions about sessions/tasks/PRs/Jira; summarize counts and highlights aloud and let the visual panel carry detail; for `send_cmux_prompt`, `create_cmux_session`, or `launch_coding_agent`, first state exactly what will be sent/created and ask for verbal confirmation — only call the tool after the user confirms in a following turn (kill/restart stay approval-gated server-side).
2. **Follow-up continuity** — `buildMessages` includes the last 4 assistant messages (trimmed to ~400 chars each) when `mode === "voice"`, so "what about the second one?" works. User-message cap stays at 6.
3. **Abort on disconnect** — `server.js` wires `req.on("close")` to an `AbortController` passed as `abortSignal` to `streamText`; nothing is emitted after abort. This makes client-side barge-in actually stop the LLM run.
4. Dry-run and grounded-status paths keep working unchanged.

## Frontend spec (`frontend/orchestrator-v2/`)

### View plumbing

- New view kind `"voice"` rendered as a **fixed full-viewport overlay** above the app shell (the dashboard stays mounted underneath). Entry: a **Visual Mode** button in the TopBar (orb glyph) and `?view=voice` deep link; `history.pushState`/`popstate` sync so refresh/back work for this view. Exit: **Dashboard** button top-right returns to the previous view.
- `streamAgent` gains an optional `AbortSignal` parameter (default behavior unchanged for existing callers).

### Session state machine

`off → greeting → idle ⇄ listening → transcribing → thinking → speaking → followup → (idle | listening) … → off`

- **Start session**: begins mic permission + WebAudio context, plays a greeting (one of ~4 short variants through `/voice/local/speak`), then opens the mic in follow-up mode.
- **Talk CTA**: hold-to-talk (mouse/touch/Space) or tap-to-toggle with VAD auto-stop (900 ms silence, 450 ms min speech, 20 s cap) — mode in a settings popover, default tap-to-toggle.
- **Live captions**: while recording, accumulated PCM is sent every ~1.5 s as a `partial` transcribe; interim text renders as the user caption line. While the agent streams, assistant deltas render as captions (markdown stripped for the caption line).
- **Quick-ack**: on first `TOOL_CALL_START`, TTS + play a rotating deterministic ack unless the answer audio is already ready.
- **Speaking**: answer audio decoded via WebAudio (`decodeAudioData` → `BufferSource` + `AnalyserNode` for the orb). Barge-in monitor per Decision 7; tap Talk or Esc also interrupts.
- **Follow-up**: 6 s auto-listen window after playback; VAD decides speech vs. silence.
- **End session** stops everything, closes streams, releases the mic.

### Persona orb (the signature element)

Layered CSS/SVG orb ~300 px: radial core + slowly rotating conic aurora ring + audio-reactive halo (analyser RMS → glow scale), two soft eyes with occasional blink. State palettes: idle = deep blue breathing; listening = teal ring that expands with mic level; thinking = slow orbiting shimmer; speaking = pulse synced to output amplitude. `prefers-reduced-motion`: static gradients, opacity-only transitions. When an answer panel is present the orb scales to ~64 % and shifts up to yield the stage.

### Answer panel

Slides up under the orb: instant `react-markdown` render of the answer (plus a compact tool-activity strip: which tools ran), then when `/voice/enrich` returns, swap to `<iframe sandbox="" srcDoc={html}>` with a Text ⇄ Rich toggle. Panel is per-turn; a new turn replaces it.

### History drawer

Left overlay drawer listing `GET /chat/messages` (most recent first, day dividers, mic badge when `metadata.mode` is voice-ish). Read-only, scrollable, Esc/scrim closes.

### Visual design (scoped `.voice-*` tokens; do not touch dashboard tokens)

- `--voice-void #0A0E16` (bg), `--voice-haze #131A28` (surfaces), hairline `rgba(148,163,196,.14)`, text `#E6EDF7` / `#8B96AD`, orb core `#5B8CFF`, listening `#34D0B6`, attention `#E8A13D`, error kin to dashboard red.
- Type: system stack for body; **mono eyebrows** (`SFMono/Menlo`, letter-spaced uppercase) for state labels — LISTENING · THINKING · SPEAKING; captions set large (~20 px) and centered, subtitle-style.
- Top strip: persona name + session timer (mono, quiet) · History · Dashboard. Bottom center: End session · **Talk** (large pill, mic glyph) · settings.
- Persona name constant `VOICE_PERSONA_NAME = "Maestro"` (single source, easy to change). Greeting copy: short, plain, varied.
- Errors are directive toasts: e.g. "Speech service is offline — check the Parakeet tunnel (127.0.0.1:18793)." Capability data gates the Start button with a setup hint instead of a dead click.
- Quality floor: keyboard focus visible, Space/Esc shortcuts, reduced-motion respected, no layout shift when captions wrap.

### Tests

Fix the vitest environment first (Node's experimental `localStorage` shadows jsdom's — provide a functional localStorage in test setup so the 19 existing tests run again). Keep existing assertions passing (update text expectations where the UI legitimately changed). Add coverage: visual mode opens from TopBar/URL, greeting → idle flow with fake fetch, transcribe→chat→speak turn wiring, enrich swap renders sandboxed iframe, End session cleanup, History drawer renders global messages.

## Non-goals (this pass)

Wake words / always-listening; streaming sentence-level TTS; per-turn panel history navigation; iOS app voice; multi-user concurrency hardening.

## Verification runbook

```bash
scripts/orchestrator_v2_health.py                          # parakeet + kokoro checks green
python3 -m unittest discover -s tests -q                   # 553+ tests
cd frontend/orchestrator-v2 && npm test && npm run build
python3 dashboard.py                                        # then open http://localhost:9091/orchestrator-v2?view=voice
```

Manual pass: start session → greeting audio → ask "what sessions do I have running in cmux?" → captions stream → spoken answer (bm_daniel) → rich panel swaps in → barge-in mid-answer → follow-up window → history drawer → End session → toggle to dashboard and back.
