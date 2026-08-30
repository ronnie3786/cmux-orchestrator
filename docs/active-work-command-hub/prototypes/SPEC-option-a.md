# Option A — "Trail Map" (agenttrail-style spatial canvas)

File: option-a-trail-map.html · <title>Herdr Trail Map</title>
Thesis: the Buzz pipeline becomes a zoomable world. Work items are trains on a
rail map; stations are stages; agents are marks riding the line. Direct
transplant of agenttrail's canvas model into Herdr's chrome and palette.

## Layout

Standard Herdr chrome (SPEC-shared). The content area right of the sidebar is a
full-bleed **world viewport** (no 1120px column): background var(--crust),
24px dot-grid SVG pattern (dots rgba(166,173,200,.14), opacity .35), plus a
fixed feTurbulence grain overlay at opacity .025.

Inside, one `g.world` with `translate(panX panY) scale(zoom)`, containing:

1. **Phase regions** — four rounded-26 region rects laid left→right:
   OPEN · BUILD · PROVE · SHIP (mono uppercase 44px labels, letter-spacing -1,
   fill rgba(30,30,46,.5)). Region hosting a needs-you item gets stroke
   rgba(243,139,168,.4). Left of OPEN sits a smaller dashed-mauve region
   "IDEA INTAKE" for IDEA-07.
2. **The rail geography** — 8 station columns at fixed world x positions
   (2 per phase region). Faint vertical hairlines mark station columns inside
   regions; station glyphs render per item lane (below).
3. **Item lanes** — each of the 3 pipeline items gets a horizontal lane
   (fixed y, ~260 world units apart; lanes never reshuffle). Per lane:
   - **Trail polyline** through all 8 station points:
     traveled segments = solid 2.5px var(--signal) opacity .55;
     segment entering the current station = var(--accent)
     `stroke-dasharray:5 8` with `travel` marching animation (to offset -26);
     future segments = rgba(166,173,200,.35) `stroke-dasharray:2 7` round caps.
     All edges `vector-effect: non-scaling-stroke`.
   - **Stations**: 8 markers on the lane. Passed = 8px filled --signal circle
     with tiny check; current = 13px ring in item status color with halo
     (needs-you = --alert + soft beacon pulse); future = 5px hollow --muted.
     Checkpoint stations (Plan/Proof/Pre-PR/PR) render as rotated-45° squares
     (gates): approved = filled --signal; pending = --alert stroke pulsing;
     future = hollow. Small mono stage label under each station (8px,
     visible when zoom ≥ .7). Agent marks (10px circles w/ 2-char glyph,
     gradient fills per avatar_key) park ABOVE stations where link_state is
     active/queued (queued at .48 opacity).
   - **The item card** — agenttrail gnode, fixed 400×128 world units, docked
     above its current station (connected by a short dashed tether):
     rect radius 12 fill var(--graphite) stroke hairline (needs-you: stroke
     --alert; selected: stroke --accent 1.5). Contents:
     kicker `KEY · skill_name` (mono 11 faint) · status icon top-right
     (active = track circle + accent arc dasharray "16 41" spinning 1100ms;
     needs-you = --alert circle + "!"; near-done = filled --signal + check) ·
     **obs-ring**: r13 accent arc dasharray "23 59" spinning 1300ms around the
     status icon, only while simulated activity is <60s old, with mono label
     "Editing" + latest file `impact_guard.py · 12s` (t-ago span) ·
     title 600 15px · meta "2 of 8 stages · Implement" tabular ·
     4px progress bar (accent when active) · agent chips right-aligned ·
     bottom action `SHOW STAGES ↓` (mono 11 500 .04em).
4. **Expanded card** — clicking the card (or Enter) appends a foreignObject
   capsule list below it (radius 16, var(--graphite), reveal animation,
   rows staggered 80ms): one row per stage, agenttrail task-capsule anatomy —
   done: 22px --signal badge w/ check (capsule-pop) · active: 24px ring with
   sequence number inside + spinning arc · pending: hollow ring w/ number ·
   row copy = stage title · right side: mini agent chips, then pills:
   `2 threads` (neutral), `pi · 486k` (accent) when populated, checkpoint pill
   (`✓ approved` signal / `awaiting you` alert). Chevron rotates when open.
   Row detail (grid-rows 0fr→1fr accordion): for that stage — each Buzz thread
   (`# title` + status + **Open in Buzz** link), each Pi session
   (`title · model · tokens` + **Open pane wX:tN**), continuity docs, and
   activity lines (`13:31 · Pi coder — Reading schema integration points.`)
   with live t-ago on the newest. Every Open fires the toast.
5. **Run cards** (HTML overlay, absolute top-right, 340px): one per RUNNING
   pi session (pi-9a02) + one ended (pi-7c11, dimmed, dot static): head =
   agent mark + name + breathing --success dot + elapsed `in Implement`
   (component link — clicking FLIES the camera to that item's card);
   run-task line = current activity; run-tool mono line
   `Edit <span class=td>api/impact_guard.py</span> <span class=ta>3s</span>`
   that updates with the simulator; click expands recent-tools history
   (5 rows, mono 11, durations right-aligned tabular).
6. **Needs-you dock** (HTML overlay, top-left under canvas tools): two compact
   alert strips "IOSDOX-27458 · approve event map" / "AGENTIC-472 · merge
   PR #510" — click flies the camera there. The flown-to card's primary
   action button ("Review event map" / "Decide on PR #510") sits in its
   expanded footer.

## Camera

- Drag pan (pointer capture, grab/grabbing cursor; skip when target is a card),
  wheel pans, ⌘/Ctrl+wheel zooms to cursor (world-point invariant math).
- Canvas tools top-left: − · zoom% · + · ⛶ fit. Fit computes bounds of all
  lanes + cards.
- Camera flights: set world transition `transform 600ms cubic-bezier(.23,1,.32,1)`,
  jump pan/zoom, clear after 650ms. Sidebar "active work" card refits; dock
  strips + run-card links fly.
- Minimap bottom-right (150px wide, rgba(30,30,46,.92)): item rects colored by
  status, viewport rect, click-to-jump.
- LOD: zoom < 0.45 → cards swap to giant name plates (KEY + status square +
  agent marks); capsules force-fold. Hysteresis: re-expand at ≥ 0.55.
- Keyboard hint strip bottom-left with .key keycaps: `drag` pan · `⌘ scroll`
  zoom · `F` fit (implement the F shortcut).

## Motion & liveness

Two-speed system (700ms var(--ease) ambient / 250ms var(--ease-out) controls,
easings from agenttrail: cubic-bezier(.32,.72,0,1) and cubic-bezier(.23,1,.32,1)).
working-pulse 1.6s on all live dots. Simulator (SPEC-shared) appends activity
to AGENTIC-575/implement: updates run-card tool line, flashes the obs-ring,
bumps t-ago stamps (1s interval patcher; never rebuild the world for time).
