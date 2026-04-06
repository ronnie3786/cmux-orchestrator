(() => {
  const CONSOLE_LOG_PRESETS = [
    { id: 'all', label: 'All', pattern: '' },
    { id: 'analytics', label: 'Analytics', pattern: 'analytics event:' },
    { id: 'analytics_names', label: 'Analytics names only', pattern: 'Track analytics event:|Screen analytics event:' },
    { id: 'network', label: 'Network', pattern: 'Starting fetch|Starting mutation|Result of fetch|Result of mutation' },
    { id: 'errors', label: 'Errors', pattern: ' E ' },
    { id: 'graphql', label: 'GraphQL', pattern: '\\(doxx:GraphQL\\)' },
    { id: 'messaging', label: 'Messaging', pattern: 'MessagingConversation:' },
    { id: 'custom', label: 'Custom', pattern: null }
  ];
  const state = {
    objectives: [],
    activeObjectiveId: null,
    activeObjective: null,
    actionButtons: [],
    actionButtonState: {},
    messages: [],
    typing: false,
    config: null,
    gitPanelOpen: false,
    gitStatus: null,
    gitDiffFile: '',
    gitDiffSection: 'unstaged',
    gitDiffTab: 'diff',
    gitDiffIsMarkdown: false,
    gitDiffCache: {
      diffHtml: '',
      previewHtml: ''
    },
    gitExpandedCommit: null,
    gitCommitFiles: [],
    gitCommitFilesLoading: false,
    workerOutputTaskId: null,
    workerOutputContent: '',
    workerOutputPolling: false,
    gitContextFile: '',
    gitContextSection: '',
    lastMessageTimestamp: null,
    relativeTick: Date.now(),
    isMobile: null,
    sidebarOpen: true,
    sidebarFormOpen: false,
    settingsOpen: false,
    settingsSaving: false,
    fabModalOpen: false,
    fabSaving: false,
    fabDeletingId: null,
    debugOpen: false,
    debugEntries: [],
    debugHasErrors: false,
    debugLoading: false,
    buildLogOpen: false,
    buildLogAuto: false,
    buildLogFile: 'build.log',
    buildLogData: null,
    buildLogLoading: false,
    buildLogError: '',
    buildLogInterval: null,
    buildLogPinned: true,
    buildLogHasNewOutput: false,
    buildLogLastSignature: '',
    consoleLogOpen: false,
    consoleLogAuto: false,
    consoleLogFile: null,
    consoleLogFilter: '',
    consoleLogDraftFilter: '',
    consoleLogPreset: 'all',
    consoleLogData: null,
    consoleLogLoading: false,
    consoleLogError: '',
    consoleLogInterval: null,
    consoleLogPinned: true,
    consoleLogHasNewOutput: false,
    consoleLogLastSignature: '',
    draftProjectDir: '',
    draftBaseBranch: 'main',
    draftBranchName: '',
    draftGoal: '',
    pendingCreate: false,
    pendingSend: false,
    pollers: {
      objectives: null,
      messages: null,
      objective: null,
      git: null,
      relative: null,
      debug: null
    }
  };

  const els = {
    sidebar: document.getElementById('sidebar'),
    sidebarBackdrop: document.getElementById('sidebarBackdrop'),
    sidebarCloseButton: document.getElementById('sidebarCloseButton'),
    main: document.getElementById('main'),
    objectiveList: document.getElementById('objectiveList'),
    contextStrip: document.getElementById('contextStrip'),
    messagesPane: document.getElementById('messagesPane'),
    messageColumn: document.getElementById('messageColumn'),
    chatInput: document.getElementById('chatInput'),
    sendButton: document.getElementById('sendButton'),
    inputHint: document.getElementById('inputHint'),
    sidebarForm: document.getElementById('sidebarForm'),
    newObjectiveButton: document.getElementById('newObjectiveButton'),
    settingsButton: document.getElementById('settingsButton'),
    settingsModal: document.getElementById('settingsModal'),
    settingsCloseButton: document.getElementById('settingsCloseButton'),
    settingsCancelButton: document.getElementById('settingsCancelButton'),
    settingsSaveButton: document.getElementById('settingsSaveButton'),
    settingsProjectDir: document.getElementById('settingsProjectDir'),
    settingsBaseBranch: document.getElementById('settingsBaseBranch'),
    settingsPollInterval: document.getElementById('settingsPollInterval'),
    settingsReviewEnabled: document.getElementById('settingsReviewEnabled'),
    settingsReviewModel: document.getElementById('settingsReviewModel'),
    settingsReviewBackend: document.getElementById('settingsReviewBackend'),
    fabRail: document.getElementById('fabRail'),
    fabModal: document.getElementById('fabModal'),
    fabCloseButton: document.getElementById('fabCloseButton'),
    fabCancelButton: document.getElementById('fabCancelButton'),
    fabSaveButton: document.getElementById('fabSaveButton'),
    fabLabel: document.getElementById('fabLabel'),
    fabPrompt: document.getElementById('fabPrompt'),
    fabIcon: document.getElementById('fabIcon'),
    fabColor: document.getElementById('fabColor'),
    fabList: document.getElementById('fabList'),
    debugFab: document.getElementById('debugFab'),
    debugModal: document.getElementById('debugModal'),
    debugCloseButton: document.getElementById('debugCloseButton'),
    debugCopyAllButton: document.getElementById('debugCopyAllButton'),
    debugCopyLastButton: document.getElementById('debugCopyLastButton'),
    debugModalSubtitle: document.getElementById('debugModalSubtitle'),
    debugLogBody: document.getElementById('debugLogBody'),
    buildLogPanel: document.getElementById('buildLogPanel'),
    buildLogTitle: document.getElementById('buildLogTitle'),
    buildLogMeta: document.getElementById('buildLogMeta'),
    buildLogFileSelect: document.getElementById('buildLogFileSelect'),
    buildLogAutoButton: document.getElementById('buildLogAutoButton'),
    buildLogRefreshButton: document.getElementById('buildLogRefreshButton'),
    buildLogCloseButton: document.getElementById('buildLogCloseButton'),
    buildLogBody: document.getElementById('buildLogBody'),
    buildLogContent: document.getElementById('buildLogContent'),
    buildLogNewOutputBadge: document.getElementById('buildLogNewOutputBadge'),
    consoleLogPanel: document.getElementById('consoleLogPanel'),
    consoleLogTitle: document.getElementById('consoleLogTitle'),
    consoleLogMeta: document.getElementById('consoleLogMeta'),
    consoleLogFileSelect: document.getElementById('consoleLogFileSelect'),
    consoleLogPresetSelect: document.getElementById('consoleLogPresetSelect'),
    consoleLogCustomInput: document.getElementById('consoleLogCustomInput'),
    consoleLogApplyButton: document.getElementById('consoleLogApplyButton'),
    consoleLogAutoButton: document.getElementById('consoleLogAutoButton'),
    consoleLogRefreshButton: document.getElementById('consoleLogRefreshButton'),
    consoleLogCloseButton: document.getElementById('consoleLogCloseButton'),
    consoleLogBody: document.getElementById('consoleLogBody'),
    consoleLogContent: document.getElementById('consoleLogContent'),
    consoleLogNewOutputBadge: document.getElementById('consoleLogNewOutputBadge'),
    gitPanel: document.getElementById('gitPanel'),
    gitPanelBranch: document.getElementById('gitPanelBranch'),
    gitPanelPath: document.getElementById('gitPanelPath'),
    gitPanelBody: document.getElementById('gitPanelBody'),
    gitPanelCopyButton: document.getElementById('gitPanelCopyButton'),
    gitPanelRefreshButton: document.getElementById('gitPanelRefreshButton'),
    gitPanelCloseButton: document.getElementById('gitPanelCloseButton'),
    gitContextMenu: document.getElementById('gitContextMenu'),
    diffOverlay: document.getElementById('diffOverlay'),
    diffPanelTitle: document.getElementById('diffPanelTitle'),
    diffTabs: document.getElementById('diffTabs'),
    diffTabDiff: document.getElementById('diffTabDiff'),
    diffTabPreview: document.getElementById('diffTabPreview'),
    diffPanelBody: document.getElementById('diffPanelBody'),
    diffCloseButton: document.getElementById('diffCloseButton'),
    workerOutputOverlay: document.getElementById('workerOutputOverlay'),
    workerOutputTitle: document.getElementById('workerOutputTitle'),
    workerOutputBody: document.getElementById('workerOutputBody'),
    workerOutputClose: document.getElementById('workerOutputClose'),
    workerOutputRefresh: document.getElementById('workerOutputRefresh'),
    terminalLink: document.getElementById('terminalLink'),
    toastWrap: document.getElementById('toastWrap')
  };

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function escapeRegExp(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function sanitizeHref(value) {
    const normalized = String(value == null ? '' : value).trim();
    if (!normalized) return '';
    if (/^(https?:\/\/|mailto:)/i.test(normalized)) return normalized;
    if (/^(\/|#)/.test(normalized)) return normalized;
    return '';
  }

  function renderMarkdownInline(text) {
    let html = String(text || '');
    const placeholders = [];

    function store(replacement) {
      const token = '%%MD_TOKEN_' + placeholders.length + '%%';
      placeholders.push(replacement);
      return token;
    }

    html = html.replace(/!\[([^\]]*)\]\(([^)\s]+(?:\s+[^)]*)?)\)/g, (_, alt, src) => {
      const safeSrc = sanitizeHref(src);
      return safeSrc ? store('<img src="' + safeSrc + '" alt="' + alt + '">') : alt;
    });
    html = html.replace(/`([^`\n]+)`/g, (_, code) => store('<code>' + code + '</code>'));
    html = html.replace(/\[([^\]]+)\]\(([^)\s]+(?:\s+[^)]*)?)\)/g, (_, label, href) => {
      const safeHref = sanitizeHref(href);
      return safeHref
        ? store('<a href="' + safeHref + '" target="_blank" rel="noopener noreferrer">' + label + '</a>')
        : label;
    });
    html = html.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/(^|[^\*])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>');

    placeholders.forEach((replacement, index) => {
      html = html.replaceAll('%%MD_TOKEN_' + index + '%%', replacement);
    });

    return html;
  }

  function renderMarkdown(text, wrapperClass = 'md-content') {
    const safe = esc(text || '').replace(/\r\n?/g, '\n');
    const lines = safe.split('\n');
    const parts = [];
    let paragraph = [];
    let listType = null;
    let listItems = [];
    let tableLines = [];
    let inCodeBlock = false;
    let codeLines = [];

    function flushParagraph() {
      if (!paragraph.length) return;
      parts.push('<p>' + paragraph.map(renderMarkdownInline).join('<br>') + '</p>');
      paragraph = [];
    }

    function flushList() {
      if (!listType || !listItems.length) return;
      parts.push('<' + listType + '>' + listItems.map((item) => '<li>' + renderMarkdownInline(item) + '</li>').join('') + '</' + listType + '>');
      listType = null;
      listItems = [];
    }

    function flushTable() {
      if (!tableLines.length) return;
      const rows = tableLines.map((line) => line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((cell) => cell.trim()));
      if (rows.length >= 2 && rows[1].every((cell) => /^:?-{3,}:?$/.test(cell))) {
        const header = rows[0];
        const bodyRows = rows.slice(2);
        const headHtml = '<thead><tr>' + header.map((cell) => '<th>' + renderMarkdownInline(cell) + '</th>').join('') + '</tr></thead>';
        const bodyHtml = bodyRows.length
          ? '<tbody>' + bodyRows.map((row) => '<tr>' + row.map((cell) => '<td>' + renderMarkdownInline(cell) + '</td>').join('') + '</tr>').join('') + '</tbody>'
          : '';
        parts.push('<table>' + headHtml + bodyHtml + '</table>');
      } else {
        paragraph.push(...tableLines);
      }
      tableLines = [];
    }

    function flushCodeBlock() {
      if (!inCodeBlock) return;
      parts.push('<pre><code>' + codeLines.join('\n') + '</code></pre>');
      inCodeBlock = false;
      codeLines = [];
    }

    function flushBlocks() {
      flushParagraph();
      flushList();
      flushTable();
    }

    lines.forEach((line) => {
      const trimmed = line.trim();

      if (inCodeBlock) {
        if (/^```/.test(trimmed)) {
          flushCodeBlock();
        } else {
          codeLines.push(line);
        }
        return;
      }

      if (/^```/.test(trimmed)) {
        flushBlocks();
        inCodeBlock = true;
        codeLines = [];
        return;
      }

      if (trimmed.includes('|')) {
        flushParagraph();
        flushList();
        tableLines.push(line);
        return;
      }
      flushTable();

      const headingMatch = line.match(/^(#{1,6})\s+(.*)$/);
      if (headingMatch) {
        flushBlocks();
        const level = headingMatch[1].length;
        parts.push('<h' + level + '>' + renderMarkdownInline(headingMatch[2]) + '</h' + level + '>');
        return;
      }

      if (/^---+$/.test(trimmed)) {
        flushBlocks();
        parts.push('<hr>');
        return;
      }

      const blockquoteMatch = line.match(/^>\s?(.*)$/);
      if (blockquoteMatch) {
        flushBlocks();
        parts.push('<blockquote>' + renderMarkdownInline(blockquoteMatch[1]) + '</blockquote>');
        return;
      }

      const ulMatch = line.match(/^\s*[-*]\s+(.*)$/);
      if (ulMatch) {
        flushParagraph();
        if (listType && listType !== 'ul') flushList();
        listType = 'ul';
        listItems.push(ulMatch[1]);
        return;
      }

      const olMatch = line.match(/^\s*\d+\.\s+(.*)$/);
      if (olMatch) {
        flushParagraph();
        if (listType && listType !== 'ol') flushList();
        listType = 'ol';
        listItems.push(olMatch[1]);
        return;
      }

      if (!trimmed) {
        flushBlocks();
        return;
      }

      flushList();
      paragraph.push(line);
    });

    flushBlocks();
    flushCodeBlock();

    return '<div class="' + wrapperClass + '">' + parts.join('') + '</div>';
  }

  function parseIso(value) {
    if (!value) return null;
    const ts = Date.parse(value);
    return Number.isNaN(ts) ? null : ts;
  }

  function relativeTime(value) {
    const ts = parseIso(value);
    if (!ts) return 'just now';
    const diff = Math.max(0, Math.floor((state.relativeTick - ts) / 1000));
    if (diff < 15) return 'just now';
    if (diff < 60) return diff + 's ago';
    if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
    if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
    if (diff < 172800) return 'yesterday';
    return Math.floor(diff / 86400) + 'd ago';
  }

  function durationFrom(start, end) {
    const startTs = parseIso(start);
    const endTs = parseIso(end) || Date.now();
    if (!startTs || endTs <= startTs) return null;
    let diff = Math.floor((endTs - startTs) / 1000);
    const hours = Math.floor(diff / 3600);
    diff -= hours * 3600;
    const mins = Math.floor(diff / 60);
    const secs = diff - mins * 60;
    if (hours > 0) return hours + 'h ' + mins + 'm';
    if (mins > 0) return mins + 'm ' + secs + 's';
    return secs + 's';
  }

  function statusMeta(status) {
    switch ((status || '').toLowerCase()) {
      case 'completed':
        return { dot: 'od-done', fill: 'opf-done', badge: 'badge-done', label: 'Done' };
      case 'failed':
        return { dot: 'od-failed', fill: 'opf-failed', badge: 'badge-failed', label: 'Failed' };
      case 'plan_review':
        return { dot: 'od-plan-review', fill: 'opf-plan-review', badge: 'badge-plan-review', label: 'reviewing plan' };
      case 'planning':
        return { dot: 'od-reviewing', fill: 'opf-reviewing', badge: 'badge-planning', label: 'Planning' };
      case 'reviewing':
      case 'rework':
        return { dot: 'od-reviewing', fill: 'opf-reviewing', badge: 'badge-reviewing', label: 'Reviewing' };
      case 'executing':
      case 'running':
        return { dot: 'od-running', fill: 'opf-running', badge: 'badge-running', label: 'Running' };
      default:
        return { dot: 'od-queued', fill: 'opf-running', badge: 'badge-queued', label: 'Queued' };
    }
  }

  function getCurrentObjectiveId() {
    return state.activeObjectiveId;
  }

  function isActionTask(task) {
    return String(task && task.source || '').toLowerCase() === 'action-button';
  }

  function taskDisplayTitle(task) {
    if (!task) return 'Task';
    const title = String(task.title || task.id || 'Task');
    return isActionTask(task) ? ('Action: ' + title) : title;
  }

  function taskDisplayIcon(task) {
    return isActionTask(task) ? '🔘' : null;
  }

  function buttonStateClass(buttonId) {
    const value = state.actionButtonState[buttonId];
    if (value === 'launching') return ' launching';
    if (value === 'success') return ' success';
    return '';
  }

  function setActionButtonState(buttonId, value, clearMs) {
    if (!buttonId) return;
    state.actionButtonState = Object.assign({}, state.actionButtonState, { [buttonId]: value });
    renderFabRail();
    if (clearMs) {
      window.setTimeout(() => {
        if (state.actionButtonState[buttonId] !== value) return;
        const next = Object.assign({}, state.actionButtonState);
        delete next[buttonId];
        state.actionButtonState = next;
        renderFabRail();
      }, clearMs);
    }
  }

  function sortedObjectives(list) {
    return [...(list || [])].sort((a, b) => {
      const aTs = parseIso(a.updatedAt || a.createdAt) || 0;
      const bTs = parseIso(b.updatedAt || b.createdAt) || 0;
      return bTs - aTs;
    });
  }

  function getRecentProjects() {
    const seen = new Set();
    return sortedObjectives(state.objectives)
      .map((item) => item.projectDir)
      .filter((dir) => {
        if (!dir || seen.has(dir)) return false;
        seen.add(dir);
        return true;
      });
  }

  function defaultProjectDir() {
    return state.draftProjectDir || (state.config && state.config.defaultProjectDir) || getRecentProjects()[0] || '';
  }

  function defaultBaseBranch() {
    return state.draftBaseBranch || (state.config && state.config.defaultBaseBranch) || 'main';
  }

  function isMobileViewport() {
    return window.innerWidth <= 768;
  }

  function openSidebar() {
    if (!state.isMobile) return;
    state.sidebarOpen = true;
    renderSidebarChrome();
  }

  function closeSidebar() {
    if (!state.isMobile) return;
    state.sidebarOpen = false;
    renderSidebarChrome();
  }

  function toggleSidebar() {
    if (!state.isMobile) return;
    state.sidebarOpen = !state.sidebarOpen;
    renderSidebarChrome();
  }

  function syncResponsiveState(forceRender) {
    const nextIsMobile = isMobileViewport();
    const previousIsMobile = state.isMobile;
    state.isMobile = nextIsMobile;
    if (previousIsMobile === null) {
      state.sidebarOpen = !nextIsMobile;
    } else if (previousIsMobile !== nextIsMobile) {
      state.sidebarOpen = !nextIsMobile;
    }
    if (forceRender) {
      render();
    } else {
      renderSidebarChrome();
      autoResizeTextarea();
    }
  }

  function renderSidebarChrome() {
    els.sidebar.className = 'sidebar' + ((state.isMobile && state.sidebarOpen) || !state.isMobile ? ' open' : '');
    els.sidebarBackdrop.className = 'sidebar-backdrop' + (state.isMobile && state.sidebarOpen ? ' visible' : '');
    const menuButton = document.getElementById('mobileMenuBtn');
    if (menuButton) {
      menuButton.setAttribute('aria-expanded', state.isMobile && state.sidebarOpen ? 'true' : 'false');
    }
  }

  async function api(path, options) {
    const response = await fetch(path, {
      headers: { 'Content-Type': 'application/json' },
      ...options
    });
    if (!response.ok) {
      let detail = '';
      try {
        const data = await response.json();
        detail = data && data.error ? data.error : '';
      } catch (err) {
        detail = response.statusText || '';
      }
      throw new Error(detail || ('Request failed: ' + response.status));
    }
    const text = await response.text();
    return text ? JSON.parse(text) : {};
  }

  async function loadActionButtons(objectiveId) {
    if (!objectiveId) {
      state.actionButtons = [];
      state.actionButtonState = {};
      renderFabRail();
      renderFabModal();
      return;
    }
    const data = await api('/api/objectives/' + encodeURIComponent(objectiveId) + '/action-buttons');
    if (state.activeObjectiveId !== objectiveId) return;
    state.actionButtons = Array.isArray(data.buttons) ? data.buttons : [];
    renderFabRail();
    renderFabModal();
  }

  function showAddModal() {
    if (!state.activeObjectiveId) return;
    els.fabLabel.value = '';
    els.fabPrompt.value = '';
    els.fabIcon.value = '';
    els.fabColor.value = '#4f8ef7';
    state.fabModalOpen = true;
    renderFabModal();
    window.setTimeout(() => {
      if (els.fabLabel) els.fabLabel.focus();
    }, 0);
  }

  function hideAddModal() {
    state.fabModalOpen = false;
    state.fabSaving = false;
    state.fabDeletingId = null;
    renderFabModal();
  }

  function renderFabRail() {
    const objectiveId = getCurrentObjectiveId();
    const hasObjective = !!objectiveId && !!state.activeObjective;
    els.fabRail.className = 'fab-rail' + (hasObjective ? ' visible' : '');
    if (!hasObjective) {
      els.fabRail.innerHTML = '';
      return;
    }
    const buttons = Array.isArray(state.actionButtons) ? state.actionButtons : [];
    els.fabRail.innerHTML = '';
    buttons.forEach((button) => {
      const el = document.createElement('button');
      el.className = 'fab-btn' + buttonStateClass(button.id);
      el.type = 'button';
      el.dataset.buttonId = button.id;
      el.style.background = button.color || '#4f8ef7';
      el.title = button.label || 'Action';
      const iconSpan = document.createElement('span');
      iconSpan.className = 'fab-btn-icon';
      iconSpan.textContent = button.icon || '⚡';
      el.appendChild(iconSpan);
      const labelSpan = document.createElement('span');
      labelSpan.className = 'fab-btn-label';
      labelSpan.textContent = button.label || 'Action';
      el.appendChild(labelSpan);
      el.disabled = state.fabSaving;
      el.addEventListener('click', () => {
        executeAction(button);
      });
      els.fabRail.appendChild(el);
    });
    const addButton = document.createElement('button');
    addButton.className = 'fab-btn fab-add';
    addButton.type = 'button';
    addButton.id = 'fabAdd';
    addButton.title = 'Add Action...';
    addButton.textContent = '+';
    addButton.disabled = state.fabSaving;
    addButton.addEventListener('click', showAddModal);
    els.fabRail.appendChild(addButton);
  }

  function renderFabModal() {
    const visible = state.fabModalOpen && !!state.activeObjectiveId;
    els.fabModal.className = 'modal-overlay' + (visible ? ' open' : '');
    els.fabSaveButton.disabled = state.fabSaving;
    const buttons = Array.isArray(state.actionButtons) ? state.actionButtons : [];
    els.fabList.innerHTML = buttons.length ? buttons.map((button) => [
      '<div class="fab-list-item">',
      '<div class="fab-list-icon" style="background:' + esc(button.color || '#4f8ef7') + ';">' + esc(button.icon || '⚡') + '</div>',
      '<div class="fab-list-main">',
      '<div class="fab-list-label">' + esc(button.label || 'Action') + '</div>',
      '<div class="fab-list-prompt">' + esc(button.prompt || '') + '</div>',
      (button.isDefault ? '<div class="fab-list-badge">Default</div>' : ''),
      '</div>',
      (button.isDefault
        ? ''
        : '<button class="fab-delete" type="button" data-action-button-delete="' + esc(button.id) + '"' + (state.fabDeletingId === button.id ? ' disabled' : '') + '>Delete</button>'),
      '</div>'
    ].join('')).join('') : '<div class="fab-list-empty">No saved action buttons yet.</div>';
    els.fabList.querySelectorAll('[data-action-button-delete]').forEach((node) => {
      node.addEventListener('click', () => {
        deleteActionButton(node.getAttribute('data-action-button-delete'));
      });
    });
  }

  async function saveActionButton() {
    if (!state.activeObjectiveId) return;
    const label = els.fabLabel.value.trim();
    const prompt = els.fabPrompt.value.trim();
    const icon = (els.fabIcon.value || '').trim() || '⚡';
    const color = (els.fabColor.value || '').trim() || '#4f8ef7';
    if (!label || !prompt) {
      showToast('Action label and prompt are required');
      return;
    }
    state.fabSaving = true;
    renderFabModal();
    renderFabRail();
    try {
      await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/action-buttons', {
        method: 'POST',
        body: JSON.stringify({ label, prompt, icon, color })
      });
      els.fabLabel.value = '';
      els.fabPrompt.value = '';
      els.fabIcon.value = '';
      els.fabColor.value = '#4f8ef7';
      await loadActionButtons(state.activeObjectiveId);
      hideAddModal();
      showToast('Action button saved');
    } catch (error) {
      showToast(error.message || 'Could not save action button');
      state.fabSaving = false;
      renderFabModal();
      renderFabRail();
    }
  }

  async function deleteActionButton(buttonId) {
    if (!state.activeObjectiveId || !buttonId) return;
    state.fabDeletingId = buttonId;
    renderFabModal();
    try {
      await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/action-buttons/' + encodeURIComponent(buttonId), {
        method: 'DELETE'
      });
      await loadActionButtons(state.activeObjectiveId);
      state.fabDeletingId = null;
      renderFabModal();
      showToast('Action button removed');
    } catch (error) {
      state.fabDeletingId = null;
      renderFabModal();
      showToast(error.message || 'Could not remove action button');
    }
  }

  async function executeAction(button) {
    const objectiveId = getCurrentObjectiveId();
    if (!objectiveId) return;
    setActionButtonState(button.id, 'launching');
    showToast('Spawning ' + (button.label || 'action') + ' session...');
    try {
      const data = await api('/api/objectives/' + encodeURIComponent(objectiveId) + '/action-inject', {
        method: 'POST',
        body: JSON.stringify({ buttonId: button.id })
      });
      if (data && data.ok) {
        setActionButtonState(button.id, 'success', 1800);
        await Promise.all([
          pollActiveObjective(true),
          pollMessages(false)
        ]);
        return;
      }
      throw new Error('Action spawn failed');
    } catch (error) {
      const next = Object.assign({}, state.actionButtonState);
      delete next[button.id];
      state.actionButtonState = next;
      renderFabRail();
      showToast(error.message || 'Could not launch action');
    }
  }

  function activeGitPath() {
    return state.activeObjective && (state.activeObjective.worktreePath || state.activeObjective.projectDir)
      ? String(state.activeObjective.worktreePath || state.activeObjective.projectDir).trim()
      : '';
  }

  function gitButtonLabel() {
    const branch = state.gitStatus && state.gitStatus.branch
      ? state.gitStatus.branch
      : (state.activeObjective && state.activeObjective.branchName ? state.activeObjective.branchName : '');
    return branch ? ('⎇ ' + branch) : '⎇ git';
  }

  function currentObjectiveName() {
    const objective = state.activeObjective || sortedObjectives(state.objectives).find((item) => item.id === state.activeObjectiveId);
    return objective && objective.goal ? String(objective.goal) : 'No objective selected';
  }

  function buildLogSignature(data) {
    if (!data || !data.exists) return '';
    return [
      data.fileSize || 0,
      data.totalLines || 0,
      Array.isArray(data.lines) ? data.lines.join('\n') : ''
    ].join('::');
  }

  function consoleLogSignature(data) {
    if (!data || !data.exists) return '';
    return [
      data.activeFile || '',
      data.fileSize || 0,
      data.totalLines || 0,
      data.matchedLines || 0,
      Array.isArray(data.lines) ? data.lines.join('\n') : ''
    ].join('::');
  }

  function consoleLogPresetById(id) {
    return CONSOLE_LOG_PRESETS.find((preset) => preset.id === id) || CONSOLE_LOG_PRESETS[0];
  }

  function consoleLogPresetForPattern(pattern) {
    const value = String(pattern || '');
    return CONSOLE_LOG_PRESETS.find((preset) => preset.pattern === value && preset.pattern !== null) || consoleLogPresetById('custom');
  }

  function isBuildLogPinned() {
    const el = els.buildLogBody;
    return (el.scrollTop + el.clientHeight) >= (el.scrollHeight - 20);
  }

  function scrollBuildLogToBottom() {
    els.buildLogBody.scrollTop = els.buildLogBody.scrollHeight;
    state.buildLogPinned = true;
    state.buildLogHasNewOutput = false;
    renderBuildLogBadge();
  }

  function renderBuildLogBadge() {
    els.buildLogNewOutputBadge.className = 'build-log-badge' + (state.buildLogHasNewOutput ? ' visible' : '');
  }

  function isConsoleLogPinned() {
    const el = els.consoleLogBody;
    return (el.scrollTop + el.clientHeight) >= (el.scrollHeight - 20);
  }

  function scrollConsoleLogToBottom() {
    els.consoleLogBody.scrollTop = els.consoleLogBody.scrollHeight;
    state.consoleLogPinned = true;
    state.consoleLogHasNewOutput = false;
    renderConsoleLogBadge();
  }

  function renderConsoleLogBadge() {
    els.consoleLogNewOutputBadge.className = 'build-log-badge' + (state.consoleLogHasNewOutput ? ' visible' : '');
  }

  function renderConsoleLogLine(line, pattern) {
    const text = String(line == null ? '' : line);
    if (!pattern) return '<div class="build-log-line">' + esc(text) + '</div>';
    let matcher;
    try {
      matcher = new RegExp(pattern, 'ig');
    } catch (error) {
      return '<div class="build-log-line">' + esc(text) + '</div>';
    }
    let html = '';
    let cursor = 0;
    let matched = false;
    let guard = 0;
    while (guard < 5000) {
      const match = matcher.exec(text);
      if (!match) break;
      const value = String(match[0] || '');
      const index = Number(match.index || 0);
      if (!value) {
        matcher.lastIndex = index + 1;
        guard += 1;
        continue;
      }
      matched = true;
      html += esc(text.slice(cursor, index));
      html += '<mark class="console-log-match">' + esc(value) + '</mark>';
      cursor = index + value.length;
      guard += 1;
    }
    if (!matched) return '<div class="build-log-line">' + esc(text) + '</div>';
    html += esc(text.slice(cursor));
    return '<div class="build-log-line">' + html + '</div>';
  }

  function renderBuildLog() {
    const objectiveName = currentObjectiveName();
    const fileLabel = state.buildLogFile || 'build.log';
    const data = state.buildLogData;
    els.buildLogPanel.className = 'build-log-panel' + (state.buildLogOpen ? ' open' : '');
    els.buildLogTitle.textContent = 'Build Log';
    els.buildLogFileSelect.value = fileLabel;
    els.buildLogFileSelect.disabled = !state.activeObjectiveId;
    els.buildLogAutoButton.className = 'build-log-toggle' + (state.buildLogAuto ? ' active' : '');
    els.buildLogAutoButton.setAttribute('aria-pressed', state.buildLogAuto ? 'true' : 'false');
    els.buildLogRefreshButton.disabled = !state.activeObjectiveId || state.buildLogLoading;
    els.buildLogCloseButton.disabled = !state.buildLogOpen;

    if (!state.activeObjectiveId) {
      els.buildLogMeta.textContent = 'Select an objective to view logs.';
      els.buildLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">⎔</div><div>No active objective selected.</div></div>';
      state.buildLogHasNewOutput = false;
      renderBuildLogBadge();
      return;
    }

    if (state.buildLogLoading && !data) {
      els.buildLogMeta.textContent = objectiveName + ' · ' + fileLabel;
      els.buildLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-spinner"></div><div>Loading build log…</div></div>';
      state.buildLogHasNewOutput = false;
      renderBuildLogBadge();
      return;
    }

    if (state.buildLogError) {
      els.buildLogMeta.textContent = objectiveName + ' · ' + fileLabel;
      els.buildLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">⚠</div><div>Failed to read build log.</div><button class="build-log-retry" id="buildLogRetryButton" type="button">Retry</button></div>';
      const retryButton = document.getElementById('buildLogRetryButton');
      if (retryButton) retryButton.addEventListener('click', () => fetchBuildLog(true));
      renderBuildLogBadge();
      return;
    }

    if (!data || !data.exists) {
      els.buildLogMeta.textContent = objectiveName + ' · ' + fileLabel;
      els.buildLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">⎔</div><div>No build log yet. Run a build to see output here.</div></div>';
      state.buildLogHasNewOutput = false;
      renderBuildLogBadge();
      return;
    }

    const lineCount = Number(data.totalLines || 0);
    const fileSizeHuman = data.fileSizeHuman || '0 B';
    els.buildLogMeta.textContent = fileLabel + ' · ' + fileSizeHuman + ' · ' + lineCount + ' lines';
    const lines = Array.isArray(data.lines) ? data.lines : [];
    els.buildLogContent.innerHTML = lines.length
      ? lines.map((line) => '<div class="build-log-line">' + esc(line) + '</div>').join('')
      : '<div class="build-log-state"><div class="build-log-state-icon">⎔</div><div>Log file is empty.</div></div>';
    renderBuildLogBadge();
  }

  function renderConsoleLog() {
    const objectiveName = currentObjectiveName();
    const data = state.consoleLogData;
    const files = data && Array.isArray(data.files) ? data.files : [];
    const activeFile = state.consoleLogFile || (data && data.activeFile) || (files[0] || '');
    const preset = consoleLogPresetById(state.consoleLogPreset);

    els.consoleLogPanel.className = 'build-log-panel' + (state.consoleLogOpen ? ' open' : '');
    els.consoleLogTitle.textContent = activeFile ? ('Console Logs - ' + activeFile) : 'Console Logs';
    els.consoleLogAutoButton.className = 'build-log-toggle' + (state.consoleLogAuto ? ' active' : '');
    els.consoleLogAutoButton.setAttribute('aria-pressed', state.consoleLogAuto ? 'true' : 'false');
    els.consoleLogRefreshButton.disabled = !state.activeObjectiveId || state.consoleLogLoading;
    els.consoleLogCloseButton.disabled = !state.consoleLogOpen;
    els.consoleLogPresetSelect.innerHTML = CONSOLE_LOG_PRESETS.map((item) => (
      '<option value="' + esc(item.id) + '">' + esc(item.label) + '</option>'
    )).join('');
    els.consoleLogPresetSelect.value = preset.id;
    els.consoleLogCustomInput.value = state.consoleLogDraftFilter;
    els.consoleLogCustomInput.disabled = !state.activeObjectiveId;
    els.consoleLogApplyButton.disabled = !state.activeObjectiveId;
    els.consoleLogFileSelect.disabled = !state.activeObjectiveId || files.length <= 1;
    els.consoleLogFileSelect.innerHTML = files.length
      ? files.map((file) => '<option value="' + esc(file) + '">' + esc(file) + '</option>').join('')
      : '<option value="">No files</option>';
    els.consoleLogFileSelect.value = activeFile;

    if (!state.activeObjectiveId) {
      els.consoleLogMeta.textContent = 'Select an objective to view logs.';
      els.consoleLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">📟</div><div>No active objective selected.</div></div>';
      state.consoleLogHasNewOutput = false;
      renderConsoleLogBadge();
      return;
    }

    if (state.consoleLogLoading && !data) {
      els.consoleLogMeta.textContent = objectiveName + (activeFile ? (' · ' + activeFile) : '');
      els.consoleLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-spinner"></div><div>Loading console logs…</div></div>';
      state.consoleLogHasNewOutput = false;
      renderConsoleLogBadge();
      return;
    }

    if (state.consoleLogError) {
      els.consoleLogMeta.textContent = objectiveName + (activeFile ? (' · ' + activeFile) : '');
      els.consoleLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">⚠</div><div>Failed to read console logs.</div><button class="build-log-retry" id="consoleLogRetryButton" type="button">Retry</button></div>';
      const retryButton = document.getElementById('consoleLogRetryButton');
      if (retryButton) retryButton.addEventListener('click', () => fetchConsoleLog(true));
      renderConsoleLogBadge();
      return;
    }

    if (!data || !data.exists) {
      els.consoleLogMeta.textContent = objectiveName + ' · waiting for .build/logs/*.log';
      els.consoleLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">📟</div><div>No console logs yet. Run the app to see runtime output here.</div></div>';
      state.consoleLogHasNewOutput = false;
      renderConsoleLogBadge();
      return;
    }

    const totalLines = Number(data.totalLines || 0);
    const matchedLines = Number(data.matchedLines || 0);
    const fileSizeHuman = data.fileSizeHuman || '0 B';
    const filterLabel = state.consoleLogFilter ? (' · ' + matchedLines + ' matches') : '';
    els.consoleLogMeta.textContent = (data.activeFile || activeFile) + ' · ' + fileSizeHuman + ' · ' + totalLines + ' lines' + filterLabel;
    const lines = Array.isArray(data.lines) ? data.lines : [];
    els.consoleLogContent.innerHTML = lines.length
      ? lines.map((line) => renderConsoleLogLine(line, state.consoleLogFilter)).join('')
      : '<div class="build-log-state"><div class="build-log-state-icon">📟</div><div>' + (state.consoleLogFilter ? 'No lines matched the current filter.' : 'Log file is empty.') + '</div></div>';
    renderConsoleLogBadge();
  }

  async function fetchBuildLog(forceRender) {
    if (!state.activeObjectiveId) {
      state.buildLogData = null;
      state.buildLogError = '';
      state.buildLogLoading = false;
      state.buildLogLastSignature = '';
      state.buildLogHasNewOutput = false;
      renderContext();
      if (forceRender) renderBuildLog();
      return;
    }

    const objectiveId = state.activeObjectiveId;
    const wasPinned = isBuildLogPinned();
    state.buildLogPinned = wasPinned;
    if (!state.buildLogData) state.buildLogLoading = true;
    state.buildLogError = '';
    if (forceRender) renderBuildLog();

    try {
      const data = await api(
        '/api/objectives/' + encodeURIComponent(objectiveId) +
        '/build-log?lines=200&file=' + encodeURIComponent(state.buildLogFile)
      );
      if (state.activeObjectiveId !== objectiveId) return;
      const nextSignature = buildLogSignature(data);
      const changed = state.buildLogLastSignature && state.buildLogLastSignature !== nextSignature;
      state.buildLogData = data;
      state.buildLogLastSignature = nextSignature;
      state.buildLogError = '';
      state.buildLogLoading = false;
      renderContext();
      renderBuildLog();
      if (changed && !wasPinned) {
        state.buildLogHasNewOutput = true;
        renderBuildLogBadge();
      } else if (wasPinned) {
        window.setTimeout(scrollBuildLogToBottom, 0);
      }
    } catch (error) {
      if (state.activeObjectiveId !== objectiveId) return;
      state.buildLogLoading = false;
      state.buildLogError = error.message || 'Failed to read build log';
      renderContext();
      renderBuildLog();
    }
  }

  async function fetchConsoleLog(forceRender) {
    if (!state.activeObjectiveId) {
      state.consoleLogData = null;
      state.consoleLogError = '';
      state.consoleLogLoading = false;
      state.consoleLogLastSignature = '';
      state.consoleLogHasNewOutput = false;
      renderContext();
      if (forceRender) renderConsoleLog();
      return;
    }

    const objectiveId = state.activeObjectiveId;
    const wasPinned = isConsoleLogPinned();
    state.consoleLogPinned = wasPinned;
    if (!state.consoleLogData) state.consoleLogLoading = true;
    state.consoleLogError = '';
    if (forceRender) renderConsoleLog();

    try {
      let path = '/api/objectives/' + encodeURIComponent(objectiveId) + '/console-logs?lines=500';
      if (state.consoleLogFile) {
        path += '&file=' + encodeURIComponent(state.consoleLogFile);
      }
      if (state.consoleLogFilter) {
        path += '&filter=' + encodeURIComponent(state.consoleLogFilter);
      }
      const data = await api(path);
      if (state.activeObjectiveId !== objectiveId) return;
      const nextSignature = consoleLogSignature(data);
      const changed = state.consoleLogLastSignature && state.consoleLogLastSignature !== nextSignature;
      state.consoleLogData = data;
      state.consoleLogLastSignature = nextSignature;
      state.consoleLogError = '';
      state.consoleLogLoading = false;
      if (!state.consoleLogFile && data.activeFile) state.consoleLogFile = data.activeFile;
      if (state.consoleLogFile && data.files && !data.files.includes(state.consoleLogFile)) {
        state.consoleLogFile = data.activeFile || data.files[0] || null;
      }
      renderContext();
      renderConsoleLog();
      if (changed && !wasPinned) {
        state.consoleLogHasNewOutput = true;
        renderConsoleLogBadge();
      } else if (wasPinned) {
        window.setTimeout(scrollConsoleLogToBottom, 0);
      }
    } catch (error) {
      if (state.activeObjectiveId !== objectiveId) return;
      state.consoleLogLoading = false;
      state.consoleLogError = error.message || 'Failed to read console logs';
      renderContext();
      renderConsoleLog();
    }
  }

  function stopBuildLogPoll() {
    if (state.buildLogInterval) {
      window.clearInterval(state.buildLogInterval);
      state.buildLogInterval = null;
    }
  }

  function startBuildLogPoll() {
    stopBuildLogPoll();
    if (!state.buildLogOpen || !state.buildLogAuto || !state.activeObjectiveId) return;
    state.buildLogInterval = window.setInterval(() => {
      fetchBuildLog(false).catch((error) => {
        console.error(error);
      });
    }, 3000);
  }

  function stopConsoleLogPoll() {
    if (state.consoleLogInterval) {
      window.clearInterval(state.consoleLogInterval);
      state.consoleLogInterval = null;
    }
  }

  function startConsoleLogPoll() {
    stopConsoleLogPoll();
    if (!state.consoleLogOpen || !state.consoleLogAuto || !state.activeObjectiveId) return;
    state.consoleLogInterval = window.setInterval(() => {
      fetchConsoleLog(false).catch((error) => {
        console.error(error);
      });
    }, 3000);
  }

  function toggleBuildLog() {
    state.buildLogOpen = !state.buildLogOpen;
    if (!state.buildLogOpen) {
      state.buildLogAuto = false;
      state.buildLogHasNewOutput = false;
      stopBuildLogPoll();
      renderContext();
      renderBuildLog();
      return;
    }
    if (state.consoleLogOpen) {
      state.consoleLogOpen = false;
      state.consoleLogAuto = false;
      state.consoleLogHasNewOutput = false;
      stopConsoleLogPoll();
      renderConsoleLog();
    }
    renderContext();
    renderBuildLog();
    fetchBuildLog(true);
    startBuildLogPoll();
  }

  function toggleBuildLogAuto() {
    if (!state.activeObjectiveId) return;
    state.buildLogAuto = !state.buildLogAuto;
    renderContext();
    renderBuildLog();
    if (state.buildLogAuto) {
      fetchBuildLog(false);
      startBuildLogPoll();
    } else {
      stopBuildLogPoll();
    }
  }

  function setBuildLogFile(filename) {
    const nextFile = filename === 'prebuild.log' ? 'prebuild.log' : 'build.log';
    if (state.buildLogFile === nextFile) return;
    state.buildLogFile = nextFile;
    state.buildLogData = null;
    state.buildLogError = '';
    state.buildLogLastSignature = '';
    state.buildLogHasNewOutput = false;
    renderContext();
    renderBuildLog();
    if (state.buildLogOpen) {
      fetchBuildLog(true);
      startBuildLogPoll();
    }
  }

  function setConsoleLogFilter(pattern, presetName) {
    const nextPattern = String(pattern || '');
    const nextPreset = presetName || consoleLogPresetForPattern(nextPattern).id;
    if (state.consoleLogFilter === nextPattern && state.consoleLogPreset === nextPreset) {
      renderConsoleLog();
      return;
    }
    state.consoleLogFilter = nextPattern;
    state.consoleLogDraftFilter = nextPattern;
    state.consoleLogPreset = nextPreset;
    state.consoleLogData = null;
    state.consoleLogError = '';
    state.consoleLogLastSignature = '';
    state.consoleLogHasNewOutput = false;
    renderContext();
    renderConsoleLog();
    if (state.consoleLogOpen) {
      fetchConsoleLog(true);
      startConsoleLogPoll();
    }
  }

  function applyConsoleLogPreset(presetName) {
    const preset = consoleLogPresetById(presetName);
    if (preset.id === 'custom') {
      const pattern = String(els.consoleLogCustomInput.value || '').trim();
      setConsoleLogFilter(pattern, consoleLogPresetForPattern(pattern).id);
      return;
    }
    setConsoleLogFilter(preset.pattern || '', preset.id);
  }

  function setConsoleLogFile(filename) {
    const nextFile = String(filename || '').trim() || null;
    if (state.consoleLogFile === nextFile) return;
    state.consoleLogFile = nextFile;
    state.consoleLogData = null;
    state.consoleLogError = '';
    state.consoleLogLastSignature = '';
    state.consoleLogHasNewOutput = false;
    renderContext();
    renderConsoleLog();
    if (state.consoleLogOpen) {
      fetchConsoleLog(true);
      startConsoleLogPoll();
    }
  }

  function toggleConsoleLog() {
    state.consoleLogOpen = !state.consoleLogOpen;
    if (!state.consoleLogOpen) {
      state.consoleLogAuto = false;
      state.consoleLogHasNewOutput = false;
      stopConsoleLogPoll();
      renderContext();
      renderConsoleLog();
      return;
    }
    if (state.buildLogOpen) {
      state.buildLogOpen = false;
      state.buildLogAuto = false;
      state.buildLogHasNewOutput = false;
      stopBuildLogPoll();
      renderBuildLog();
    }
    renderContext();
    renderConsoleLog();
    fetchConsoleLog(true);
    startConsoleLogPoll();
  }

  function toggleConsoleLogAuto() {
    if (!state.activeObjectiveId) return;
    state.consoleLogAuto = !state.consoleLogAuto;
    renderContext();
    renderConsoleLog();
    if (state.consoleLogAuto) {
      fetchConsoleLog(false);
      startConsoleLogPoll();
    } else {
      stopConsoleLogPoll();
    }
  }

  function resetBuildLogState() {
    stopBuildLogPoll();
    state.buildLogOpen = false;
    state.buildLogAuto = false;
    state.buildLogData = null;
    state.buildLogLoading = false;
    state.buildLogError = '';
    state.buildLogInterval = null;
    state.buildLogPinned = true;
    state.buildLogHasNewOutput = false;
    state.buildLogLastSignature = '';
    state.buildLogFile = 'build.log';
  }

  function resetConsoleLogState() {
    stopConsoleLogPoll();
    state.consoleLogOpen = false;
    state.consoleLogAuto = false;
    state.consoleLogData = null;
    state.consoleLogLoading = false;
    state.consoleLogError = '';
    state.consoleLogInterval = null;
    state.consoleLogPinned = true;
    state.consoleLogHasNewOutput = false;
    state.consoleLogLastSignature = '';
    state.consoleLogFile = null;
    state.consoleLogFilter = '';
    state.consoleLogDraftFilter = '';
    state.consoleLogPreset = 'all';
  }

  function debugJsonl(entries) {
    return (entries || []).map((entry) => JSON.stringify(entry)).join('\n');
  }

  async function fetchDebugErrorState() {
    if (!state.activeObjectiveId) {
      state.debugHasErrors = false;
      renderDebugChrome();
      return;
    }
    try {
      const errors = await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/debug?level=error&limit=1');
      state.debugHasErrors = Array.isArray(errors) && errors.length > 0;
    } catch (error) {
      state.debugHasErrors = false;
    }
    renderDebugChrome();
  }

  async function fetchDebugEntries() {
    if (!state.activeObjectiveId) {
      state.debugEntries = [];
      renderDebugModal();
      renderDebugChrome();
      return;
    }
    state.debugLoading = true;
    renderDebugModal();
    try {
      const entries = await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/debug?limit=200');
      state.debugEntries = Array.isArray(entries) ? entries : [];
      state.debugHasErrors = state.debugEntries.some((entry) => String(entry.level || '').toLowerCase() === 'error');
    } catch (error) {
      state.debugEntries = [];
      showToast(error.message || 'Could not load debug log');
    } finally {
      state.debugLoading = false;
      renderDebugModal();
      renderDebugChrome();
      window.setTimeout(scrollDebugToBottom, 0);
    }
  }

  function scrollDebugToBottom() {
    if (!state.debugOpen) return;
    els.debugLogBody.scrollTop = els.debugLogBody.scrollHeight;
  }

  function renderDebugChrome() {
    els.debugFab.disabled = !state.activeObjectiveId;
    els.debugFab.className = 'debug-fab' + (state.debugHasErrors ? ' has-errors' : '');
    els.debugModal.className = 'modal-overlay' + (state.debugOpen ? ' open' : '');
  }

  function renderDebugModal() {
    renderDebugChrome();
    els.debugModalSubtitle.textContent = currentObjectiveName();
    if (!state.debugOpen) return;
    if (state.debugLoading && !state.debugEntries.length) {
      els.debugLogBody.innerHTML = '<div class="debug-empty">Loading debug log…</div>';
      return;
    }
    if (!state.debugEntries.length) {
      els.debugLogBody.innerHTML = '<div class="debug-empty">No debug entries yet.</div>';
      return;
    }
    els.debugLogBody.innerHTML = state.debugEntries.map((entry, index) => {
      const level = String(entry.level || 'info').toLowerCase();
      const details = entry.details && typeof entry.details === 'object' ? entry.details : {};
      const detailsText = JSON.stringify(details, null, 2);
      const detailsHtml = detailsText && detailsText !== '{}'
        ? '<details' + (index === state.debugEntries.length - 1 ? ' open' : '') + '><summary>Details</summary><pre class="debug-details">' + esc(detailsText) + '</pre></details>'
        : '';
      return [
        '<div class="debug-entry">',
        '<div class="debug-entry-head">',
        '<div class="debug-entry-time">' + esc(relativeTime(entry.timestamp)) + '</div>',
        '<div class="debug-level ' + esc(level) + '">' + esc(level) + '</div>',
        '<div class="debug-event">' + esc(entry.event || 'unknown') + '</div>',
        '</div>',
        detailsHtml,
        '</div>'
      ].join('');
    }).join('');
  }

  async function openDebugModal() {
    if (!state.activeObjectiveId) return;
    state.debugOpen = true;
    renderDebugModal();
    await fetchDebugEntries();
  }

  function closeDebugModal() {
    state.debugOpen = false;
    renderDebugModal();
  }

  async function deleteActiveObjective() {
    if (!state.activeObjectiveId) return;
    const confirmed = window.confirm('Are you sure you want to clear this objective? This cannot be undone.');
    if (!confirmed) return;
    const deletingId = state.activeObjectiveId;
    try {
      await api('/api/objectives/' + encodeURIComponent(deletingId), { method: 'DELETE' });
      if (state.activeObjectiveId === deletingId) {
        state.activeObjectiveId = null;
        state.activeObjective = null;
        state.actionButtons = [];
        state.actionButtonState = {};
        state.fabModalOpen = false;
        state.messages = [];
        state.lastMessageTimestamp = null;
        state.debugEntries = [];
        state.debugHasErrors = false;
        resetBuildLogState();
        resetConsoleLogState();
        closeDebugModal();
      }
      await pollObjectives();
      if (state.activeObjectiveId) await loadActiveObjective(true);
      else render();
      showToast('Objective cleared');
    } catch (error) {
      showToast(error.message || 'Could not clear objective');
    }
  }

  function renderDiffView(diffText) {
    const lines = String(diffText || '').split('\n');
    if (!lines.length || (lines.length === 1 && !lines[0])) {
      return '<div class="diff-loading">No diff output</div>';
    }
    let oldLine = 0;
    let newLine = 0;
    const rows = lines.map((line) => {
      if (/^@@ /.test(line)) {
        const match = /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
        if (match) {
          oldLine = Number(match[1]);
          newLine = Number(match[2]);
        }
        return '<tr class="diff-row-hunk"><td colspan="3">' + esc(line) + '</td></tr>';
      }
      if (/^(diff --git|index |--- |\+\+\+ )/.test(line)) {
        return '<tr class="diff-row-hdr"><td colspan="3">' + esc(line) + '</td></tr>';
      }
      if (line.startsWith('-')) {
        const current = oldLine++;
        return '<tr class="diff-row-del"><td class="diff-ln">' + current + '</td><td class="diff-ln diff-ln-new"></td><td class="diff-content">' + esc(line) + '</td></tr>';
      }
      if (line.startsWith('+')) {
        const current = newLine++;
        return '<tr class="diff-row-add"><td class="diff-ln"></td><td class="diff-ln diff-ln-new">' + current + '</td><td class="diff-content">' + esc(line) + '</td></tr>';
      }
      if (line.startsWith('\\')) {
        return '<tr><td class="diff-ln"></td><td class="diff-ln diff-ln-new"></td><td class="diff-content">' + esc(line) + '</td></tr>';
      }
      const oldCurrent = oldLine ? oldLine++ : '';
      const newCurrent = newLine ? newLine++ : '';
      return '<tr><td class="diff-ln">' + oldCurrent + '</td><td class="diff-ln diff-ln-new">' + newCurrent + '</td><td class="diff-content">' + esc(line) + '</td></tr>';
    }).join('');
    return '<table class="diff-table"><tbody>' + rows + '</tbody></table>';
  }

  function objectiveProgress(objective) {
    const tasks = Array.isArray(objective && objective.tasks) ? objective.tasks : [];
    const total = tasks.length;
    const done = tasks.filter((task) => String(task.status).toLowerCase() === 'completed').length;
    return { done, total, percent: total ? Math.round((done / total) * 100) : 0 };
  }

  function ensureSelection() {
    const available = sortedObjectives(state.objectives);
    if (!available.length) {
      state.activeObjectiveId = null;
      state.activeObjective = null;
      state.actionButtons = [];
      state.actionButtonState = {};
      state.fabModalOpen = false;
      state.messages = [];
      state.lastMessageTimestamp = null;
      resetBuildLogState();
      resetConsoleLogState();
      return;
    }
    if (state.activeObjectiveId && available.some((item) => item.id === state.activeObjectiveId)) {
      return;
    }
    const running = available.find((item) => ['planning', 'plan_review', 'executing', 'reviewing', 'rework'].includes(String(item.status).toLowerCase()));
    state.activeObjectiveId = (running || available[0]).id;
  }

  function isNearBottom() {
    const el = els.messagesPane;
    return (el.scrollHeight - el.scrollTop - el.clientHeight) < 100;
  }

  function scrollToBottom() {
    els.messagesPane.scrollTop = els.messagesPane.scrollHeight;
  }

  function autoResizeTextarea() {
    const el = els.chatInput;
    const baseHeight = state.isMobile ? 22 : 24;
    const maxHeight = state.isMobile ? 108 : 140;
    el.style.height = baseHeight + 'px';
    el.style.height = Math.min(el.scrollHeight, maxHeight) + 'px';
  }

  function showToast(text) {
    const node = document.createElement('div');
    node.className = 'toast';
    node.textContent = text;
    els.toastWrap.appendChild(node);
    window.setTimeout(() => {
      node.remove();
    }, 2600);
  }

  async function copyText(value, label) {
    const text = String(value || '').trim();
    if (!text) return;
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text);
      } else {
        const input = document.createElement('textarea');
        input.value = text;
        input.setAttribute('readonly', 'readonly');
        input.style.position = 'fixed';
        input.style.opacity = '0';
        document.body.appendChild(input);
        input.select();
        document.execCommand('copy');
        document.body.removeChild(input);
      }
      showToast((label || 'Copied') + ' copied');
    } catch (error) {
      showToast('Copy failed');
    }
  }

  function syncDraftsFromConfig() {
    if (!state.config) return;
    if (!state.draftProjectDir) state.draftProjectDir = state.config.defaultProjectDir || '';
    if (!state.draftBaseBranch || state.draftBaseBranch === 'main') {
      state.draftBaseBranch = state.config.defaultBaseBranch || 'main';
    }
  }

  function populateSettingsForm() {
    const cfg = state.config || {};
    els.settingsProjectDir.value = cfg.defaultProjectDir || '';
    els.settingsBaseBranch.value = cfg.defaultBaseBranch || 'main';
    els.settingsPollInterval.value = cfg.pollInterval != null ? String(cfg.pollInterval) : '5';
    els.settingsReviewEnabled.checked = !!cfg.reviewEnabled;
    els.settingsReviewModel.value = cfg.reviewModel || '';
    els.settingsReviewBackend.value = ['claude', 'lmstudio', 'ollama'].includes(cfg.reviewBackend) ? cfg.reviewBackend : 'ollama';
  }

  function renderSettingsModal() {
    els.settingsModal.className = 'modal-overlay' + (state.settingsOpen ? ' open' : '');
    els.settingsSaveButton.disabled = state.settingsSaving;
    els.settingsCancelButton.disabled = state.settingsSaving;
    els.settingsCloseButton.disabled = state.settingsSaving;
  }

  function openSettingsModal() {
    populateSettingsForm();
    state.settingsOpen = true;
    renderSettingsModal();
  }

  function closeSettingsModal() {
    if (state.settingsSaving) return;
    state.settingsOpen = false;
    renderSettingsModal();
  }

  async function loadConfig() {
    const config = await api('/api/config');
    state.config = config || {};
    syncDraftsFromConfig();
    return state.config;
  }

  async function saveSettings() {
    state.settingsSaving = true;
    renderSettingsModal();
    try {
      const payload = {
        defaultProjectDir: els.settingsProjectDir.value.trim(),
        defaultBaseBranch: els.settingsBaseBranch.value.trim() || 'main',
        pollInterval: Number(els.settingsPollInterval.value || 5),
        reviewEnabled: !!els.settingsReviewEnabled.checked,
        reviewModel: els.settingsReviewModel.value.trim(),
        reviewBackend: els.settingsReviewBackend.value || 'ollama'
      };
      const config = await api('/api/config', {
        method: 'POST',
        body: JSON.stringify(payload)
      });
      state.config = config || payload;
      state.draftProjectDir = state.config.defaultProjectDir || '';
      state.draftBaseBranch = state.config.defaultBaseBranch || 'main';
      state.settingsOpen = false;
      render();
      showToast('Settings saved');
      installPollers();
    } catch (error) {
      showToast(error.message || 'Could not save settings');
    } finally {
      state.settingsSaving = false;
      renderSettingsModal();
    }
  }

  function hideGitContextMenu() {
    els.gitContextMenu.classList.remove('visible');
    state.gitContextFile = '';
    state.gitContextSection = '';
  }

  function setDiffTabState(tab) {
    state.gitDiffTab = tab === 'preview' ? 'preview' : 'diff';
    els.diffTabDiff.classList.toggle('active', state.gitDiffTab === 'diff');
    els.diffTabPreview.classList.toggle('active', state.gitDiffTab === 'preview');
  }

  async function switchDiffTab(tab) {
    if (tab === 'preview' && !state.gitDiffIsMarkdown) return;
    const path = activeGitPath();
    const file = state.gitDiffFile;
    if (!path || !file) return;
    setDiffTabState(tab);

    if (state.gitDiffTab === 'diff') {
      els.diffPanelBody.innerHTML = state.gitDiffCache.diffHtml || '<div class="diff-loading">Loading diff…</div>';
      return;
    }

    if (state.gitDiffCache.previewHtml) {
      els.diffPanelBody.innerHTML = state.gitDiffCache.previewHtml;
      return;
    }

    els.diffPanelBody.innerHTML = '<div class="diff-loading">Loading preview…</div>';
    try {
      const response = await api('/api/file-content', {
        method: 'POST',
        body: JSON.stringify({ path, file })
      });
      if (state.gitDiffFile !== file || state.gitDiffTab !== 'preview') return;
      state.gitDiffCache.previewHtml = response.ok
        ? renderMarkdown(response.content || '', 'md-preview')
        : '<div class="diff-loading" style="color:var(--red)">' + esc(response.error || 'Failed to load preview') + '</div>';
      els.diffPanelBody.innerHTML = state.gitDiffCache.previewHtml;
    } catch (error) {
      if (state.gitDiffFile !== file || state.gitDiffTab !== 'preview') return;
      state.gitDiffCache.previewHtml = '<div class="diff-loading" style="color:var(--red)">' + esc(error.message || 'Failed to load preview') + '</div>';
      els.diffPanelBody.innerHTML = state.gitDiffCache.previewHtml;
    }
  }

  function closeDiffOverlay() {
    state.gitDiffFile = '';
    state.gitDiffSection = 'unstaged';
    state.gitDiffIsMarkdown = false;
    state.gitDiffCache = { diffHtml: '', previewHtml: '' };
    if (els.diffTabs) els.diffTabs.style.display = 'none';
    setDiffTabState('diff');
    els.diffOverlay.classList.remove('visible');
    els.diffPanelBody.innerHTML = '';
  }

  async function openGitDiff(file, section) {
    const path = activeGitPath();
    if (!path || !file) return;
    state.gitDiffFile = file;
    state.gitDiffSection = section || 'unstaged';
    state.gitDiffIsMarkdown = /\.md$/i.test(file);
    state.gitDiffCache = { diffHtml: '', previewHtml: '' };
    if (els.diffTabs) els.diffTabs.style.display = state.gitDiffIsMarkdown ? 'flex' : 'none';
    setDiffTabState('diff');
    els.diffPanelTitle.textContent = file;
    els.diffPanelBody.innerHTML = '<div class="diff-loading">Loading diff…</div>';
    els.diffOverlay.classList.add('visible');
    try {
      const response = await api('/api/git-diff-path', {
        method: 'POST',
        body: JSON.stringify({ path, file, section: state.gitDiffSection })
      });
      if (state.gitDiffFile !== file) return;
      state.gitDiffCache.diffHtml = response.ok
        ? renderDiffView(response.diff || '')
        : '<div class="diff-loading" style="color:var(--red)">' + esc(response.error || 'Failed to load diff') + '</div>';
      if (state.gitDiffTab === 'diff') {
        els.diffPanelBody.innerHTML = state.gitDiffCache.diffHtml;
      }
    } catch (error) {
      if (state.gitDiffFile !== file) return;
      state.gitDiffCache.diffHtml = '<div class="diff-loading" style="color:var(--red)">' + esc(error.message || 'Failed to load diff') + '</div>';
      if (state.gitDiffTab === 'diff') {
        els.diffPanelBody.innerHTML = state.gitDiffCache.diffHtml;
      }
    }
  }

  async function runGitContextAction(action) {
    const path = activeGitPath();
    const file = state.gitContextFile;
    const section = state.gitContextSection;
    hideGitContextMenu();
    if (!path || !file) return;
    if (action === 'diff') {
      await openGitDiff(file, section);
      return;
    }
    const endpoint = action === 'stage' ? '/api/git-stage-path' : '/api/git-unstage-path';
    try {
      await api(endpoint, {
        method: 'POST',
        body: JSON.stringify({ path, file })
      });
      await fetchGitStatus();
    } catch (error) {
      showToast(error.message || 'Git action failed');
    }
  }

  function showGitContextMenu(event, file, section) {
    if (!file || !section) return;
    state.gitContextFile = file;
    state.gitContextSection = section;
    let html = '';
    if (section === 'unstaged' || section === 'untracked') {
      html += '<div class="git-ctx-item" data-git-action="stage">Stage file</div>';
    }
    if (section === 'staged') {
      html += '<div class="git-ctx-item" data-git-action="unstage">Unstage file</div>';
    }
    html += '<div class="git-ctx-item" data-git-action="diff">View diff</div>';
    els.gitContextMenu.innerHTML = html;
    els.gitContextMenu.classList.add('visible');
    let x = event.clientX;
    let y = event.clientY;
    const rect = els.gitContextMenu.getBoundingClientRect();
    if (x + rect.width > window.innerWidth) x = window.innerWidth - rect.width - 4;
    if (y + rect.height > window.innerHeight) y = window.innerHeight - rect.height - 4;
    els.gitContextMenu.style.left = x + 'px';
    els.gitContextMenu.style.top = y + 'px';
  }

  function renderGitPanel() {
    const path = activeGitPath();
    els.gitPanel.className = 'git-panel' + (state.gitPanelOpen ? ' open' : '');
    els.gitPanelBranch.textContent = (state.gitStatus && state.gitStatus.branch) || (state.activeObjective && state.activeObjective.branchName) || 'Git';
    els.gitPanelPath.textContent = (state.gitStatus && state.gitStatus.cwd) || path || 'No working directory';
    els.gitPanelCopyButton.disabled = !((state.gitStatus && state.gitStatus.cwd) || path);
    const data = state.gitStatus;
    if (!state.gitPanelOpen) return;
    if (!path) {
      els.gitPanelBody.innerHTML = '<div class="git-empty">No active objective worktree</div>';
      return;
    }
    if (!data) {
      els.gitPanelBody.innerHTML = '<div class="diff-loading">Loading git status…</div>';
      return;
    }
    const staged = Array.isArray(data.staged) ? data.staged : [];
    const unstaged = Array.isArray(data.unstaged) ? data.unstaged : [];
    const untracked = Array.isArray(data.untracked) ? data.untracked : [];
    const commits = Array.isArray(data.commits) ? data.commits : [];
    if (!staged.length && !unstaged.length && !untracked.length && !commits.length) {
      els.gitPanelBody.innerHTML = '<div class="git-empty">' + (data.cwd ? 'Working tree clean' : 'No git repo detected') + '</div>';
      return;
    }
    function fileEl(status, file, cls, section) {
      return '<div class="git-file" data-git-file="' + esc(file) + '" data-git-section="' + esc(section) + '" title="' + esc(file) + '"><span class="git-status ' + cls + '">' + esc(status) + '</span><span class="git-file-name">' + esc(file) + '</span></div>';
    }
    let html = '';
    if (commits.length) {
      html += '<div class="git-section"><div class="git-section-title commits">Commits</div>';
      commits.forEach((commit) => {
        const isExpanded = state.gitExpandedCommit === commit.hash;
        const chevron = '<span class="git-commit-chevron">' + (isExpanded ? '▼' : '►') + '</span>';
        html += '<div class="git-commit' + (isExpanded ? ' expanded' : '') + '" data-commit-hash="' + esc(commit.hash) + '">' + chevron + '<span class="git-hash">' + esc(commit.hash) + '</span>' + esc(commit.message) + '</div>';
        if (isExpanded) {
          if (state.gitCommitFilesLoading) {
            html += '<div class="git-commit-files"><div class="diff-loading">Loading files…</div></div>';
          } else if (state.gitCommitFiles.length) {
            html += '<div class="git-commit-files">';
            state.gitCommitFiles.forEach((cf) => {
              const statusCls = 'cf-' + (cf.status || 'M').charAt(0);
              html += '<div class="git-commit-file" data-commit-file="' + esc(cf.file) + '" data-commit-hash="' + esc(commit.hash) + '"><span class="git-cf-status ' + statusCls + '">' + esc(cf.status) + '</span><span class="git-file-name">' + esc(cf.file) + '</span></div>';
            });
            html += '</div>';
          } else {
            html += '<div class="git-commit-files"><div class="git-empty" style="padding:4px 0;font-size:11px">No files changed</div></div>';
          }
        }
      });
      html += '</div>';
    }
    if (staged.length) {
      html += '<div class="git-section"><div class="git-section-title staged">Staged</div>';
      staged.forEach((item) => {
        html += fileEl(item.status, item.file, 'st-staged', 'staged');
      });
      html += '</div>';
    }
    if (unstaged.length) {
      html += '<div class="git-section"><div class="git-section-title unstaged">Unstaged</div>';
      unstaged.forEach((item) => {
        html += fileEl(item.status, item.file, 'st-unstaged', 'unstaged');
      });
      html += '</div>';
    }
    if (untracked.length) {
      html += '<div class="git-section"><div class="git-section-title untracked">Untracked</div>';
      untracked.forEach((item) => {
        html += fileEl('?', item, 'st-untracked', 'untracked');
      });
      html += '</div>';
    }
    els.gitPanelBody.innerHTML = html;
    els.gitPanelBody.querySelectorAll('[data-git-file]').forEach((node) => {
      node.addEventListener('click', () => {
        openGitDiff(node.getAttribute('data-git-file'), node.getAttribute('data-git-section'));
      });
      node.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        showGitContextMenu(event, node.getAttribute('data-git-file'), node.getAttribute('data-git-section'));
      });
    });
    els.gitPanelBody.querySelectorAll('[data-commit-hash].git-commit').forEach((node) => {
      node.addEventListener('click', () => {
        toggleCommitExpansion(node.getAttribute('data-commit-hash'));
      });
    });
    els.gitPanelBody.querySelectorAll('[data-commit-file]').forEach((node) => {
      node.addEventListener('click', (event) => {
        event.stopPropagation();
        openCommitDiff(node.getAttribute('data-commit-hash'), node.getAttribute('data-commit-file'));
      });
    });
  }

  async function openWorkerOutput(taskId) {
    if (!state.activeObjectiveId || !taskId) return;
    state.workerOutputTaskId = taskId;
    state.workerOutputContent = '';
    const task = findTask(taskId);
    els.workerOutputTitle.textContent = 'Worker Output' + (task ? ' \u2014 ' + taskDisplayTitle(task) : '');
    els.workerOutputBody.innerHTML = '<div class="diff-loading">Loading output\u2026</div>';
    els.workerOutputOverlay.classList.add('visible');
    await refreshWorkerOutput();
  }

  async function refreshWorkerOutput() {
    const taskId = state.workerOutputTaskId;
    if (!taskId || !state.activeObjectiveId) return;
    try {
      const response = await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/tasks/' + encodeURIComponent(taskId) + '/screen');
      if (state.workerOutputTaskId !== taskId) return;
      if (response.ok) {
        state.workerOutputContent = response.screen || '';
        const lines = state.workerOutputContent.split('\n');
        const html = lines.map((line) => '<div class="wo-line">' + esc(line) + '</div>').join('');
        els.workerOutputBody.innerHTML = '<div class="worker-output-content">' + html + '</div>';
        els.workerOutputBody.scrollTop = els.workerOutputBody.scrollHeight;
      } else {
        els.workerOutputBody.innerHTML = '<div class="diff-loading" style="color:var(--red)">' + esc(response.error || 'Failed to load output') + '</div>';
      }
    } catch (error) {
      if (state.workerOutputTaskId !== taskId) return;
      els.workerOutputBody.innerHTML = '<div class="diff-loading" style="color:var(--red)">' + esc(error.message || 'Failed to load output') + '</div>';
    }
  }

  function closeWorkerOutput() {
    state.workerOutputTaskId = null;
    state.workerOutputContent = '';
    state.workerOutputPolling = false;
    els.workerOutputOverlay.classList.remove('visible');
    els.workerOutputBody.innerHTML = '';
  }

  async function toggleCommitExpansion(hash) {
    if (state.gitExpandedCommit === hash) {
      state.gitExpandedCommit = null;
      state.gitCommitFiles = [];
      state.gitCommitFilesLoading = false;
      renderGitPanel();
      return;
    }
    state.gitExpandedCommit = hash;
    state.gitCommitFiles = [];
    state.gitCommitFilesLoading = true;
    renderGitPanel();
    try {
      const response = await api('/api/git-commit-files', {
        method: 'POST',
        body: JSON.stringify({ path: activeGitPath(), hash })
      });
      if (state.gitExpandedCommit !== hash) return;
      state.gitCommitFiles = response.ok ? (response.files || []) : [];
    } catch (error) {
      if (state.gitExpandedCommit !== hash) return;
      state.gitCommitFiles = [];
    }
    state.gitCommitFilesLoading = false;
    renderGitPanel();
  }

  async function openCommitDiff(hash, file) {
    const path = activeGitPath();
    if (!path || !hash || !file) return;
    const shortHash = hash.substring(0, 7);
    state.gitDiffFile = file;
    state.gitDiffSection = 'commit';
    state.gitDiffIsMarkdown = /\.md$/i.test(file);
    state.gitDiffCache = { diffHtml: '', previewHtml: '' };
    if (els.diffTabs) els.diffTabs.style.display = state.gitDiffIsMarkdown ? 'flex' : 'none';
    setDiffTabState('diff');
    els.diffPanelTitle.textContent = file + ' @ ' + shortHash;
    els.diffPanelBody.innerHTML = '<div class="diff-loading">Loading diff\u2026</div>';
    els.diffOverlay.classList.add('visible');
    try {
      const response = await api('/api/git-commit-diff', {
        method: 'POST',
        body: JSON.stringify({ path, hash, file })
      });
      if (state.gitDiffFile !== file) return;
      state.gitDiffCache.diffHtml = response.ok
        ? renderDiffView(response.diff || '')
        : '<div class="diff-loading" style="color:var(--red)">' + esc(response.error || 'Failed to load diff') + '</div>';
      if (state.gitDiffTab === 'diff') {
        els.diffPanelBody.innerHTML = state.gitDiffCache.diffHtml;
      }
    } catch (error) {
      if (state.gitDiffFile !== file) return;
      state.gitDiffCache.diffHtml = '<div class="diff-loading" style="color:var(--red)">' + esc(error.message || 'Failed to load diff') + '</div>';
      if (state.gitDiffTab === 'diff') {
        els.diffPanelBody.innerHTML = state.gitDiffCache.diffHtml;
      }
    }
  }

  async function fetchGitStatus() {
    const path = activeGitPath();
    if (!state.gitPanelOpen || !path) {
      state.gitStatus = null;
      renderGitPanel();
      return;
    }
    try {
      const response = await api('/api/git-status-path?path=' + encodeURIComponent(path));
      state.gitStatus = response.ok ? response : null;
      renderGitPanel();
    } catch (error) {
      state.gitStatus = null;
      renderGitPanel();
      showToast(error.message || 'Could not load git status');
    }
  }

  function closeGitPanel() {
    state.gitPanelOpen = false;
    renderContext();
    renderGitPanel();
    hideGitContextMenu();
    closeDiffOverlay();
  }

  function toggleGitPanel() {
    if (!activeGitPath()) return;
    state.gitPanelOpen = !state.gitPanelOpen;
    renderContext();
    renderGitPanel();
    if (state.gitPanelOpen) {
      fetchGitStatus();
    } else {
      hideGitContextMenu();
      closeDiffOverlay();
    }
  }

  function updateSidebarFormFromState() {
    const recent = getRecentProjects();
    const options = recent.map((dir) => '<option value="' + esc(dir) + '"></option>').join('');
    const className = 'sidebar-form' + (state.sidebarFormOpen ? ' open' : '');
    const nextHtml = [
      '<input class="sf-input" id="projectDirInput" list="recentProjectDirs" placeholder="Project directory" value="' + esc(state.draftProjectDir) + '">',
      '<datalist id="recentProjectDirs">' + options + '</datalist>',
      '<div class="sf-row">',
      '<input class="sf-input" id="baseBranchInput" placeholder="Base branch" value="' + esc(state.draftBaseBranch || 'main') + '">',
      '</div>',
      '<input class="sf-input" id="branchNameInput" placeholder="Feature branch name (optional)" value="' + esc(state.draftBranchName || '') + '">',
      '<textarea class="sf-textarea" id="sidebarGoalInput" placeholder="Describe the objective">' + esc(state.draftGoal) + '</textarea>',
      '<div class="sf-actions">',
      '<button class="sf-submit" id="sidebarCreateButton">Create &amp; start</button>',
      '<button class="sf-cancel" id="sidebarCancelButton">Cancel</button>',
      '</div>',
      '<div class="sf-hint">Paste a project path, e.g. <span class="mono">~/projects/my-app</span>. The last project is prefilled when available.</div>'
    ].join('');
    if (els.sidebarForm.className === className && els.sidebarForm.innerHTML === nextHtml) return;
    els.sidebarForm.className = className;
    els.sidebarForm.innerHTML = nextHtml;
    if (!state.sidebarFormOpen) return;
    const projectDirInput = document.getElementById('projectDirInput');
    const baseBranchInput = document.getElementById('baseBranchInput');
    const branchNameInput = document.getElementById('branchNameInput');
    const sidebarGoalInput = document.getElementById('sidebarGoalInput');
    document.getElementById('sidebarCreateButton').addEventListener('click', submitSidebarObjective);
    document.getElementById('sidebarCancelButton').addEventListener('click', () => {
      state.sidebarFormOpen = false;
      updateSidebarFormFromState();
    });
    projectDirInput.addEventListener('input', (event) => {
      state.draftProjectDir = event.target.value;
    });
    baseBranchInput.addEventListener('input', (event) => {
      state.draftBaseBranch = event.target.value || 'main';
    });
    branchNameInput.addEventListener('input', (event) => {
      state.draftBranchName = event.target.value;
    });
    sidebarGoalInput.addEventListener('input', (event) => {
      state.draftGoal = event.target.value;
    });
  }

  function openSidebarForm(seedGoal) {
    openSidebar();
    state.sidebarFormOpen = true;
    state.draftProjectDir = state.draftProjectDir || defaultProjectDir();
    state.draftBaseBranch = defaultBaseBranch();
    state.draftBranchName = state.draftBranchName || '';
    if (typeof seedGoal === 'string') state.draftGoal = seedGoal;
    updateSidebarFormFromState();
    window.setTimeout(() => {
      const input = document.getElementById('projectDirInput');
      if (input) input.focus();
    }, 0);
  }

  function checkpointStatus(status) {
    const value = String(status || '').toLowerCase();
    if (value === 'done' || value === 'completed') return 'done';
    if (value === 'in_progress' || value === 'active' || value === 'executing') return 'active';
    return 'pending';
  }

  function taskMap() {
    const map = {};
    ((state.activeObjective && state.activeObjective.tasks) || []).forEach((task) => {
      map[task.id] = task;
    });
    return map;
  }

  function findTask(taskId) {
    return taskMap()[taskId] || null;
  }

  function taskTitle(taskId) {
    const task = findTask(taskId);
    return task ? task.title : taskId;
  }

  function renderSidebar() {
    const items = sortedObjectives(state.objectives);
    if (!items.length) {
      els.objectiveList.innerHTML = '<div class="obj-item" style="cursor:default"><div class="obj-info"><div class="obj-name" style="color:var(--t2)">No objectives yet</div><div class="obj-progress">Create one to start the orchestrator.</div></div></div>';
      return;
    }
    els.objectiveList.innerHTML = items.map((objective) => {
      const meta = statusMeta(objective.status);
      const progress = objectiveProgress(objective);
      const active = objective.id === state.activeObjectiveId ? ' active' : '';
      const doneClass = String(objective.status).toLowerCase() === 'completed' ? ' done' : '';
      let progressText = progress.total ? (progress.done + ' of ' + progress.total + ' done') : meta.label.toLowerCase();
      if (String(objective.status).toLowerCase() === 'completed') {
        progressText = 'done · ' + relativeTime(objective.updatedAt || objective.createdAt);
      } else if (String(objective.status).toLowerCase() === 'failed') {
        progressText = 'failed · ' + relativeTime(objective.updatedAt || objective.createdAt);
      }
      return [
        '<div class="obj-item' + active + doneClass + '" data-objective-id="' + esc(objective.id) + '">',
        '<div class="obj-dot ' + meta.dot + '"></div>',
        '<div class="obj-info">',
        '<div class="obj-name">' + esc(objective.goal || 'Untitled objective') + '</div>',
        '<div class="obj-progress">',
        '<div class="obj-prog-bar"><div class="obj-prog-fill ' + meta.fill + '" style="width:' + progress.percent + '%"></div></div>',
        '<span>' + esc(progressText) + '</span>',
        '</div>',
        '</div>',
        '</div>'
      ].join('');
    }).join('');
    els.objectiveList.querySelectorAll('[data-objective-id]').forEach((node) => {
      node.addEventListener('click', () => {
        const id = node.getAttribute('data-objective-id');
        if (!id) return;
        if (id !== state.activeObjectiveId) {
          state.activeObjectiveId = id;
          loadActiveObjective(true);
        }
        closeSidebar();
      });
    });
  }

  function renderContext() {
    const objective = state.activeObjective || sortedObjectives(state.objectives).find((item) => item.id === state.activeObjectiveId);
    if (!objective) {
      els.contextStrip.innerHTML = state.isMobile
        ? [
            '<button class="mobile-menu-btn" id="mobileMenuBtn" type="button" aria-label="Open sidebar" aria-expanded="false">☰</button>',
            '<div class="ctx-main">',
            '<div class="ctx-mobile-row primary"><div class="ctx-title">No objective selected</div></div>',
            '<div class="ctx-mobile-row secondary">',
            '<div class="ctx-dot od-queued" title="Idle" aria-label="Idle"></div>',
            '<div class="ctx-meta">waiting</div>',
            '</div>',
            '</div>',
            '<div class="ctx-actions"><div class="ctx-badge badge-queued">Idle</div></div>'
          ].join('')
        : [
            '<div class="ctx-dot od-queued"></div>',
            '<div class="ctx-main">',
            '<div class="ctx-title">No objective selected</div>',
            '<div class="ctx-secondary"><div class="ctx-meta">waiting</div></div>',
            '</div>',
            '<div class="ctx-actions"><div class="ctx-badge badge-queued">Idle</div></div>'
          ].join('');
      const menuButton = document.getElementById('mobileMenuBtn');
      if (menuButton) {
        menuButton.addEventListener('click', toggleSidebar);
      }
      return;
    }
    const meta = statusMeta(objective.status);
    const progress = objectiveProgress(objective);
    const elapsed = durationFrom(objective.createdAt, String(objective.status).toLowerCase() === 'completed' ? objective.updatedAt : null) || relativeTime(objective.createdAt);
    const taskCount = progress.total + ' task' + (progress.total === 1 ? '' : 's');
    const gitPath = activeGitPath();
    const branchName = objective.branchName ? String(objective.branchName) : '';
    const sessionActive = !!objective.orchestratorSessionActive;
    const logIndicator = state.buildLogAuto && state.buildLogData && state.buildLogData.exists
      ? '<span class="ctx-icon-indicator"></span>'
      : '';
    const consoleLogIndicator = state.consoleLogData && state.consoleLogData.exists
      ? '<span class="ctx-icon-indicator"></span>'
      : '';
    const logButtonClass = 'ctx-icon-button has-indicator' + (state.buildLogOpen ? ' log-active' : '');
    const consoleLogButtonClass = 'ctx-icon-button has-indicator' + (state.consoleLogOpen ? ' log-active' : '');
    els.contextStrip.innerHTML = state.isMobile
      ? [
          '<button class="mobile-menu-btn" id="mobileMenuBtn" type="button" aria-label="Open sidebar" aria-expanded="false">☰</button>',
          '<div class="ctx-main">',
          '<div class="ctx-mobile-row primary">',
          '<div class="ctx-title">' + esc(objective.goal || 'Untitled objective') + '</div>',
          '</div>',
          '<div class="ctx-mobile-row secondary">',
          '<div class="ctx-dot ' + meta.dot + '" title="' + esc(meta.label) + '" aria-label="' + esc(meta.label) + '"></div>',
          '<div class="ctx-meta">' + esc(taskCount) + '</div>',
          '<div class="ctx-meta">' + esc(elapsed) + '</div>',
          branchName ? '<div class="ctx-meta mono">' + esc(branchName) + '</div>' : '',
          '<div class="ctx-session' + (sessionActive ? ' active' : '') + '"><div class="ctx-session-dot"></div><span>' + esc(sessionActive ? 'Session active' : 'Session idle') + '</span></div>',
          gitPath ? '<button class="ctx-git-button' + (state.gitPanelOpen ? ' open' : '') + '" id="gitPanelToggleButton" type="button">' + esc(gitButtonLabel()) + '</button>' : '',
          '</div>',
          '</div>',
          '<div class="ctx-actions">',
          '<button class="' + consoleLogButtonClass + '" id="consoleLogToggleButton" type="button" title="Toggle console logs" aria-label="Toggle console logs">&gt;_' + consoleLogIndicator + '</button>',
          '<button class="' + logButtonClass + '" id="buildLogToggleButton" type="button" title="Toggle build log" aria-label="Toggle build log">⎔' + logIndicator + '</button>',
          '<button class="ctx-icon-button danger" id="clearObjectiveButton" type="button" title="Clear objective" aria-label="Clear objective">🗑</button>',
          '</div>'
        ].join('')
      : [
          '<div class="ctx-dot ' + meta.dot + '"></div>',
          '<div class="ctx-main">',
          '<div class="ctx-title">' + esc(objective.goal || 'Untitled objective') + '</div>',
          '<div class="ctx-secondary">',
          '<div class="ctx-meta">' + esc(elapsed + ' · ' + taskCount) + '</div>',
          branchName ? '<div class="ctx-meta mono">' + esc(branchName) + '</div>' : '',
          '<div class="ctx-session' + (sessionActive ? ' active' : '') + '"><div class="ctx-session-dot"></div><span>' + esc(sessionActive ? 'Session active' : 'Session idle') + '</span></div>',
          '</div>',
          '</div>',
          '<div class="ctx-actions">',
          gitPath ? '<button class="ctx-git-button' + (state.gitPanelOpen ? ' open' : '') + '" id="gitPanelToggleButton" type="button">' + esc(gitButtonLabel()) + '</button>' : '',
          '<button class="' + consoleLogButtonClass + '" id="consoleLogToggleButton" type="button" title="Toggle console logs" aria-label="Toggle console logs">&gt;_' + consoleLogIndicator + '</button>',
          '<button class="' + logButtonClass + '" id="buildLogToggleButton" type="button" title="Toggle build log" aria-label="Toggle build log">⎔' + logIndicator + '</button>',
          '<button class="ctx-icon-button danger" id="clearObjectiveButton" type="button" title="Clear objective" aria-label="Clear objective">🗑</button>',
          '<div class="ctx-badge ' + meta.badge + '">' + esc(meta.label) + '</div>',
          '</div>'
        ].join('');
    const gitButton = document.getElementById('gitPanelToggleButton');
    if (gitButton) {
      gitButton.addEventListener('click', toggleGitPanel);
    }
    const menuButton = document.getElementById('mobileMenuBtn');
    if (menuButton) {
      menuButton.addEventListener('click', toggleSidebar);
    }
    const clearButton = document.getElementById('clearObjectiveButton');
    if (clearButton) {
      clearButton.addEventListener('click', deleteActiveObjective);
    }
    const buildLogButton = document.getElementById('buildLogToggleButton');
    if (buildLogButton) {
      buildLogButton.addEventListener('click', toggleBuildLog);
    }
    const consoleLogButton = document.getElementById('consoleLogToggleButton');
    if (consoleLogButton) {
      consoleLogButton.addEventListener('click', toggleConsoleLog);
    }
  }

  function shouldCollapseAutoApproval(message) {
    if (!message || message.type !== 'system') return false;
    return /auto-approved/i.test(message.content || '');
  }

  function isHiddenSystemMessage(message) {
    if (!message || message.type !== 'system') return false;
    const content = String(message.content || '').trim();
    if (!content) return false;
    if (/No launchable tasks found\. Task statuses:/i.test(content)) return true;
    if (/terminal active but no progress updates/i.test(content)) return true;
    if (/Reviewing Task task-/i.test(content)) return true;
    if (/Launching \d+ ready tasks:/i.test(content)) return true;
    if (/^Task task-[A-Za-z0-9_-]+:.*[--]\s*launched$/i.test(content)) return true;
    if (/^Task task-[A-Za-z0-9_-]+: completed, starting review\.\.\.$/i.test(content)) return true;
    if (/^\[\((?:\\x27|')[\s\S]*\)\]$/.test(content) && /(\\x27|')task-[A-Za-z0-9_-]+/.test(content)) return true;
    return false;
  }

  function extractTaskId(message) {
    const metadataId = message && message.metadata && message.metadata.task_id;
    if (metadataId) return metadataId;
    const match = /Task\s+([A-Za-z0-9_-]+)/i.exec(message && message.content || '');
    return match ? match[1] : null;
  }

  function normalizeMessages(messages) {
    const items = [];
    let insertedSyntheticPlan = false;
    const tasks = (state.activeObjective && state.activeObjective.tasks) || [];
    const hasPlanMessage = messages.some((message) => message.type === 'plan' || message.type === 'plan_review');

    messages.forEach((message) => {
      if (isHiddenSystemMessage(message)) return;
      const taskId = extractTaskId(message);
      if (shouldCollapseAutoApproval(message)) {
        const previous = items[items.length - 1];
        if (previous && previous.kind === 'approval-burst') {
          previous.count += 1;
          previous.lastTimestamp = message.timestamp;
          if (taskId && !previous.taskIds.includes(taskId)) previous.taskIds.push(taskId);
        } else {
          items.push({
            kind: 'approval-burst',
            id: 'burst-' + message.id,
            taskIds: taskId ? [taskId] : [],
            count: 1,
            firstTimestamp: message.timestamp,
            lastTimestamp: message.timestamp
          });
        }
        return;
      }

      items.push({
        kind: message.type,
        id: message.id,
        message,
        taskId
      });

      if (!insertedSyntheticPlan && !hasPlanMessage && tasks.length) {
        const content = String(message.content || '');
        if (message.type === 'system' && /plan ready|tasks identified|broken this into/i.test(content)) {
          items.push({ kind: 'plan-synthetic', id: 'synthetic-plan', message });
          insertedSyntheticPlan = true;
        }
      }
    });

    if (!insertedSyntheticPlan && !hasPlanMessage && tasks.length) {
      const insertAt = items.findIndex((item) => item.kind === 'user');
      const synthetic = { kind: 'plan-synthetic', id: 'synthetic-plan', message: { timestamp: state.activeObjective.updatedAt || state.activeObjective.createdAt } };
      if (insertAt >= 0) {
        items.splice(insertAt + 1, 0, synthetic);
      } else {
        items.unshift(synthetic);
      }
    }
    return items;
  }

  function renderPlanReviewCard(message) {
    const metadata = message.metadata || {};
    const tasks = Array.isArray(metadata.tasks) ? metadata.tasks : [];
    return [
      '<div class="card-plan-review">',
      '<div class="plan-review-head">',
      '<div class="plan-review-title">Plan Review</div>',
      '<div class="plan-review-count">' + esc(tasks.length + ' task' + (tasks.length === 1 ? '' : 's')) + '</div>',
      '</div>',
      '<div class="plan-review-body">',
      tasks.map((task, index) => [
        '<div class="plan-review-task">',
        '<div class="plan-review-task-head">',
        '<div class="plan-review-task-number">Task ' + esc(String(index + 1)) + '</div>',
        '<div class="plan-review-task-title">' + esc(task.title || task.id || ('Task ' + (index + 1))) + '</div>',
        '</div>',
        '<div class="plan-review-row">',
        '<div class="plan-review-label">User Story</div>',
        '<div class="plan-review-list">' + (task.userStory
          ? '<span class="plan-review-chip">' + esc(task.userStory) + '</span>'
          : '<span class="plan-review-chip">none listed</span>') + '</div>',
        '</div>',
        '<div class="plan-review-row">',
        '<div class="plan-review-label">Deliverables</div>',
        '<div class="plan-review-list">' + ((task.deliverables || []).length
          ? task.deliverables.map((item) => '<span class="plan-review-chip">' + esc(item) + '</span>').join('')
          : '<span class="plan-review-chip">none listed</span>') + '</div>',
        '</div>',
        '<div class="plan-review-row">',
        '<div class="plan-review-label">Dependencies</div>',
        '<div class="plan-review-list">' + ((task.dependsOn || []).length
          ? task.dependsOn.map((dep) => '<span class="plan-review-chip">' + esc(dep) + '</span>').join('')
          : '<span class="plan-review-chip">none</span>') + '</div>',
        '</div>',
        '<div class="plan-review-row">',
        '<div class="plan-review-label">Checkpoints</div>',
        '<div class="plan-review-checkpoints">' + ((task.checkpoints || []).length
          ? task.checkpoints.map((cp, cpIndex) => '<div class="plan-review-checkpoint">' + esc((cpIndex + 1) + '. ' + cp) + '</div>').join('')
          : '<div class="plan-review-checkpoint">No checkpoints listed.</div>') + '</div>',
        '</div>',
        '</div>'
      ].join('')).join(''),
      '<div class="plan-review-actions">',
      '<button class="plan-review-approve" type="button" data-plan-action="approve">✅ Approve Plan</button>',
      '<div class="plan-review-hint">Type feedback in the chat to request changes, or approve to start execution.</div>',
      '</div>',
      '</div>',
      '</div>'
    ].join('');
  }

  function renderPlanCard() {
    const tasks = (state.activeObjective && state.activeObjective.tasks) || [];
    return [
      '<div class="card-plan">',
      '<div class="card-head"><span>📋</span> Plan · ' + tasks.length + ' tasks</div>',
      tasks.map((task) => {
        const status = String(task.status || '').toLowerCase();
        let iconClass = isActionTask(task) ? 'pri-action' : 'pri-queue';
        let icon = taskDisplayIcon(task) || '-';
        let statusClass = 'prs-queue';
        let statusText = 'waiting';
        if (status === 'completed') {
          iconClass = isActionTask(task) ? 'pri-action pri-done' : 'pri-done';
          icon = taskDisplayIcon(task) || '✓';
          statusClass = 'prs-done';
          statusText = durationFrom(task.startedAt, task.completedAt) || 'done';
        } else if (status === 'executing' || status === 'reviewing' || status === 'rework') {
          iconClass = isActionTask(task) ? 'pri-action pri-active' : 'pri-active';
          icon = taskDisplayIcon(task) || '●';
          statusClass = 'prs-active';
          const checkpoints = Array.isArray(task.checkpoints) ? task.checkpoints : [];
          const done = checkpoints.filter((cp) => checkpointStatus(cp.status) === 'done').length;
          const active = checkpoints.find((cp) => checkpointStatus(cp.status) === 'active');
          statusText = checkpoints.length ? ('cp ' + Math.min(done + (active ? 1 : 0), checkpoints.length) + '/' + checkpoints.length) : 'running';
          if (status === 'reviewing') statusText = 'reviewing';
          if (status === 'rework') statusText = 'rework';
        } else if (status === 'failed') {
          iconClass = isActionTask(task) ? 'pri-action pri-failed' : 'pri-failed';
          icon = taskDisplayIcon(task) || '✕';
          statusClass = 'prs-failed';
          statusText = 'failed';
        }
        return [
          '<div class="plan-row">',
          '<div class="pr-icon ' + iconClass + '">' + icon + '</div>',
          '<div class="pr-main">',
          '<span class="pr-name pr-name-text">' + esc(taskDisplayTitle(task)) + '</span>',
          (isActionTask(task) ? '<span class="action-chip">action</span>' : ''),
          ((status === 'completed' || status === 'executing' || status === 'reviewing' || status === 'rework') && state.activeObjective && state.activeObjective.branchName
            ? '<span class="task-branch-badge" title="' + esc(state.activeObjective.branchName) + '">' + esc(state.activeObjective.branchName) + '</span>'
            : ''),
          ((status === 'executing' || status === 'reviewing' || status === 'rework') && task.workspaceId
            ? '<button class="worker-output-btn" data-worker-task-id="' + esc(task.id) + '" title="View worker output">⌘</button>'
            : ''),
          '</div>',
          '<span class="pr-status ' + statusClass + '">' + esc(statusText) + '</span>',
          '</div>'
        ].join('');
      }).join(''),
      '</div>'
    ].join('');
  }

  function renderProgressCard(message) {
    const metadata = message.metadata || {};
    const task = findTask(metadata.task_id);
    const checkpoints = metadata.checkpoints || (task ? task.checkpoints : []) || [];
    const total = checkpoints.length;
    const done = checkpoints.filter((cp) => checkpointStatus(cp.status) === 'done').length;
    const activeIndex = checkpoints.findIndex((cp) => checkpointStatus(cp.status) === 'active');
    const current = activeIndex >= 0 ? activeIndex + 1 : (done || 1);
    const elapsed = task ? (durationFrom(task.startedAt) || relativeTime(task.startedAt)) : relativeTime(message.timestamp);
    return [
      '<div class="card-progress">',
      task && (task.worktreePath || (state.activeObjective && state.activeObjective.branchName)) ? '<div class="cp-meta"><div class="cp-meta-main">' +
        ((task.worktreePath || (state.activeObjective && state.activeObjective.branchName)) ? '<div class="cp-path-row">' : '') +
        (task.worktreePath ? '<div class="cp-path-value" title="' + esc(task.worktreePath) + '">' + esc(task.worktreePath) + '</div>' : '') +
        (task.worktreePath ? '<button class="cp-copy-button" type="button" data-copy-path="' + esc(task.worktreePath) + '">Copy</button>' : '') +
        (state.activeObjective && state.activeObjective.branchName ? '<span class="cp-branch">' + esc(state.activeObjective.branchName) + '</span>' : '') +
        ((task.worktreePath || (state.activeObjective && state.activeObjective.branchName)) ? '</div>' : '') +
        '</div></div>' : '',
      '<div class="cp-top">',
      '<span class="cp-task-label">' + esc(task ? taskDisplayTitle(task) : (metadata.task_id || 'Task')) + '</span>',
      (task && isActionTask(task) ? '<span class="action-chip">action</span>' : ''),
      total ? '<span class="cp-check-badge">checkpoint ' + current + ' of ' + total + '</span>' : '',
      '<span class="cp-time">' + esc(elapsed) + '</span>',
      '</div>',
      '<div class="cp-description">' + esc(message.content || '') + '</div>',
      total ? '<div class="cp-pips">' + checkpoints.map((cp, index) => {
        const status = checkpointStatus(cp.status);
        const klass = status === 'done' ? ' done' : (status === 'active' ? ' active' : '');
        return '<div class="pip' + klass + '" title="' + esc(cp.name || ('Checkpoint ' + (index + 1))) + '"></div>';
      }).join('') + '</div>' : '',
      '</div>'
    ].join('');
  }

  function reviewData(message) {
    const metadata = message.metadata || {};
    return metadata.review || {};
  }

  function reviewFilesChanged(review) {
    return Array.isArray(review.filesChanged) ? review.filesChanged.length : 0;
  }

  function renderReviewCard(message) {
    const metadata = message.metadata || {};
    const review = reviewData(message);
    const task = findTask(metadata.task_id);
    const issues = metadata.issues || review.issues || [];
    const verdict = String(review.verdict || '').toLowerCase();
    const passed = verdict === 'pass' || /review passed/i.test(message.content || '');
    const warningClass = passed ? '' : ' review-warning';
    const badge = passed
      ? '<span class="cr-badge crb-pass">✓ Review passed</span>'
      : '<span class="cr-badge crb-issues">⚠ Issues found</span>';
    const recommendation = review.recommendation || review.summary || message.content || 'Review requires changes.';
    const fileCount = reviewFilesChanged(review);
    const linesAdded = Number(review.linesAdded || 0);
    const linesRemoved = Number(review.linesRemoved || 0);
    return [
      '<div class="card-review' + warningClass + '">',
      '<div class="cr-head">',
      badge,
      '<span class="cr-name">' + esc(task ? taskDisplayTitle(task) : (metadata.task_id || 'Review')) + '</span>',
      (task && isActionTask(task) ? '<span class="action-chip">action</span>' : ''),
      '</div>',
      '<div class="cr-body">',
      passed
        ? '<div class="cr-stats"><span>' + esc(String(fileCount) + ' file' + (fileCount === 1 ? '' : 's')) + '</span><span>+' + esc(String(linesAdded)) + '</span><span>-' + esc(String(linesRemoved)) + '</span></div>'
        : '',
      !passed && issues.length ? '<div class="review-issues">' + issues.map((issue) => '<div class="review-issue">' + esc(issue) + '</div>').join('') + '</div>' : '',
      !passed ? '<div class="cr-summary">' + renderMarkdown(recommendation) + '</div>' : '',
      '</div>',
      '</div>',
      '</div>'
    ].join('');
  }

  function renderCompletionCard(message) {
    const metadata = message.metadata || {};
    const taskCount = ((state.activeObjective && state.activeObjective.tasks) || []).length;
    return [
      '<div class="card-complete">',
      '<div class="cc-icon">✓</div>',
      '<div class="cc-text">',
      '<div class="cc-title">Objective complete!</div>',
      '<div class="cc-body">' + renderMarkdown(metadata.summary || message.content || '') + '</div>',
      '<div class="cc-body" style="margin-top:6px">' + esc(taskCount + ' tasks · ' + (metadata.rework_count || 0) + ' rework cycles') + '</div>',
      '</div>',
      '</div>'
    ].join('');
  }

  function renderAlertCard(message) {
    const metadata = message.metadata || {};
    return [
      '<div class="card-alert">',
      '<div class="alert-title">Alert</div>',
      '<div class="alert-body">' + renderMarkdown(message.content || '') + '</div>',
      metadata.screen_preview ? '<div class="screen-preview">' + esc(metadata.screen_preview) + '</div>' : '',
      '</div>'
    ].join('');
  }

  function renderApprovalCard(message) {
    const metadata = message.metadata || {};
    const taskId = metadata.task_id || '';
    return [
      '<div class="card-approval">',
      '<div class="approval-title">Approval needed</div>',
      '<div class="approval-body">' + esc(message.content || '') + '</div>',
      metadata.screen_preview ? '<div class="screen-preview">' + esc(metadata.screen_preview) + '</div>' : '',
      '<div class="approval-actions">',
      '<button class="approval-btn approve" data-approval-action="approve" data-task-id="' + esc(taskId) + '">Approve</button>',
      '<button class="approval-btn takeover" data-approval-action="takeover" data-task-id="' + esc(taskId) + '">Take over</button>',
      '</div>',
      '</div>'
    ].join('');
  }

  function renderBurst(item) {
    const label = item.count === 1 ? 'permission' : 'permissions';
    const taskSuffix = item.taskIds && item.taskIds.length
      ? ' (' + esc(item.taskIds.join(', ')) + ')'
      : '';
    return '<div class="approval-burst">🔓 Auto-approved ' + item.count + ' ' + label + taskSuffix + '</div>';
  }

  function itemTimestamp(item) {
    if (!item) return null;
    if (item.kind === 'approval-burst') return item.lastTimestamp || item.firstTimestamp || null;
    return item.message ? item.message.timestamp : null;
  }

  function isSystemTimelineItem(item) {
    return !!item && item.kind !== 'user' && item.kind !== 'approval-burst';
  }

  function shouldGroupSystemItem(items, index) {
    const item = items[index];
    const previous = items[index - 1];
    if (!isSystemTimelineItem(item) || !isSystemTimelineItem(previous)) return false;
    const itemTs = parseIso(itemTimestamp(item));
    const prevTs = parseIso(itemTimestamp(previous));
    if (!itemTs || !prevTs) return false;
    return (itemTs - prevTs) <= 30000;
  }

  function renderMessageItem(item, grouped) {
    const groupClass = grouped ? ' msg-grouped' : '';
    if (item.kind === 'approval-burst') return renderBurst(item);
    if (item.kind === 'plan_review') {
      const time = relativeTime(item.message.timestamp);
      return [
        '<div class="msg' + groupClass + '">',
        grouped ? '' : '<div class="msg-av av-c">⌘</div>',
        '<div class="msg-body">',
        grouped ? '' : '<div class="msg-header"><span class="msg-name mn-sys">cmux</span><span class="msg-time">' + esc(time) + '</span></div>',
        renderPlanReviewCard(item.message),
        '</div>',
        '</div>'
      ].join('');
    }
    if (item.kind === 'plan' || item.kind === 'plan-synthetic') {
      const time = relativeTime(item.message.timestamp);
      return [
        '<div class="msg' + groupClass + '">',
        grouped ? '' : '<div class="msg-av av-c">⌘</div>',
        '<div class="msg-body">',
        grouped ? '' : '<div class="msg-header"><span class="msg-name mn-sys">cmux</span><span class="msg-time">' + esc(time) + '</span></div>',
        renderPlanCard(),
        '</div>',
        '</div>'
      ].join('');
    }
    const message = item.message;
    const isUser = item.kind === 'user';
    const header = [
      '<div class="msg-header">',
      '<span class="msg-name ' + (isUser ? 'mn-user' : 'mn-sys') + '">' + (isUser ? 'You' : 'cmux') + '</span>',
      '<span class="msg-time">' + esc(relativeTime(message.timestamp)) + '</span>',
      '</div>'
    ].join('');

    let content = '';
    if (item.kind === 'system') {
      content = '<div class="msg-bubble">' + renderMarkdown(message.content || '') + '</div>';
    } else if (item.kind === 'user') {
      content = '<div class="msg-bubble">' + esc(message.content || '') + '</div>';
    } else if (item.kind === 'assistant') {
      content = '<div class="msg-bubble">' + renderMarkdown(message.content || '') + '</div>';
    } else if (item.kind === 'progress') {
      content = renderProgressCard(message);
    } else if (item.kind === 'review') {
      const review = reviewData(message);
      const hasStructuredReview = Object.keys(review).length || (message.metadata && message.metadata.issues);
      content = hasStructuredReview
        ? renderReviewCard(message)
        : '<div class="msg-muted">' + esc(message.content || '') + '</div>';
    } else if (item.kind === 'completion') {
      content = renderCompletionCard(message);
    } else if (item.kind === 'alert') {
      content = renderAlertCard(message);
    } else if (item.kind === 'approval') {
      content = renderApprovalCard(message);
    } else {
      content = '<div class="msg-bubble">' + esc(message.content || '') + '</div>';
    }

    return [
      '<div class="msg' + (isUser ? ' user' : '') + groupClass + '">',
      (grouped && !isUser) ? '' : '<div class="msg-av ' + (isUser ? 'av-r">Y' : 'av-c">⌘') + '</div>',
      '<div class="msg-body">',
      (grouped && !isUser) ? '' : header,
      content,
      '</div>',
      '</div>'
    ].join('');
  }

  function renderEmptyState() {
    return [
      '<div class="empty-state">',
      '<div class="empty-card">',
      '<div class="empty-kicker">Orchestrator</div>',
      '<div class="empty-title">Give me a goal and a codebase - I\u2019ll break it down and build it.</div>',
      '<div class="empty-copy">Start with the input below or open <span class="mono">New objective</span> to set the project directory first.</div>',
      '</div>',
      '</div>'
    ].join('');
  }

  function renderMessages() {
    const beforeBottom = isNearBottom();
    const oldScrollTop = els.messagesPane.scrollTop;
    const items = normalizeMessages(state.messages);
    let html = '';
    if (!state.objectives.length && !state.activeObjectiveId) {
      els.messageColumn.innerHTML = renderEmptyState();
      return;
    }
    if (!items.length) {
      html = '<div class="thread-div">now</div><div class="msg"><div class="msg-av av-c">⌘</div><div class="msg-body"><div class="msg-header"><span class="msg-name mn-sys">cmux</span><span class="msg-time">just now</span></div><div class="msg-bubble">Waiting for the objective to start.</div></div></div>';
    } else {
      html = '<div class="thread-div">now</div>' + items.map((item, index) => renderMessageItem(item, shouldGroupSystemItem(items, index))).join('');
    }
    if (state.typing) {
      html += '<div class="msg"><div class="msg-av av-c">⌘</div><div class="msg-body"><div class="msg-bubble typing-indicator"><span class="dot"></span><span class="dot"></span><span class="dot"></span></div></div></div>';
    }
    els.messageColumn.innerHTML = html;
    els.messageColumn.querySelectorAll('[data-worker-task-id]').forEach((node) => {
      node.addEventListener('click', (event) => {
        event.stopPropagation();
        openWorkerOutput(node.getAttribute('data-worker-task-id'));
      });
    });
    els.messageColumn.querySelectorAll('[data-approval-action]').forEach((node) => {
      node.addEventListener('click', async () => {
        const taskId = node.getAttribute('data-task-id');
        const action = node.getAttribute('data-approval-action');
        if (!state.activeObjectiveId || !taskId) return;
        try {
          if (action === 'approve') {
            await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/tasks/' + encodeURIComponent(taskId) + '/approve', {
              method: 'POST',
              body: JSON.stringify({ action: 'y\n' })
            });
          } else {
            await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/message', {
              method: 'POST',
              body: JSON.stringify({ message: 'take over', context: { task_id: taskId, take_over: true } })
            });
            state.lastMessageTimestamp = null;
          }
          await pollMessages(true);
          await pollActiveObjective(true);
        } catch (error) {
          showToast(error.message || 'Approval action failed');
        }
      });
    });
    els.messageColumn.querySelectorAll('[data-plan-action="approve"]').forEach((node) => {
      node.addEventListener('click', async () => {
        if (!state.activeObjectiveId) return;
        try {
          await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/approve-plan', {
            method: 'POST',
            body: JSON.stringify({})
          });
          state.lastMessageTimestamp = null;
          await pollMessages(true);
          await pollActiveObjective(true);
        } catch (error) {
          showToast(error.message || 'Could not approve plan');
        }
      });
    });
    els.messageColumn.querySelectorAll('[data-copy-path]').forEach((node) => {
      node.addEventListener('click', () => {
        copyText(node.getAttribute('data-copy-path'), 'Path');
      });
    });

    if (beforeBottom) {
      scrollToBottom();
    } else {
      els.messagesPane.scrollTop = oldScrollTop;
    }
  }

  function mergeIncomingMessages(existing, incoming) {
    const serverUserSignatures = new Set(
      incoming
        .filter((message) => message && message.type === 'user')
        .map((message) => String(message.content || ''))
    );
    const base = existing.filter((message) => {
      if (!message || typeof message.id !== 'string' || !message.id.startsWith('local-')) return true;
      return !serverUserSignatures.has(String(message.content || ''));
    });
    return base.concat(incoming);
  }

  function renderInputState() {
    const objective = state.activeObjective;
    const status = String(objective && objective.status || '').toLowerCase();
    const hasObjective = !!state.activeObjectiveId && !!objective;
    if (!hasObjective) {
      els.inputHint.textContent = 'Select or create an objective to start.';
      els.chatInput.placeholder = 'No objective selected...';
      els.chatInput.disabled = true;
      els.sendButton.disabled = true;
      return;
    }
    els.chatInput.disabled = false;
    if (status === 'plan_review') {
      els.inputHint.textContent = 'Type feedback in chat or approve the plan above.';
      els.chatInput.placeholder = 'Type plan feedback or approve above...';
    } else if (status === 'completed') {
      els.inputHint.textContent = 'Objective complete. Ask questions about the work done.';
      els.chatInput.placeholder = 'Ask about the completed work...';
    } else if (status === 'failed') {
      els.inputHint.textContent = 'Objective failed. Type "retry" to restart or ask what happened.';
      els.chatInput.placeholder = 'Type retry or ask what went wrong...';
    } else {
      els.inputHint.textContent = 'Chat with the orchestrator about this objective.';
      els.chatInput.placeholder = 'Ask about status, blockers, or give feedback...';
    }
    els.sendButton.disabled = state.pendingCreate || state.pendingSend;
  }

  function render() {
    renderSidebar();
    renderContext();
    renderBuildLog();
    renderConsoleLog();
    renderFabRail();
    renderSidebarChrome();
    updateSidebarFormFromState();
    renderFabModal();
    renderSettingsModal();
    renderDebugModal();
    renderGitPanel();
    renderMessages();
    renderInputState();
    autoResizeTextarea();
  }

  async function pollObjectives() {
    const previousActiveId = state.activeObjectiveId;
    const data = await api('/api/objectives');
    state.objectives = Array.isArray(data) ? data : [];
    if (!state.draftProjectDir) {
      state.draftProjectDir = defaultProjectDir();
    }
    if (!state.draftBaseBranch) {
      state.draftBaseBranch = defaultBaseBranch();
    }
    ensureSelection();
    if (state.activeObjectiveId && state.activeObjectiveId !== previousActiveId) {
      state.actionButtonState = {};
      await loadActiveObjective(false);
    }
    renderSidebar();
    renderContext();
    renderInputState();
  }

  async function pollActiveObjective(forceRender) {
    if (!state.activeObjectiveId) {
      state.activeObjective = null;
      state.actionButtons = [];
      state.actionButtonState = {};
      state.fabModalOpen = false;
      resetBuildLogState();
      resetConsoleLogState();
      renderBuildLog();
      renderConsoleLog();
      renderFabRail();
      renderFabModal();
      return;
    }
    const previousPath = activeGitPath();
    const objective = await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId));
    state.activeObjective = objective;
    await loadActionButtons(state.activeObjectiveId);
    const nextPath = activeGitPath();
    if (previousPath !== nextPath) {
      state.gitStatus = null;
      if (!nextPath) {
        state.gitPanelOpen = false;
        hideGitContextMenu();
        closeDiffOverlay();
      } else if (state.gitPanelOpen) {
        await fetchGitStatus();
      }
    }
    const index = state.objectives.findIndex((item) => item.id === objective.id);
    if (index >= 0) {
      state.objectives[index] = objective;
    }
    await fetchDebugErrorState();
    if (forceRender) render();
    else {
      renderContext();
      renderBuildLog();
      renderConsoleLog();
      renderSidebar();
      renderDebugModal();
      renderMessages();
      renderInputState();
    }
  }

  async function pollMessages(forceRender) {
    if (!state.activeObjectiveId) {
      state.messages = [];
      state.lastMessageTimestamp = null;
      if (forceRender) renderMessages();
      return;
    }
    const query = state.lastMessageTimestamp ? ('?after=' + encodeURIComponent(state.lastMessageTimestamp)) : '';
    const incoming = await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/messages' + query);
    const list = Array.isArray(incoming) ? incoming : [];
    if (state.lastMessageTimestamp) {
      if (list.length) {
        state.messages = mergeIncomingMessages(state.messages, list);
        state.typing = false;
      }
    } else {
      state.messages = list;
      state.typing = false;
    }
    const last = state.messages[state.messages.length - 1];
    state.lastMessageTimestamp = last ? last.timestamp : null;
    if (forceRender) renderMessages();
    else renderMessages();
  }

  async function loadActiveObjective(forceAll) {
    state.messages = [];
    state.lastMessageTimestamp = null;
    resetBuildLogState();
    resetConsoleLogState();
    await Promise.all([
      pollActiveObjective(false),
      pollMessages(false)
    ]);
    if (forceAll) render();
  }

  async function createObjective(goal, projectDir, baseBranch, branchName) {
    state.pendingCreate = true;
    renderInputState();
    try {
      const objective = await api('/api/objectives', {
        method: 'POST',
        body: JSON.stringify({
          goal,
          projectDir,
          baseBranch: baseBranch || 'main',
          branchName: branchName || ''
        })
      });
      await api('/api/objectives/' + encodeURIComponent(objective.id) + '/start', {
        method: 'POST',
        body: JSON.stringify({})
      });
      state.activeObjectiveId = objective.id;
      closeSidebar();
      state.sidebarFormOpen = false;
      state.draftGoal = '';
      state.draftBranchName = '';
      els.chatInput.value = '';
      autoResizeTextarea();
      await pollObjectives();
      await loadActiveObjective(true);
    } finally {
      state.pendingCreate = false;
      renderInputState();
    }
  }

  async function submitSidebarObjective() {
    const projectDirInput = document.getElementById('projectDirInput');
    const baseBranchInput = document.getElementById('baseBranchInput');
    const branchNameInput = document.getElementById('branchNameInput');
    const sidebarGoalInput = document.getElementById('sidebarGoalInput');
    state.draftProjectDir = projectDirInput ? projectDirInput.value.trim() : state.draftProjectDir;
    state.draftBaseBranch = baseBranchInput ? (baseBranchInput.value.trim() || 'main') : (state.draftBaseBranch || 'main');
    state.draftBranchName = branchNameInput ? branchNameInput.value.trim() : state.draftBranchName;
    state.draftGoal = sidebarGoalInput ? sidebarGoalInput.value.trim() : state.draftGoal;
    if (!state.draftProjectDir || !state.draftGoal) {
      showToast('Project directory and goal are required');
      return;
    }
    try {
      await createObjective(state.draftGoal, state.draftProjectDir, state.draftBaseBranch, state.draftBranchName);
    } catch (error) {
      showToast(error.message || 'Could not create objective');
    }
  }

  async function sendMessage() {
    const text = els.chatInput.value.trim();
    if (!text) return;
    if (!state.activeObjectiveId || !state.activeObjective) {
      showToast('No active objective selected. Use "New objective" to create one.');
      return;
    }
    state.pendingSend = true;
    renderInputState();
    const optimistic = {
      id: 'local-' + Math.random().toString(16).slice(2),
      timestamp: new Date().toISOString(),
      type: 'user',
      content: text,
      metadata: {}
    };
    state.messages.push(optimistic);
    state.lastMessageTimestamp = optimistic.timestamp;
    els.chatInput.value = '';
    autoResizeTextarea();
    state.typing = true;
    renderMessages();
    try {
      await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/message', {
        method: 'POST',
        body: JSON.stringify({ message: text })
      });
    } catch (error) {
      state.typing = false;
      renderMessages();
      showToast(error.message || 'Could not send message');
    } finally {
      state.pendingSend = false;
      renderInputState();
    }
  }

  function installPollers() {
    if (state.pollers.objectives) window.clearInterval(state.pollers.objectives);
    if (state.pollers.messages) window.clearInterval(state.pollers.messages);
    if (state.pollers.objective) window.clearInterval(state.pollers.objective);
    if (state.pollers.git) window.clearInterval(state.pollers.git);
    if (state.pollers.relative) window.clearInterval(state.pollers.relative);
    if (state.pollers.debug) window.clearInterval(state.pollers.debug);

    state.pollers.objectives = window.setInterval(async () => {
      try {
        await pollObjectives();
      } catch (error) {
        console.error(error);
      }
    }, 5000);

    state.pollers.messages = window.setInterval(async () => {
      try {
        await pollMessages(false);
      } catch (error) {
        console.error(error);
      }
    }, 3000);

    state.pollers.objective = window.setInterval(async () => {
      try {
        await pollActiveObjective(false);
      } catch (error) {
        console.error(error);
      }
    }, 5000);

    state.pollers.git = window.setInterval(async () => {
      try {
        if (state.gitPanelOpen) {
          await fetchGitStatus();
        }
      } catch (error) {
        console.error(error);
      }
    }, 10000);

    state.pollers.relative = window.setInterval(() => {
      state.relativeTick = Date.now();
      renderSidebar();
      renderContext();
      renderDebugModal();
      renderGitPanel();
      renderMessages();
    }, 30000);

    state.pollers.debug = window.setInterval(async () => {
      try {
        if (state.debugOpen) {
          await fetchDebugEntries();
        } else if (state.activeObjectiveId) {
          await fetchDebugErrorState();
        }
      } catch (error) {
        console.error(error);
      }
    }, 5000);
  }

  function bindEvents() {
    els.newObjectiveButton.addEventListener('click', () => {
      openSidebarForm(state.draftGoal);
    });
    els.settingsButton.addEventListener('click', openSettingsModal);
    els.settingsCloseButton.addEventListener('click', closeSettingsModal);
    els.settingsCancelButton.addEventListener('click', closeSettingsModal);
    els.settingsSaveButton.addEventListener('click', saveSettings);
    els.settingsModal.addEventListener('click', (event) => {
      if (event.target === els.settingsModal) closeSettingsModal();
    });
    els.fabCloseButton.addEventListener('click', hideAddModal);
    els.fabCancelButton.addEventListener('click', hideAddModal);
    els.fabSaveButton.addEventListener('click', saveActionButton);
    els.fabModal.addEventListener('click', (event) => {
      if (event.target === els.fabModal) hideAddModal();
    });
    els.debugFab.addEventListener('click', openDebugModal);
    els.debugCloseButton.addEventListener('click', closeDebugModal);
    els.debugModal.addEventListener('click', (event) => {
      if (event.target === els.debugModal) closeDebugModal();
    });
    els.debugCopyAllButton.addEventListener('click', () => {
      copyText(debugJsonl(state.debugEntries), 'Debug log');
    });
    els.debugCopyLastButton.addEventListener('click', () => {
      copyText(debugJsonl(state.debugEntries.slice(-20)), 'Last 20 debug entries');
    });
    els.buildLogFileSelect.addEventListener('change', (event) => {
      setBuildLogFile(event.target.value);
    });
    els.buildLogAutoButton.addEventListener('click', toggleBuildLogAuto);
    els.buildLogRefreshButton.addEventListener('click', () => {
      fetchBuildLog(true);
    });
    els.buildLogCloseButton.addEventListener('click', () => {
      if (state.buildLogOpen) toggleBuildLog();
    });
    els.buildLogBody.addEventListener('scroll', () => {
      state.buildLogPinned = isBuildLogPinned();
      if (state.buildLogPinned && state.buildLogHasNewOutput) {
        state.buildLogHasNewOutput = false;
        renderBuildLogBadge();
      }
    });
    els.buildLogNewOutputBadge.addEventListener('click', scrollBuildLogToBottom);
    els.consoleLogFileSelect.addEventListener('change', (event) => {
      setConsoleLogFile(event.target.value);
    });
    els.consoleLogPresetSelect.addEventListener('change', (event) => {
      const preset = event.target.value;
      if (preset === 'custom') {
        state.consoleLogPreset = 'custom';
        state.consoleLogDraftFilter = String(els.consoleLogCustomInput.value || '');
        renderConsoleLog();
        els.consoleLogCustomInput.focus();
        return;
      }
      applyConsoleLogPreset(preset);
    });
    els.consoleLogCustomInput.addEventListener('input', () => {
      const pattern = String(els.consoleLogCustomInput.value || '');
      state.consoleLogDraftFilter = pattern;
      state.consoleLogPreset = consoleLogPresetForPattern(pattern).id;
      els.consoleLogPresetSelect.value = state.consoleLogPreset;
    });
    els.consoleLogCustomInput.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter') return;
      event.preventDefault();
      const pattern = String(els.consoleLogCustomInput.value || '').trim();
      setConsoleLogFilter(pattern, consoleLogPresetForPattern(pattern).id);
    });
    els.consoleLogApplyButton.addEventListener('click', () => {
      const pattern = String(els.consoleLogCustomInput.value || '').trim();
      setConsoleLogFilter(pattern, consoleLogPresetForPattern(pattern).id);
    });
    els.consoleLogAutoButton.addEventListener('click', toggleConsoleLogAuto);
    els.consoleLogRefreshButton.addEventListener('click', () => {
      fetchConsoleLog(true);
    });
    els.consoleLogCloseButton.addEventListener('click', () => {
      if (state.consoleLogOpen) toggleConsoleLog();
    });
    els.consoleLogBody.addEventListener('scroll', () => {
      state.consoleLogPinned = isConsoleLogPinned();
      if (state.consoleLogPinned && state.consoleLogHasNewOutput) {
        state.consoleLogHasNewOutput = false;
        renderConsoleLogBadge();
      }
    });
    els.consoleLogNewOutputBadge.addEventListener('click', scrollConsoleLogToBottom);
    els.sidebarBackdrop.addEventListener('click', closeSidebar);
    els.sidebarCloseButton.addEventListener('click', closeSidebar);
    els.gitPanelRefreshButton.addEventListener('click', fetchGitStatus);
    els.gitPanelCloseButton.addEventListener('click', closeGitPanel);
    els.gitPanelCopyButton.addEventListener('click', () => {
      copyText((state.gitStatus && state.gitStatus.cwd) || activeGitPath(), 'Path');
    });
    els.gitContextMenu.addEventListener('click', (event) => {
      const actionNode = event.target.closest('[data-git-action]');
      if (!actionNode) return;
      runGitContextAction(actionNode.getAttribute('data-git-action'));
    });
    els.diffTabs.addEventListener('click', (event) => {
      const tabNode = event.target.closest('[data-tab]');
      if (!tabNode) return;
      switchDiffTab(tabNode.getAttribute('data-tab'));
    });
    els.diffCloseButton.addEventListener('click', closeDiffOverlay);
    els.diffOverlay.addEventListener('click', (event) => {
      if (event.target === els.diffOverlay) closeDiffOverlay();
    });
    els.workerOutputClose.addEventListener('click', closeWorkerOutput);
    els.workerOutputRefresh.addEventListener('click', refreshWorkerOutput);
    els.workerOutputOverlay.addEventListener('click', (event) => {
      if (event.target === els.workerOutputOverlay) closeWorkerOutput();
    });
    els.sendButton.addEventListener('click', sendMessage);
    els.chatInput.addEventListener('input', () => {
      autoResizeTextarea();
    });
    els.chatInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey) {
        event.preventDefault();
        sendMessage();
      }
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && state.fabModalOpen) {
        event.preventDefault();
        hideAddModal();
        return;
      }
      if (event.key === 'Escape' && state.settingsOpen) {
        event.preventDefault();
        closeSettingsModal();
        return;
      }
      if (event.key === 'Escape' && state.debugOpen) {
        event.preventDefault();
        closeDebugModal();
        return;
      }
      if (event.key === 'Escape' && els.workerOutputOverlay.classList.contains('visible')) {
        event.preventDefault();
        closeWorkerOutput();
        return;
      }
      if (event.key === 'Escape' && els.diffOverlay.classList.contains('visible')) {
        event.preventDefault();
        closeDiffOverlay();
        return;
      }
      if (event.key === 'Escape' && els.gitContextMenu.classList.contains('visible')) {
        event.preventDefault();
        hideGitContextMenu();
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'n') {
        event.preventDefault();
        openSidebarForm(state.draftGoal);
      }
    });
    document.addEventListener('click', (event) => {
      if (!els.gitContextMenu.contains(event.target)) hideGitContextMenu();
    });
    window.addEventListener('resize', () => {
      syncResponsiveState(true);
    });
    els.terminalLink.addEventListener('click', () => {
      showToast('Terminal sessions view is not wired here yet');
    });
  }

  async function boot() {
    bindEvents();
    state.relativeTick = Date.now();
    syncResponsiveState(false);
    render();
    try {
      await loadConfig();
      render();
      await pollObjectives();
      if (state.activeObjectiveId) {
        await loadActiveObjective(true);
      } else {
        render();
      }
    } catch (error) {
      console.error(error);
      showToast(error.message || 'Initial load failed');
      render();
    }
    installPollers();
  }

  boot();
})();
