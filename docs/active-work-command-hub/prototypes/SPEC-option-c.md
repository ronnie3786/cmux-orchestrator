# Option C — "Journey Refit" (polish the shipped Journey rows + Focus route)

File: option-c-journey-refit.html · <title>Herdr Journey Refit</title>
Thesis: same information architecture Ronnie already shipped in SwiftUI —
Journey rows and Focus route — but visually rebuilt: a metro-line rail with
station popovers (the per-stage associations today's UI hides), calmer cards,
one obvious priority, and Focus route grown into a real dossier. This is the
"minimum migration, maximum polish" option: everything maps 1:1 onto the
existing ActiveWorkBoardView / ActiveWorkFocusRouteView.

## Layout

Standard Herdr chrome. The center segmented control switches TWO views on this
page: **Journey rows ⇄ Focus route** (real toggle, state preserved).

### View 1 — Journey rows (refit)

Content column `min(1120px, 100% - 36px)`.

1. Board head (h1 30px rounded 750) + subtitle + ↻ Refresh · ⌁ Ask board.
2. **Priority line** replaces the flat 3-metric card: left = the single most
   urgent thing as a sentence with an action —
   "✋ IOSDOX-27458 is waiting on your Proof approval · **Review event map**" —
   right = quiet mono tallies `4 items · 14 attachments · 1 live session`.
   A second pending item shows as a small chip after the sentence.
3. **Journey cards**, one per item, radius 18 — decluttered vs today:
   - Header: kind pill only (skill moves into the rail tooltip), KEY · Title,
     mono meta line, 30px agent stack (breathing dots), status pill.
   - **Metro rail** (replaces the boxy stage nodes; inset panel
     rgba(17,17,27,.7) radius 14): a continuous 3px line; on load the filled
     portion animates from 0 to the current station (600ms ease-out, once).
     Stations: done = 10px filled --signal circle (✓ appears at hover-scale);
     current = 16px halo ring in status color, riders (18px agent marks)
     standing above it; upcoming = 6px hollow. Checkpoint stations are 12px
     rotated-square GATES: approved = filled --signal, pending = --alert
     outlined + soft pulse, upcoming = hollow with faint ★. Stage names mono
     8px under stations (current in --text, rest --muted).
   - **Station popovers** (the headline addition): every station is a button.
     Click/Enter opens an anchored popover (radius 13, --elevated, shadow
     0 12px 40px rgba(0,0,0,.6), pop animation 250ms, closes on Esc/outside):
     header `Implement · buzz-implement · started 12:27` + checkpoint pill
     when relevant; then three tight groups —
     **cast** (agent rows: mark, name, link_role, link_state pill),
     **threads** (# title + status dot + Open in Buzz),
     **pi sessions** (title · model · tokens + Open pane wX:tN),
     plus continuity docs as mono chips and the newest activity line with
     live t-ago. Empty groups say so honestly in --muted. Open* → toast.
     Populated stations wear a tiny 3px dot-badge under the station
     (accent = has sessions, mauve = has threads) so density is scannable
     without opening anything.
   - **Selected card detail** (click card body): the 3-column block —
     next movement · traveling cast (rows now include per-agent mini
     stage-strip: 8 tiny cells shaded where attached) · continuity — under a
     hairline, 250ms accordion.
   - Needs-you card: --alert spine + border tint + its primary action button
     right in the header. Idea card: dashed-mauve preflight block (as today,
     tidied).
4. Ordering: needs-you first, then later-stage first ("ordered by next
   intervention" caption stays).

### View 2 — Focus route (refit)

`grid-template-columns: 255px minmax(0,1fr)`.

- **Left rail**: item buttons (KEY 11px 700, status mono 9, 22px stack;
  active = accent border + gradient wash) + needs-you items pinned on top with
  alert dot.
- **Hero card**: kind pill · `KEY · Title` (23px rounded 750) · mono meta ·
  stack right. Big metro rail (same grammar as View 1, stations 30px hit area,
  riders 22px) — stations open the SAME popovers.
- **Below hero, grid `1.15fr .9fr`**:
  - **Route activity** panel → a real timeline: 2px vertical rail on the left,
    each event = mark dot in actor color + `13:30` mono + actor + message;
    stage-transition events render as small gate markers with stage name;
    the newest event carries a live t-ago and slides in when the simulator
    fires (this panel is wired to the shared simulator for AGENTIC-575).
  - **Traveling cast** panel → agent rows: 25px mark, name + role, right side
    an 8-cell mini stage-strip showing that agent's attachment span (done
    signal/active accent shimmer/queued dashed) + state pill. Hovering a row
    highlights that agent's stations up in the hero rail (class toggle).
- **Checkpoint card** (only when current stage checkpoint_state = pending):
  radius 16, alert-tinted hairline: "Proof checkpoint — approve the analytics
  event map." + primary **Approve** and quiet **Request changes** buttons
  (both toast; Approve flips the demo state: gate fills, rail advances,
  status pill → working — a real interactive moment showing the payoff).
- **Stage details** disclosure (collapsed by default): 8 rows mirroring the
  Mac app's disclosure — stage title + counts, expanding to the same dossier
  content as popovers (shared render fn).

## Motion

Calmest of the three options: 250ms controls, one-time rail fill on load,
breathing working dots, popover pop, timeline slide-in. No marching ants here —
the refit stays close to what SwiftUI can ship this week. All in
prefers-reduced-motion guard.
