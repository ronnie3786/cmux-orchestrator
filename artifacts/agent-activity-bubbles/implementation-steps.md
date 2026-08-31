# Agent Activity Bubbles — implementation steps

Feature: working agents (pi sessions) on the Active Work board show a live 1–3 word
comic-style hover bubble ("delegating", "scanning code", "running tests") generated
from their real tool-call stream, with glow-on-change (Phase 2).

Repo: ~/Documents/Development/cmux-harness (work on `main`, stdlib-only Python —
no new dependencies, no requests/httpx: use urllib).

## Architecture (agreed — do not redesign)

Data already flows: the pi-semantic-bridge extension streams per-pane Pi events
(`tool_execution_start/end` with toolName+args, `agent_settled`, `session_start`,
…) over a Unix socket into `PiSemanticManager` (`herdr_harness/pi_semantic.py`),
which journals them and fires the service's `on_event` callback per event.
The board already maps pi sessions to work-item stages (`pi_sessions` table,
ingested by buzz sync with `pane_id` from the ticket runtime) and live-reloads on
the `active_work.updated` SSE event (`queueBoardReload()` in board.html).

New pieces:
1. `pi_sessions` gains `activity_message` + `activity_message_at` columns
   (schema v3 migration) and a direct write path used in-process by the harness.
2. New `herdr_harness/agent_activity.py`: `AgentActivityManager` — consumes pi
   event envelopes, keeps a tiny per-pane ring of recent tool events, produces a
   micro-summary via (a) deterministic canned rules first, (b) a fast local model
   call only when no rule matches, then writes the session row and publishes
   `active_work.updated`.
3. `static/board.html`: hover bubble on run/session chips.

Key existing anchors (line numbers approximate, re-verify):
- `herdr_harness/active_work_store.py`: SCHEMA_V1 pi_sessions CREATE (~171),
  `_migrate_locked` (~453, version 2 → add version 3), CURRENT_SCHEMA_VERSION in
  `active_work.py`, `_upsert_stage_session_locked` (~2196, allowed fields +
  upsert), `_session_from_row` (~3069), item revision/audit pattern in
  `_ingest_activity_locked` (~2473).
- `herdr_harness/service.py`: `__init__` constructs `pi_semantic` with
  `on_event=self._publish_pi_event` (~135) and `active_work` (~145);
  `start()`/`stop()` manage threads (~267-320); `_publish_active_work_updated`
  (~1271) is the SSE envelope shape to reuse.
- `herdr_harness/pi_semantic.py`: journal envelope shape in `ingest` /
  `_append_event_locked` (~345/528); manager fires on_event per journaled event
  in `_watch` (~1029-1032).
- `herdr_harness/static/board.html`: `adaptBoard` (~2550, sessions spread with
  `...session` so new fields flow automatically), run card head (~3548), stage
  session rows (~3009, ~3720), SSE handler `queueBoardReload` (~2645).

Event envelope: `{kind: "event", pane_id, event: {type, ...}}` — types include
`tool_call`, `tool_result`, `tool_execution_start`, `tool_execution_update`,
`tool_execution_end`, `input`, `agent_settled`, `session_start`,
`session_shutdown`, `bridge.connection`.

## Privacy rules (hard constraints)

- Never read or include transcript message bodies, file contents, or user prompt
  text in anything sent to the model. Only: tool names, and at most a 100-char
  gist of a `bash` command string or the agent name for `subagent`. Prompt must
  stay under ~2 KB.
- Never write secrets/credentials; the model endpoint is the local tailnet vLLM.
- The store "owns only durable coordination metadata" — the message is 1–3 words.

## Chunk 1 — store: schema v3 + activity write path

Files: `herdr_harness/active_work_store.py`, `herdr_harness/active_work.py`,
`tests/test_active_work_store.py`.

1. SCHEMA_V1: add to pi_sessions CREATE TABLE:
   `activity_message TEXT NOT NULL DEFAULT ''` and `activity_message_at TEXT`.
2. `CURRENT_SCHEMA_VERSION` → 3. In `_migrate_locked`, add version 2→3 step:
   two `ALTER TABLE pi_sessions ADD COLUMN ...` statements + migration-table row
   + `PRAGMA user_version=3`, same BEGIN IMMEDIATE/COMMIT pattern as v1→v2.
3. `_upsert_stage_session_locked`: accept optional `activity_message`
   (text, max 80) and `activity_message_at` (timestamp) in the session body's
   allowed fields; when present, persist; when absent, keep existing (the upsert
   must NOT wipe them — follow the `session_text` field-in-body pattern).
4. `_session_from_row`: project both new fields.
5. New public repository method:
   `update_session_activity(pane_id, *, activity_message, activity_message_at=None, status=None, last_seen_at=None, actor="agent:activity")`
   - Find the newest pi_sessions row with that pane_id and status NOT IN
     ('ended','failed','completed') (ORDER BY COALESCE(last_seen_at, created_at)
     DESC). None → return None.
   - Update activity_message/activity_message_at (+ optional status/last_seen_at)
     ONLY if something actually changed; bump the owning work item's revision and
     write an audit row (reuse the existing ingest audit/revision pattern).
   - Return the item projection (same shape other store methods return) so the
     caller can publish SSE.
6. Tests (`/usr/bin/python3 -m pytest tests/test_active_work_store.py -q`):
   fresh DB has the columns; ingestion upsert with/without the fields preserves
   them; `update_session_activity` updates the right session by pane_id (picks
   newest, skips ended), bumps revision, no-op returns unchanged; migration
   v2→v3 (create a DB at v2 by executing the v1+v2 statements minus new columns,
   reopen, verify columns exist and data survived).

## Chunk 2 — summarizer: agent_activity.py + service wiring

Files: new `herdr_harness/agent_activity.py`, `herdr_harness/service.py`, new
`tests/test_agent_activity.py` (+ extend `tests/test_herdr_service.py` only if a
wiring test fits its existing pattern).

1. `AgentActivityManager(active_work, broker, environ, ...)`:
   - `handle_event(envelope)` — cheap, never blocks, never raises: parse
     pane_id/event; on `tool_call`/`tool_execution_start` append to a bounded
     in-memory per-pane ring (max 48 entries, entry = tool name + gist);
     on `agent_settled` schedule a summarization for that pane (Phase 1 trigger
     = agent_settled ONLY). Internal queue + one daemon worker thread, started
     by `start()`, stopped by `stop()` (follow service.py thread patterns).
   - Summarize(pane): (a) canned rules over the ring, newest-first, e.g.
     subagent → "delegating"; git commit → "committing"; git push → "pushing";
     gh pr/review → "reviewing"; test/pytest/xcodebuild → "running tests";
     ≥60% read/grep/find → "scanning code"; mostly write/edit → "editing code";
     web/browse → "browsing". (b) If no rule matches and the model is enabled,
     call the model. (c) Model failure/timeout/garbage → skip the write unless
     the session has no message yet (then "working").
   - Only write when the phrase CHANGED (no-op otherwise; keeps noise at zero).
   - Model call: urllib POST `{url}/chat/completions`, JSON
     {model, messages:[{role:"user", content: prompt}], max_tokens: 24,
      temperature: 0, chat_template_kwargs: {"enable_thinking": false}};
     timeout 4s. Env: `HERDR_HARNESS_ACTIVITY_MODEL_URL` (default
     `http://100.120.49.92:8012/v1`, empty string = canned-only mode) and
     `HERDR_HARNESS_ACTIVITY_MODEL_NAME` (default `qwen3.8-27b-bf16`). Prompt
     built ONLY from tool names + gists, ≤2 KB, asking for 1–3 comic-style words
     describing what the agent is doing, output words only.
   - Sanitize model output: strip, single line, ≤40 chars, ≤3 words; else treat
     as failure.
   - Write path: `active_work.update_session_activity(pane_id, activity_message=…,
     activity_message_at=now, status="running" if current in (unknown, queued),
     last_seen_at=now)` → if it returns an item, `broker.publish(
     "active_work.updated", {work_item_id, revision, change: "activity",
     generated_at})` — same envelope shape as `_publish_active_work_updated`.
   - All errors logged-and-swallowed (a broken bubble must never hurt the
     harness). No logging framework — silent degrade is fine for v1.
2. service.py wiring: construct the manager in `__init__` after `active_work`;
   change pi_semantic's on_event to a dispatcher that calls BOTH
   `_publish_pi_event(envelope)` and `self.agent_activity.handle_event(envelope)`;
   `start()`/`stop()` start/stop the manager (guard exceptions the same way
   pi_semantic start is guarded).
3. Tests: unit tests with a fake repository (records calls) + fake in-process
   HTTP server (http.server on an ephemeral port) for model success/garbage/
     timeout; assert canned rules, agent_settled-only triggering (tool events
     alone produce no writes in Phase 1), phrase-change gating, sanitized output,
     no-crash on malformed envelopes, canned-only mode when URL empty.

## Chunk 3 — board UI (Phase 1 look)

Files: `herdr_harness/static/board.html`.

1. Sessions already carry the new fields via `adaptBoard`'s `...session` spread.
2. Hover bubble on every rendered pi-session chip: run cards (`run-head` ~3548)
   and stage session rows (~3009, ~3720). Show only when `activity_message` is
   non-empty. Bubble = small comic-style tooltip (Phase 1 font stack:
   `"Comic Sans MS","Chalkboard SE","Marker Felt",cursive`, uppercase, 1–3
   words) + relative time from `activity_message_at` using existing `t-ago`
   helpers/patterns. Reuse the existing overlay/tooltip patterns in the file —
   do not invent a new positioning system.
3. Keep it hover-only (no layout shift, no extra API calls).

## Chunk 4 — Phase 2: live updates, glow, bundled font

Files: `herdr_harness/agent_activity.py`, `static/board.html`, tests.

1. Manager: also evaluate on `tool_execution_start`, with a per-pane debounce
   (`HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS`, default 20) — a write only when
   the phrase changed AND the debounce window elapsed (agent_settled always
   bypasses the debounce).
2. UI glow: when `activity_message_at` is newer than the locally acknowledged
   timestamp (localStorage map keyed by session id), the chip gets a glow
   animation; hover/click acknowledges (stores the seen timestamp) and stops the
   glow.
3. Bundle an OFL comic font (Bangers or Comic Neue woff2) under a static assets
   dir the board already serves from; `@font-face` + fallback to the Phase 1
   stack. Keep the file small (<100 KB).
4. Tests: debounce unit tests (phrase-change + window gating, agent_settled
   bypass); a light check that board.html references the bundled font.

## Global rules

- Follow existing code style exactly (stdlib only, type hints like the
  surrounding code, minimal comments — the repo is deliberately low-comment).
- No unrelated refactors, no renames, no formatting sweeps.
- Run the touched test files with `/usr/bin/python3 -m pytest <files> -q` and
  the full suite `/usr/bin/python3 -m pytest tests -q` before reporting done.
- If an anchor line number drifted, find the real one; if a step is impossible,
  STOP and report instead of improvising.
- Report format: files changed, decisions/deviations, validation (commands +
  results), residual risks.
