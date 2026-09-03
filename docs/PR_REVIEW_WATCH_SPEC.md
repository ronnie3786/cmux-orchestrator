# PR Review Watch — Spec

Ronnie's voice-note idea (2026-05-24, "4210 Valley Pike St 23.m4a"), built as a
Herdr Active Work workflow. Buzz is bypassed entirely — the Active Work board
IS the review queue, and everything runs with pi sessions.

## What it is

A 30-second watcher polls Ronnie's iOS PR review queue (`review-requested:@me`
on `doximity/iOS-Doximity`, direct + team). Every NEW request lands on the
Active Work board under the **PR Review Watch** workflow with an AI assessment
(rating, CR-time estimate, one-sentence summary) waiting in the Queue section.
From there, one decision — pick a review path — moves the PR through review
stages with a pi session attached, and artifacts collect in the Outputs
section.

## The workflow (applied: `pr-review-watch` v1)

Three board regions (phases), seven stages:

```
QUEUE                REVIEW                              OUTPUTS
┌──────────┐   ┌──> manual-review ──────┐          ┌───────────────┐
│ queued * │───┼──> ios-review ─────────┼────────> │ complete      │
└──────────┘   ├──> explainer-video ────┤          └───────────────┘
   (assess)     ├──> comprehensive-review┤            (artifacts)
               └──> custom-review ───────┘
```

- `queued` — **human gate**. The watcher creates items here with the
  assessment; every queued PR surfaces in the board's **needs-you** badge.
  Its five forward branches ARE the CTA options.
- Review stages carry the real skill kickers:
  `ios-review-remote-pr` · `github-pr-explainer-video-v2` ·
  `comprehensive-pr-review` (the three pre-baked options Ronnie replies
  A/B/C to in Buzz today), plus `manual-review` (Ronnie reviews himself)
  and `custom-review` (free-text prompt, passed verbatim).
- `complete` — terminal. Review artifacts attach here as stage documents
  (`attach-doc`) with tailnet URLs the board's Open action launches.

## Phase 1 — shipped and running (this change)

| Piece | File | Role |
|---|---|---|
| Workflow config | `herdr_harness/workflows/pr-review-watch.json` | Board regions, stages, branches, gate — applied at harness startup + now via CLI |
| Watcher | `scripts/herdr_pr_review_watch.py` | 30s loop: gh queue check → dedupe vs board IDs → enrich (review-scope ±, direct/team, Jira link) → create item → headless-pi assessment → stage/item summary |
| Assessor agent | `~/.pi/agent/agents/pr-review-assessor.md` | Headless pi (`--no-session`) following `buzz-check-pr-reviews-ios` §2–§3; answers one `ASSESSMENT_JSON:` line |
| LaunchAgent | `scripts/com.ronnierocha.herdr-pr-review-watch.plist` | `--loop 30`, KeepAlive, background priority |
| Tests | `tests/test_pr_review_watch.py` | Pure-logic coverage: classification, review-scope exclusions, assessment parsing, dedupe, pass flow |

Design decisions worth knowing:

- **Dedupe = the board itself.** Items get stable IDs
  (`pr-watch-doximity-ios-doximity-<N>`); one `list` call per pass is the
  whole dedupe state. No separate alerted.json.
- **Deterministic first, AI second.** The item appears within seconds of
  discovery with a deterministic summary (author, ± counts, direct/team).
  The assessment patches summary + `queued` stage content when the headless
  pi run finishes; any failure keeps the deterministic line. Errors are
  never treated as an empty queue.
- **Metadata follows the board's convention** (`metadata.pr.number`,
  `metadata.done_label`) so existing board rendering (e.g. the terminal
  "reviewed · complete" action label) lights up.
- The watcher writes only through the supported `herdr-active-work` CLI
  (`agent:pr-review-watch` actor). It never posts to Buzz, never touches
  Jira, never copies transcripts.

## Phase 2 — CTAs + session attach (the Mac app part)

Today the gate capsule approves to `next[0]` only (manual-review). What the
voice note actually wants:

1. **Review-chooser overlay** in `board.html` — clicking a queued item's
   action opens the multiple-choice menu (Manual / iOS Review / Explainer
   Video / Comprehensive / Custom) plus a free-text box for the custom path.
   The board's overlay machinery + `mutateLive` transitions already exist;
   this replaces the single-target `applyApprove` for this workflow.
2. **Spawn on choose** — the chosen transition ALSO starts a dedicated pi
   session with exactly the PR link + the stage's skill (+ the custom text
   verbatim when chosen). No other context — if the skill needs more, the
   skill gets updated (that's the point). The board webview can't spawn
   terminals (manage token has no terminal scope), so the chooser posts a
   new `WKScriptMessage` (e.g. `spawnReview`) through the existing
   `ActiveWorkBoardMessage` bridge and the Mac app — which holds pairing
   credentials — creates the workspace/tab/pane via `pi-session-spawn`
   semantics (workspace `PR Reviews`, tab per PR, pane == chat).
3. **Session attach** — after spawn, observe the native pi session onto the
   item's review stage (stable source `pr-review-watch`, idempotency key
   from PR + stage) so it renders as the stage's session avatar and Ronnie
   can jump into it from the board at any point.
4. **Completion protocol** — the three review skills get a small Herdr
   section (or one shared runner skill) so a session spawned with just a
   link knows to: attach its artifacts to `complete` via `attach-doc`
   (HTML reports, videos — tailnet URLs), move the item to `complete`,
   and mark it `done`. Artifacts then sit in the Outputs region with Open
   actions.

## Ops

```bash
# status
tail -20 ~/.local/state/herdr-pr-review-watch/runs.log
herdr-active-work list            # pr-watch-* items
herdr-active-work workflow-show pr-review-watch

# manual single pass (no daemon)
python3 scripts/herdr_pr_review_watch.py --once

# without the AI assessment
python3 scripts/herdr_pr_review_watch.py --once --no-assess

# LaunchAgent
launchctl kickstart -k gui/$(id -u)/com.ronnierocha.herdr-pr-review-watch
tail -f ~/Library/Logs/herdr-pr-review-watch.log
```

Boundaries: repo is hardcoded to `doximity/iOS-Doximity` (same as the Buzz
scout). Drafts are queued but flagged. Interval floor is 10s. The watcher
never archives or moves items on its own — lifecycle decisions stay with
Ronnie (and, in phase 2, the runner sessions).
