# Action Buttons Implementation Spec

## Overview

Add floating action buttons (FAB rail) to the orchestrator UI. Each button spawns a NEW Claude Code session in the objective's worktree, injects a saved prompt, and registers it as a task on the objective so the orchestrator maintains full visibility.

## Architecture

```
Click FAB → POST /api/objectives/{id}/action-inject
  → _create_worker_workspace(title, worktreePath)
  → _wait_for_repl(ws_uuid)
  → send_prompt_to_workspace(ws_uuid, prompt)
  → Register task on objective with source: "action-button"
  → Engine auto-monitors (approval, completion, review)
```

## Backend Changes

### 1. New API Endpoints in `server.py`

#### GET /api/objectives/{id}/action-buttons
Returns the action buttons for an objective.
- Response: `{ "buttons": [...] }`
- Buttons stored in `objective.json` under `"actionButtons"` key
- If no buttons defined, return default set (Build & Run)

#### POST /api/objectives/{id}/action-buttons
Create a new action button for an objective.
- Body: `{ "label": "Build & Run", "icon": "▶", "color": "#34d399", "prompt": "/exp-project-run" }`
- Generates UUID for `id`, appends to objective's `actionButtons` array
- Response: `{ "ok": true, "button": {...} }`

#### DELETE /api/objectives/{id}/action-buttons/{buttonId}
Remove an action button.
- Response: `{ "ok": true }`

#### POST /api/objectives/{id}/action-inject
Execute an action button — the main endpoint.
- Body: `{ "buttonId": "uuid", "prompt": "optional override" }`
  - If `buttonId` provided, look up the button's prompt from objective config
  - If `prompt` provided directly, use that instead (for ad-hoc injection)
- Flow:
  1. Read objective to get `worktreePath`
  2. Call `orchestrator._create_worker_workspace(title, worktreePath, objective_id, purpose="action-button")`
  3. Call `orchestrator._wait_for_repl(ws_uuid, objective_id=objective_id)`
  4. Call `cmux_api.send_prompt_to_workspace(ws_uuid, prompt)`
  5. Create task entry and add to objective's tasks array:
     ```json
     {
       "id": "action-{buttonLabel_slug}-{unix_timestamp}",
       "title": "{button.label}",
       "source": "action-button",
       "actionId": "{button.id}",
       "status": "executing",
       "workspaceId": "{ws_uuid}",
       "worktreePath": "{objective.worktreePath}",
       "startedAt": "ISO timestamp",
       "prompt": "{the prompt text}",
       "dependsOn": [],
       "files": [],
       "checkpoints": []
     }
     ```
  6. Response: `{ "ok": true, "taskId": "...", "workspaceId": "..." }`
- Error cases:
  - Objective not found → 404
  - Missing worktreePath → 400
  - Workspace creation failed → 500
  - REPL not ready → 500
  - Prompt delivery failed → 500

### 2. Orchestrator Changes (`orchestrator.py`)

The `_create_worker_workspace()` and `_wait_for_repl()` methods are already public enough to be called from the server route handler via `engine.orchestrator`. No changes needed to those methods.

The orchestrator's monitoring loop already picks up all workspaces. Action-button tasks with `"status": "executing"` and a `"workspaceId"` will be monitored automatically by the engine's polling loop.

**One addition needed:** In the orchestrator's `_build_orchestrator_context_prompt()`, action-button tasks already show up because it iterates all tasks. But add a note in the context about action-button tasks so the orchestrator chat session knows they exist and can report on them when asked.

### 3. Default Action Buttons

When an objective has no `actionButtons` key, the API should return these defaults:

```json
[
  {
    "id": "default-build-run",
    "label": "Build & Run",
    "icon": "▶",
    "color": "#34d399",
    "prompt": "/exp-project-run",
    "isDefault": true,
    "order": 0
  }
]
```

## Frontend Changes (`orchestrator.html`)

### 4. FAB Rail Component

Add a floating button rail to the right side of the main content area (not inside the sidebar, not inside the chat panel — in the main orchestrator view when an objective is selected).

#### HTML Structure
```html
<div class="fab-rail" id="fabRail">
  <!-- Buttons rendered dynamically -->
  <button class="fab-btn" data-button-id="..." style="background:...;" title="Build & Run">▶</button>
  <button class="fab-btn" data-button-id="..." style="background:...;" title="Run Tests">🧪</button>
  <!-- Add button always at bottom -->
  <button class="fab-btn fab-add" id="fabAdd" title="Add Action...">+</button>
</div>
```

#### CSS
```css
.fab-rail {
  position: fixed;
  right: 20px;
  top: 50%;
  transform: translateY(-50%);
  display: flex;
  flex-direction: column;
  gap: 10px;
  z-index: 200;
}
.fab-btn {
  width: 48px;
  height: 48px;
  border-radius: 14px;
  border: none;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 18px;
  cursor: pointer;
  box-shadow: 0 2px 12px rgba(0,0,0,.4);
  transition: transform .15s, box-shadow .15s;
  color: #000;
  position: relative;
}
.fab-btn:hover {
  transform: scale(1.08);
  box-shadow: 0 4px 16px rgba(0,0,0,.5);
}
.fab-btn:active { transform: scale(0.95); }
.fab-add {
  background: var(--raised);
  border: 2px dashed var(--b2);
  color: var(--t2);
  font-size: 22px;
}
/* Tooltip on hover */
.fab-btn::after {
  content: attr(title);
  position: absolute;
  right: 56px;
  top: 50%;
  transform: translateY(-50%);
  background: var(--raised);
  border: 1px solid var(--b2);
  padding: 4px 10px;
  border-radius: 6px;
  font-size: 12px;
  white-space: nowrap;
  color: var(--t1);
  opacity: 0;
  pointer-events: none;
  transition: opacity .15s;
  font-family: 'Inter', sans-serif;
}
.fab-btn:hover::after { opacity: 1; }
```

**Important:** Only show the FAB rail when an objective is selected/active. Hide it when on the objective list view or when no objective exists.

### 5. Add Action Modal

When clicking the "+" FAB button, show a small modal/popup:

```html
<div class="fab-modal" id="fabModal">
  <div class="fab-modal-content">
    <h3>Add Action Button</h3>
    <label>Label</label>
    <input type="text" id="fabLabel" placeholder="e.g. Run Tests" />
    <label>Prompt</label>
    <textarea id="fabPrompt" placeholder="e.g. Run the test suite and report failures" rows="3"></textarea>
    <label>Icon (emoji)</label>
    <input type="text" id="fabIcon" placeholder="🧪" maxlength="4" />
    <label>Color</label>
    <input type="color" id="fabColor" value="#4f8ef7" />
    <div class="fab-modal-actions">
      <button id="fabCancel">Cancel</button>
      <button id="fabSave" class="primary">Save</button>
    </div>
  </div>
</div>
```

Style it consistently with the existing orchestrator UI (dark theme, Inter font, same border/surface colors).

### 6. JavaScript Logic

```javascript
// Fetch and render action buttons when objective is loaded
async function loadActionButtons(objectiveId) {
  const res = await fetch(`/api/objectives/${objectiveId}/action-buttons`);
  const data = await res.json();
  renderFabRail(data.buttons || []);
}

// Render FAB rail
function renderFabRail(buttons) {
  const rail = document.getElementById('fabRail');
  rail.innerHTML = '';
  buttons.forEach(btn => {
    const el = document.createElement('button');
    el.className = 'fab-btn';
    el.dataset.buttonId = btn.id;
    el.style.background = btn.color;
    el.title = btn.label;
    el.textContent = btn.icon;
    el.onclick = () => executeAction(btn);
    rail.appendChild(el);
  });
  // Add button
  const addBtn = document.createElement('button');
  addBtn.className = 'fab-btn fab-add';
  addBtn.title = 'Add Action...';
  addBtn.textContent = '+';
  addBtn.onclick = () => showAddModal();
  rail.appendChild(addBtn);
}

// Execute action button
async function executeAction(btn) {
  const objectiveId = getCurrentObjectiveId(); // get from current state
  const res = await fetch(`/api/objectives/${objectiveId}/action-inject`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ buttonId: btn.id }),
  });
  const data = await res.json();
  if (data.ok) {
    // Show brief success indicator on the button (pulse green)
    // Refresh task list to show new action-button task
  } else {
    // Show error toast
  }
}

// Save new action button
async function saveActionButton() {
  const objectiveId = getCurrentObjectiveId();
  const res = await fetch(`/api/objectives/${objectiveId}/action-buttons`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      label: document.getElementById('fabLabel').value,
      prompt: document.getElementById('fabPrompt').value,
      icon: document.getElementById('fabIcon').value || '⚡',
      color: document.getElementById('fabColor').value,
    }),
  });
  if ((await res.json()).ok) {
    hideAddModal();
    loadActionButtons(objectiveId);
  }
}
```

### 7. Button Click Feedback

When a FAB is clicked:
1. Button briefly pulses/animates to confirm click
2. A small toast appears: "Spawning Build & Run session..."
3. When the task appears in the task list, it shows with a 🔘 icon indicating it's an action-button task (vs 📋 for planned tasks)
4. If spawn fails, show error toast

### 8. Integration with Existing Task Cards

Action-button tasks should appear in the objective's task list alongside planned tasks. They should be visually distinguishable:
- Show the action button icon instead of a task number
- Label shows "Action: Build & Run" or similar
- Same status badges (executing, completed, failed)
- Same screen preview on hover/click
- Same review results display

## File Changes Summary

| File | Changes |
|------|---------|
| `server.py` | Add 4 new API routes (GET/POST action-buttons, DELETE action-button, POST action-inject) |
| `orchestrator.py` | Minor: update context prompt to mention action-button tasks |
| `objectives.py` | No changes needed (existing update_objective handles new keys) |
| `orchestrator.html` | Add FAB rail, add action modal, JS for button CRUD + execution |

## Testing

After implementation:
1. Create an objective with a project dir
2. Verify default "Build & Run" button appears in FAB rail
3. Click "+" to add a custom action button — verify it persists
4. Click an action button — verify:
   - New cmux workspace appears
   - Claude Code launches in the worktree
   - Prompt is injected
   - Task appears in objective's task list with `source: "action-button"`
   - Engine monitors the session (auto-approval works)
5. Ask orchestrator chat "how's the build going?" — verify it can read the action-button task's screen
6. Delete a custom action button — verify it's removed
