# DevBox Activity Forwarding — Implementation Plan

**Status: IMPLEMENTED + E2E-PROVEN 2026-08-31 ~12:45Z** (throwaway DevBox pi pane `wR:p5` → live bubble `"Peeking in trash"` on a throwaway board item; both cleaned up).

**Findings context:** `2026-08-31-0637-activity-bubbles-investigation-findings.md` (Option 1 + Option 2 combined; no DevBox changes required).

**Date:** 2026-08-31 ~13:00 local
**Goal:** devbox-floor buzz agents (e.g. `IDEA-native-bridge-text-selection`, agent `iOS-native-bridge`) get live activity bubbles on the work-Mac Active Work board.
**Findings context:** `2026-08-31-0637-activity-bubbles-investigation-findings.md` §3.2 + §3.3 (Option 1 + Option 2 combined).

## Inspection results (read-only, 2026-08-31)

- DevBox runs the same cmux-harness stack from `~/Documents/Development/cmux-harness` (older commit, tmux-launched, port 9092, Tailscale HTTPS on :8461). It does NOT have the activity-bubbles code — and does not need it.
- DevBox pi-semantic journal is live (108,900 events; pane `wZ:p2` emitting today). The buzz IDEA state's "stale" pane refs are real DevBox panes: workspace `wZ` = "NB · Native Bridge Text Selection", pi agent at `wZ:p2` (agent_status done between chunks). `root_pane: wZ:p1` in the state points at a non-pi shell pane — stale/wrong for bubbles.
- The DevBox harness exposes `GET /api/v1/panes/{paneId}/pi/events` (SSE, cursor-based, `Last-Event-ID` resume, heartbeat every 15s, reset events for backend restarts) — verified reachable from the work Mac over Tailscale with the DevBox harness API token.
- Work-Mac board store already has `update_session_activity(pane_id, ...)` matching any non-ended `pi_sessions` row by `pane_id`; the ingestion selector supports `work_item_id` / `buzz_channel_id`; the IDEA state carries `active_work_id` + `buzz_channel`.
- Floors in buzz states: 6× `devbox`, 2× `local`.

## Design (chosen: work-Mac polls DevBox over Tailscale)

Poll, don't push — the work-Mac harness gains a `RemoteActivityPoller` that tails the
DevBox harness's existing SSE endpoint. Zero DevBox changes (its harness is an older
commit we don't want to redeploy), no new push API, no new DevBox launchd job.

- One long-lived SSE connection per relevant pane (`?after=<cursor>` + `Last-Event-ID` on reconnect). Server heartbeats every 15s; reconnect on error resumes from the last seen cursor. First connect adopts `latest_cursor` (bubbles are live-only; no history replay storms).
- Only panes with an ACTIVE board session row whose `pane_id` starts with `<prefix>:` are polled (today: just `wZ:p2` → `devbox:wZ:p2`). No board row → no model calls, no junk phrases.
- Forwarded envelopes get `pane_id = "<prefix>:<pane_id>"` and feed `AgentActivityManager.handle_event` directly (in-process) — phrase computation, debounce, canned rules, Qwen fallback, `active_work.updated` SSE are all reused unchanged.
- Privacy: only structured tool-event envelopes cross the tailnet (the journal already caps payloads and strips transcripts); the poller runs on the work Mac holding a private token file.

## Changes

1. `herdr_harness/remote_activity.py` (new): `RemoteActivityPoller` — reconciler + per-pane SSE readers, injectable opener for tests.
   - Env: `HERDR_HARNESS_REMOTE_ACTIVITY_URL` (empty = disabled), `HERDR_HARNESS_REMOTE_ACTIVITY_TOKEN_FILE`, `HERDR_HARNESS_REMOTE_ACTIVITY_PREFIX` (default `devbox`), `HERDR_HARNESS_REMOTE_ACTIVITY_POLL_SECONDS` (default 5, clamp 1–120).
2. `herdr_harness/service.py`: construct + start/stop the poller alongside `agent_activity`; relevance = active board pane ids from the store.
3. `herdr_harness/active_work_store.py`: `active_pane_ids()` read helper (non-ended sessions).
4. `scripts/herdr_active_work_sync.py`:
   - `REMOTE_FLOORS = frozenset({"devbox"})`; `pi_sessions.pane_id` becomes `"<floor>:<pane>"` for remote floors (collision-proof vs local panes; `wF` exists on both machines).
   - Invalid-directory tickets fall back to targeting by the state's `active_work_id` (raw sync-target rows, one GET); selector omits `jira_key` for non-Jira keys (store would 409 on unresolvable jira selector); equality check skipped for IDEA dirs; `SyncTarget.ticket_key` = directory name for identity/idempotency.
   - `HerdrClient.sync_targets()` returns the raw response; `run_sync` parses once.
5. `~/.config/herdr-harness/launch-herdr-harness.sh`: add `HERDR_HARNESS_REMOTE_ACTIVITY_URL` + validated token-file export (same pattern as the ingest token).
6. `~/Documents/Development/buzz-workflow/tickets/IDEA-native-bridge-text-selection/state.json`: refresh runtime fields → `workspace: wZ`, `tab: wZ:t1`, `root_pane: wZ:p2` (the real DevBox pi pane).
7. Tests: sync IDEA targeting (target-by-work-item, selector shape, pane prefix), poller (envelope prefixing, cursor adoption/resume, relevance filtering, error backoff), store helper.

## Non-goals / left open

- AGENTIC-472 missing buzz channel (§3.4): stays failing-loud pending Ronnie's call (Option 3).
- Durable `pi install` of the bridge for bare `pi` sessions (secondary note).
- Session lifecycle for devbox panes: bubbles only; session status transitions stay as-ingested (running on first activity).

## Implementation notes (what actually shipped)

- `herdr_harness/remote_activity.py`: `RemoteActivityPoller` — per-relevant-pane SSE reader thread over the remote harness `/api/v1/panes/{id}/pi/events` (Last-Event-ID resume), cursor adoption from `pi/snapshot` on first watch, transport events (`ready`/`stream.reset`) skipped, reconcile loop every 5s follows the board's active session rows. Startup + reader attach/detach + throttled errors land on stderr.
- Service wiring: poller constructed + started/stopped alongside `AgentActivityManager`; disabled unless `HERDR_HARNESS_REMOTE_ACTIVITY_URL` is set.
- Launch script `~/.config/herdr-harness/launch-herdr-harness.sh` now exports the remote URL + validated token file (`devbox-activity-token`, the DevBox harness API token, 0600).
- During bring-up the poller surfaced three bugs, all fixed and covered by tests: missing `_reconcile_loop` (thread target raised inside `start()` and the service swallowed it — the start-path test now covers this), the error-lock attribute mismatch, and short-read JSON parsing of the snapshot endpoint.
- E2E proof (2026-08-31 ~12:42Z): scratch pi pane `wR:p5` on the DevBox, prompted via `pane send-text` + `return` → tool events reached the work-Mac board → session `devbox:wR:p5` bubbled `"Peeking in trash"` (status running, revision bump + SSE observed). Scratch item archived, DevBox tab closed, scratch files trashed.
- Full suite: 1103 tests, 1 pre-existing unrelated failure (`test_herdr_cmux_proxy_http` git-routes test, pre-existing).
- Everything remains uncommitted in the cmux-harness working tree for Ronnie's review.

## UI follow-up (2026-08-31 ~13:15Z): activity bubble readability

Ronnie reported the agent activity bubbles were unreadable — "clear background". Verified in a live browser: the bubble pill used `background: var(--overlay)` (#181818) on the near-black board canvas/card, so the pill blended into the surface and the 10px Bangers text floated ghost-like.

Fix in `board.html` (dark + light variants):
- `.act-bubble`: solid lifted background (`#2d2d2d` dark / `#fffdf8` light), brighter border, stronger outer shadow ring, padding up 1px→3px 8px, font 10→11px, z-index 6→20 so it never slips under neighbor cards.
- `.act-time` timestamp bumped `--faint` → `--dim` for readability.
- Verified via browser screenshots in both themes; bubble text now clearly legible on hover.
