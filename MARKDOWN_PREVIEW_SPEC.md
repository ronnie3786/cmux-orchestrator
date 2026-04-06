# Markdown Preview in Diff Viewer — Spec

## Overview

Add a secondary "Preview" tab to the diff overlay for `.md` files. When viewing a diff for any Markdown file, the user can toggle between the normal diff view and a rendered Markdown preview of the current file content.

## Requirements

### Backend: New API Route

Add a new POST endpoint in `server.py`:

**`POST /api/file-content`**
- Request body: `{ "path": "<git-repo-path>", "file": "<relative-file-path>" }`
- Reads the raw file content from disk (`os.path.join(resolved_path, file)`)
- Response: `{ "ok": true, "content": "<file-content-string>" }`
- Error: `{ "ok": false, "error": "<message>" }` with appropriate status code
- Use `_resolve_git_path()` for path resolution (same as git-diff-path)
- Max file size: 500KB (return error if larger)
- Security: validate that `file` doesn't escape the repo root (no `..` traversal)

### Frontend: Tab Toggle in Diff Panel

**HTML changes (`orchestrator.html`):**
- Add a tab bar inside `.diff-panel-header`, between the title and close button
- Two tabs: "Diff" (default, active) and "Preview" (only visible for `.md` files)
- Tab bar HTML structure:
```html
<div class="diff-tabs" id="diffTabs" style="display:none">
  <button class="diff-tab active" data-tab="diff">Diff</button>
  <button class="diff-tab" data-tab="preview">Preview</button>
</div>
```

**JS changes (`orchestrator.js`):**

1. In `openGitDiff()`:
   - After setting `diffPanelTitle`, check if `file` ends with `.md` (case-insensitive)
   - If yes: show `#diffTabs` (`display: flex`), set active tab to "diff"
   - If no: hide `#diffTabs` (`display: none`)

2. New function `switchDiffTab(tab)`:
   - If `tab === 'diff'`: show the existing diff content (already loaded)
   - If `tab === 'preview'`: fetch raw file content via `POST /api/file-content`, render as HTML
   - Update active tab styling
   - Cache both the diff HTML and preview HTML so switching tabs doesn't re-fetch

3. Markdown rendering:
   - Use a simple, lightweight markdown-to-HTML converter — implement inline (no external library)
   - Must support: headings (#-######), bold (**), italic (*), inline code (`), code blocks (```), unordered lists (- or *), ordered lists (1.), links [text](url), horizontal rules (---), blockquotes (>), tables (|)
   - Render into `diffPanelBody` with a wrapper: `<div class="md-preview">...</div>`

4. In `closeDiffOverlay()`:
   - Clear any cached preview content
   - Reset tab state

**CSS changes (`orchestrator.css`):**

```css
/* Tab bar */
.diff-tabs {
  display: flex;
  gap: 2px;
  margin-left: 16px;
}
.diff-tab {
  padding: 4px 12px;
  border: none;
  background: transparent;
  color: rgba(255,255,255,.5);
  font-size: 13px;
  cursor: pointer;
  border-radius: 4px;
}
.diff-tab:hover { color: rgba(255,255,255,.75); }
.diff-tab.active {
  background: rgba(255,255,255,.1);
  color: #fff;
}

/* Markdown preview */
.md-preview {
  padding: 20px 24px;
  font-size: 14px;
  line-height: 1.7;
  color: rgba(255,255,255,.85);
}
.md-preview h1, .md-preview h2, .md-preview h3,
.md-preview h4, .md-preview h5, .md-preview h6 {
  color: #fff;
  margin: 1.2em 0 0.4em;
}
.md-preview h1 { font-size: 1.6em; border-bottom: 1px solid rgba(255,255,255,.1); padding-bottom: 6px; }
.md-preview h2 { font-size: 1.3em; border-bottom: 1px solid rgba(255,255,255,.08); padding-bottom: 4px; }
.md-preview h3 { font-size: 1.1em; }
.md-preview code {
  background: rgba(255,255,255,.08);
  padding: 2px 6px;
  border-radius: 3px;
  font-size: 0.9em;
}
.md-preview pre {
  background: rgba(0,0,0,.3);
  padding: 14px 18px;
  border-radius: 6px;
  overflow-x: auto;
  margin: 12px 0;
}
.md-preview pre code {
  background: none;
  padding: 0;
}
.md-preview blockquote {
  border-left: 3px solid rgba(79,142,247,.5);
  margin: 12px 0;
  padding: 4px 16px;
  color: rgba(255,255,255,.65);
}
.md-preview table {
  border-collapse: collapse;
  margin: 12px 0;
  width: 100%;
}
.md-preview th, .md-preview td {
  border: 1px solid rgba(255,255,255,.12);
  padding: 8px 12px;
  text-align: left;
}
.md-preview th {
  background: rgba(255,255,255,.06);
  font-weight: 600;
}
.md-preview a { color: var(--blue, #4f8ef7); }
.md-preview hr { border: none; border-top: 1px solid rgba(255,255,255,.1); margin: 16px 0; }
.md-preview ul, .md-preview ol { padding-left: 24px; margin: 8px 0; }
.md-preview li { margin: 4px 0; }
.md-preview img { max-width: 100%; border-radius: 4px; }
```

## Files to Modify

| File | Change |
|------|--------|
| `cmux_harness/server.py` | Add `POST /api/file-content` route |
| `cmux_harness/static/orchestrator.html` | Add diff tab bar HTML |
| `cmux_harness/static/orchestrator.js` | Tab switching logic, markdown renderer, file content fetch |
| `cmux_harness/static/orchestrator.css` | Tab bar + markdown preview styles |
| `tests/test_server.py` | Tests for `/api/file-content` endpoint |

## Constraints

- No external dependencies (no marked.js, no showdown). Implement a simple inline markdown parser.
- All existing tests (234) must continue to pass.
- The diff view must remain the default tab. Preview is secondary.
- Tab bar only appears for `.md` files. Non-markdown files show no tabs.
- Preview fetches the CURRENT file content from disk (not from the diff).

## Branch

Work on branch `feature/sprint-contracts-evaluator` (current branch).
