# cmux Harness — Roadmap

## Immediate Next (v3.1)

### 1. Fix diff capture for committed work
**Problem:** `git diff` only shows uncommitted changes. If Claude Code commits mid-session, the diff is empty and the reviewer sees "no code changes" even though files were modified.

**Fix:** Capture the HEAD commit hash when a session starts (`git rev-parse HEAD`). At completion, diff between the saved hash and current HEAD: `git diff <start-hash> HEAD`. This captures everything the session touched regardless of whether Claude committed along the way.

**Where:** `_capture_completion_snapshot_async()` needs to record the starting commit hash in the workspace state. `_capture_completion_snapshot()` needs to use it for the diff command.

### 2. Verify review file persistence
The `~/.cmux-harness/reviews/` directory should contain JSON files for every completed session. Confirm these are being written correctly on the work machine. If not, debug the file path or permissions issue.

### 3. Git log context for committed work
When there's no uncommitted diff but there ARE new commits since session start, include `git log --oneline <start-hash>..HEAD` and `git diff --stat <start-hash> HEAD` in the review context. The reviewer should see what was committed, not just what's uncommitted.

---

## Recently Shipped

### Action Buttons / FAB Rail (v3.2, 2026-04-04)
- [x] Per-objective custom action buttons (CRUD API + UI)
- [x] FAB rail on right side of orchestrator with "Add Action" modal
- [x] Click-to-launch: spawns new Claude Code session in worktree, injects prompt
- [x] Tasks registered on objective with `source: "action-button"`, visible in task list
- [x] Default "Build & Run" button with `/exp-project-run` prompt
- [x] Orchestrator context updated to know about action-button tasks

### Build Log Viewer (v3.2, 2026-04-04)
- [x] `GET /api/objectives/{id}/build-log` endpoint (tails with deque, handles 2.4MB+ files)
- [x] Bottom slide-out panel with monospace terminal display
- [x] Auto-refresh toggle (3s polling, off by default)
- [x] File switcher (build.log / prebuild.log)
- [x] Smart scroll (auto-pin + "New output" badge)

## Open TODOs

- [ ] **Scheduled task execution** — Submit a preset prompt scheduled for a future time. At the scheduled time, the harness opens a cmux session, launches Claude Code, and injects the prompt automatically. Primary use case: scheduling failed Waldo test reruns overnight or at off-peak times without manual intervention.
- [ ] Filter/sort controls in Command Center (show only active, only needs-you)
- [ ] "Pause for 5 minutes" button
- [ ] Favicon for tab identification *(low priority)*
- [ ] Mobile-responsive layout *(low priority)*
- [ ] Allow "soft" dependencies (context sharing without hard blocking)
- [ ] Fix worker scope creep (tighter worker prompts)
- [ ] Review calibration (softer review for intermediate tasks)
- [ ] Build/test gate (`swift build` / `swift test` as real signal after worker completion)

---

## Long-Term Vision: The Orchestrator

The harness evolves from a tool you operate into an autonomous tech lead that manages your coding sessions. You become the CEO; it becomes the PM.

### Current State
```
You (developer)
  → manually open sessions
  → manually assign tasks
  → check terminals
  → read reviews
  → decide what's next
```

### Target State
```
You (CEO)
  ↕ decisions + briefings
Orchestrator (Tech Lead / PM)
  ↕ plans + reviews + coordination
Session Manager (current harness)
  ↕ auto-approve + monitoring
Claude Code Sessions (workers)
```

### Layer 1: Session Intelligence

The reviewer becomes context-aware across sessions, not just within one.

- **Session planning.** Before a session starts, the orchestrator reads the ticket/issue, breaks it into steps, and writes a plan. When the session ends, it compares plan vs actual. "You asked for auth refactoring. Claude refactored 3/5 files. 2 remaining."
- **Cross-session memory.** If Session A worked on the auth module and Session B is about to touch the same files, the orchestrator flags the overlap and potential merge conflicts.
- **Commit quality gate.** After completion, the orchestrator runs `swift build` or `swift test` automatically. Did it compile? Did tests pass? That's real signal beyond LLM opinion. Pass/fail gets added to the review card.

### Layer 2: Task Management (the PM brain)

The orchestrator becomes proactive instead of reactive.

- **Work queue.** Feed it a backlog (GitHub issues, a spec, a TODO list). It prioritizes, sequences, and assigns tasks to sessions. You approve the plan, it executes.
- **Session spawning.** Instead of you opening a cmux tab and typing `claude`, the orchestrator creates the session, writes the prompt with full context, and launches Claude Code. You just approve the plan.
- **Multi-session coordination.** Three sessions running in parallel on different features. The orchestrator tracks dependencies, prevents file conflicts, and knows which session to check on first.
- **Handoff detection.** Claude Code hits a wall or makes a questionable decision. The orchestrator detects this from terminal output patterns or stalled progress and either restarts with better context or escalates to you with a specific question, not "something went wrong."

### Layer 3: CEO Dashboard

You stop looking at terminals and start looking at outcomes.

- **Daily briefing.** "Today: 4 sessions completed, 12 files changed, 2 PRs ready for review, 1 session needs your input on an architecture decision."
- **Decision queue.** A feed of decisions that need a human. "Session 3 wants to refactor the auth module into 3 files. Approve / Reject / Modify." You tap approve, the orchestrator tells the session to proceed.
- **PR pipeline.** Reviews that pass quality gates auto-create draft PRs. You see a list of PRs with the orchestrator's assessment. One-click merge.
- **Cost and velocity tracking.** Session costs, throughput, ROI per session. You're managing budget and output, not code.

### Layer 4: Learning Loop

The orchestrator gets smarter over time.

- **Pattern recognition.** "Sessions in this repo take 2x longer when they touch the database layer. Consider breaking DB tasks into smaller chunks."
- **Prompt refinement.** Track which session prompts lead to good vs bad outcomes. Auto-improve the prompts it writes.
- **Preference learning.** Learn what you approve, reject, and modify. Over time, fewer decisions need to bubble up.

---

## Build Order (suggested)

1. **v3.1** — Diff capture fix + review persistence (immediate pain points)
2. **v3.2** — Session planning + plan-vs-actual reviews (Layer 1 start)
3. **v3.3** — Build/test quality gate after completion (Layer 1)
4. **v4.0** — Work queue + session spawning (Layer 2, the big shift)
5. **v4.1** — Multi-session coordination + conflict detection (Layer 2)
6. **v5.0** — CEO dashboard + decision queue (Layer 3)
7. **v5.1** — Cost/velocity analytics (Layer 3)
8. Ongoing — Learning loop (Layer 4, builds naturally as usage grows)
