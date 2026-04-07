# cmux orchestrator QA smoke test checklist

## Purpose
Use this checklist to validate the major orchestrator changes on the current `feature/sprint-contracts-evaluator` branch before continuing feature work.

## Branch scope covered
This checklist covers the major changes added since the branch diverged from `main`, including:

- high-level planner output
- sprint contract negotiation flow
- skeptical evaluator behavior
- two-tier evaluator flow
- worker live output viewer
- markdown preview in diff viewer
- git commit history browser
- projects backend foundation
- project-grouped sidebar
- project-first objective creation
- objective Files button opens VS Code worktree
- objective status summary
- Haiku-enriched status summary

---

## Recommended smoke-test order
If you want the shortest high-value pass, run these first:

1. Create a new project
2. Create a structured objective from that project
3. Walk through planner → contract review → execution
4. Open Status and verify Haiku summary
5. Open Files and verify it opens the objective worktree in VS Code
6. Open Git and commit history
7. Check worker live output
8. Run one direct-mode objective
9. Test markdown preview in diff
10. Verify edit/delete project behavior

---

## 1. Projects foundation

### Test
- [ ] Create a new project from a valid git repo path
- [ ] Verify the project appears in the sidebar
- [ ] Edit the project if that UI is available
- [ ] Delete a project with no objectives
- [ ] Attempt to delete a project that still has objectives and confirm it is blocked
- [ ] Verify multiple objectives can exist under one project

### Edge cases
- [ ] Duplicate project root is rejected
- [ ] Non-git path is rejected
- [ ] Existing legacy objectives still load and behave normally
- [ ] Unusual base branch names still work

---

## 2. Project-grouped sidebar

### Test
- [ ] Verify objectives are grouped under projects instead of shown as one flat list
- [ ] Expand and collapse a project row
- [ ] Verify the active objective auto-expands its project
- [ ] Use the project `+` button to start a new objective
- [ ] Verify the no-projects empty state if no projects exist
- [ ] Verify `New objective` routes correctly when no projects exist
- [ ] Verify sidebar still behaves reasonably on mobile/narrow width if applicable

### Edge cases
- [ ] Many projects render cleanly
- [ ] Many objectives under one project render cleanly
- [ ] Project with zero objectives still behaves correctly
- [ ] Switching active objective across projects updates sidebar state correctly

---

## 3. Project-first objective creation

### Test
- [ ] Create an objective from the global `New objective` button
- [ ] Create an objective from a project-row `+` button
- [ ] Verify project preselection works when launched from a project row
- [ ] Verify base branch defaults from the selected project
- [ ] Verify manual base branch override works
- [ ] Verify workflow mode toggle works:
  - [ ] Structured
  - [ ] Direct
- [ ] Verify created objective actually follows the chosen mode
- [ ] Verify Settings no longer shows `Default Project Directory`

### Edge cases
- [ ] No projects configured
- [ ] Unusual branch names
- [ ] Switching selected project mid-form updates default branch correctly
- [ ] Direct mode skips planning/evaluator as intended

---

## 4. Planner and sprint contract flow

### Test
- [ ] Create a new structured objective from scratch
- [ ] Verify planner output is high-level, focused on user stories/deliverables rather than micromanaged file paths
- [ ] Verify sprint contract review appears before worker execution
- [ ] Approve the contract and confirm execution starts
- [ ] Verify task sequencing still works after approval
- [ ] If possible, reject or revise a contract and confirm the flow behaves correctly

### Edge cases
- [ ] Tiny objective with minimal contract overhead
- [ ] Single-task objective
- [ ] Multi-task objective
- [ ] Objective with parallelizable tasks
- [ ] Cancel/abandon during contract review

---

## 5. Evaluator flow

### Test
- [ ] Run an objective that should pass build + evaluator cleanly
- [ ] Run one with a known flaw and verify evaluator catches it
- [ ] Verify evaluator failure feeds into rework correctly
- [ ] Verify review/rework cycle messaging is clear
- [ ] Verify contract-based grading appears sensible

### Edge cases
- [ ] Build passes, functional/evaluator step fails
- [ ] Build fails before next tier runs
- [ ] Repeated rework cycles
- [ ] Evaluator output is empty or malformed

---

## 6. Worker live output viewer

### Test
- [ ] Start a long-running objective
- [ ] Open the worker live output viewer while work is in progress
- [ ] Verify output updates correctly
- [ ] Switch away and back, confirm it still behaves correctly
- [ ] Verify completed worker output remains viewable
- [ ] Verify failed worker output is still inspectable

### Edge cases
- [ ] Worker has no output yet
- [ ] Worker exits very quickly
- [ ] Multiple workers active
- [ ] Stale/dead session

---

## 7. Git commit history browser

### Test
- [ ] Open commit history for the active objective/worktree
- [ ] Verify commits load in the correct order
- [ ] Open a commit and inspect details
- [ ] Switch between current work and history without UI weirdness
- [ ] Verify history works on a branch with multiple commits

### Edge cases
- [ ] Minimal history
- [ ] Odd branch state
- [ ] Large history
- [ ] Missing/invalid worktree path

---

## 8. Markdown preview in diff viewer

### Test
- [ ] Open a git diff for a `.md` file
- [ ] Switch between raw diff and markdown preview
- [ ] Verify headings, lists, code blocks, and links render correctly
- [ ] Verify non-markdown files do not show an incorrect markdown preview
- [ ] Verify long markdown files do not break layout

### Edge cases
- [ ] Malformed markdown
- [ ] Empty markdown file
- [ ] Deleted/renamed markdown file

---

## 9. Objective Files button behavior

### Test
- [ ] Click `Files` for the active objective
- [ ] Verify VS Code opens the objective worktree, not the project root
- [ ] Verify the Files button does not open a right-side browser panel
- [ ] Switch between `Status`, `Git`, and `Files` without UI weirdness

### Edge cases
- [ ] Worktree path missing or deleted
- [ ] VS Code app launch fails cleanly
- [ ] Objective has no active worktree yet

---

## 10. Objective status summary

### Test
- [ ] Click `Status` on the active objective
- [ ] Verify the status card renders in the main pane
- [ ] Verify refresh works
- [ ] Verify source label indicates Haiku vs fallback appropriately
- [ ] Verify summary reflects current objective state during:
  - [ ] Planning
  - [ ] Contract review
  - [ ] Executing
  - [ ] Reviewing
  - [ ] Failed
  - [ ] Completed
- [ ] Verify summary reflects approvals/reviews/git state sensibly

### Edge cases
- [ ] Objective with no tasks
- [ ] Pending approval
- [ ] Failed review with blockers
- [ ] Haiku unavailable or malformed response
- [ ] Clean repo vs dirty repo

---

## Biggest risk areas to watch closely
If something breaks, it is most likely to be in one of these areas:

1. **Project-first create flow**
   - project preselection
   - base branch defaults and overrides
   - direct vs structured behavior

2. **Project-grouped sidebar state**
   - expand/collapse behavior
   - active objective switching
   - empty state behavior

3. **Status summary**
   - stale signals
   - Haiku fallback behavior
   - inaccurate blocker detection

4. **File browser**
   - worktree-root assumptions
   - search behavior
   - preview behavior

5. **Evaluator / contract flow**
   - core orchestration sequence changed significantly
   - rework loop could regress in subtle ways

---

## Suggested QA notes section
Use this section while testing.

### Passed
- 
- 
- 

### Failed / buggy
- 
- 
- 

### Follow-up polish ideas
- 
- 
- 
