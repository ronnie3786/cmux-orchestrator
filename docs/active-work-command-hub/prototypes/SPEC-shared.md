# Shared spec — Herdr Active Work prototypes

Three self-contained HTML prototypes for the Herdr Mac harness "Active Work" section.
Each is ONE .html file, no external requests of any kind (no CDNs, no fonts — system
fonts only; the real app is native macOS so SF faces are correct and free). Vanilla
JS only. Every option inlines the same dataset (herdr-active-work-data.js, in this
directory) verbatim near the top of its <script>.

## Audience & job

Ronnie runs a fleet of coding agents through an 8-stage "Buzz pipeline". The page's
single job: *follow each work item's path, see which agents/Buzz threads/Pi sessions
belong to each step, and dive deeper* — while keeping one obvious next action
(ADHD-friendly: calm color, progressive disclosure, few competing elements).

## Hard constraints

- Dark, single-theme, committed (matches the shipped Herdr app; `<meta name="color-scheme" content="dark">`).
  Paint `body` background explicitly `#050506`. No light theme, no `data-theme` machinery.
- Artifact wrapper adds doctype/head/body — write content directly, but a full standalone
  file that also opens from disk is fine (include <title>). NO external network requests.
- Tokens (Catppuccin Mocha, verbatim from HerdrTheme.swift / pipeline prototype):
  ```css
  :root {
    --ink:#181825; --graphite:#1e1e2e; --elevated:#313244; --surface:#45475a;
    --mist:#a6adc8; --muted:#6c7086; --text:#e5eafa; --accent:#89b4fa;
    --mauve:#cba6f7; --signal:#94e2d5; --success:#a6e3a1; --working:#f9e2af;
    --alert:#f38ba8; --warning:#fab387; --code:#f5c2e7; --crust:#11111b;
    --body:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
    --rounded:ui-rounded,"SF Pro Rounded",-apple-system,system-ui,sans-serif;
    --mono:"SFMono-Regular","SF Mono",Menlo,ui-monospace,monospace;
    --card-radius:16px; --compact-radius:10px;
  }
  ```
- Status encoding (never decorate with these hues, only signal):
  working = --working on rgba(249,226,175,.08) fill / .28 border;
  needs-you = --alert on rgba(243,139,168,.09) / .3;
  done/monitoring = --signal on rgba(148,226,213,.08) / .28;
  neutral pill = --mist on rgba(49,50,68,.52);
  queued = --muted at .48 opacity; idea = --mauve dashed rgba(203,166,247,.35) on rgba(203,166,247,.045).
- Hairlines: 1px solid rgba(166,173,200,.16–.22); dividers rgba(255,255,255,.08).
- Type: mono for ALL metadata/pills/timestamps/IDs (9–10px, 600–650); --rounded 750 for h1 (30px)
  and hero titles (23px); --body for prose (11–13px). letter-spacing -.02em on big headings;
  slight tracking on uppercase/mono labels. tabular-nums where digits align.

## App chrome (identical in all three, so options compare cleanly)

Page bg `#050506`. Centered `.app-window`: `width:min(1700px,calc(100vw - 28px));
height:min(930px,calc(100vh - 24px)); border-radius:28px; border:1px solid rgba(166,173,200,.34);
box-shadow:0 30px 90px rgba(0,0,0,.62); background:var(--ink); overflow:hidden`.

Toolbar (66px, grid `270px 1fr 270px`): left = three 14px traffic lights (#ff5f57,#febc2e,#28c840);
center = a segmented control naming THIS option (single active pill, plus a muted non-interactive
"Concept N of 3" caption); right = 40×40 mic button (filled --accent, radius 12) + "⋯" outline button.

Shell: `grid-template-columns:310px minmax(0,1fr)`. Sidebar (border-right hairline):
- `herdr` wordmark: mono 750 15px + tiny 3-bar glyph (accent/mauve/signal bars).
- Selected "active work" card: 3px left gradient bar (mauve→accent), title + "4 riding",
  caption "Tickets, features, and ideas moving through the Buzz pipeline.",
  mini-pills "2 moving" · "2 need you".
- "my work · 5 watching" section: collapsible rows "github reviews (2)" / "jira tickets (3)"
  with count badges; two muted inbox items under github reviews
  (doximity/iOS-Doximity #11,856 "Add calculator access to the drawer";
  doximity/agentic-dev #520 "Register managed MCP runtime").
- Links: console · workspaces · new pi session.
- Footer, mono 9px muted: "board source / 8 buzz-* stages · 4 checkpoints / tickets/<KEY>/ carries state".

Sidebar is presentational (hover states only) — keep it calm.

## Interactions every option must support

1. Click a work item → its detail surface (per-option form).
2. Per-STAGE association: some gesture reveals, for any stage of any item, the agents
   (with link_role + link_state), Buzz threads, Pi sessions, docs, and timestamps attached
   to that stage. This is the headline capability the current UI lacks.
3. Dive-deeper affordances: buttons/links labeled like real deep links —
   "Open pane w1G:t1", "Open in Buzz", "Open handoff" — each fires a toast
   (bottom-center, --elevated card, auto-dismiss 2.6s) describing the navigation,
   e.g. "Opening pane w1G:t1 on rocketbot…". Never a dead click: everything that looks
   interactive responds.
4. "Needs you" is the loudest thing on the page, and each needs-you item carries ONE
   primary action button (e.g. "Review event map", "Decide on PR #510").
5. Live feel: a small simulator appends a new activity line to AGENTIC-575's implement
   stage every ~7s (rotating through 3–4 plausible messages), updates its "updated" stamp,
   and pulses whatever "live" indicator the option has. Working dots breathe (1.15s ease
   halo pulse). All motion inside `@media (prefers-reduced-motion: no-preference)`.

## Quality floor

- Keyboard: cards/stages focusable (tabindex, Enter/Space activate), `:focus-visible`
  outline 2px --accent offset 2px.
- No layout jank: hover states change color/border only, never size. Wide internals get
  `overflow-x:auto` on their own container; page body never scrolls horizontally.
  Min sensible width 1020px; degrade gracefully to ~900px.
- Cursor: pointer only on interactive things.
- Realistic copy everywhere — never lorem, never "TODO".
- End the file with an HTML comment listing the option name and the interactions
  implemented (a manifest for review).
