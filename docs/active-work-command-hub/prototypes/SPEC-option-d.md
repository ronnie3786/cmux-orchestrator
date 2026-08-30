# Option D — "Buzz Trail" (the faithful agenttrail port)

File: option-d-buzz-trail.html · <title>Herdr Buzz Trail</title>
Thesis: this is agenttrail itself, pointed at the ticket pipeline instead of a
codebase. Where agenttrail draws 5–9 repo components with task capsules inside,
we draw the EIGHT BUZZ STAGES as the stable component map, and the WORK ITEMS
ride through them as capsules. agenttrail's whole visual identity comes along:
near-black ground, amber accent, grain, its exact motion system, its light/dark
theme toggle, its topbar/sidebar chrome. NO Herdr mac-window chrome, NO
Catppuccin — the point of this option is fidelity to the source.

## Source fidelity (binding)

The real agenttrail UI source is at:
  /private/tmp/claude-501/-Users-ronnierocha-projects-cmux-orchestrator/daaebd4d-1aae-47ca-8edb-0e12f3281554/scratchpad/agenttrail/public/index.pretty.html
READ its CSS (the full <style> block) and its key render patterns before
writing a line, and LIFT the real recipes: token names, radii ladder, shadow
pair, capsule anatomy, gnode SVG structure, run-card markup, tree rows, badge
styles, switcher, theme toggle, canvas tools, minimap, keycap hints, toast.
Adapt names/data, keep the craft. AGENTTRAIL-TECHNIQUES.md (same dir as this
spec) is the condensed cookbook; the dataset is herdr-active-work-data.js
(inline verbatim).

Tokens (verbatim from agenttrail — dark default, light via
:root[data-theme="light"], pre-paint localStorage script, storage key
"herdr-trail-theme"):

```css
:root { color-scheme: dark;
  --bg:#000; --surface:#181818; --raised:#1f1f1f; --hover:#272727; --line:#313131;
  --text:#fff; --soft:#d1d1d1; --dim:#9b9b9b; --faint:#686868;
  --accent:#e9a23b; --accent-bg:#2e220f; --danger:#db6b67; --success:#7aa36a;
  --complete-text:#70a784; --complete-bg:rgba(63,127,87,.18); --complete-weight:500;
  --done-agent-opacity:.45; --working-border:#1d2b22; --working-bg:#141f18;
  --watch-ring:#172015; --region:rgba(24,24,24,.5); --minimap-bg:rgba(24,24,24,.92);
  --overlay:#181818; --grid:#313131; --shadow-soft:rgba(0,0,0,.24); --shadow-strong:#000;
  --font:"Geist","Manrope",-apple-system,system-ui,sans-serif;
  --mono:"Geist Mono","SF Mono",ui-monospace,monospace;
  --ease:cubic-bezier(.32,.72,0,1); --ease-out:cubic-bezier(.23,1,.32,1); }
:root[data-theme="light"] {
  --bg:#fff; --surface:rgb(0 0 0/.025); --raised:rgb(0 0 0/.05); --hover:rgb(0 0 0/.07);
  --line:rgb(0 0 0/.14); --text:#000; --soft:rgb(0 0 0/.78); --dim:#666; --faint:rgb(0 0 0/.48);
  --accent:color-mix(in srgb,#e9a23b 64%,#000); --accent-bg:rgb(233 162 59/.16);
  --danger:#c4524e; --success:#3f7f57; --complete-text:#3f7f57; --complete-bg:rgb(63 127 87/.18);
  --complete-weight:600; --done-agent-opacity:.72; --working-border:rgb(63 127 87/.24);
  --working-bg:rgb(63 127 87/.1); --watch-ring:rgb(63 127 87/.14); --region:rgb(0 0 0/.015);
  --minimap-bg:rgb(255 255 255/.94); --overlay:#fbfaf8; --grid:rgb(0 0 0/.16);
  --shadow-soft:rgb(0 0 0/.1); --shadow-strong:rgb(0 0 0/.14); }
```
Grain (feTurbulence data-URI at .025), 24px dot-grid pattern under the world,
body font 400 14px/20px var(--font) letter-spacing -.01em, mono kickers
500 11px .04em, tabular-nums on every number. LIGHT MODE MUST BE REAL — the
toggle works, compensates with tint + weight per the source, and both themes
are checked for contrast.

## Chrome (agenttrail's, re-branded)

- `.app` grid: topbar (64px) over workspace (272px sidebar + world), 100dvh.
- Topbar left: 3-bar Herdr glyph recolored amber/soft/dim + brand block —
  "herdr" (600 15px) over mono subline "workspace / buzz-feature-work".
- Topbar right: theme switch (labeled "Light"/"Dark", role=switch, exact
  agenttrail track/thumb) · badge "Working · <t-ago>" (green working style w/
  pulsing dot, driven by the simulator's 60s window; falls back to neutral
  "Board is live") · badge "2 need you" (danger text/border/tint; click flies
  camera to the first blocked stage card) · "watching" green dot w/ halo ring.
- Sidebar = the TICKET TREE (agenttrail's file tree, exactly its row anatomy):
  root `tickets/`, one dir per work item — AGENTIC-575/ (state.json,
  handoff.md, context-dump.md, coder-brief.md), IOSDOX-27458/ (state.json,
  handoff.md, event-map.md), AGENTIC-472/ (state.json, pr-summary.md) — plus
  `_ideas/` holding IDEA-07.md, and buzz.log at root. Chevron dirs open/close
  (remembered in Sets); "just touched" rows get .hot amber name + right-aligned
  live ago stamp; the simulator touches AGENTIC-575/context-dump.md and
  state.json alternately, auto-revealing that folder. Sticky legend at bottom:
  "most recent edit · time since last write". Light mode: inset 2px amber edge
  + weight 600 on hot rows (verbatim behavior).

## The world: stages are the components

SVG world (`g.world` translate/scale), phase REGIONS as the multi-repo
regions: OPEN, BUILD, PROVE, SHIP — four rounded-26 region rects in a row
(region name in the corner, mono uppercase, big letter-spacing -1 style),
each containing its two stage gnode cards stacked with agenttrail's column
layout (fixed 400-wide cards, gy 48, positions NEVER reshuffle).

Each stage card = a faithful gnode:
- kicker: skill slug (`buzz-implement`) mono 11 faint; CHECKPOINT stages
  (plan, proof, code-review-pre-pr, pr) additionally carry a bottom-right
  mono tag `HUMAN GATE` in #e08bb8 (the "SESSION PLAN" treatment).
- title: stage title 600 15px ("Implement", "Agent review", …).
- status icon top-right, derived from the items at that stage:
  any item active here → track circle + accent arc spinner (16 41, 1100ms);
  any item blocked-on-human here → danger circle + "!" (card stroke danger);
  every pipeline item already past it → filled green #3f7f57 circle + check;
  else hollow faint circle.
- obs-ring (23 59 arc @1300ms) + "Editing" + live file label on the card where
  simulated activity <60s (Implement) — the declared-vs-observed transplant.
- node-meta line, tabular: e.g. "2 cleared · 1 riding" / "3 cleared · 1 gate".
- progress bar: fraction of the 3 pipeline items that have cleared this stage.
- agent chips right-aligned: marks of agents CURRENTLY attached at the stage.
- action: `SHOW TICKETS ↓ / HIDE TICKETS ↑`.

Expanded card → foreignObject capsule list (agenttrail's exact task-capsule
anatomy, entry stagger 80ms), one capsule per work item with a record at that
stage, ordered active → blocked → done:
- `[~]` riding: 24px ring-track + accent live arc with the item's stage
  sequence number inside; copy = `AGENTIC-575 — Mobile API Impact Guard`;
  right: agent chips (by: marks), "Editing now" amount when observed-live,
  pill `Riding` (accent-bg).
- `[!]` waiting on human: danger 22px badge "!"; pill `Your gate` (danger
  #e79490 on rgba(219,107,103,.16)); chips include Ronnie's mark.
- `[x]` cleared: green badge + check (capsule-pop), agent chips faded to
  var(--done-agent-opacity), pill `Cleared 12:41` (complete colors).
- queued/next: hollow marker, pill `Queued` (faint on hover-bg).
Capsule detail (0fr→1fr accordion, staggered detail rows, the 1px vertical
rule column): rows for each Buzz thread (`# Implement · diff streaming` +
`Open in Buzz` accent link), each Pi session (`pi-9a02 · deepseek-v3 · 486k`
+ `Open pane w1G:t1`), checkpoint state (`gate approved 12:27` or an accent
action row `Review event map →` / `Decide on PR #510 →` for the two blocked
gates — the ONE loud action each), and latest activity lines with live agos.
All Open*/action rows fire the agenttrail toast (role=status, bottom-center).

Edges & trails:
- Solid needs: arrows stage→stage in sequence (quiet --grid arrowheads,
  vector-effect non-scaling); the edge INTO a stage with riding work marches
  (edge.active accent 5 8, travel keyframes).
- One dashed link (2 7 round caps): Agent review ⇢ Pre-PR labeled by a small
  mono hint "safe skip" on hover title.
- Per-item session TRAILS: bead-chain polylines (2.5px, 1 7, round caps)
  through the centers of the stages each item has visited — item colors
  #5b7fd6 (575), #e08bb8 (27458), #7aa36a (472); opacity .55 for items still
  riding, .2 for AGENTIC-472 (parked at triage, oldest). Trails sit UNDER
  edges/cards.

## Camera, overlays, liveness

- Identical camera system: drag pan (pointer capture, skip on .gnode), wheel
  pan, ⌘/ctrl+wheel zoom-to-cursor, F fit, canvas-tools (− % + ⛶), minimap
  (region/status-colored rects + viewport, click-to-jump), keycap hint strip.
- Altitudes with hysteresis: <0.45 regions collapse to giant phase name-cards
  with mini status squares; ≥1.05 auto-unfold all capsule lists, ≤0.85 fold.
  BOOT: fit must land ABOVE the LOD threshold (clamp initial fit zoom to
  ≥0.6) so the first paint shows real cards, not plates.
- Run cards top-right (340px, exact anatomy): live pi-9a02 (glyph mark,
  breathing success dot, elapsed + "in Implement" link that flies the camera,
  current-task line, streaming tn/td/ta tool line, click → todo list + last-5
  tool history w/ durations) and ended pi-7c11 (dimmed, static dot,
  "Idle — waiting for you").
- Simulator (same contract as the other options): every ~7s advance
  AGENTIC-575's implement activity — new capsule-detail activity line, tool
  line swap, obs-ring flash, ticket-tree hot stamp, topbar Working badge
  refresh. 1s t-ago patcher for ALL times; no structural rebuilds on ticks.
- a11y floor: gnodes role=button tabindex=0 Enter/Space, aria-expanded,
  focus-visible 2px accent, reduced-motion kill switch, skip-link like the
  source. End file with the manifest comment.
