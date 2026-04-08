# Open / New Unified UX Spec

_Last updated: 2026-04-07_

## Goal

Unify the current "objective" and "workspace" concepts into a single user-facing mental model.

For users, the distinction should no longer be:
- objective vs workspace

It should instead be:
- **New** = start a new feature or task from scratch
- **Open** = resume or inspect an existing feature, branch, repo root, or worktree that already has work in progress

This is primarily a **product language and UX refactor**, not a required backend storage rewrite.

## Product Positioning

### User-facing model

The user should think of both flows as opening a working context in cmux.

- **New**
  - I am starting something new.
  - cmux should create the working context for me.
  - This is the current objective flow.

- **Open**
  - I already have a working context.
  - cmux should attach to an existing repo root, branch checkout, or worktree.
  - This is the current workspace flow.

### Important clarification

Internally, the codebase may still keep separate records for objectives and workspace sessions for now.

That is acceptable in the first pass.

The requirement is that the **UI stops teaching users that these are fundamentally different product concepts**.

## Terminology Changes

### Primary labels

Change the top-level sidebar actions from:
- `New objective`
- `Open workspace`

To:
- `New`
- `Open`

Keep `Add project` as-is.

### Secondary labels

Update supporting copy so the UI explains the difference as:
- `New`: create a new feature or task in this project
- `Open`: open an existing feature, repo root, or worktree that has already been worked on

Avoid teaching:
- "workspace session"
- "ad hoc session"
- "tracked objective" vs "workspace"

unless that distinction is strictly needed in developer-facing docs.

## Product Rules

### Rule 1: Button meaning must be stable

The `New` button must always open the new-item flow.

It must never switch behavior based on current selection.

Current behavior to remove:
- if a workspace is selected, the `New objective` button currently opens the workspace form

### Rule 2: The list stays unified

Do **not** split the sidebar into separate "Objectives" and "Workspaces" sections.

The user wants one unified project list because both items represent the same practical thing:
- a unit of work the user can open and continue

### Rule 3: Differentiate by entry state, not by category

Within the unified list, items may still show subtle metadata that communicates whether they were:
- created by `New`
- opened by `Open`

But this should be lightweight and secondary.

Examples:
- small pill: `new`
- small pill: `open`
- or a subtle icon

This metadata is optional in the first pass. The critical change is stable wording and flow behavior.

## Sidebar Changes

## Top actions

Replace the current top action stack with:

1. `New`
2. `Open`
3. `Add project`

Recommended visual hierarchy:
- `New` is the primary button
- `Open` is a secondary button directly beneath it
- `Add project` remains tertiary

## Sidebar width

Increase sidebar width from `240px` to a larger fixed width.

Recommended first-pass width:
- `280px`

Acceptable range:
- `272px` to `296px`

Do not add resize behavior in this pass.

### Why

The current width truncates:
- project names
- project paths
- item titles
- progress/status metadata

Widening the fixed sidebar is enough for now.

## Unified project list

Keep the current grouped-by-project structure.

Inside each expanded project, continue rendering one chronological mixed list.

Recommended ordering:
- newest updated items first

Recommended item treatment:
- same base card shape for all items
- subtle metadata to indicate origin or state
- active selection remains visually strong

## Item metadata

Each unified item row should aim to show:
- title
- short secondary line
- status or activity signal
- recency

Suggested secondary line behavior:
- for `New` items: progress or status text
- for `Open` items: path hint or recent activity

Do not overload the row with both progress bars and full paths if it makes scanability worse.

## New Flow

## Entry point

The `New` button opens the current objective-style creation flow.

### Form title

Change:
- `New objective`

To:
- `New`

### Form purpose copy

Use copy similar to:

`Start a new feature or task in this project. cmux will create the working context and get started.`

### Fields

Keep the current fields:
- Project
- Workflow
- Base branch
- Branch name
- Goal

### Primary CTA

Change:
- `Create & start`

To one of:
- `Start new`
- `Create new`

Recommended:
- `Start new`

### Behavior after adding a project mid-flow

If the user had been in the `New` flow and needed to add a project first:
- return them to the `New` flow after project creation

## Open Flow

## Entry point

The `Open` button opens the existing-work flow.

### Form title

Change:
- `Open workspace`

To:
- `Open`

### Form purpose copy

Use copy similar to:

`Open an existing feature, repo root, or worktree that already has work in progress.`

### Fields

Keep:
- Project
- Path
- Name (optional)

Add parity with project creation:
- a folder picker button
- manual path fallback

### Primary CTA

Change:
- `Open workspace`

To:
- `Open`

## Folder picker parity

The `Open` flow should have the same quality as project creation.

### Required behavior

Add a folder picker button beside the path input.

Recommended behavior:
- default selected path to the chosen project's root path
- allow browsing to a different repo root or worktree
- if picker is unavailable, fall back to manual path entry

### Manual entry fallback

Mirror the current project flow behavior:
- show a readonly selected-path field plus `Browse...`
- allow `Type path manually`
- preserve entered values across rerenders

### Source metadata

When practical, the open flow should still record source hints internally:
- `project-root`
- `existing-worktree`
- `manual-path`

This is implementation detail, not primary UI copy.

## Unified Empty States

The empty and waiting states should align with the unified model.

### No projects

Use copy like:

`Add a project, then choose New or Open.`

### No selected item

Use copy like:

`Choose an item from the sidebar, or start with New or Open.`

### Empty message thread after open

Do not say:
- `Waiting for the objective to start.`

For opened items, use copy like:
- `Workspace ready. Ask about the codebase or make a change.`

For new items that are still spinning up, use copy like:
- `Starting the new task...`

If the frontend cannot yet distinguish these states cleanly, use neutral copy:
- `Ready when you are.`

## Context Strip Changes

The context strip should support the unified model without teaching different product categories.

### Titles

If an item came from `Open`, do not emphasize "workspace".

If an item came from `New`, do not emphasize "objective".

Prefer:
- item title
- branch/path info
- status/activity

### Empty strip

Change:
- `No objective selected`

To:
- `Nothing selected`

## State and Interaction Rules

## Selection priority

Selection should not always prefer opened items over new items.

Recommended priority:
1. currently active selection, if still present
2. running or recently active `New` item
3. most recently active `Open` item
4. newest updated item overall

This prevents active work from being hidden just because an opened item exists.

## Preserve user intent across setup

If the user starts with `Open` but must add a project first:
- return to `Open`

If the user starts with `New` but must add a project first:
- return to `New`

Project creation must not always bounce the user into the new-item flow.

## Loading and submit states

Both `New` and `Open` forms should:
- disable primary CTA while submitting
- show inline submitting text
- prevent duplicate submissions

Recommended button labels while pending:
- `Starting...`
- `Opening...`

## Visual Direction

### Keep

Keep the current overall orchestrator visual language:
- dark shell
- project-grouped sidebar
- inline sidebar forms

### Improve

Refine the top of the sidebar so the three top actions feel intentional:
- stronger separation from the project list
- better spacing between primary and secondary actions
- clearer form headers and helper copy

The widened sidebar should improve readability without changing the whole layout.

## Implementation Scope

## Files expected to change

Frontend:
- `cmux_harness/static/orchestrator.html`
- `cmux_harness/static/orchestrator.css`
- `cmux_harness/static/orchestrator.js`

Optional backend support:
- reuse existing picker endpoint for the `Open` flow if possible
- add a dedicated picker endpoint for open-path selection only if needed

## Required frontend changes

### `orchestrator.html`
- rename top buttons to `New` and `Open`
- add a dedicated `Open` button next to existing top actions

### `orchestrator.css`
- widen sidebar
- rebalance button hierarchy and spacing
- support any new open-form picker row styling
- ensure titles, paths, and metadata fit better at the new width

### `orchestrator.js`
- add a stable `Open` entry point
- make `New` always open the new-item flow
- rename form titles and CTAs
- add folder picker support to the open flow
- preserve originating intent when project creation interrupts a flow
- fix empty/waiting copy to support unified wording
- improve default selection priority

## Non-goals

Not in scope for this pass:
- making the sidebar resizable
- merging backend objective/workspace storage into one record type
- changing planner/review semantics
- redesigning the main chat timeline
- splitting the list into separate sections

## Acceptance Criteria

This work is complete when all of the following are true:

1. The sidebar top actions read `New`, `Open`, and `Add project`.
2. Clicking `New` always opens the new-item flow.
3. Clicking `Open` always opens the existing-work flow.
4. The unified project list remains a single mixed list under each project.
5. The `Open` flow includes a folder picker and manual path fallback.
6. Adding a project returns the user to the flow they started from.
7. The sidebar is visibly wider and item truncation is reduced.
8. Empty and waiting states no longer teach "objective" vs "workspace" as separate user concepts.

## Recommended Rollout Order

1. Fix button semantics and terminology.
2. Add explicit `Open` top-level action.
3. Widen the sidebar and tune item layout.
4. Add folder picker parity to `Open`.
5. Fix empty states, waiting copy, and intent-preserving transitions.
6. Tune selection priority after the UX language is stable.
