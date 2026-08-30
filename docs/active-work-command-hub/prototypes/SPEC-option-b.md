# Option B — "Run Ledger" (agenttrail run-card DNA in the journey feed)

File: option-b-run-ledger.html · <title>Herdr Run Ledger</title>
Thesis: keep the vertical feed Ronnie already scans, but rebuild each journey
as a live *run strip* whose signature is the **cast ledger** — an agents × stages
attachment grid that answers "who was where, when" at a glance. agenttrail's
liveness (streaming tool line, declared-vs-observed, recency fades) rides along.

## Layout

Standard Herdr chrome. Content column `min(1180px, 100% - 36px)`.

1. **Board head** — h1 "Active work", subtitle "Every journey, its cast, and
   what each stage produced." Right: ↻ Refresh · ⌁ Ask board.
2. **Needs-you dock** (the one loud thing): for each needs_attention item a
   flight-strip banner — 4px --alert left spine, KEY + attention_reason,
   ONE primary action button ("Review event map" / "Decide on PR #510"),
   and a quiet "jump to strip ↓" link that scrolls + flashes the strip.
   Everything else on the page stays calm.
3. **Summary strip** — 4 metrics in one --graphite card with hairline dividers:
   work items 4 · agent attachments 14 · live pi sessions 1 · need you 2
   (last in --alert). tabular-nums.
4. **The strips** — `display:grid; gap:14px`. Each pipeline item is a
   `.run-strip` card (radius 18, rgba(30,30,46,.78), hairline border; 4px
   status spine on the left edge; reveal animation staggered 80ms):

   **Header row** (grid `1fr auto auto`): kind pill + skill pill · KEY · Title
   (15px 700) · mono meta `floor · pane · updated <t-ago>` · agent stack
   (overlapping 28px marks, working dots breathing) · status pill · elapsed-in-
   stage `⏱ 1h 17m` (tabular, ticking each second for the active item).

   **Trail spine**: full-width 8-stop line — 3px track (--surface); filled
   portion --signal; the segment into the current stop = accent marching ants
   (dasharray 5 8, travel keyframes); stops = 9px circles (done filled signal
   w/ check at hover, current = 15px accent ring + halo, needs-you = alert),
   checkpoints = rotated squares (gates) colored by checkpoint_state
   (approved filled signal · pending pulsing alert stroke · future hollow).
   Stage titles under stops, mono 8px; current stop's title in --text.

   **Cast ledger** (THE signature; sits in an inset panel rgba(17,17,27,.7)
   radius 14): CSS grid `160px repeat(8, 1fr)`. Header row = stage numbers
   (mono, current column tinted rgba(137,180,250,.1) full-height, needs-you
   column rgba(243,139,168,.08)). One row per agent that has any stage_link:
   left cell = 18px mark + name (11px 600) + link_role (mono 9 muted).
   Body cells: an attachment bar (6px tall, radius 3) spanning the stages the
   agent was/is attached to — per-cell state: done = --signal at .45 alpha;
   active = --accent with `rail-live` shimmer; queued = dashed outline --muted;
   waiting-on-human = --alert. Empty cells: faint 3px center dot. Hovering a
   bar shows a title tooltip `attached 12:27 → now · coder`.
   Under the active agent's row, an **observed line** (mono 10, accent):
   `Editing · api/impact_guard.py ×3 · <t-ago>` — agenttrail's declared-vs-
   observed channel; it lights only while simulated activity < 60s old.

   **Stage dossiers**: every ledger column header is a button (aria-expanded).
   Clicking opens ONE dossier accordion below the ledger (grid-rows 0fr→1fr,
   250ms) for that stage: three mini-columns —
   `threads` → each Buzz thread (# title · status dot · **Open in Buzz**),
   `pi sessions` → (title · model · tokens · **Open pane wX:tN**),
   `record` → checkpoint state, started/completed times, continuity docs,
   activity lines with t-ago stamps. Empty stage → honest empty line
   ("Nothing attached at Proof yet — Proof runner joins after Agent review.").
   Open buttons fire toasts. The active stage's dossier is pre-opened on the
   first strip at load.

   **Footer row** (hairline-top, mono 10): next_action sentence (--mist) ·
   right side: streaming tool line for a running session
   (`<span class=tn>Edit</span> <span class=td>…</span> <span class=ta>3s</span>`)
   or "idle — waiting for you" (--muted) on needs-you strips.

5. **Idea strip** — IDEA-07 as a compact dashed-mauve capsule (no ledger):
   kind pill "Idea" · title · "Explore first. No worktree until a prototype
   decision is approved." · Buzz driver chip + `shaping` pill.

## Recency & motion

- Ended/done attribution fades: done bars, ended session rows, resolved thread
  rows at opacity .55; the strip whose item updated most recently carries a
  subtle 1px accent glow that decays (class flip at 60s window).
- Two-speed motion; working-pulse 1.6s; reveal (rise 16px + blur 4px→0) on
  load with 80ms stagger; capsule-pop on done badges when a dossier opens.
- Simulator (SPEC-shared): appends to AGENTIC-575 implement dossier's activity
  list live (new line slides in), updates footer tool line + elapsed + t-ago
  spans (1s patcher; no full re-render).
- Keyboard: strips and column headers tabbable; ← → move between stage
  columns of the focused strip (roving tabindex), Enter toggles dossier.
