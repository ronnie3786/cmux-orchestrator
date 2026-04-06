# Git Commit History Browser — Spec

## Overview

Make the commit list in the git panel interactive. Clicking a commit shows its changed files; clicking a file in that list shows the diff for that file at that specific commit. This enables reviewing historical diffs, not just the current working tree state.

## Current State

- The git panel already shows the last 3 commits (from `git log --oneline -3`) in the "Commits" section
- Commits render as `<div class="git-commit">` with `<span class="git-hash">` + message
- Commits are NOT clickable — they're display-only
- The diff overlay (`diffOverlay`) already supports viewing diffs for staged/unstaged/untracked files

## Requirements

### Backend: Two New API Routes

**1. `POST /api/git-commit-files`**
- Request: `{ "path": "<repo-path>", "hash": "<commit-hash>" }`
- Runs: `git diff-tree --no-commit-id --name-status -r <hash>` in the resolved repo path
- Response: `{ "ok": true, "files": [{"status": "M", "file": "src/app.py"}, {"status": "A", "file": "tests/new_test.py"}] }`
- Validate: `hash` must match `/^[0-9a-f]{4,40}$/i` (hex only, 4-40 chars) to prevent command injection
- Use `_resolve_git_path()` for path resolution
- Error if path or hash missing: 400

**2. `POST /api/git-commit-diff`**
- Request: `{ "path": "<repo-path>", "hash": "<commit-hash>", "file": "<file-path>" }`
- Runs: `git diff <hash>~1 <hash> -- <file>` (diff between parent and commit for that file)
- If the commit is the first commit (no parent), use: `git diff --no-index /dev/null <file>` or `git show <hash> -- <file>`
- Response: `{ "ok": true, "diff": "<diff-text>" }`
- Same hash validation as above
- Max diff size: 50KB (consistent with existing diff routes)
- Use `engine._run_git_command()` for execution

### Frontend: Interactive Commit List

**State additions (`orchestrator.js`):**
```javascript
gitExpandedCommit: null,    // hash of currently expanded commit, or null
gitCommitFiles: [],         // files changed in the expanded commit
gitCommitFilesLoading: false
```

**Behavior:**

1. **Clicking a commit** in the git panel:
   - If already expanded (same hash) → collapse it (set `gitExpandedCommit = null`)
   - If different commit → expand it: set `gitExpandedCommit = hash`, fetch files via `POST /api/git-commit-files`
   - Show a loading indicator while fetching
   - Render the file list inline below that commit row (inside the Commits section)

2. **File list rendering** (below expanded commit):
   - Each file shows status badge (M/A/D/R) + file name, styled similarly to staged/unstaged files
   - Status colors: A = green, D = red, M = yellow/orange, R = blue
   - The file list appears directly below the expanded commit, before the next commit

3. **Clicking a file** in the commit's file list:
   - Opens the diff overlay (reuse existing `diffOverlay`)
   - Fetches diff via `POST /api/git-commit-diff` with `{ path, hash, file }`
   - Renders using existing `renderDiffView()` function
   - Title shows: `<file> @ <short-hash>`
   - If it's a `.md` file, the Diff/Preview tabs should still appear (reuse the existing tab logic)

4. **Visual indicators:**
   - Add `cursor: pointer` to `.git-commit`
   - Expanded commit gets an `.expanded` class (slightly different background)
   - Small chevron or arrow indicator showing expanded/collapsed state

**renderGitPanel changes:**
- In the commits section, after rendering each commit div, if `state.gitExpandedCommit === commit.hash`, render the file list below it
- Add click handler on commit rows to toggle expansion
- Add click handler on commit file rows to open the diff overlay

### CSS additions

```css
.git-commit { cursor: pointer; }
.git-commit.expanded {
  background: rgba(255,255,255,.06);
}
.git-commit-chevron {
  display: inline-block;
  width: 12px;
  font-size: 9px;
  color: var(--t3);
  transition: transform 0.15s;
}
.git-commit.expanded .git-commit-chevron {
  transform: rotate(90deg);
}
.git-commit-files {
  padding: 2px 0 4px 18px;
}
.git-commit-file {
  font-size: 11px;
  font-family: 'JetBrains Mono','SF Mono',monospace;
  padding: 3px 4px;
  border-radius: 3px;
  cursor: pointer;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--t2);
}
.git-commit-file:hover { background: rgba(255,255,255,.04); color: var(--t1); }
.git-cf-status {
  display: inline-block;
  width: 16px;
  text-align: center;
  font-weight: 600;
  margin-right: 4px;
  font-size: 10px;
}
.git-cf-status.cf-A { color: var(--green); }
.git-cf-status.cf-D { color: #f87171; }
.git-cf-status.cf-M { color: #fbbf24; }
.git-cf-status.cf-R { color: var(--blue); }
```

### Increase commit count

In `engine.py`, change `git log --oneline -3` to `git log --oneline -10` so there are more commits to browse. Update the corresponding line in `_get_git_status_payload()`.

## Files to Modify

| File | Change |
|------|--------|
| `cmux_harness/server.py` | Add `POST /api/git-commit-files` and `POST /api/git-commit-diff` routes |
| `cmux_harness/engine.py` | Change commit log count from 3 to 10 |
| `cmux_harness/static/orchestrator.js` | Interactive commit expansion, file list, commit diff viewing |
| `cmux_harness/static/orchestrator.css` | Commit interaction styles |
| `tests/test_server.py` | Tests for both new endpoints |

## Constraints

- No external dependencies
- All existing tests (238) must continue to pass
- Reuse existing `renderDiffView()` and diff overlay for displaying commit diffs
- Reuse existing markdown preview tab logic for `.md` files in commit diffs
- Hash validation is mandatory (prevent injection via git command args)

## Branch

Work on branch `feature/sprint-contracts-evaluator` (current branch).
