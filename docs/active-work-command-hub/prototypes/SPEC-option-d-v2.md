# Buzz Trail v2 — flesh-out spec (delta on SPEC-option-d.md)

Target: EDIT the existing ${DIR}/option-d-buzz-trail.html in place (do not start
over — v1 shipped and its structure/fidelity is approved). Everything in
SPEC-option-d.md remains binding: agenttrail's tokens, both themes, motion,
camera, a11y, the 1s t-ago patcher, no-dead-pixels, manifest comment.

Goal: bring in much more of the REAL Herdr setup — the full harness model and
its live behaviors — so the board reads like Ronnie's actual fleet, not a demo.

## 1. Dataset swap

Replace the inlined v1 dataset with herdr-active-work-data-v2.js VERBATIM
(same directory). New realities the UI must derive (derive ALL counts/badges
from data — zero hardcoded numbers anywhere):
- 6 pipeline items incl. HUD-441 (kind:task, Kimi reviewing on devbox),
  AGENTIC-512 (lifecycle:blocked at Plan with checkpoint_state
  changes_requested), IOSDOX-27102 (lifecycle:done — merged, monitoring).
- INTAKE list (pre-pipeline): IDEA-07 (setup_state board_created) and
  IOSDOX-27655 (channel_linked — channel exists, no driver).
- JIRA_CANDIDATES rail, MACHINES (rocketbot/devbox), full 10-agent roster
  with statuses (working/idle/queued/waiting/offline).
- New per-item fields: machine_id, channel{name}, jira{issue_key,issue_type,
  priority,url}, pr{number,url} where present, handoff_cmd, unscoped_threads,
  gate_action, trail_color, done_label.

## 2. Board changes

- **INTAKE region** left of OPEN: dashed-stroke region (agenttrail region
  grammar, but dashed 4 6) holding one mini-card per INTAKE entry: kicker
  `idea intake` / `setup · channel_linked`, title, note line, and a mono
  next-step action row (`Link a Buzz channel →` / `Attach driver →`) that
  toasts. Style: quieter than gnodes (smaller, raised fill, faint stroke;
  the channel_linked one shows its #channel name).
- **Done treatment**: IOSDOX-27102 appears ONLY as: bead trail at opacity .2
  across all 8 stages, faded `[x]` capsules (collapsed cards count it in
  "cleared"), and a `merged this morning · monitoring` line in its capsules'
  detail. Its capsule pill: `Done` complete-colors. No loud presence.
- **Stage card counts** re-derive: e.g. Implement meta now reads from data
  (2 riding at review? no — HUD-441 rides architect-code-review, 575 rides
  implement, 512 blocked at plan, 27458 at proof, 472 at triage). Cards with
  a blocked item get danger stroke; with riding item, spinner; etc. (v1 rules,
  new data).
- **Machine chips**: capsule detail session rows show `machine · pane`
  (`rocketbot · w1G:t1`, `devbox · wA:t5`); run cards show the machine in
  their faint subline. Items on devbox get a tiny mono `DevBox` chip after
  the capsule copy (faint, no color).
- **Jira row** in capsule detail: `P2 · Story · Open AGENTIC-512 in Jira`
  (accent link → toast). PR items add `Open PR #510 →`.
- **Channel row**: each expanded card's capsule detail (or card-level footer
  row in the capsule list) shows the item's Buzz channel `#agentic-575-guard`
  + unscoped threads when present.

## 3. Real behaviors (the heart of v2)

a. **Working gate transitions** (models POST /transitions):
   - IOSDOX-27458's gate action `Review event map →` opens a small agenttrail
     overlay confirm (surface card, 2 buttons: `Approve` accent / `Request
     changes` quiet). Approve → LIVE STATE CHANGE: proof flips to
     complete/approved, item advances to code-review-pre-pr (riding), the
     bead trail extends, stage cards re-derive (counts, strokes, spinners),
     needs-you badge decrements, activity line + toast (`IOSDOX-27458 cleared
     Proof — Pre-PR started`), capsule moves cards. Request changes →
     checkpoint_state changes_requested (danger pill flips wording) + toast.
   - AGENTIC-472's `Merge PR #510 →` confirm → item completes: triage clears,
     lifecycle done, trail dims to .2, capsules fade to Done, badge
     decrements, toast `PR #510 merged — AGENTIC-472 is done · monitoring`.
   - AGENTIC-512's `Reopen plan review →` just toasts (driver still revising).
   All transitions must keep the 1s/7s machinery consistent afterwards.

b. **Needs-you dropdown with ack** (models harness alerts + ack projection):
   clicking the topbar `N need you` badge opens an anchored overlay listing
   each attention item — danger dot · KEY · attention_reason · mono ago —
   click row = camera flight to that gate capsule (and opens it); a small
   `ack` button per row dims that row (opacity .45, dot hollow) without
   changing the badge count (acks are a viewing aid, not state — matches the
   harness's ack projection). Esc/outside closes.

c. **Pi handoff command** (real Herdr feature): in every live/ended session
   detail row and in expanded run cards, a mono row
   `herdr pi handoff --pane w1G:t1` with a copy glyph — click copies to
   clipboard (navigator.clipboard with execCommand fallback) + toast
   `Handoff command copied`.

d. **buzz.log console**: clicking `buzz.log` in the ticket tree opens a
   full-height right-side overlay panel (agenttrail overlay surface, 420px,
   slide-in 250ms) — the merged activity stream across ALL items, newest
   first: mono rows `13:44 · <agent mark> DeepSeek coder · AGENTIC-575 —
   message` with live t-agos; simulator appends here live. Filter chips at
   top: `all` + one per active item key. Esc closes.

e. **Ask board** (Herdr's voice affordance, agenttrail-quiet): a small ⌁
   button in the topbar next to the badges. Opens an overlay with three
   canned questions as keycap-style rows — `What needs me next?`, `Where is
   AGENTIC-575?`, `Who is idle?` — answering from CURRENT demo state (post-
   transition answers must be correct: derive, don't hardcode). Answer
   renders as a mono paragraph with agent marks; a mic glyph pulses
   record-style while "answering" (450ms), honoring reduced-motion.

f. **Sidebar: agents + candidates** (below the ticket tree, same tree
   styling):
   - `agents` section: one row per roster agent — mark, name, status dot
     (working=pulsing success, idle=static faint, queued=hollow, waiting=
     amber, offline=dim slash) + mono status word. Click an attached agent →
     camera flight to its stage card (+ toast naming the attachment); click
     an unattached one → toast (`iOS QA is idle — no attachment`).
   - `jira candidates` section: rows `IOSDOX-27710 · P3` with a mono
     `set up →` action: click → row shows `setting up…` (spinner ring) then
     after ~1.4s the ticket APPEARS in the INTAKE region as a new
     channel_linked card (+ toast). Derives from JIRA_CANDIDATES.
   - `new pi session` link stays → toast.
   - Ticket tree gains folders for the new items (HUD-441/, AGENTIC-512/,
     IOSDOX-27102/) — done item's folder renders faint.

g. **Simulator v2**: keep the coder tick; every ~3rd tick also do ONE of:
   Kimi review activity on HUD-441 (buzz.log + its card obs-ring flash),
   token counts bump on live run cards, or the implement thread row gains a
   `new` dot that clears when its capsule detail opens. Bounded, in-place
   patches only.

## 4. Quality bar

Same as v1 (both themes! every new surface must be checked in light mode too;
new overlays use --overlay/--minimap-bg tokens so they theme for free).
Overlays layer correctly with run cards/minimap; only one overlay open at a
time (opening one closes others). Keyboard: all new rows/actions tabbable,
Esc closes overlays, focus returns to the opener. Update the manifest comment
with the v2 interaction list.
