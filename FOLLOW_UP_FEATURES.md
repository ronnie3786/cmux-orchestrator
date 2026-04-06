# Follow-Up Features (post sprint-contracts merge)

## 1. Worker Session Live Output Button
- Add a CTA button next to each running worker task in the task list
- Clicking it shows the current cmux terminal output for that worker's Claude Code session
- Lets the human see real-time status of where the worker is at without switching to the dashboard view

## 2. Git Commit History Browser
- In the git diff viewer, show a list of recent commits (not just current diff)
- Clicking a commit shows the file status (files changed) for that specific commit
- Clicking a file in that commit shows the git diff for that file at that commit
- Enables reviewing historical diffs, not just the latest state

## 3. Markdown Rendering in Diff Viewer
- For any `.md` file in the diff viewer, add a secondary tab
- Tab 1: Normal diff view (additions/deletions)
- Tab 2: Rendered markdown view showing the current version with full markdown formatting
- Only `.md` files get this secondary tab; other file types stay as-is
