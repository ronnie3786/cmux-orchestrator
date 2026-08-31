# Agent Activity Bubbles — Investigation Findings & Follow-Up Options

**Date:** 2026-08-31 ~06:37 (local) / 11:37Z
**Trigger:** Ronnie added new tasks, expected agents tracked on the Active Work board, saw no activity bubbles.
**Verdict up front:** The bubble pipeline itself works end to end. Three separate linkage/data gaps blocked what Ronnie expected to see. One was fixed during the investigation (buzz sync abort bug — see Working-Tree State). The other two are open follow-ups and are the real blockers for the new task.

---

## 1. What the feature is (recap)

Working pi sessions on the Herdr Active Work board get a live 1–3 word comic-style hover bubble ("delegating", "Peeking around") derived from their real tool-call stream. Deployed 2026-08-31 to the work-Mac harness (launchd `com.ronnierocha.herdr-harness`, runs from the cmux-harness repo working tree).

**Pipeline:** pi pane → pi-semantic-bridge extension (per-pane unix socket) → harness journal (`~/.config/herdr-harness/pi-semantic.sqlite3`) → `AgentActivityManager` (`herdr_harness/agent_activity.py`: canned regex rules first, local Qwen 27B fallback, `agent_settled` trigger + 20s debounced `tool_execution_start`) → `update_session_activity` writes `pi_sessions.activity_message` / `activity_message_at` (schema v3) → `active_work.updated` SSE (`change: "activity"`) → board UI hover bubble with glow-on-change (Bangers font, hover-to-clear).

**Hard requirement for a bubble to appear:** a board `pi_sessions` row must exist whose `pane_id` matches a LOCAL pane that is emitting pi-semantic events. Missing either half = no bubble, silently.

## 2. What was verified working (do not re-investigate)

- **E2E proven 2026-08-31 ~09:53Z** with a throwaway pi pane (`w15:p1S`) + throwaway board item: `ls` turn → bubble `"Peeking around"` (model path, ~5s); subagent turn → `"delegating"` (canned path, zero model calls); `echo` turn → correctly no update (phrase-change gating); SSE `active_work.updated {change: "activity"}` observed for each real write.
- **Harness service healthy** (`/api/v1/health`: herdr connected, events connected). Real board DB migrated to schema v3 (`PRAGMA user_version` = 3 on `~/.config/herdr-harness/active-work.sqlite3`).
- **Every pi pane on this Mac is bridged** — all 28 live pi panes in the herdr snapshot appear in the pi-semantic state table (see §4 evidence). The bridge is injected by `herdr agent start --kind pi`. Bare `pi` launched outside herdr would NOT be bridged (durable `pi install` was never run — `~/.pi/agent/settings.json` has `extensions: []`) — secondary gap, not the current blocker.
- **Journal is receiving live events today** (2026-08-31): `wE:p4` (SSE Lab), `wF:p8` (Buzz "Tab 2" — the orchestrator session itself), `w1:p9` (26368 · Text Selection), `wK:p10`/`wK:p1Y`/`wK:p25` (MOA · Agent Manager) all emitted tool events.
- **Buzz sync regression-tested against the new schema** — ingestion contract unaffected by the activity columns.

## 3. Root causes found (why Ronnie saw no activity)

### 3.1 Buzz sync was aborting entirely, every 5 minutes, for ~6 hours — FIXED during investigation

- The launchd job `com.ronnierocha.herdr-active-work-sync` (runs `scripts/herdr_active_work_sync.py` every 300s from the cmux-harness repo) had `last exit code = 2` and its stdout log hadn't been written since 05:17 local.
- Cause: Ronnie's new ticket directory `~/Documents/Development/buzz-workflow/tickets/IDEA-native-bridge-text-selection/` fails the sync's `_require_ticket()` name validation (expects Jira-style `LETTERS-NUMBERS` keys). The raise inside `run_sync()`'s per-file loop propagated to `main()` and **aborted the whole run** — so NO ticket (not even valid Jira-keyed ones) got agents/pi_sessions ingested for ~6 hours. Board items had no session rows → no bubbles, even for panes that were actively working.
- Exact pre-fix code: `scripts/herdr_active_work_sync.py`, `run_sync()`, loop head: `directory_key = _require_ticket(state_path.parent.name, field="ticket directory")` raising `SyncError` → `main()` catches → prints `{"error": "invalid ticket directory: IDEA-NATIVE-BRIDGE-TEXT-SELECTION"}` → exit 2. The error log (`~/Library/Logs/herdr-active-work-sync.error.log`) shows this error repeating on every run.
- Post-fix sync output: `discovered: 9, tracked: 3, unchanged: 2, untracked: 6, failed: 1` — completes and ingests again. (The fix is described in §6; not elaborated here per Ronnie's request.)

### 3.2 The new task is IDEA-keyed — the sync can never target it

- New task: board item `work_e30d97a4cf27` ("Native text selection over custom TextRenderer (Native Bridge)"), stage `plan`, created via the raw-idea path with **no Jira link**.
- Buzz state: `~/Documents/Development/buzz-workflow/tickets/IDEA-native-bridge-text-selection/state.json` — `kind: "idea"`, `stage: "implementing"`, `status: "in-progress"`, `official_ticket: "Jura ticket to be created later (Ronnie)"`, `predecessor: "IOSDOX-26368"`, `active_work_id: "work_e30d97a4cf27"`.
- The sync resolves targets **by Jira key only** (`targets.get(directory_key)` from `herdr.sync_targets()`). Even with the abort fixed, this ticket counts as `untracked` and gets nothing ingested — no session rows, no agent roster, no bubbles. The state carries `active_work_id`, so target-by-work-item-id matching is feasible.
- Note: the buzz raw-idea path is explicitly "not built yet" (per the buzz-start-ticket skill); this dir was hand-rolled and its `workspace/tab/root_pane` fields (`wY` / `wZ:t1` / `wZ:p1`) are stale template leftovers from **Aug 19** — those panes/workspaces no longer exist in the local herdr snapshot.

### 3.3 The new task is `floor: "devbox"` — its agent's events never reach this Mac

- Its buzz agent `iOS-native-bridge` (`buzz_agent_state: "saved-active ..."`, updated 2026-08-31T11:50Z) runs **on the DevBox**, via the DevBox's own herdr.
- The pi-semantic bridge connects to a LOCAL unix socket (`HERDR_SOCKET_PATH`) and journals into the LOCAL harness DB. DevBox pi events land in the DevBox's journal — the work-Mac board never sees them. This was the documented Phase-1 limitation ("devbox-floor sessions get no bubbles"); it is now clearly the **primary gap for Ronnie's actual workflow**, since new buzz tickets default to the devbox floor.
- Consequence: even after fixing 3.2 (IDEA-key targeting), devbox-floor agents still cannot bubble on this Mac's board without a cross-machine activity path.

### 3.4 Pre-existing data issue: AGENTIC-472 tracks no Buzz channel

- Every sync run reports `failed: 1` / `ok: false` with error: `"AGENTIC-472: ticket state does not track a Buzz channel"`.
- Its state (`~/Documents/Development/buzz-workflow/tickets/AGENTIC-472/state.json`) lacks a `buzz_channel`. Ingestion for it fails every run, so its agents/sessions (the MOA panes, several of which were active today) never reach the board. This predates the activity-bubbles work.

## 4. Evidence snapshot (2026-08-31 ~11:30Z)

**Board active items (7 non-archived):**

| Item | Title | Stage | Sessions w/ pane? | Bubbles possible today? |
|---|---|---|---|---|
| `work_e30d97a4cf27` | Native text selection (IDEA, **devbox**) | plan | none | No — §3.2 + §3.3 |
| `work_cc8303ad235b` | Divider line after tapping… | pr-triage | none | No sessions ingested |
| `work_933c60c789a5` | Update iOS skills (IOSDOX-26700) | start-ticket | none | — |
| `work_26335467b1e9` | AGENTIC-575 Mobile API Impact Guard | pr | **yes: `w1G:p1`**, status unknown, idle since 08-26 | Yes — the moment that pane works |
| `work_e738f4633fc9` | AGENTIC-472 OpenCode MOA | pr-triage | none (channel missing, §3.4) | Yes after §3.4 fix |
| `work_5e9829d0534f` | IOSDOX-27458 Audit Ask/analytics | pr-triage | tracked, replayed | Yes when its panes work |
| `work_441590f33a59` | Merge ask-tab-navigation skill | pr-triage | none | — |

**Local panes emitting journal events today** (events after 09:00Z, all bridged): `wE:p4` (sse-lab pi), `wF:p8` (Buzz Tab 2 — orchestrator itself), `w1:p9` (26368 · Text Selection), `wK:p10`, `wK:p1Y`, `wK:p25` (MOA). **None of these are linked to a board pi_sessions row** — that's the visibility gap in one sentence: events exist, board rows don't.

**Key facts for a fresh session:**
- pi-semantic state table pane_ids are namespaced `sha256^<0x1f>pane_id` — the separator is `\x1f` (ASCII unit separator), NOT a printable string. (Cost me one wrong conclusion; don't repeat it.)
- Sync `untracked: 6` includes the IDEA dir (invalid name, now skipped) + valid-key dirs not set up in Herdr.
- The sync writes stdout to `~/Library/Logs/herdr-active-work-sync.log`, errors to `...error.log`; check `launchctl print gui/$(id -u)/com.ronnierocha.herdr-active-work-sync` for `last exit code` (0/1 = ran to completion, 1 = per-ticket data failure; 2 = hard abort — should no longer happen).

## 5. Current working-tree state (context, not fix documentation)

The cmux-harness repo working tree (branch `main`, **uncommitted, Ronnie has not reviewed**) contains:
- The full agent-activity-bubbles feature (Phases 1+2): `herdr_harness/agent_activity.py` (new), `active_work_store.py` (schema v3 + `update_session_activity`), `active_work.py`, `service.py`, `static/board.html`, `tests/test_agent_activity.py` (new), `tests/test_active_work_store.py`.
- The buzz-sync skip-invalid-directory change in `scripts/herdr_active_work_sync.py` + regression test `test_invalid_ticket_directory_is_skipped_and_sync_continues` in `tests/test_active_work_sync.py` (18/18 pass).
- `artifacts/agent-activity-bubbles/implementation-steps.md` (the original implementation contract).
- Full suite: 1080 passed, 1 pre-existing unrelated failure (`test_herdr_cmux_proxy_http.py` git-routes test).
- The harness launchd service runs FROM this working tree — fixes go live on service restart; the sync launchd job runs the script from this tree too (already live).
- Throwaway E2E artifacts were cleaned up (test item archived: `work_dac3fac13417`, `work_c4b867e3c4dc`; tab `w15:t7` closed).

## 6. Follow-up options (pick per option; estimates included)

### Option 1 — DevBox activity forwarding (the real fix for the new task) — ~1 day
Make devbox-floor agents' pi activity reach this Mac's board. First step is a read-only inspection of the DevBox harness setup (does the DevBox run the same cmux-harness stack? Does it have a pi-semantic journal? Which pi sessions run there and are they bridged?). Candidate designs (decide after inspection):
- (a) DevBox harness tails its own journal and POSTs activity summaries to the work-Mac ingestion API over Tailscale (small, privacy-safe — sends only the 1–3 word phrase + pane ref, never transcripts).
- (b) Work-Mac harness polls the DevBox journal over Tailscale SSH.
- Privacy rule to preserve: only structured ~100-token tool events / final phrases cross the wire — never message bodies (the bridge's no-transcript guarantee).

### Option 2 — IDEA-key sync targeting — ~2 hours
Extend `run_sync()` target resolution: when the directory name fails `_require_ticket`, fall back to matching by the state's `active_work_id` (selector already supports `work_item_id` in the store's ingestion). Gets the new task's stage/agent/session structure onto the board. Caveats: its state's `workspace/tab/root_pane` are stale Aug-19 leftovers and must be refreshed to the real devbox panes (or omitted for devbox floor) before session rows are meaningful; and without Option 1, devbox sessions still won't bubble — this only fixes board structure.

### Option 3 — AGENTIC-472 buzz channel data fix — ~30 min
Repair its state.json buzz channel (or re-link via the buzz CLI) so ingestion stops failing; its MOA agents then sync and bubble locally when active.

### Secondary (noted, not urgent)
- Durable-install the bridge (`pi install ~/Documents/Development/cmux-harness/pi-semantic-bridge`) so bare `pi` sessions outside herdr also journal — today only `herdr agent start` sessions are bridged.
- The sync's missing-buzz-channel failure could arguably be skip-and-warn like invalid dirs — judgment call, keep failing-loud for now.

## 7. Open questions for Ronnie

1. Which option(s) to green-light (1 is the only one that makes the new task actually bubble).
2. For Option 1: is the DevBox running the same harness stack, and is a Tailscale-only path acceptable? (Inspection will confirm.)
3. Should the new task get a real Jira key eventually (`official_ticket: "Jura ticket to be created later"`), which would obsolete part of Option 2?
4. AGENTIC-472: fix the channel data (Option 3) or leave failing-loud?

## 8. Key paths & commands (fresh-session quick reference)

```
# Harness health / board
TOKEN=$(cat ~/.config/herdr-harness/api-token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9092/api/v1/health
~/.local/bin/herdr-active-work list|show <work_id>     # actor: agent:board-sync

# DBs (read-only while service runs; use ?mode=ro URI or sqlite3 CLI)
~/.config/herdr-harness/pi-semantic.sqlite3            # tables: pi_semantic_events, pi_semantic_state
~/.config/herdr-harness/active-work.sqlite3            # board DB (schema v3)

# Journal queries
sqlite3 ~/.config/herdr-harness/pi-semantic.sqlite3 \
  "SELECT datetime(generated_at), pane_id, event_type, count(*) FROM pi_semantic_events
   WHERE generated_at > '2026-08-31T09:00:00' GROUP BY pane_id, event_type"
# state table pane_id separator is \x1f

# Sync (run manually exactly like launchd; BUZZ_PRIVATE_KEY collides if exported in shell)
env -u BUZZ_PRIVATE_KEY /opt/homebrew/bin/python3 \
  ~/Documents/Development/cmux-harness/scripts/herdr_active_work_sync.py \
  --workflow-root ~/Documents/Development/buzz-workflow \
  --base-url http://127.0.0.1:9092 \
  --buzz-cli ~/.local/bin/buzz \
  --token-file ~/.config/herdr-harness/active-work-ingest-token \
  --buzz-private-key-file ~/.config/buzz/private-key

# Service management
launchctl kickstart -k gui/$(id -u)/com.ronnierocha.herdr-harness            # restart harness
launchctl kickstart -k gui/$(id -u)/com.ronnierocha.herdr-active-work-sync   # kick sync now
tail -f ~/Library/Logs/herdr-active-work-sync.log ~/Library/Logs/herdr-active-work-sync.error.log

# Feature code
~/Documents/Development/cmux-harness/herdr_harness/agent_activity.py
~/Documents/Development/cmux-harness/scripts/herdr_active_work_sync.py
~/Documents/Development/cmux-harness/artifacts/agent-activity-bubbles/       # this doc + implementation-steps.md

# Env knobs (harness service)
HERDR_HARNESS_ACTIVITY_MODEL_URL   # empty = canned-only; set = http://100.120.49.92:8012/v1
HERDR_HARNESS_ACTIVITY_MODEL_NAME  # qwen3.8-27b-bf16
HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS  # default 20, clamp 2–300

# Tracker records (TASK-API board)
herdr-phase-1-agent-micro-status…  # completed; incident note added 2026-08-31
herdr-phase-2-debounced-per-tool-call…  # completed
herdr-phase-3-deferred-first-line-defense…  # low priority, deferred
```

**New-task buzz state:** `~/Documents/Development/buzz-workflow/tickets/IDEA-native-bridge-text-selection/` (state.json + investigation.md, planner/architect briefs, decisions.html/json, handoff.md, implementation-steps.md — the ticket has its own plan artifacts ready for implementation work).
