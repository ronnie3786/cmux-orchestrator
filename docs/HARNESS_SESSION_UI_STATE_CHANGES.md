# Harness Session UI State Changes

This note summarizes the `/harness` active/idle cleanup so the same behavior can be mirrored in the iOS app.

## Goal

The harness should show terminal sessions as stable workspace cards. It should not visually classify, group, collapse, reorder, or notify based on whether a Claude/Codex process appears active in the terminal.

## Removed Concepts

- No `Active` or `Idle` labels in the session card UI.
- No active/idle counters in the top bar.
- No gray status dot for neutral sessions.
- No small split-pane/surface symbol before the card title.
- No collapsed idle-card behavior.
- No card reordering or card rebuilds caused by `hasClaude` changing.
- No “session complete” notification based only on `hasClaude` flipping from true to false.

## Remaining Session States

The UI has only two meaningful visual states for a harness card:

- `Session`: normal neutral state.
- `Needs You`: attention state when the latest relevant harness log entry for that workspace contains a human-action signal.

In the web harness, this is represented by `classifyWs(w)` returning:

- `waiting` when the newest log entry for the workspace has an action containing `human`.
- `session` otherwise.

## Top Stats

The top-level harness stats now show:

- total session count
- sessions needing attention

They no longer show active, idle, or waiting as process-state buckets.

## Stable Ordering

Session ordering should be based on stable display identity only, such as:

- `surfaceLabel`
- `customName`
- `name`

Do not include active/idle/attention state in the sort key or structural identity. Attention state should update in place so the user’s card positions do not shift while the app refreshes.

## Backend/API Notes

The backend still exposes `hasClaude`, `sessionCost`, and session metadata. These can remain useful for cost display, review snapshots, or completion bookkeeping, but they should not drive the primary harness layout.

Screen polling now reads all visible workspaces uniformly. There is no separate idle-read behavior.

## Auto Mode

The per-session `Auto` toggle remains the source of truth. Auto mode is independent from active/idle process detection.

For iOS, keep Auto visible per session and show the auto-expiration countdown when `autoExpiresAt` is present. Do not add a global Auto toggle.

## iOS Implementation Checklist

- Replace active/idle badges with one neutral `Session` badge.
- Show `Needs You` only when the workspace attention classifier says it needs human input.
- Remove neutral status dots and process-state icons from cards.
- Remove active/idle counters from the main summary.
- Use total sessions plus needs-attention count in summaries.
- Keep cards fully expanded regardless of process state.
- Keep card ordering stable across refreshes.
- Do not trigger completion notifications from `hasClaude` transitions alone.
- Continue using `hasClaude` only for secondary metadata such as cost display if needed.
