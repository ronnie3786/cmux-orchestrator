const state = {
  commandCenter: null,
  briefing: null,
  projects: [],
  activeView: 'command',
  search: '',
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.ok === false) {
    throw new Error(payload.error || `Request failed: ${response.status}`);
  }
  return payload;
}

function toast(message) {
  const element = $('#toast');
  element.textContent = message;
  element.classList.add('show');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.classList.remove('show'), 2200);
}

function setView(view) {
  state.activeView = view;
  $$('.view').forEach((element) => element.classList.toggle('active', element.id === `view-${view}`));
  $$('.nav button').forEach((button) => button.classList.toggle('active', button.dataset.view === view));
  $('#pageTitle').textContent = {
    command: 'Command Center',
    ideas: 'Ideas + Assigned Jira',
    decisions: 'Decision Queue',
    briefing: 'Briefing',
  }[view] || 'Workflow Orchestrator';
}

function badgeHtml(badges = []) {
  const visible = badges.length ? badges : [];
  if (!visible.length) return '';
  return `<div class="badges">${visible.map((badge) => `<span class="badge ${escapeHtml(badge.severity || 'info')}">${escapeHtml(badge.label)}</span>`).join('')}</div>`;
}

function cardMatches(card) {
  if (!state.search) return true;
  const text = [card.title, card.summary, card.status, card.type, ...(card.contextHealth?.badges || []).map((b) => b.label)].join(' ').toLowerCase();
  return text.includes(state.search.toLowerCase());
}

function renderSidebar() {
  const data = state.commandCenter || {};
  const ideas = data.ideas || [];
  const jira = data.assignedJira?.tickets || [];
  $('#sidebarIdeas').innerHTML = ideas.slice(0, 4).map((idea) => `
    <button class="side-item" data-view-target="ideas">
      <strong>${escapeHtml(idea.title)}</strong>
      <span>${escapeHtml(idea.status || 'inbox')}</span>
    </button>
  `).join('') || '<div class="empty">No ideas yet.</div>';

  $('#sidebarJira').innerHTML = jira.slice(0, 5).map((ticket) => `
    <a class="side-item" href="${escapeHtml(ticket.url || '#')}" target="_blank" rel="noreferrer">
      <strong>${escapeHtml(ticket.key)} ${escapeHtml(ticket.title)}</strong>
      <span>${escapeHtml(ticket.status || ticket.issueType || 'Assigned')}</span>
    </a>
  `).join('') || `<div class="empty">${escapeHtml(data.assignedJira?.error || 'No assigned Jira tickets returned.')}</div>`;

  $$('#sidebarIdeas [data-view-target]').forEach((element) => element.addEventListener('click', () => setView('ideas')));
}

function renderHero() {
  const top = state.commandCenter?.topPriority || {};
  $('#topTitle').textContent = top.title || 'Nothing urgent needs Ronnie right now.';
  $('#topSummary').textContent = top.summary || 'The orchestrator is watching active work.';
  $('#heroNeeds').textContent = state.commandCenter?.summary?.needsRonnie ?? 0;
  $('#topActionButton').textContent = topActionLabel(top);
}

function topActionLabel(top = {}) {
  if (top.recommendedAction === 'review_decision') return 'Review decision';
  if (top.recommendedAction === 'review_context') return 'Clear context';
  if ((state.commandCenter?.summary?.ideas || 0) > 0) return 'Groom idea';
  if ((state.commandCenter?.summary?.assignedJira || 0) > 0) return 'Review Jira';
  return 'Open board';
}

function goToTopAction() {
  const top = state.commandCenter?.topPriority || {};
  if (top.recommendedAction === 'review_decision') return setView('decisions');
  if (top.recommendedAction === 'review_context') return setView('command');
  if ((state.commandCenter?.summary?.ideas || 0) > 0) return setView('ideas');
  if ((state.commandCenter?.summary?.assignedJira || 0) > 0) return setView('ideas');
  return setView('command');
}

function renderMetrics() {
  const summary = state.commandCenter?.summary || {};
  const metrics = [
    ['Watched', summary.objectivesWatched || 0],
    ['Sessions', summary.activeSessions || 0],
    ['Needs Ronnie', summary.needsRonnie || 0],
    ['Review-ready', summary.reviewReady || 0],
    ['Ideas', summary.ideas || 0],
    ['Assigned Jira', summary.assignedJira || 0],
  ];
  $('#metrics').innerHTML = metrics.map(([label, value]) => `
    <div class="metric"><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></div>
  `).join('');
  $('#needsCount').textContent = summary.needsRonnie || 0;
  $('#ideasCount').textContent = (summary.ideas || 0) + (summary.assignedJira || 0);
  $('#decisionCount').textContent = state.commandCenter?.decisions?.length || 0;
}


function renderFlowProof() {
  const flow = state.commandCenter?.flowProof || {};
  const steps = flow.steps || [];
  const percent = Math.max(0, Math.min(100, Number(flow.progressPercent || 0)));
  $('#flowProof').innerHTML = `
    <div>
      <p class="eyebrow">End-to-end proof</p>
      <h3>${escapeHtml(flow.title || 'No proof flow started yet.')}</h3>
      <p>${escapeHtml(flow.summary || 'Capture an idea, clear context, launch an objective, review it, then mark it done.')}</p>
    </div>
    <div class="flow-meter" aria-label="${escapeHtml(percent)} percent complete">
      <strong>${escapeHtml(percent)}%</strong>
      <span>${escapeHtml((flow.currentStage || 'intake').replaceAll('_', ' '))}</span>
    </div>
    <ol class="flow-steps">
      ${steps.map((step) => `<li class="${escapeHtml(step.state || 'waiting')}"><span>${escapeHtml(step.label)}</span></li>`).join('')}
    </ol>
  `;
}

function renderBoard() {
  const lanes = state.commandCenter?.lanes || [];
  $('#board').innerHTML = lanes.map((lane) => {
    const cards = (lane.cards || []).filter(cardMatches);
    return `
      <section class="lane">
        <div class="lane-title">${escapeHtml(lane.title)} <span>${cards.length}</span></div>
        ${cards.map((card) => renderWorkCard(card)).join('') || '<div class="empty">Nothing here.</div>'}
      </section>
    `;
  }).join('');
  $$('[data-launch-preflight]').forEach((button) => {
    button.addEventListener('click', () => launchPreflightObjective(button.dataset));
  });
  $$('[data-preflight-context]').forEach((button) => {
    button.addEventListener('click', () => updatePreflightContext(button.dataset));
  });
  $$('[data-objective-status]').forEach((button) => {
    button.addEventListener('click', () => updateObjectiveStatus(button.dataset));
  });
  $$('[data-objective-checkin]').forEach((button) => {
    button.addEventListener('click', () => checkObjective(button.dataset.objectiveCheckin));
  });
}

function projectOptionsHtml(selectedPath = '') {
  const projects = state.projects || [];
  if (!projects.length) return '';
  return projects.map((project) => {
    const root = project.rootPath || '';
    const selected = selectedPath && root === selectedPath ? ' selected' : '';
    return `<option value="${escapeHtml(root)}" data-branch="${escapeHtml(project.defaultBaseBranch || 'main')}"${selected}>${escapeHtml(project.name || root)}</option>`;
  }).join('');
}

function renderPreflightLaunchControl(card, blockingMissing) {
  if (card.objectiveId) {
    const detailUrl = card.launchSummary?.detailUrl || `/api/objectives/${encodeURIComponent(card.objectiveId)}`;
    return `<a class="mini-link" href="${escapeHtml(detailUrl)}" target="_blank" rel="noreferrer">Open objective data</a>`;
  }
  if (blockingMissing.length) return `<button class="mini-button muted" disabled>Resolve context first</button>`;
  const projects = state.projects || [];
  const selectedProjectDir = card.projectDir || (projects[0]?.rootPath || '');
  if (!selectedProjectDir) return `<button class="mini-button muted" disabled>Add project first</button>`;
  return `
    <label class="mini-select-label">Repo
      <select class="mini-select" data-project-for="${escapeHtml(card.id)}">
        ${projectOptionsHtml(selectedProjectDir)}
      </select>
    </label>
    <button class="mini-button primary" data-launch-preflight="${escapeHtml(card.id)}" data-goal="${escapeHtml(card.goal || card.title)}" data-project-dir="${escapeHtml(selectedProjectDir)}" data-base-branch="${escapeHtml(card.baseBranch || projects[0]?.defaultBaseBranch || 'main')}">${card.launchReady ? 'Launch objective' : 'Use repo & launch'}</button>
  `;
}

function renderLaunchPlan(card) {
  const plan = card.launchPlan || {};
  const steps = Array.isArray(plan.steps) ? plan.steps : [];
  const context = Array.isArray(plan.context) ? plan.context : [];
  if (!steps.length && !context.length) return '';
  const stepHtml = steps.map((step) => `
    <li class="launch-step ${escapeHtml(step.state || 'waiting')}">
      <span>${escapeHtml(step.label)}</span>
      <strong>${escapeHtml(step.state || 'waiting')}</strong>
    </li>
  `).join('');
  const contextHtml = context.map((item) => {
    const canResolve = item.required && !item.ready && !card.objectiveId;
    return `
      <li class="context-row ${item.ready ? 'ready' : 'needs-work'}">
        <span>${escapeHtml(item.label)} <em>${escapeHtml(item.state)}</em></span>
        ${canResolve ? `<button class="mini-button tiny" data-preflight-context="${escapeHtml(card.id)}" data-context-id="${escapeHtml(item.id)}" data-context-state="resolved">Mark resolved</button>` : ''}
      </li>
    `;
  }).join('');
  return `
    <div class="launch-cockpit">
      <div class="cockpit-head"><strong>Launch cockpit</strong><span>${escapeHtml(plan.nextAction || '')}</span></div>
      ${stepHtml ? `<ol class="launch-steps">${stepHtml}</ol>` : ''}
      ${contextHtml ? `<ul class="context-checklist">${contextHtml}</ul>` : ''}
    </div>
  `;
}

function renderLaunchSummary(card) {
  const summary = card.launchSummary || {};
  if (!card.objectiveId || !Object.keys(summary).length) return '';
  const rows = [
    ['Objective', summary.objectiveId || card.objectiveId],
    ['Status', summary.status],
    ['Branch', summary.branchName],
    ['Next', summary.nextAction],
    ['Worktree', summary.worktreePath],
  ].filter(([, value]) => value);
  if (!rows.length) return '';
  return `<dl class="launch-summary">${rows.map(([label, value]) => `
    <div><dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd></div>
  `).join('')}</dl>`;
}

function renderWorkCard(card) {
  if (card.type === 'preflight') {
    const missing = card.missingRequirements || [];
    const blockingMissing = missing.filter((item) => item.id !== 'project');
    const launchButton = renderPreflightLaunchControl(card, blockingMissing);
    const readyCopy = card.objectiveId ? '<p class="ready-copy">Objective launched and being tracked.</p>' : '<p class="ready-copy">Ready to become an objective.</p>';
    return `
      <article class="work-card">
        <strong>${escapeHtml(card.title)}</strong>
        <p>${escapeHtml(card.summary || 'Context pre-flight')}</p>
        ${badgeHtml(card.contextHealth?.badges || [])}
        ${missing.length ? `<ul class="missing-list">${missing.map((item) => `<li>${escapeHtml(item.label)}: ${escapeHtml(item.reason || 'needed')}</li>`).join('')}</ul>` : readyCopy}
        ${renderLaunchPlan(card)}
        ${renderLaunchSummary(card)}
        <span class="status-chip">${escapeHtml(card.status || 'gathering_context')}</span>
        <div class="card-actions compact">
          ${launchButton}
          ${card.sourceUrl ? `<a class="mini-link" href="${escapeHtml(card.sourceUrl)}" target="_blank" rel="noreferrer">Source</a>` : ''}
        </div>
      </article>
    `;
  }
  if (card.type === 'objective') {
    const summary = card.launchSummary || {};
    return `
      <article class="work-card objective-card">
        <strong>${escapeHtml(card.title)}</strong>
        <p>${escapeHtml(card.summary || 'Objective created.')}</p>
        ${badgeHtml(card.contextHealth?.badges || [])}
        ${summary.branchName || summary.nextAction ? `<dl class="launch-summary">
          ${summary.status ? `<div><dt>Status</dt><dd>${escapeHtml(summary.status)}</dd></div>` : ''}
          ${summary.branchName ? `<div><dt>Branch</dt><dd>${escapeHtml(summary.branchName)}</dd></div>` : ''}
          ${summary.nextAction ? `<div><dt>Next</dt><dd>${escapeHtml(summary.nextAction)}</dd></div>` : ''}
        </dl>` : ''}
        <span class="status-chip">${escapeHtml(card.status || 'objective')}</span>
        <div class="card-actions compact">
          <button class="mini-button" data-objective-checkin="${escapeHtml(card.id)}">Check objective</button>
          ${card.status === 'review' ? `<button class="mini-button primary" data-objective-status="completed" data-summary="Reviewed and accepted from the web handoff." data-id="${escapeHtml(card.id)}">Accept complete</button>` : ''}
          ${['review', 'completed', 'done', 'accepted'].includes(card.status) ? '' : `<button class="mini-button primary" data-objective-status="review" data-summary="Ready for Ronnie to inspect." data-id="${escapeHtml(card.id)}">Mark review-ready</button>`}
          <a class="mini-link" href="/api/objectives/${encodeURIComponent(card.id)}" target="_blank" rel="noreferrer">Open objective data</a>
          ${card.sourcePreflightId ? `<span class="mini-pill">From pre-flight</span>` : ''}
        </div>
      </article>
    `;
  }
  const href = card.url ? ` href="${escapeHtml(card.url)}" target="_blank" rel="noreferrer"` : '';
  const tag = card.url ? 'a' : 'button';
  return `
    <${tag} class="work-card"${href}>
      <strong>${escapeHtml(card.title)}</strong>
      <p>${escapeHtml(card.summary || 'No summary yet.')}</p>
      ${badgeHtml(card.contextHealth?.badges || [])}
      <span class="status-chip">${escapeHtml(card.status || card.type || 'watching')}</span>
    </${tag}>
  `;
}

function renderIdeas() {
  const ideas = state.commandCenter?.ideas || [];
  const jira = state.commandCenter?.assignedJira?.tickets || [];
  $('#ideasList').innerHTML = ideas.map((idea) => `
    <article class="work-card">
      <strong>${escapeHtml(idea.title)}</strong>
      <p>${escapeHtml(idea.summary || 'No notes yet.')}</p>
      <span class="status-chip">${escapeHtml(idea.status || 'inbox')}</span>
      <div class="card-actions compact">
        <button class="mini-button" data-idea-status="brainstorming" data-id="${escapeHtml(idea.id)}">Brainstorm</button>
        <button class="mini-button" data-idea-status="researching" data-id="${escapeHtml(idea.id)}">Research</button>
        <button class="mini-button primary" data-preflight-source="idea" data-id="${escapeHtml(idea.id)}" data-title="${escapeHtml(idea.title)}" data-summary="${escapeHtml(idea.summary || '')}">Start pre-flight</button>
      </div>
    </article>
  `).join('') || '<div class="empty">No ideas captured yet.</div>';

  $('#jiraList').innerHTML = jira.map((ticket) => `
    <article class="work-card">
      <strong>${escapeHtml(ticket.key)}: ${escapeHtml(ticket.title)}</strong>
      <p>${escapeHtml(ticket.status || 'Assigned')} ${ticket.priority ? `• ${escapeHtml(ticket.priority)}` : ''}</p>
      <span class="status-chip">${escapeHtml(ticket.issueType || 'Jira')}</span>
      <div class="card-actions compact">
        <a class="mini-link" href="${escapeHtml(ticket.url)}" target="_blank" rel="noreferrer">Open Jira</a>
        <button class="mini-button primary" data-preflight-source="jira" data-id="${escapeHtml(ticket.key)}" data-title="${escapeHtml(ticket.title)}" data-summary="${escapeHtml(ticket.status || '')}" data-url="${escapeHtml(ticket.url || '')}">Start pre-flight</button>
      </div>
    </article>
  `).join('') || `<div class="empty">${escapeHtml(state.commandCenter?.assignedJira?.error || 'No assigned Jira tickets returned.')}</div>`;

  $$('[data-idea-status]').forEach((button) => {
    button.addEventListener('click', () => updateIdeaStatus(button.dataset.id, button.dataset.ideaStatus));
  });
  $$('[data-preflight-source]').forEach((button) => {
    button.addEventListener('click', () => createPreflight(button.dataset));
  });
}

function renderDecisions() {
  const decisions = state.commandCenter?.decisions || [];
  $('#decisionList').innerHTML = decisions.map((decision) => `
    <article class="decision-card">
      <h3>${escapeHtml(decision.title)}</h3>
      <p>${escapeHtml(decision.summary || decision.recommendation || 'Decision needs review.')}</p>
      ${decision.risk ? `<p><strong>Risk:</strong> ${escapeHtml(decision.risk)}</p>` : ''}
      <div class="card-actions">
        <button class="primary-action small" data-decision-action="approve" data-id="${escapeHtml(decision.id)}">Approve</button>
        <button class="ghost-button" data-decision-action="snooze" data-id="${escapeHtml(decision.id)}">Snooze</button>
        <button class="ghost-button" data-decision-action="reject" data-id="${escapeHtml(decision.id)}">Reject</button>
      </div>
    </article>
  `).join('') || '<div class="empty">No open decisions.</div>';

  $$('[data-decision-action]').forEach((button) => {
    button.addEventListener('click', () => updateDecision(button.dataset.id, button.dataset.decisionAction));
  });
}

function renderBriefing() {
  const briefing = state.briefing || {};
  const checkins = briefing.recentCheckIns || state.commandCenter?.latestCheckIns || [];
  const actions = briefing.nextActions || [];
  $('#briefingTitle').textContent = briefing.headline || 'Current state';
  $('#briefingSummary').textContent = actions.length
    ? actions.map((action) => `${action.label}: ${action.title}`).join(' • ')
    : 'No urgent items.';
  $('#checkinList').innerHTML = checkins.map((checkin) => `
    <article class="work-card">
      <strong>${escapeHtml(checkin.summary)}</strong>
      <p>${escapeHtml(checkin.createdAt || '')}</p>
      <span class="status-chip">${escapeHtml(checkin.health || 'green')}</span>
    </article>
  `).join('') || '<div class="empty">No check-ins yet. Use Check all to create one.</div>';
}

function renderAll() {
  renderSidebar();
  renderHero();
  renderMetrics();
  renderFlowProof();
  renderBoard();
  renderIdeas();
  renderDecisions();
  renderBriefing();
}

async function loadCommandCenter() {
  try {
    const [commandCenter, briefing, projects] = await Promise.all([
      api('/api/command-center'),
      api('/api/briefing'),
      api('/api/projects'),
    ]);
    state.commandCenter = commandCenter;
    state.briefing = briefing;
    state.projects = Array.isArray(projects) ? projects : [];
    renderAll();
  } catch (error) {
    toast(error.message);
  }
}

async function createIdea(form) {
  const formData = new FormData(form);
  await api('/api/ideas', {
    method: 'POST',
    body: JSON.stringify({
      title: formData.get('title'),
      summary: formData.get('summary'),
    }),
  });
  toast('Idea saved');
  form.reset();
  $('#ideaDialog').close();
  await loadCommandCenter();
  setView('ideas');
}

async function createCheckin() {
  try {
    await api('/api/check-ins', { method: 'POST', body: JSON.stringify({ targetType: 'all' }) });
    toast('Check-in saved');
    await loadCommandCenter();
  } catch (error) {
    toast(error.message);
  }
}

async function createPreflight(dataset) {
  try {
    await api('/api/preflights', {
      method: 'POST',
      body: JSON.stringify({
        sourceType: dataset.preflightSource,
        sourceId: dataset.id,
        title: dataset.preflightSource === 'jira' ? `${dataset.id}: ${dataset.title}` : dataset.title,
        summary: dataset.summary,
        sourceUrl: dataset.url,
      }),
    });
    toast('Pre-flight started');
    await loadCommandCenter();
    setView('command');
  } catch (error) {
    toast(error.message);
  }
}

async function updateIdeaStatus(id, status) {
  try {
    await api(`/api/ideas/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      body: JSON.stringify({ status }),
    });
    toast(`Idea moved to ${status.replaceAll('_', ' ')}`);
    await loadCommandCenter();
  } catch (error) {
    toast(error.message);
  }
}

async function updatePreflightContext(dataset) {
  const preflightId = dataset.preflightContext;
  const contextId = dataset.contextId;
  const nextState = dataset.contextState || 'resolved';
  const card = (state.commandCenter?.preflights || []).find((item) => item.id === preflightId);
  if (!card) {
    toast('Pre-flight not found on board');
    return;
  }
  const requiredContext = (card.requiredContext || []).map((item) => {
    if (item.id !== contextId) return item;
    return {
      ...item,
      state: nextState,
      reason: nextState === 'resolved' ? 'Resolved from launch cockpit.' : item.reason,
    };
  });
  try {
    await api(`/api/preflights/${encodeURIComponent(preflightId)}`, {
      method: 'PATCH',
      body: JSON.stringify({ requiredContext }),
    });
    toast('Context updated');
    await loadCommandCenter();
  } catch (error) {
    toast(error.message);
  }
}

async function launchPreflightObjective(dataset) {
  const fallbackProject = state.projects?.[0] || {};
  const projectDir = dataset.projectDir || fallbackProject.rootPath || '';
  if (!projectDir) {
    toast('Add a project before launching');
    return;
  }
  try {
    const select = document.querySelector(`[data-project-for="${CSS.escape(dataset.launchPreflight)}"]`);
    const selectedOption = select?.selectedOptions?.[0];
    const payload = {
      goal: dataset.goal,
      projectDir: select?.value || projectDir,
      baseBranch: selectedOption?.dataset?.branch || dataset.baseBranch || 'main',
      workflowMode: 'structured',
    };
    await api(`/api/preflights/${encodeURIComponent(dataset.launchPreflight)}/launch-objective`, {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    toast('Objective created from pre-flight');
    await loadCommandCenter();
    setView('command');
  } catch (error) {
    toast(error.message);
  }
}

async function updateObjectiveStatus(dataset) {
  try {
    await api(`/api/objectives/${encodeURIComponent(dataset.id)}`, {
      method: 'PATCH',
      body: JSON.stringify({ status: dataset.objectiveStatus, summary: dataset.summary || '' }),
    });
    toast(dataset.objectiveStatus === 'completed' ? 'Objective completed' : 'Objective moved to review');
    await loadCommandCenter();
  } catch (error) {
    toast(error.message);
  }
}

async function checkObjective(objectiveId) {
  try {
    await api(`/api/objectives/${encodeURIComponent(objectiveId)}/check-in`, {
      method: 'POST',
      body: JSON.stringify({}),
    });
    toast('Objective check-in saved');
    await loadCommandCenter();
  } catch (error) {
    toast(error.message);
  }
}

async function updateDecision(id, action) {
  try {
    await api(`/api/decisions/${encodeURIComponent(id)}/${action}`, { method: 'POST', body: JSON.stringify({}) });
    toast(`Decision ${action}d`);
    await loadCommandCenter();
  } catch (error) {
    toast(error.message);
  }
}

function bindEvents() {
  $$('.nav button').forEach((button) => button.addEventListener('click', () => setView(button.dataset.view)));
  $('#refreshButton').addEventListener('click', loadCommandCenter);
  $('#checkAllButton').addEventListener('click', createCheckin);
  $('#topActionButton').addEventListener('click', goToTopAction);
  $('#newWorkButton').addEventListener('click', () => $('#ideaDialog').showModal());
  $('#addIdeaButton').addEventListener('click', () => $('#ideaDialog').showModal());
  $('#voiceButton').addEventListener('click', () => $('#voiceDialog').showModal());
  $('#closeVoiceButton').addEventListener('click', () => $('#voiceDialog').close());
  $('#focusButton').addEventListener('click', () => {
    $('#appShell').classList.toggle('focus-mode');
    toast($('#appShell').classList.contains('focus-mode') ? 'Focus mode on' : 'Focus mode off');
  });
  $('#searchInput').addEventListener('input', (event) => {
    state.search = event.target.value || '';
    renderBoard();
  });
  $('#ideaForm').addEventListener('submit', (event) => {
    event.preventDefault();
    createIdea(event.currentTarget).catch((error) => toast(error.message));
  });
}

bindEvents();
loadCommandCenter();
