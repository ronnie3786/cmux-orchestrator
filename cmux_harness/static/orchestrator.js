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
    projects: [],
    objectives: [],
    workspaces: [],
    activeTargetType: null,
    activeObjectiveId: null,
    activeObjective: null,
    activeWorkspaceId: null,
    activeWorkspace: null,
    actionButtons: [],
    actionButtonState: {},
    messages: [],
    typing: false,
    config: null,
    gitPanelOpen: false,
    rightPanelMode: 'git',
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
    workerOutputMode: '',
    workerOutputContent: '',
    workerOutputPolling: false,
    workerOutputInterval: null,
    gitContextMode: '',
    gitContextFile: '',
    gitContextSection: '',
    gitContextAbsolutePath: '',
    lastMessageTimestamp: null,
    relativeTick: Date.now(),
    isMobile: null,
    sidebarOpen: true,
    sidebarFormOpen: false,
    sidebarFormMode: 'objective',
    draftWorkspaceName: '',
    draftWorkspaceRootPath: '',
    openPathPickerFallback: false,
    openPathPickerBusy: false,
    projectExpansion: {},
    ctxTarget: null,
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
    statusSummary: null,
    statusSummaryLoading: false,
    statusSummaryError: '',
    statusSummaryTargetKey: null,
    activeWorkspaceTurn: null,
    draftProjectDir: '',
    draftProjectId: '',
    draftProjectName: '',
    draftProjectRootPath: '',
    projectPickerFallback: false,
    projectPickerBusy: false,
    projectCreationReturnMode: '',
    draftProjectBaseBranch: 'main',
    draftWorkflowMode: 'structured',
    draftBaseBranch: 'main',
    draftBranchName: '',
    draftGoal: '',
    pendingCreate: false,
    pendingSend: false,
    pollers: {
      objectives: null,
      messages: null,
      objective: null,
      activeTurn: null,
      git: null,
      relative: null,
      debug: null
    },
    onboardingOpen: false,
    tourActive: false,
    tourStep: 0,
    prereqStatus: null
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
    openWorkspaceButton: document.getElementById('openWorkspaceButton'),
    addProjectButton: document.getElementById('addProjectButton'),
    settingsButton: document.getElementById('settingsButton'),
    settingsModal: document.getElementById('settingsModal'),
    settingsCloseButton: document.getElementById('settingsCloseButton'),
    settingsCancelButton: document.getElementById('settingsCancelButton'),
    settingsSaveButton: document.getElementById('settingsSaveButton'),
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
    diffSidebar: document.getElementById('diffSidebar'),
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
    toastWrap: document.getElementById('toastWrap'),
    ctxMenu: document.getElementById('ctxMenu'),
    ctxRename: document.getElementById('ctxRename'),
    ctxDelete: document.getElementById('ctxDelete'),
    deleteConfirmOverlay: document.getElementById('deleteConfirmOverlay'),
    deleteConfirmTitle: document.getElementById('deleteConfirmTitle'),
    deleteConfirmName: document.getElementById('deleteConfirmName'),
    deleteConfirmCancel: document.getElementById('deleteConfirmCancel'),
    deleteConfirmOk: document.getElementById('deleteConfirmOk'),
    onboardingOverlay: document.getElementById('onboardingOverlay'),
    onboardingPrereqs: document.getElementById('onboardingPrereqs'),
    onboardingFeatures: document.getElementById('onboardingFeatures'),
    onboardingCloseButton: document.getElementById('onboardingCloseButton'),
    onboardingSkipButton: document.getElementById('onboardingSkipButton'),
    onboardingTourButton: document.getElementById('onboardingTourButton'),
    onboardingRecheckButton: document.getElementById('onboardingRecheckButton'),
    tourOverlay: document.getElementById('tourOverlay'),
    tourTooltip: document.getElementById('tourTooltip'),
    helpFab: document.getElementById('helpFab')
  };

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function stripAnsi(text) {
    return String(text == null ? '' : text).replace(/\x1b\[[0-9;]*m/g, '');
  }

  function ansiToHtml(text) {
    var raw = String(text == null ? '' : text);
    var RE = /\x1b\[([0-9;]*)m/g;
    var FG = {
      '30': 'ansi-black',   '31': 'ansi-red',     '32': 'ansi-green',  '33': 'ansi-yellow',
      '34': 'ansi-blue',    '35': 'ansi-magenta',  '36': 'ansi-cyan',   '37': 'ansi-white',
      '90': 'ansi-bright-black', '91': 'ansi-bright-red', '92': 'ansi-bright-green',
      '93': 'ansi-bright-yellow', '94': 'ansi-bright-blue', '95': 'ansi-bright-magenta',
      '96': 'ansi-bright-cyan', '97': 'ansi-bright-white'
    };
    var BG = {
      '40': 'ansi-bg-black',   '41': 'ansi-bg-red',     '42': 'ansi-bg-green',  '43': 'ansi-bg-yellow',
      '44': 'ansi-bg-blue',    '45': 'ansi-bg-magenta',  '46': 'ansi-bg-cyan',   '47': 'ansi-bg-white',
      '100': 'ansi-bg-bright-black', '101': 'ansi-bg-bright-red', '102': 'ansi-bg-bright-green',
      '103': 'ansi-bg-bright-yellow', '104': 'ansi-bg-bright-blue', '105': 'ansi-bg-bright-magenta',
      '106': 'ansi-bg-bright-cyan', '107': 'ansi-bg-bright-white'
    };
    var parts = [];
    var openSpans = 0;
    var lastIndex = 0;
    var match;
    while ((match = RE.exec(raw)) !== null) {
      if (match.index > lastIndex) {
        parts.push(esc(raw.substring(lastIndex, match.index)));
      }
      lastIndex = RE.lastIndex;
      var codes = match[1] ? match[1].split(';') : ['0'];
      for (var ci = 0; ci < codes.length; ci++) {
        var code = codes[ci];
        if (code === '' || code === '0') {
          while (openSpans > 0) { parts.push('</span>'); openSpans--; }
        } else if (code === '1') {
          parts.push('<span class="ansi-bold">'); openSpans++;
        } else if (code === '2') {
          parts.push('<span class="ansi-dim">'); openSpans++;
        } else if (code === '3') {
          parts.push('<span class="ansi-italic">'); openSpans++;
        } else if (code === '4') {
          parts.push('<span class="ansi-underline">'); openSpans++;
        } else if (FG[code]) {
          parts.push('<span class="' + FG[code] + '">'); openSpans++;
        } else if (BG[code]) {
          parts.push('<span class="' + BG[code] + '">'); openSpans++;
        }
      }
    }
    if (lastIndex < raw.length) {
      parts.push(esc(raw.substring(lastIndex)));
    }
    while (openSpans > 0) { parts.push('</span>'); openSpans--; }
    return parts.join('');
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

  function formatDateTime(value) {
    const ts = parseIso(value);
    if (!ts) return '';
    try {
      return new Date(ts).toLocaleString([], {
        month: 'short',
        day: 'numeric',
        hour: 'numeric',
        minute: '2-digit'
      });
    } catch (error) {
      return '';
    }
  }

  function statusMeta(status) {
    switch ((status || '').toLowerCase()) {
      case 'completed':
        return { dot: 'od-done', fill: 'opf-done', badge: 'badge-done', label: 'Done' };
      case 'failed':
        return { dot: 'od-failed', fill: 'opf-failed', badge: 'badge-failed', label: 'Failed' };
      case 'plan_review':
        return { dot: 'od-plan-review', fill: 'opf-plan-review', badge: 'badge-plan-review', label: 'reviewing plan' };
      case 'contract_review':
        return { dot: 'od-plan-review', fill: 'opf-plan-review', badge: 'badge-plan-review', label: 'reviewing contracts' };
      case 'negotiating_contracts':
        return { dot: 'od-reviewing', fill: 'opf-reviewing', badge: 'badge-planning', label: 'Negotiating' };
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

  function sortedProjects(list) {
    return [...(list || [])].sort((a, b) => {
      const aTs = parseIso(a.updatedAt || a.createdAt) || 0;
      const bTs = parseIso(b.updatedAt || b.createdAt) || 0;
      if (bTs !== aTs) return bTs - aTs;
      return String(a.name || '').localeCompare(String(b.name || ''));
    });
  }

  function compactPath(path) {
    const value = String(path || '').trim();
    if (!value) return '';
    const home = (window.HOME || '').trim();
    if (home && value.startsWith(home)) return '~' + value.slice(home.length);
    return value.replace(/^\/Users\/[^/]+/, '~');
  }

  function projectObjectives(projectId) {
    return sortedObjectives((state.objectives || []).filter((objective) => objective.projectId === projectId));
  }

  function sortedWorkspaces(list) {
    return [...(list || [])].sort((a, b) => {
      const aTs = parseIso(a.updatedAt || a.createdAt) || 0;
      const bTs = parseIso(b.updatedAt || b.createdAt) || 0;
      return bTs - aTs;
    });
  }

  function projectWorkspaces(projectId) {
    return sortedWorkspaces((state.workspaces || []).filter((workspace) => workspace.projectId === projectId));
  }

  function findProject(projectId) {
    return (state.projects || []).find((project) => project.id === projectId) || null;
  }

  function selectedProjectId() {
    if (state.draftProjectId && findProject(state.draftProjectId)) return state.draftProjectId;
    if (state.activeObjective && state.activeObjective.projectId && findProject(state.activeObjective.projectId)) return state.activeObjective.projectId;
    if (state.activeWorkspace && state.activeWorkspace.projectId && findProject(state.activeWorkspace.projectId)) return state.activeWorkspace.projectId;
    return (sortedProjects(state.projects)[0] || {}).id || '';
  }

  function ensureProjectExpansion() {
    const next = Object.assign({}, state.projectExpansion);
    sortedProjects(state.projects).forEach((project) => {
      if (typeof next[project.id] !== 'boolean') {
        next[project.id] = true;
      }
    });
    if (state.activeObjective) {
      next[state.activeObjective.projectId] = true;
    }
    if (state.activeWorkspace) {
      next[state.activeWorkspace.projectId] = true;
    }
    state.projectExpansion = next;
  }

  function defaultBaseBranch() {
    return state.draftBaseBranch || (state.config && state.config.defaultBaseBranch) || 'main';
  }

  function defaultWorkflowMode() {
    return state.draftWorkflowMode || 'structured';
  }

  function setDraftProject(projectId, options) {
    const settings = options || {};
    const nextProjectId = String(projectId || '').trim();
    const project = findProject(nextProjectId);
    state.draftProjectId = project ? project.id : '';
    state.draftProjectDir = (project && project.rootPath) || '';
    if (settings.updateBaseBranch !== false) {
      state.draftBaseBranch = (project && project.defaultBaseBranch) || (state.config && state.config.defaultBaseBranch) || 'main';
    }
    return project;
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

  function inferProjectNameFromPath(path) {
    const trimmed = String(path || '').trim().replace(/[\\/]+$/, '');
    if (!trimmed) return '';
    const parts = trimmed.split(/[\\/]+/).filter(Boolean);
    return parts.length ? parts[parts.length - 1] : '';
  }

  async function pickFolderPath() {
    return api('/api/projects/pick-root', {
      method: 'POST',
      body: JSON.stringify({})
    });
  }

  async function loadActionButtons() {
    const base = currentTargetApiBase();
    if (!base) {
      state.actionButtons = [];
      state.actionButtonState = {};
      renderFabRail();
      renderFabModal();
      return;
    }
    const targetKey = currentTargetKey();
    const data = await api(base + '/action-buttons');
    if (currentTargetKey() !== targetKey) return;
    state.actionButtons = Array.isArray(data.buttons) ? data.buttons : [];
    renderFabRail();
    renderFabModal();
  }

  function showAddModal() {
    if (!currentActiveTarget()) return;
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
    const target = currentActiveTarget();
    const hasTarget = !!target && !!(state.activeObjective || state.activeWorkspace);
    els.fabRail.className = 'fab-rail' + (hasTarget ? ' visible' : '');
    if (!hasTarget) {
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
    const visible = state.fabModalOpen && !!currentActiveTarget();
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
    const base = currentTargetApiBase();
    if (!base) return;
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
      await api(base + '/action-buttons', {
        method: 'POST',
        body: JSON.stringify({ label, prompt, icon, color })
      });
      els.fabLabel.value = '';
      els.fabPrompt.value = '';
      els.fabIcon.value = '';
      els.fabColor.value = '#4f8ef7';
      await loadActionButtons();
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
    const base = currentTargetApiBase();
    if (!base || !buttonId) return;
    state.fabDeletingId = buttonId;
    renderFabModal();
    try {
      await api(base + '/action-buttons/' + encodeURIComponent(buttonId), {
        method: 'DELETE'
      });
      await loadActionButtons();
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
    const base = currentTargetApiBase();
    if (!base) return;
    setActionButtonState(button.id, 'launching');
    showToast('Spawning ' + (button.label || 'action') + ' session...');
    try {
      const data = await api(base + '/action-inject', {
        method: 'POST',
        body: JSON.stringify({ buttonId: button.id })
      });
      if (data && data.ok) {
        setActionButtonState(button.id, 'success', 1800);
        const pollTarget = state.activeWorkspaceId ? pollActiveWorkspace : pollActiveObjective;
        await Promise.all([
          pollTarget(true),
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
    if (state.activeWorkspace && state.activeWorkspace.rootPath) return String(state.activeWorkspace.rootPath).trim();
    return state.activeObjective && (state.activeObjective.worktreePath || state.activeObjective.projectDir)
      ? String(state.activeObjective.worktreePath || state.activeObjective.projectDir).trim()
      : '';
  }

  function currentActiveTarget() {
    if (state.activeWorkspaceId) return { kind: 'workspace', id: state.activeWorkspaceId };
    if (state.activeObjectiveId) return { kind: 'objective', id: state.activeObjectiveId };
    return null;
  }

  function currentTargetKey() {
    const target = currentActiveTarget();
    return target ? (target.kind + ':' + target.id) : '';
  }

  function currentTargetApiBase() {
    const target = currentActiveTarget();
    if (!target) return '';
    return '/api/' + (target.kind === 'workspace' ? 'workspaces' : 'objectives') + '/' + encodeURIComponent(target.id);
  }

  function workspaceMeta(workspace) {
    const status = String(workspace && workspace.status || '').toLowerCase();
    if (status === 'failed') return { dot: 'od-failed', badge: 'badge-failed', label: 'Needs attention' };
    if (workspace && workspace.sessionActive) return { dot: 'od-running', badge: 'badge-running', label: 'Active' };
    return { dot: 'od-queued', badge: 'badge-queued', label: 'Idle' };
  }

  function activeFilesRoot() {
    if (state.activeWorkspace && state.activeWorkspace.rootPath) return String(state.activeWorkspace.rootPath).trim();
    return state.activeObjective && state.activeObjective.worktreePath
      ? String(state.activeObjective.worktreePath).trim()
      : '';
  }

  function gitButtonLabel() {
    const branch = state.gitStatus && state.gitStatus.branch
      ? state.gitStatus.branch
      : (state.activeObjective && state.activeObjective.branchName ? state.activeObjective.branchName : '');
    return branch ? ('⎇ ' + branch) : '⎇ git';
  }

  function currentTargetName() {
    if (state.activeWorkspace) return String(state.activeWorkspace.name || state.activeWorkspace.rootPath || 'Untitled item');
    const objective = state.activeObjective || sortedObjectives(state.objectives).find((item) => item.id === state.activeObjectiveId);
    return objective && objective.goal ? String(objective.goal) : 'Nothing selected';
  }

  async function openActiveRootInVSCode() {
    if (state.activeWorkspaceId) {
      try {
        await api('/api/workspaces/' + encodeURIComponent(state.activeWorkspaceId) + '/open-root', {
          method: 'POST',
          body: JSON.stringify({})
        });
        showToast('Opened path in VS Code');
      } catch (error) {
        console.error('open-workspace failed', error);
        showToast(error.message || 'Could not open path in VS Code');
      }
      return;
    }
    if (!state.activeObjectiveId) {
      showToast('No active item selected');
      return;
    }
    try {
      await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/open-worktree', {
        method: 'POST',
        body: JSON.stringify({})
      });
      showToast('Opened path in VS Code');
    } catch (error) {
      console.error('open-worktree failed', error);
      showToast(error.message || 'Could not open worktree in VS Code');
    }
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
    const targetName = currentTargetName();
    const hasTarget = !!currentActiveTarget();
    const fileLabel = state.buildLogFile || 'build.log';
    const data = state.buildLogData;
    els.buildLogPanel.className = 'build-log-panel' + (state.buildLogOpen ? ' open' : '');
    els.buildLogTitle.textContent = 'Build Log';
    els.buildLogFileSelect.value = fileLabel;
    els.buildLogFileSelect.disabled = !hasTarget;
    els.buildLogAutoButton.className = 'build-log-toggle' + (state.buildLogAuto ? ' active' : '');
    els.buildLogAutoButton.setAttribute('aria-pressed', state.buildLogAuto ? 'true' : 'false');
    els.buildLogRefreshButton.disabled = !hasTarget || state.buildLogLoading;
    els.buildLogCloseButton.disabled = !state.buildLogOpen;

    if (!hasTarget) {
      els.buildLogMeta.textContent = 'Select an item to view logs.';
      els.buildLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">⎔</div><div>No active item selected.</div></div>';
      state.buildLogHasNewOutput = false;
      renderBuildLogBadge();
      return;
    }

    if (state.buildLogLoading && !data) {
      els.buildLogMeta.textContent = targetName + ' · ' + fileLabel;
      els.buildLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-spinner"></div><div>Loading build log…</div></div>';
      state.buildLogHasNewOutput = false;
      renderBuildLogBadge();
      return;
    }

    if (state.buildLogError) {
      els.buildLogMeta.textContent = targetName + ' · ' + fileLabel;
      els.buildLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">⚠</div><div>Failed to read build log.</div><button class="build-log-retry" id="buildLogRetryButton" type="button">Retry</button></div>';
      const retryButton = document.getElementById('buildLogRetryButton');
      if (retryButton) retryButton.addEventListener('click', () => fetchBuildLog(true));
      renderBuildLogBadge();
      return;
    }

    if (!data || !data.exists) {
      els.buildLogMeta.textContent = targetName + ' · ' + fileLabel;
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
    const targetName = currentTargetName();
    const hasTarget = !!currentActiveTarget();
    const data = state.consoleLogData;
    const files = data && Array.isArray(data.files) ? data.files : [];
    const activeFile = state.consoleLogFile || (data && data.activeFile) || (files[0] || '');
    const preset = consoleLogPresetById(state.consoleLogPreset);

    els.consoleLogPanel.className = 'build-log-panel' + (state.consoleLogOpen ? ' open' : '');
    els.consoleLogTitle.textContent = activeFile ? ('Console Logs - ' + activeFile) : 'Console Logs';
    els.consoleLogAutoButton.className = 'build-log-toggle' + (state.consoleLogAuto ? ' active' : '');
    els.consoleLogAutoButton.setAttribute('aria-pressed', state.consoleLogAuto ? 'true' : 'false');
    els.consoleLogRefreshButton.disabled = !hasTarget || state.consoleLogLoading;
    els.consoleLogCloseButton.disabled = !state.consoleLogOpen;
    els.consoleLogPresetSelect.innerHTML = CONSOLE_LOG_PRESETS.map((item) => (
      '<option value="' + esc(item.id) + '">' + esc(item.label) + '</option>'
    )).join('');
    els.consoleLogPresetSelect.value = preset.id;
    els.consoleLogCustomInput.value = state.consoleLogDraftFilter;
    els.consoleLogCustomInput.disabled = !hasTarget;
    els.consoleLogApplyButton.disabled = !hasTarget;
    els.consoleLogFileSelect.disabled = !hasTarget || files.length <= 1;
    els.consoleLogFileSelect.innerHTML = files.length
      ? files.map((file) => '<option value="' + esc(file) + '">' + esc(file) + '</option>').join('')
      : '<option value="">No files</option>';
    els.consoleLogFileSelect.value = activeFile;

    if (!hasTarget) {
      els.consoleLogMeta.textContent = 'Select an item to view logs.';
      els.consoleLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">📟</div><div>No active item selected.</div></div>';
      state.consoleLogHasNewOutput = false;
      renderConsoleLogBadge();
      return;
    }

    if (state.consoleLogLoading && !data) {
      els.consoleLogMeta.textContent = targetName + (activeFile ? (' · ' + activeFile) : '');
      els.consoleLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-spinner"></div><div>Loading console logs…</div></div>';
      state.consoleLogHasNewOutput = false;
      renderConsoleLogBadge();
      return;
    }

    if (state.consoleLogError) {
      els.consoleLogMeta.textContent = targetName + (activeFile ? (' · ' + activeFile) : '');
      els.consoleLogContent.innerHTML = '<div class="build-log-state"><div class="build-log-state-icon">⚠</div><div>Failed to read console logs.</div><button class="build-log-retry" id="consoleLogRetryButton" type="button">Retry</button></div>';
      const retryButton = document.getElementById('consoleLogRetryButton');
      if (retryButton) retryButton.addEventListener('click', () => fetchConsoleLog(true));
      renderConsoleLogBadge();
      return;
    }

    if (!data || !data.exists) {
      els.consoleLogMeta.textContent = targetName + ' · waiting for .build/logs/*.log';
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
    const target = currentActiveTarget();
    if (!target) {
      state.buildLogData = null;
      state.buildLogError = '';
      state.buildLogLoading = false;
      state.buildLogLastSignature = '';
      state.buildLogHasNewOutput = false;
      renderContext();
      if (forceRender) renderBuildLog();
      return;
    }

    const targetKey = currentTargetKey();
    const wasPinned = isBuildLogPinned();
    state.buildLogPinned = wasPinned;
    if (!state.buildLogData) state.buildLogLoading = true;
    state.buildLogError = '';
    if (forceRender) renderBuildLog();

    try {
      const data = await api(
        currentTargetApiBase() +
        '/build-log?lines=200&file=' + encodeURIComponent(state.buildLogFile)
      );
      if (currentTargetKey() !== targetKey) return;
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
      if (currentTargetKey() !== targetKey) return;
      state.buildLogLoading = false;
      state.buildLogError = error.message || 'Failed to read build log';
      renderContext();
      renderBuildLog();
    }
  }

  async function fetchConsoleLog(forceRender) {
    const target = currentActiveTarget();
    if (!target) {
      state.consoleLogData = null;
      state.consoleLogError = '';
      state.consoleLogLoading = false;
      state.consoleLogLastSignature = '';
      state.consoleLogHasNewOutput = false;
      renderContext();
      if (forceRender) renderConsoleLog();
      return;
    }

    const targetKey = currentTargetKey();
    const wasPinned = isConsoleLogPinned();
    state.consoleLogPinned = wasPinned;
    if (!state.consoleLogData) state.consoleLogLoading = true;
    state.consoleLogError = '';
    if (forceRender) renderConsoleLog();

    try {
      let path = currentTargetApiBase() + '/console-logs?lines=500';
      if (state.consoleLogFile) {
        path += '&file=' + encodeURIComponent(state.consoleLogFile);
      }
      if (state.consoleLogFilter) {
        path += '&filter=' + encodeURIComponent(state.consoleLogFilter);
      }
      const data = await api(path);
      if (currentTargetKey() !== targetKey) return;
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
      if (currentTargetKey() !== targetKey) return;
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
    if (!state.buildLogOpen || !state.buildLogAuto || !currentActiveTarget()) return;
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
    if (!state.consoleLogOpen || !state.consoleLogAuto || !currentActiveTarget()) return;
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
    if (!currentActiveTarget()) return;
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
    if (!currentActiveTarget()) return;
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

  function resetStatusSummaryState() {
    state.statusSummary = null;
    state.statusSummaryLoading = false;
    state.statusSummaryError = '';
    state.statusSummaryTargetKey = null;
  }

  function debugJsonl(entries) {
    return (entries || []).map((entry) => JSON.stringify(entry)).join('\n');
  }

  function addLocalDebugEntry(level, event, details) {
    const entry = {
      ts: new Date().toISOString(),
      level: level || 'info',
      event: event || 'ui',
      details: details || {}
    };
    state.debugEntries = [entry].concat(state.debugEntries || []).slice(0, 500);
    state.debugHasErrors = state.debugHasErrors || level === 'error';
    if (state.debugOpen) renderDebugModal();
    try {
      const fn = level === 'error' ? console.error : console.log;
      fn('[orchestrator]', event, details || {});
    } catch (_) {}
  }

  async function fetchDebugErrorState() {
    const base = currentTargetApiBase();
    if (!base) {
      state.debugHasErrors = false;
      renderDebugChrome();
      return;
    }
    try {
      const errors = await api(base + '/debug?level=error&limit=1');
      state.debugHasErrors = Array.isArray(errors) && errors.length > 0;
    } catch (error) {
      state.debugHasErrors = false;
    }
    renderDebugChrome();
  }

  async function fetchDebugEntries() {
    const base = currentTargetApiBase();
    if (!base) {
      state.debugEntries = [];
      renderDebugModal();
      renderDebugChrome();
      return;
    }
    state.debugLoading = true;
    renderDebugModal();
    try {
      const entries = await api(base + '/debug?limit=200');
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
    els.debugFab.disabled = !currentActiveTarget();
    els.debugFab.className = 'debug-fab' + (state.debugHasErrors ? ' has-errors' : '');
    els.debugModal.className = 'modal-overlay' + (state.debugOpen ? ' open' : '');
  }

  function renderDebugModal() {
    renderDebugChrome();
    els.debugModalSubtitle.textContent = currentTargetName();
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
    if (!currentActiveTarget()) return;
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
    const confirmed = window.confirm('Are you sure you want to clear this item? This cannot be undone.');
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
      showToast('Item cleared');
    } catch (error) {
      showToast(error.message || 'Could not clear item');
    }
  }

  async function deleteActiveWorkspace() {
    if (!state.activeWorkspaceId) return;
    const confirmed = window.confirm('Are you sure you want to clear this item? This cannot be undone.');
    if (!confirmed) return;
    const deletingId = state.activeWorkspaceId;
    try {
      await api('/api/workspaces/' + encodeURIComponent(deletingId), { method: 'DELETE' });
      if (state.activeWorkspaceId === deletingId) {
        state.activeWorkspaceId = null;
        state.activeWorkspace = null;
        state.messages = [];
        state.lastMessageTimestamp = null;
        state.debugEntries = [];
        state.debugHasErrors = false;
        resetBuildLogState();
        resetConsoleLogState();
        resetStatusSummaryState();
        closeDebugModal();
      }
      await pollObjectives();
      if (state.activeWorkspaceId) await loadActiveWorkspace(true);
      else if (state.activeObjectiveId) await loadActiveObjective(true);
      else render();
      showToast('Item cleared');
    } catch (error) {
      showToast(error.message || 'Could not clear item');
    }
  }

  function deleteActiveItem() {
    if (state.activeWorkspaceId) {
      deleteActiveWorkspace();
      return;
    }
    deleteActiveObjective();
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
    const availableObjectives = sortedObjectives(state.objectives);
    const availableWorkspaces = sortedWorkspaces(state.workspaces);
    if (!availableObjectives.length && !availableWorkspaces.length) {
      state.activeTargetType = null;
      state.activeObjectiveId = null;
      state.activeObjective = null;
      state.activeWorkspaceId = null;
      state.activeWorkspace = null;
      state.actionButtons = [];
      state.actionButtonState = {};
      state.fabModalOpen = false;
      state.messages = [];
      state.lastMessageTimestamp = null;
      resetBuildLogState();
      resetConsoleLogState();
      return;
    }
    if (state.activeTargetType === 'workspace' && state.activeWorkspaceId && availableWorkspaces.some((item) => item.id === state.activeWorkspaceId)) {
      return;
    }
    if (state.activeTargetType === 'objective' && state.activeObjectiveId && availableObjectives.some((item) => item.id === state.activeObjectiveId)) {
      return;
    }

    const runningObjective = availableObjectives.find((item) => (
      ['planning', 'plan_review', 'negotiating_contracts', 'contract_review', 'executing', 'reviewing', 'rework'].includes(String(item.status).toLowerCase())
    ));
    if (runningObjective) {
      state.activeTargetType = 'objective';
      state.activeObjectiveId = runningObjective.id;
      state.activeWorkspaceId = null;
      return;
    }

    const activeWorkspace = availableWorkspaces.find((item) => !!item.sessionActive);
    if (activeWorkspace) {
      state.activeTargetType = 'workspace';
      state.activeWorkspaceId = activeWorkspace.id;
      state.activeObjectiveId = null;
      return;
    }

    const mostRecent = []
      .concat(availableObjectives.map((item) => ({
        kind: 'objective',
        item,
        ts: parseIso(item.updatedAt || item.createdAt) || 0
      })))
      .concat(availableWorkspaces.map((item) => ({
        kind: 'workspace',
        item,
        ts: parseIso(item.updatedAt || item.createdAt) || 0
      })))
      .sort((a, b) => b.ts - a.ts)[0];

    if (!mostRecent) return;
    state.activeTargetType = mostRecent.kind;
    state.activeObjectiveId = mostRecent.kind === 'objective' ? mostRecent.item.id : null;
    state.activeWorkspaceId = mostRecent.kind === 'workspace' ? mostRecent.item.id : null;
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
    if (!state.draftBaseBranch || state.draftBaseBranch === 'main') {
      state.draftBaseBranch = state.config.defaultBaseBranch || 'main';
    }
    if (!state.draftWorkflowMode) {
      state.draftWorkflowMode = 'structured';
    }
  }

  function populateSettingsForm() {
    const cfg = state.config || {};
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
    state.gitContextMode = '';
    state.gitContextFile = '';
    state.gitContextSection = '';
    state.gitContextAbsolutePath = '';
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
    els.diffSidebar.innerHTML = '';
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
    renderDiffSidebar();
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
    const mode = state.gitContextMode;
    const path = activeGitPath();
    const file = state.gitContextFile;
    const section = state.gitContextSection;
    const absolutePath = state.gitContextAbsolutePath;
    hideGitContextMenu();
    if (!path || !file) return;
    if (action === 'diff') {
      await openGitDiff(file, section);
      return;
    }
    if (action === 'copy-path') {
      copyText(absolutePath || (path + '/' + file), 'Path');
      return;
    }
    if (action === 'open-native') {
      try {
        await api('/api/open-in-native', {
          method: 'POST',
          body: JSON.stringify({ cwd: path, file })
        });
        showToast('Opened in native app');
      } catch (error) {
        console.error('open-in-native failed', { path, file, absolutePath, error });
        showToast(error.message || 'Could not open file');
      }
      return;
    }
    const endpoint = action === 'stage' ? '/api/git-stage-path' : '/api/git-unstage-path';
    try {
      await api(endpoint, {
        method: 'POST',
        body: JSON.stringify({ path, file })
      });
      await fetchGitStatus();
      if (els.diffOverlay.classList.contains('visible')) renderDiffSidebar();
    } catch (error) {
      showToast(error.message || 'Git action failed');
    }
  }

  function showGitContextMenu(event, options) {
    if (!options || !options.file) return;
    state.gitContextMode = options.mode || 'git';
    state.gitContextFile = options.file;
    state.gitContextSection = options.section || '';
    state.gitContextAbsolutePath = options.absolutePath || '';
    let html = '';
    const section = options.section || '';
    if (section === 'unstaged' || section === 'untracked') {
      html += '<div class="git-ctx-item" data-git-action="stage">Stage file</div>';
    }
    if (section === 'staged') {
      html += '<div class="git-ctx-item" data-git-action="unstage">Unstage file</div>';
    }
    if (options.mode !== 'diff-sidebar') {
      html += '<div class="git-ctx-item" data-git-action="diff">View diff</div>';
    }
    html += '<div class="git-ctx-item" data-git-action="open-native">Open in native app</div>';
    html += '<div class="git-ctx-item" data-git-action="copy-path">Copy path</div>';
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

  function renderStatusPanel() {
    els.gitPanelBody.innerHTML = renderStatusSummaryCard();
    els.gitPanelBody.querySelectorAll('[data-status-summary-refresh]').forEach((node) => {
      node.addEventListener('click', () => {
        fetchStatusSummary(true);
      });
    });
  }

  function renderGitPanel() {
    const path = activeGitPath();
    els.gitPanel.className = 'git-panel' + (state.gitPanelOpen ? ' open' : '');
    const panelOverlayOpen = !!state.gitPanelOpen;
    els.main.classList.toggle('panel-overlay-open', panelOverlayOpen);
    document.body.classList.toggle('right-panel-open', panelOverlayOpen);
    const isStatusMode = state.rightPanelMode === 'status';
    const panelPath = isStatusMode
      ? activeFilesRoot() || path
      : ((state.gitStatus && state.gitStatus.cwd) || path);
    els.gitPanelBranch.textContent = isStatusMode
      ? 'Status'
      : ((state.gitStatus && state.gitStatus.branch) || (state.activeObjective && state.activeObjective.branchName) || 'Git');
    els.gitPanelPath.textContent = panelPath || 'No working directory';
    els.gitPanelCopyButton.disabled = !panelPath;
    const data = state.gitStatus;
    if (!state.gitPanelOpen) return;
    if (isStatusMode) {
      renderStatusPanel();
      return;
    }
    if (!path) {
      els.gitPanelBody.innerHTML = '<div class="git-empty">No active path available</div>';
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
        showGitContextMenu(event, {
          mode: 'git',
          file: node.getAttribute('data-git-file'),
          section: node.getAttribute('data-git-section')
        });
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

  function renderDiffSidebar() {
    const data = state.gitStatus;
    const branch = (data && data.branch) || '';
    const pathLabel = (data && data.cwd) || activeGitPath() || '';
    const staged = Array.isArray(data && data.staged) ? data.staged : [];
    const unstaged = Array.isArray(data && data.unstaged) ? data.unstaged : [];
    const untracked = Array.isArray(data && data.untracked) ? data.untracked : [];
    const commits = Array.isArray(data && data.commits) ? data.commits : [];

    function sidebarFileEl(status, file, cls, section) {
      const isActive = state.gitDiffFile === file && state.gitDiffSection === section;
      return '<div class="git-file' + (isActive ? ' active' : '') + '" data-diff-sb-file="' + esc(file) + '" data-diff-sb-section="' + esc(section) + '" title="' + esc(file) + '"><span class="git-status ' + cls + '">' + esc(status) + '</span><span class="git-file-name">' + esc(file) + '</span></div>';
    }

    let html = '<div class="diff-sidebar-header">';
    html += '<div class="diff-sidebar-branch">' + esc(branch || 'Git') + '</div>';
    if (pathLabel) html += '<div class="diff-sidebar-path" title="' + esc(pathLabel) + '">' + esc(pathLabel) + '</div>';
    html += '</div><div class="diff-sidebar-body">';

    if (commits.length) {
      html += '<div class="git-section"><div class="git-section-title commits">Commits</div>';
      commits.forEach((commit) => {
        const isExpanded = state.gitExpandedCommit === commit.hash;
        const chevron = '<span class="git-commit-chevron">' + (isExpanded ? '▼' : '►') + '</span>';
        html += '<div class="git-commit' + (isExpanded ? ' expanded' : '') + '" data-diff-sb-commit="' + esc(commit.hash) + '">' + chevron + '<span class="git-hash">' + esc(commit.hash) + '</span>' + esc(commit.message) + '</div>';
        if (isExpanded) {
          if (state.gitCommitFilesLoading) {
            html += '<div class="git-commit-files"><div class="diff-loading" style="padding:4px 16px;font-size:11px">Loading…</div></div>';
          } else if (state.gitCommitFiles.length) {
            html += '<div class="git-commit-files">';
            state.gitCommitFiles.forEach((cf) => {
              const statusCls = 'cf-' + (cf.status || 'M').charAt(0);
              const isActive = state.gitDiffFile === cf.file && state.gitDiffSection === 'commit';
              html += '<div class="git-commit-file' + (isActive ? ' active' : '') + '" data-diff-sb-cfile="' + esc(cf.file) + '" data-diff-sb-chash="' + esc(commit.hash) + '"><span class="git-cf-status ' + statusCls + '">' + esc(cf.status) + '</span><span class="git-file-name">' + esc(cf.file) + '</span></div>';
            });
            html += '</div>';
          } else {
            html += '<div class="git-commit-files"><div class="git-empty" style="padding:4px 16px;font-size:11px">No files</div></div>';
          }
        }
      });
      html += '</div>';
    }
    if (staged.length) {
      html += '<div class="git-section"><div class="git-section-title staged">Staged</div>';
      staged.forEach((item) => { html += sidebarFileEl(item.status, item.file, 'st-staged', 'staged'); });
      html += '</div>';
    }
    if (unstaged.length) {
      html += '<div class="git-section"><div class="git-section-title unstaged">Unstaged</div>';
      unstaged.forEach((item) => { html += sidebarFileEl(item.status, item.file, 'st-unstaged', 'unstaged'); });
      html += '</div>';
    }
    if (untracked.length) {
      html += '<div class="git-section"><div class="git-section-title untracked">Untracked</div>';
      untracked.forEach((item) => { html += sidebarFileEl('?', item, 'st-untracked', 'untracked'); });
      html += '</div>';
    }
    if (!commits.length && !staged.length && !unstaged.length && !untracked.length) {
      html += '<div class="git-empty" style="padding:16px;font-size:12px">No changes</div>';
    }
    html += '</div>';
    els.diffSidebar.innerHTML = html;

    els.diffSidebar.querySelectorAll('[data-diff-sb-file]').forEach((node) => {
      node.addEventListener('click', () => {
        openGitDiff(node.getAttribute('data-diff-sb-file'), node.getAttribute('data-diff-sb-section'));
      });
      node.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        showGitContextMenu(event, {
          mode: 'diff-sidebar',
          file: node.getAttribute('data-diff-sb-file'),
          section: node.getAttribute('data-diff-sb-section')
        });
      });
    });
    els.diffSidebar.querySelectorAll('[data-diff-sb-commit]').forEach((node) => {
      node.addEventListener('click', () => {
        toggleCommitExpansion(node.getAttribute('data-diff-sb-commit')).then(() => renderDiffSidebar());
      });
    });
    els.diffSidebar.querySelectorAll('[data-diff-sb-cfile]').forEach((node) => {
      node.addEventListener('click', (event) => {
        event.stopPropagation();
        openCommitDiff(node.getAttribute('data-diff-sb-chash'), node.getAttribute('data-diff-sb-cfile'));
      });
    });
  }

  async function openWorkerOutput(taskId) {
    if (!state.activeObjectiveId || !taskId) return;
    clearWorkerOutputPolling();
    state.workerOutputMode = 'task';
    state.workerOutputTaskId = taskId;
    state.workerOutputContent = '';
    const task = findTask(taskId);
    els.workerOutputTitle.textContent = 'Worker Output' + (task ? ' \u2014 ' + taskDisplayTitle(task) : '');
    els.workerOutputBody.innerHTML = '<div class="diff-loading">Loading output\u2026</div>';
    els.workerOutputOverlay.classList.add('visible');
    await refreshWorkerOutput();
  }

  function clearWorkerOutputPolling() {
    if (state.workerOutputInterval) {
      window.clearInterval(state.workerOutputInterval);
      state.workerOutputInterval = null;
    }
    state.workerOutputPolling = false;
  }

  async function openWorkspaceOutput() {
    if (!state.activeWorkspaceId) return;
    clearWorkerOutputPolling();
    state.workerOutputMode = 'workspace';
    state.workerOutputTaskId = null;
    state.workerOutputContent = '';
    const title = state.activeWorkspace && state.activeWorkspace.name
      ? 'Workspace Terminal \u2014 ' + state.activeWorkspace.name
      : 'Workspace Terminal';
    els.workerOutputTitle.textContent = title;
    els.workerOutputBody.innerHTML = '<div class="diff-loading">Loading terminal snapshot\u2026</div>';
    els.workerOutputOverlay.classList.add('visible');
    await refreshWorkerOutput();
    state.workerOutputPolling = true;
    state.workerOutputInterval = window.setInterval(() => {
      if (!els.workerOutputOverlay.classList.contains('visible') || state.workerOutputMode !== 'workspace') {
        clearWorkerOutputPolling();
        return;
      }
      refreshWorkerOutput();
    }, 3000);
  }

  function renderWorkspaceTerminalLine(line) {
    const raw = stripAnsi(String(line == null ? '' : line));
    const trimmed = raw.trim();
    if (!trimmed) {
      return '<div class="wo-line wo-empty">&nbsp;</div>';
    }
    if (/^[\u2500-\u257f_\-=]{8,}$/.test(trimmed)) {
      return '<div class="wo-line wo-rule"></div>';
    }
    if (/^\s*(Model:|Cost:|PR\s*#\d+\b|Ctx:)/i.test(trimmed) || /^\s*\*\s+Brewed for\b/i.test(trimmed)) {
      return '<div class="wo-line wo-meta">' + esc(raw) + '</div>';
    }
    const bulletMatch = raw.match(/^(\s*[●•◦⏺]\s+)(.+)$/);
    if (bulletMatch) {
      const body = bulletMatch[2];
      const kindMatch = body.match(/^([A-Za-z][A-Za-z0-9]*)(\(.+\))$/);
      if (kindMatch) {
        return [
          '<div class="wo-line wo-tool">',
          '<span class="wo-bullet">' + esc(bulletMatch[1]) + '</span>',
          '<span class="wo-kind">' + esc(kindMatch[1]) + '</span>',
          '<span class="wo-tool-call">' + esc(kindMatch[2]) + '</span>',
          '</div>'
        ].join('');
      }
      return '<div class="wo-line wo-tool"><span class="wo-bullet">' + esc(bulletMatch[1]) + '</span>' + esc(body) + '</div>';
    }
    if (/^\s*[╰└│]/.test(raw)) {
      return '<div class="wo-line wo-child">' + esc(raw) + '</div>';
    }
    const numberedMatch = raw.match(/^(\s*\d+)\s+(.*)$/);
    if (numberedMatch) {
      return [
        '<div class="wo-line wo-numbered">',
        '<span class="wo-number">' + esc(numberedMatch[1]) + '</span>',
        '<span class="wo-number-text">' + esc(numberedMatch[2]) + '</span>',
        '</div>'
      ].join('');
    }
    if (/^\s{2,}\S/.test(raw)) {
      return '<div class="wo-line wo-child">' + esc(raw) + '</div>';
    }
    if (/^(Here'?s|Potential|Priority|Three files|The instructions|With them|Earlier)/i.test(trimmed)) {
      return '<div class="wo-line wo-emphasis">' + esc(raw) + '</div>';
    }
    return '<div class="wo-line wo-plain">' + esc(raw) + '</div>';
  }

  function renderWorkerOutputContent(content, mode) {
    const lines = String(content || '').split('\n');
    if (mode === 'workspace') {
      return '<div class="worker-output-content workspace-peek">' + lines.map(renderWorkspaceTerminalLine).join('') + '</div>';
    }
    return '<div class="worker-output-content">' + lines.map((line) => '<div class="wo-line">' + ansiToHtml(line) + '</div>').join('') + '</div>';
  }

  async function refreshWorkerOutput() {
    const mode = state.workerOutputMode || 'task';
    try {
      let response;
      if (mode === 'workspace') {
        const workspaceId = state.activeWorkspaceId;
        if (!workspaceId) return;
        response = await api('/api/workspaces/' + encodeURIComponent(workspaceId) + '/screen?lines=220');
        if (state.workerOutputMode !== 'workspace' || state.activeWorkspaceId !== workspaceId) return;
      } else {
        const taskId = state.workerOutputTaskId;
        if (!taskId || !state.activeObjectiveId) return;
        response = await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/tasks/' + encodeURIComponent(taskId) + '/screen');
        if (state.workerOutputMode !== 'task' || state.workerOutputTaskId !== taskId) return;
      }
      if (response.ok) {
        state.workerOutputContent = response.screen || '';
        els.workerOutputBody.innerHTML = renderWorkerOutputContent(state.workerOutputContent, mode);
        els.workerOutputBody.scrollTop = els.workerOutputBody.scrollHeight;
      } else {
        els.workerOutputBody.innerHTML = '<div class="diff-loading" style="color:var(--red)">' + esc(response.error || 'Failed to load output') + '</div>';
      }
    } catch (error) {
      if (mode === 'workspace') {
        if (state.workerOutputMode !== 'workspace') return;
      } else if (!state.workerOutputTaskId || state.workerOutputMode !== 'task') {
        return;
      }
      els.workerOutputBody.innerHTML = '<div class="diff-loading" style="color:var(--red)">' + esc(error.message || 'Failed to load output') + '</div>';
    }
  }

  function closeWorkerOutput() {
    clearWorkerOutputPolling();
    state.workerOutputMode = '';
    state.workerOutputTaskId = null;
    state.workerOutputContent = '';
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
    renderDiffSidebar();
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
    if (!state.gitPanelOpen || state.rightPanelMode !== 'git' || !path) {
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

  async function fetchStatusSummary(force) {
    const target = currentActiveTarget();
    if (!target) {
      addLocalDebugEntry('warn', 'status-click-ignored', { reason: 'no-active-item' });
      return;
    }
    const targetKey = currentTargetKey();
    const targetBase = currentTargetApiBase();
    addLocalDebugEntry('info', 'status-clicked', {
      targetKind: target.kind,
      targetId: target.id,
      force: !!force,
      targetStatus: target.kind === 'workspace'
        ? (state.activeWorkspace && state.activeWorkspace.status)
        : (state.activeObjective && state.activeObjective.status)
    });
    if (!force && state.statusSummary && state.statusSummaryTargetKey === targetKey) {
      addLocalDebugEntry('info', 'status-using-cached-summary', { targetKind: target.kind, targetId: target.id });
      renderGitPanel();
      return;
    }
    state.statusSummaryLoading = true;
    state.statusSummaryError = '';
    if (!state.statusSummary || state.statusSummaryTargetKey !== targetKey) {
      state.statusSummary = null;
      state.statusSummaryTargetKey = targetKey;
    }
    renderGitPanel();
    try {
      const url = targetBase + '/status-summary' + (target.kind === 'objective' ? '?enrich=haiku' : '');
      addLocalDebugEntry('info', 'status-fetch-start', { targetKind: target.kind, targetId: target.id, url });
      const summary = await api(url);
      if (currentTargetKey() !== targetKey) return;
      state.statusSummary = summary;
      state.statusSummaryTargetKey = targetKey;
      state.statusSummaryError = '';
      addLocalDebugEntry('info', 'status-fetch-success', {
        targetKind: target.kind,
        targetId: target.id,
        source: summary && summary.summarySource && summary.summarySource.kind,
        display: summary && summary.summarySource && summary.summarySource.display
      });
    } catch (error) {
      if (currentTargetKey() !== targetKey) return;
      state.statusSummaryError = error.message || 'Could not load status summary';
      addLocalDebugEntry('error', 'status-fetch-failed', {
        targetKind: target.kind,
        targetId: target.id,
        message: state.statusSummaryError
      });
      showToast(state.statusSummaryError);
    } finally {
      if (currentTargetKey() === targetKey) {
        state.statusSummaryLoading = false;
        renderGitPanel();
      }
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
    toggleRightPanel('git');
  }

  function toggleStatusPanel() {
    if (!currentActiveTarget()) return;
    toggleRightPanel('status');
  }

  function toggleRightPanel(mode) {
    if (mode === 'git' && !activeGitPath()) return;
    if (mode === 'status' && !currentActiveTarget()) return;
    if (state.gitPanelOpen && state.rightPanelMode === mode) {
      state.gitPanelOpen = false;
    } else {
      state.gitPanelOpen = true;
      state.rightPanelMode = mode;
    }
    renderContext();
    renderGitPanel();
    if (state.gitPanelOpen) {
      hideGitContextMenu();
      if (mode === 'status') {
        closeDiffOverlay();
        fetchStatusSummary(false);
      } else {
        fetchGitStatus();
      }
    } else {
      hideGitContextMenu();
      closeDiffOverlay();
    }
  }

  function updateSidebarFormFromState() {
    const className = 'sidebar-form' + (state.sidebarFormOpen ? ' open' : '');
    const projects = sortedProjects(state.projects);
    const formDisabled = state.pendingCreate ? ' disabled' : '';
    const projectOptions = sortedProjects(state.projects).map((project) => {
      const selected = project.id === state.draftProjectId ? ' selected' : '';
      const hint = compactPath(project.rootPath || '');
      return '<option value="' + esc(project.id) + '"' + selected + '>' + esc(project.name || 'Untitled project') + (hint ? ' · ' + esc(hint) : '') + '</option>';
    }).join('');
    const nextHtml = state.sidebarFormMode === 'project'
      ? [
          '<div class="sf-mode-title">Add project</div>',
          '<input class="sf-input" id="projectNameInput" placeholder="Project name" value="' + esc(state.draftProjectName || '') + '">',
          '<label class="sf-field-label" for="projectFolderPickerButton">Choose Project Folder</label>',
          '<div class="sf-picker-row">',
          '<input class="sf-input sf-input-readonly" id="projectRootPathInput" placeholder="No folder selected" value="' + esc(state.draftProjectRootPath || state.draftProjectDir || '') + '" readonly>',
          '<button class="sf-picker-button" id="projectFolderPickerButton" type="button"' + ((state.projectPickerBusy || state.pendingCreate) ? ' disabled' : '') + '>' + (state.projectPickerBusy ? 'Choosing…' : 'Browse…') + '</button>',
          '</div>',
          (state.projectPickerFallback
            ? '<input class="sf-input" id="projectRootPathManualInput" placeholder="/path/to/git/repo" value="' + esc(state.draftProjectRootPath || state.draftProjectDir || '') + '">'
            : '<button class="sf-inline-link" id="projectFolderManualButton" type="button"' + formDisabled + '>Type path manually</button>'),
          '<input class="sf-input" id="projectBaseBranchInput" placeholder="Default base branch" value="' + esc(state.draftProjectBaseBranch || 'main') + '">',
          '<div class="sf-actions">',
          '<button class="sf-submit" id="sidebarCreateProjectButton"' + formDisabled + '>' + (state.pendingCreate ? 'Saving...' : 'Save project') + '</button>',
          '<button class="sf-cancel" id="sidebarCancelButton"' + formDisabled + '>Cancel</button>',
          '</div>',
          '<div class="sf-hint">Point this at an existing git repo. After that, you can choose New or Open.</div>'
        ].join('')
      : state.sidebarFormMode === 'add-kind'
        ? [
          '<div class="sf-mode-title">Start with</div>',
          '<label class="sf-field-label" for="addKindProjectSelectInput">Project</label>',
          '<select class="sf-input" id="addKindProjectSelectInput">' + projectOptions + '</select>',
          '<div class="sf-actions sf-actions-stack">',
          '<button class="sf-submit" id="chooseObjectiveButton"' + formDisabled + '>New</button>',
          '<button class="sf-submit secondary" id="chooseWorkspaceButton"' + formDisabled + '>Open</button>',
          '<button class="sf-cancel" id="sidebarCancelButton"' + formDisabled + '>Cancel</button>',
          '</div>',
          '<div class="sf-hint">Choose whether to start something new or open work that already exists.</div>'
        ].join('')
      : state.sidebarFormMode === 'workspace'
        ? [
          '<div class="sf-mode-title">Open</div>',
          '<label class="sf-field-label" for="workspaceProjectSelectInput">Project</label>',
          '<select class="sf-input" id="workspaceProjectSelectInput">' + projectOptions + '</select>',
          '<label class="sf-field-label" for="workspaceFolderPickerButton">Path</label>',
          '<div class="sf-picker-row">',
          '<input class="sf-input sf-input-readonly" id="workspaceRootPathInput" placeholder="No folder selected" value="' + esc(state.draftWorkspaceRootPath || state.draftProjectDir || '') + '" readonly>',
          '<button class="sf-picker-button" id="workspaceFolderPickerButton" type="button"' + ((state.openPathPickerBusy || state.pendingCreate) ? ' disabled' : '') + '>' + (state.openPathPickerBusy ? 'Choosing…' : 'Browse…') + '</button>',
          '</div>',
          '<label class="sf-field-label" for="workspaceNameInput">Name (optional)</label>',
          '<input class="sf-input" id="workspaceNameInput" placeholder="Main workspace" value="' + esc(state.draftWorkspaceName || '') + '">',
          '<div class="sf-actions">',
          '<button class="sf-submit" id="sidebarCreateWorkspaceButton"' + formDisabled + '>' + (state.pendingCreate ? 'Opening...' : 'Open') + '</button>',
          '<button class="sf-cancel" id="sidebarCancelButton"' + formDisabled + '>Cancel</button>',
          '</div>',
          '<div class="sf-hint">Open an existing feature, repo root, or worktree that already has work in progress.</div>'
        ].join('')
      : [
          '<div class="sf-mode-title">New</div>',
          '<label class="sf-field-label" for="projectSelectInput">Project</label>',
          '<select class="sf-input" id="projectSelectInput">' + projectOptions + '</select>',
          '<div class="sf-field-label">Workflow</div>',
          '<div class="sf-toggle-group" role="group" aria-label="Workflow mode">',
          '<button class="sf-toggle' + (defaultWorkflowMode() === 'structured' ? ' active' : '') + '" id="workflowStructuredButton" type="button" data-workflow-mode="structured" aria-pressed="' + (defaultWorkflowMode() === 'structured' ? 'true' : 'false') + '"' + formDisabled + '>Structured</button>',
          '<button class="sf-toggle' + (defaultWorkflowMode() === 'direct' ? ' active' : '') + '" id="workflowDirectButton" type="button" data-workflow-mode="direct" aria-pressed="' + (defaultWorkflowMode() === 'direct' ? 'true' : 'false') + '"' + formDisabled + '>Direct</button>',
          '</div>',
          '<label class="sf-field-label" for="baseBranchInput">Base branch</label>',
          '<div class="sf-row">',
          '<input class="sf-input" id="baseBranchInput" placeholder="Base branch" value="' + esc(defaultBaseBranch()) + '">',
          '</div>',
          '<label class="sf-field-label" for="branchNameInput">Branch name <span class="sf-field-optional">optional</span></label>',
          '<input class="sf-input" id="branchNameInput" placeholder="Feature branch name (optional)" value="' + esc(state.draftBranchName || '') + '">',
          '<label class="sf-field-label" for="sidebarGoalInput">Goal</label>',
          '<textarea class="sf-textarea" id="sidebarGoalInput" placeholder="Describe the objective">' + esc(state.draftGoal) + '</textarea>',
          '<div class="sf-actions">',
          '<button class="sf-submit" id="sidebarCreateButton"' + formDisabled + '>' + (state.pendingCreate ? 'Starting...' : 'Start new') + '</button>',
          '<button class="sf-cancel" id="sidebarCancelButton"' + formDisabled + '>Cancel</button>',
          '</div>',
          '<div class="sf-hint">Start a new feature or task in this project. cmux will create the working context and get started.</div>'
        ].join('');
    if (els.sidebarForm.className === className && els.sidebarForm.innerHTML === nextHtml) return;
    els.sidebarForm.className = className;
    els.sidebarForm.innerHTML = nextHtml;
    if (!state.sidebarFormOpen) return;
    document.getElementById('sidebarCancelButton').addEventListener('click', () => {
      if (state.sidebarFormMode === 'project') {
        state.projectCreationReturnMode = '';
      }
      state.sidebarFormOpen = false;
      updateSidebarFormFromState();
    });
    if (state.sidebarFormMode === 'project') {
      const projectNameInput = document.getElementById('projectNameInput');
      const projectRootPathInput = document.getElementById('projectRootPathInput');
      const projectRootPathManualInput = document.getElementById('projectRootPathManualInput');
      const projectBaseBranchInput = document.getElementById('projectBaseBranchInput');
      const projectFolderPickerButton = document.getElementById('projectFolderPickerButton');
      const projectFolderManualButton = document.getElementById('projectFolderManualButton');
      document.getElementById('sidebarCreateProjectButton').addEventListener('click', submitSidebarProject);
      if (projectFolderPickerButton) {
        projectFolderPickerButton.addEventListener('click', pickProjectFolder);
      }
      if (projectFolderManualButton) {
        projectFolderManualButton.addEventListener('click', () => {
          state.projectPickerFallback = true;
          updateSidebarFormFromState();
          window.setTimeout(() => {
            const input = document.getElementById('projectRootPathManualInput');
            if (input) input.focus();
          }, 0);
        });
      }
      projectNameInput.addEventListener('input', (event) => {
        state.draftProjectName = event.target.value;
      });
      if (projectRootPathInput) {
        projectRootPathInput.addEventListener('click', () => {
          if (!state.draftProjectRootPath) pickProjectFolder();
        });
      }
      if (projectRootPathManualInput) {
        projectRootPathManualInput.addEventListener('input', (event) => {
          state.draftProjectRootPath = event.target.value;
        });
      }
      projectBaseBranchInput.addEventListener('input', (event) => {
        state.draftProjectBaseBranch = event.target.value || 'main';
      });
      return;
    }
    if (state.sidebarFormMode === 'add-kind') {
      const addKindProjectSelectInput = document.getElementById('addKindProjectSelectInput');
      document.getElementById('chooseObjectiveButton').addEventListener('click', () => {
        const projectId = addKindProjectSelectInput ? addKindProjectSelectInput.value.trim() : state.draftProjectId;
        openSidebarForm('', projectId);
      });
      document.getElementById('chooseWorkspaceButton').addEventListener('click', () => {
        const projectId = addKindProjectSelectInput ? addKindProjectSelectInput.value.trim() : state.draftProjectId;
        openWorkspaceForm(projectId);
      });
      if (addKindProjectSelectInput) {
        addKindProjectSelectInput.addEventListener('change', (event) => {
          setDraftProject(event.target.value, { updateBaseBranch: false });
        });
      }
      return;
    }
    if (state.sidebarFormMode === 'workspace') {
      const workspaceProjectSelectInput = document.getElementById('workspaceProjectSelectInput');
      const workspaceRootPathInput = document.getElementById('workspaceRootPathInput');
      const workspaceNameInput = document.getElementById('workspaceNameInput');
      const workspaceFolderPickerButton = document.getElementById('workspaceFolderPickerButton');
      document.getElementById('sidebarCreateWorkspaceButton').addEventListener('click', submitSidebarWorkspace);
      workspaceProjectSelectInput.addEventListener('change', (event) => {
        const previousProjectDir = state.draftProjectDir;
        const project = setDraftProject(event.target.value);
        if ((!state.draftWorkspaceRootPath || state.draftWorkspaceRootPath === previousProjectDir) && project && project.rootPath) {
          state.draftWorkspaceRootPath = project.rootPath;
          updateSidebarFormFromState();
        }
      });
      if (workspaceFolderPickerButton) {
        workspaceFolderPickerButton.addEventListener('click', pickWorkspaceFolder);
      }
      if (workspaceRootPathInput) {
        workspaceRootPathInput.addEventListener('click', () => {
          pickWorkspaceFolder();
        });
      }
      workspaceNameInput.addEventListener('input', (event) => {
        state.draftWorkspaceName = event.target.value;
      });
      return;
    }
    const projectSelectInput = document.getElementById('projectSelectInput');
    const baseBranchInput = document.getElementById('baseBranchInput');
    const branchNameInput = document.getElementById('branchNameInput');
    const sidebarGoalInput = document.getElementById('sidebarGoalInput');
    const workflowButtons = Array.from(document.querySelectorAll('[data-workflow-mode]'));
    document.getElementById('sidebarCreateButton').addEventListener('click', submitSidebarObjective);
    projectSelectInput.addEventListener('change', (event) => {
      setDraftProject(event.target.value);
      updateSidebarFormFromState();
    });
    workflowButtons.forEach((button) => {
      button.addEventListener('click', () => {
        state.draftWorkflowMode = button.getAttribute('data-workflow-mode') === 'direct' ? 'direct' : 'structured';
        updateSidebarFormFromState();
      });
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

  function openAddKindForm(projectId) {
    openSidebar();
    state.sidebarFormMode = 'add-kind';
    state.sidebarFormOpen = true;
    const projects = sortedProjects(state.projects);
    if (!projects.length) {
      showToast('Add a project first.');
      openProjectForm();
      return;
    }
    const nextProjectId = projectId || state.draftProjectId || selectedProjectId() || (projects[0] && projects[0].id) || '';
    setDraftProject(nextProjectId, { updateBaseBranch: false });
    updateSidebarFormFromState();
    window.setTimeout(() => {
      const input = document.getElementById('addKindProjectSelectInput');
      if (input) input.focus();
    }, 0);
  }

  function openSidebarForm(seedGoal, projectId) {
    openSidebar();
    state.sidebarFormMode = 'objective';
    state.sidebarFormOpen = true;
    const projects = sortedProjects(state.projects);
    if (!projects.length) {
      showToast('Add a project first, then start something new.');
      openProjectForm({ returnMode: 'objective' });
      return;
    }
    const nextProjectId = projectId || state.draftProjectId || selectedProjectId() || (projects[0] && projects[0].id) || '';
    setDraftProject(nextProjectId, { updateBaseBranch: !state.draftProjectId || state.draftProjectId !== nextProjectId });
    if (!state.draftProjectId) {
      setDraftProject((projects[0] && projects[0].id) || '');
    }
    state.draftWorkflowMode = defaultWorkflowMode();
    state.draftBranchName = state.draftBranchName || '';
    if (typeof seedGoal === 'string') state.draftGoal = seedGoal;
    updateSidebarFormFromState();
    window.setTimeout(() => {
      const input = document.getElementById('sidebarGoalInput') || document.getElementById('projectSelectInput');
      if (input) input.focus();
    }, 0);
  }

  function openWorkspaceForm(projectId) {
    openSidebar();
    state.sidebarFormMode = 'workspace';
    state.sidebarFormOpen = true;
    state.openPathPickerBusy = false;
    const projects = sortedProjects(state.projects);
    if (!projects.length) {
      showToast('Add a project first, then open existing work.');
      openProjectForm({ returnMode: 'workspace' });
      return;
    }
    const nextProjectId = projectId || state.draftProjectId || selectedProjectId() || (projects[0] && projects[0].id) || '';
    const project = setDraftProject(nextProjectId, { updateBaseBranch: false });
    state.draftWorkspaceRootPath = (project && project.rootPath) || state.draftWorkspaceRootPath || '';
    updateSidebarFormFromState();
    pickWorkspaceFolder();
  }

  function openProjectForm(options) {
    const settings = options || {};
    openSidebar();
    state.sidebarFormMode = 'project';
    state.sidebarFormOpen = true;
    state.projectPickerFallback = false;
    state.projectPickerBusy = false;
    state.projectCreationReturnMode = settings.returnMode || '';
    state.draftProjectRootPath = state.draftProjectRootPath || state.draftProjectDir || '';
    state.draftProjectBaseBranch = state.draftProjectBaseBranch || defaultBaseBranch();
    updateSidebarFormFromState();
    window.setTimeout(() => {
      const input = document.getElementById('projectFolderPickerButton') || document.getElementById('projectNameInput');
      if (input) input.focus();
    }, 0);
  }

  async function pickProjectFolder() {
    if (state.projectPickerBusy) return;
    state.projectPickerBusy = true;
    updateSidebarFormFromState();
    try {
      const result = await pickFolderPath();
      if (result && result.ok && result.path) {
        state.draftProjectRootPath = String(result.path || '').trim();
        if (!String(state.draftProjectName || '').trim()) {
          state.draftProjectName = inferProjectNameFromPath(state.draftProjectRootPath);
        }
        state.projectPickerFallback = false;
        updateSidebarFormFromState();
        return;
      }
      if (result && result.cancelled) return;
      state.projectPickerFallback = true;
      updateSidebarFormFromState();
      showToast((result && result.error) ? result.error : 'Folder picker unavailable. Enter the path manually.');
    } catch (error) {
      state.projectPickerFallback = true;
      updateSidebarFormFromState();
      showToast(error.message || 'Folder picker unavailable. Enter the path manually.');
    } finally {
      state.projectPickerBusy = false;
      updateSidebarFormFromState();
    }
  }

  async function pickWorkspaceFolder() {
    if (state.openPathPickerBusy) return;
    state.openPathPickerBusy = true;
    updateSidebarFormFromState();
    try {
      const result = await pickFolderPath();
      if (result && result.ok && result.path) {
        state.draftWorkspaceRootPath = String(result.path || '').trim();
        if (!String(state.draftWorkspaceName || '').trim()) {
          state.draftWorkspaceName = inferProjectNameFromPath(state.draftWorkspaceRootPath);
        }
        updateSidebarFormFromState();
        window.setTimeout(() => {
          const input = document.getElementById('workspaceNameInput');
          if (input) input.focus();
        }, 0);
        return;
      }
      if (result && result.cancelled) {
        if (!state.draftWorkspaceRootPath) {
          state.sidebarFormOpen = false;
          updateSidebarFormFromState();
        }
        return;
      }
      updateSidebarFormFromState();
      showToast((result && result.error) ? result.error : 'Folder picker unavailable. Use Browse to try again.');
    } catch (error) {
      updateSidebarFormFromState();
      showToast(error.message || 'Folder picker unavailable. Use Browse to try again.');
    } finally {
      state.openPathPickerBusy = false;
      updateSidebarFormFromState();
    }
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

  function showCtxMenu(event, type, id) {
    event.preventDefault();
    event.stopPropagation();
    state.ctxTarget = { type: type, id: id };
    const menu = els.ctxMenu;
    menu.classList.add('open');
    const x = event.clientX;
    const y = event.clientY;
    menu.style.left = x + 'px';
    menu.style.top = y + 'px';
    // Adjust if overflowing viewport
    requestAnimationFrame(() => {
      const rect = menu.getBoundingClientRect();
      if (rect.bottom > window.innerHeight) {
        menu.style.top = (y - rect.height) + 'px';
      }
      if (rect.right > window.innerWidth) {
        menu.style.left = (x - rect.width) + 'px';
      }
    });
  }

  function hideCtxMenu() {
    els.ctxMenu.classList.remove('open');
    state.ctxTarget = null;
  }

  document.addEventListener('click', (e) => {
    if (!els.ctxMenu.contains(e.target)) hideCtxMenu();
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') hideCtxMenu();
  });
  // Dismiss on sidebar scroll
  const sidebarScrollTarget = document.querySelector('.obj-list') || document.querySelector('.sidebar');
  if (sidebarScrollTarget) {
    sidebarScrollTarget.addEventListener('scroll', () => hideCtxMenu(), { passive: true });
  }

  function startInlineRename(type, id) {
    const attr = type === 'objective' ? 'data-objective-id' : 'data-workspace-id';
    const itemEl = els.objectiveList.querySelector('[' + attr + '="' + CSS.escape(id) + '"]');
    if (!itemEl) return;
    const nameEl = itemEl.querySelector('.obj-name');
    if (!nameEl) return;
    const currentName = nameEl.textContent;
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'obj-name-input';
    input.value = currentName;
    nameEl.textContent = '';
    nameEl.appendChild(input);
    input.focus();
    input.select();

    // Prevent sidebar item click from navigating while editing
    itemEl.dataset.renaming = 'true';

    function commit() {
      const newName = input.value.trim();
      if (!newName || newName === currentName) {
        cancel();
        return;
      }
      const endpoint = type === 'objective'
        ? '/api/objectives/' + encodeURIComponent(id)
        : '/api/workspaces/' + encodeURIComponent(id);
      const body = type === 'objective' ? { goal: newName } : { name: newName };
      fetch(endpoint, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
        .then((res) => res.json())
        .then((updated) => {
          if (type === 'objective') {
            const idx = state.objectives.findIndex((o) => o.id === id);
            if (idx !== -1) state.objectives[idx] = updated;
            if (state.activeObjective && state.activeObjective.id === id) {
              state.activeObjective = updated;
            }
          } else {
            const idx = state.workspaces.findIndex((w) => w.id === id);
            if (idx !== -1) state.workspaces[idx] = updated;
            if (state.activeWorkspace && state.activeWorkspace.id === id) {
              state.activeWorkspace = updated;
            }
          }
          renderSidebar();
        })
        .catch(() => {
          cancel();
        });
    }

    function cancel() {
      delete itemEl.dataset.renaming;
      nameEl.textContent = currentName;
    }

    let committed = false;
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); committed = true; commit(); }
      if (e.key === 'Escape') { e.preventDefault(); cancel(); }
    });
    input.addEventListener('blur', () => {
      if (!committed) cancel();
    });
  }

  els.ctxRename.addEventListener('click', () => {
    const target = state.ctxTarget;
    hideCtxMenu();
    if (target) startInlineRename(target.type, target.id);
  });

  function showDeleteConfirm(type, id) {
    const item = type === 'objective'
      ? state.objectives.find((o) => o.id === id)
      : type === 'project'
      ? state.projects.find((p) => p.id === id)
      : state.workspaces.find((w) => w.id === id);
    if (!item) return;
    const name = type === 'objective' ? (item.goal || 'Untitled') : (item.name || 'Untitled');
    els.deleteConfirmTitle.textContent = 'Delete ' + type + '?';
    els.deleteConfirmName.textContent = name;
    els.deleteConfirmOverlay.classList.add('open');

    function cleanup() {
      els.deleteConfirmOverlay.classList.remove('open');
      els.deleteConfirmOk.removeEventListener('click', onConfirm);
      els.deleteConfirmCancel.removeEventListener('click', onCancel);
      els.deleteConfirmOverlay.removeEventListener('click', onBackdrop);
      document.removeEventListener('keydown', onEscape);
    }

    function onConfirm() {
      cleanup();
      executeDelete(type, id);
    }

    function onCancel() {
      cleanup();
    }

    function onBackdrop(e) {
      if (e.target === els.deleteConfirmOverlay) cleanup();
    }

    function onEscape(e) {
      if (e.key === 'Escape') cleanup();
    }

    els.deleteConfirmOk.addEventListener('click', onConfirm);
    els.deleteConfirmCancel.addEventListener('click', onCancel);
    els.deleteConfirmOverlay.addEventListener('click', onBackdrop);
    document.addEventListener('keydown', onEscape);
  }

  function executeDelete(type, id) {
    const endpoint = type === 'objective'
      ? '/api/objectives/' + encodeURIComponent(id)
      : type === 'project'
      ? '/api/projects/' + encodeURIComponent(id)
      : '/api/workspaces/' + encodeURIComponent(id);
    fetch(endpoint, { method: 'DELETE' })
      .then((res) => res.json())
      .then(() => {
        if (type === 'objective') {
          state.objectives = state.objectives.filter((o) => o.id !== id);
          if (state.activeObjectiveId === id) {
            state.activeObjectiveId = null;
            state.activeObjective = null;
            state.activeTargetType = null;
          }
        } else if (type === 'project') {
          state.projects = state.projects.filter((p) => p.id !== id);
          delete state.projectExpansion[id];
        } else {
          state.workspaces = state.workspaces.filter((w) => w.id !== id);
          if (state.activeWorkspaceId === id) {
            state.activeWorkspaceId = null;
            state.activeWorkspace = null;
            state.activeTargetType = null;
          }
        }
        renderSidebar();
      });
  }

  els.ctxDelete.addEventListener('click', () => {
    const target = state.ctxTarget;
    hideCtxMenu();
    if (target) showDeleteConfirm(target.type, target.id);
  });

  function showProjectMenu(event, projectId) {
    event.preventDefault();
    event.stopPropagation();
    const existing = document.getElementById('projectPopoverMenu');
    if (existing) existing.remove();
    const menu = document.createElement('div');
    menu.id = 'projectPopoverMenu';
    menu.className = 'ctx-menu open';
    menu.innerHTML = [
      '<button class="ctx-menu-item" data-action="add-item" type="button">Add item</button>',
      '<button class="ctx-menu-item destructive" data-action="delete-project" type="button">Delete project</button>'
    ].join('');
    document.body.appendChild(menu);
    const rect = event.currentTarget.getBoundingClientRect();
    menu.style.left = rect.right + 'px';
    menu.style.top = rect.bottom + 'px';
    requestAnimationFrame(() => {
      const mr = menu.getBoundingClientRect();
      if (mr.bottom > window.innerHeight) menu.style.top = (rect.top - mr.height) + 'px';
      if (mr.right > window.innerWidth) menu.style.left = (rect.left - mr.width) + 'px';
    });
    function cleanup() {
      menu.remove();
      document.removeEventListener('click', onOutside);
      document.removeEventListener('keydown', onEscape);
    }
    function onOutside(e) { if (!menu.contains(e.target)) cleanup(); }
    function onEscape(e) { if (e.key === 'Escape') cleanup(); }
    document.addEventListener('click', onOutside);
    document.addEventListener('keydown', onEscape);
    menu.querySelector('[data-action="add-item"]').addEventListener('click', () => {
      cleanup();
      openAddKindForm(projectId);
    });
    menu.querySelector('[data-action="delete-project"]').addEventListener('click', () => {
      cleanup();
      showDeleteConfirm('project', projectId);
    });
  }

  function renderSidebar() {
    // Skip re-render while inline rename is active to prevent pollers from destroying the input
    if (els.objectiveList.querySelector('.obj-name-input')) return;
    const projects = sortedProjects(state.projects);
    if (!projects.length) {
      els.objectiveList.innerHTML = [
        '<div class="sidebar-empty-state">',
        '<div class="sidebar-empty-title">No projects yet</div>',
        '<div class="sidebar-empty-copy">Add your first project, then choose New or Open.</div>',
        '<button class="sidebar-empty-button" id="sidebarEmptyAddProjectButton" type="button">+ Add project</button>',
        '</div>'
      ].join('');
      const button = document.getElementById('sidebarEmptyAddProjectButton');
      if (button) button.addEventListener('click', openProjectForm);
      return;
    }
    ensureProjectExpansion();
    const mixedCards = (projectId) => {
      const items = [];
      projectWorkspaces(projectId).forEach((workspace) => {
        items.push({ kind: 'workspace', item: workspace, sortAt: parseIso(workspace.updatedAt || workspace.createdAt) || 0 });
      });
      projectObjectives(projectId).forEach((objective) => {
        items.push({ kind: 'objective', item: objective, sortAt: parseIso(objective.updatedAt || objective.createdAt) || 0 });
      });
      items.sort((a, b) => b.sortAt - a.sortAt);
      return items.map(({ kind, item }) => {
        if (kind === 'workspace') {
          const active = item.id === state.activeWorkspaceId ? ' active' : '';
          return [
            '<div class="obj-item nested workspace' + active + '" data-workspace-id="' + esc(item.id) + '">',
            '<div class="obj-dot ' + (item.status === 'starting' ? 'od-starting' : item.status === 'error' ? 'od-failed' : item.sessionActive ? 'od-running' : 'od-queued') + '"></div>',
            '<div class="obj-info">',
            '<div class="obj-name">' + esc(item.name || 'Untitled item') + '</div>',
            '<div class="obj-progress"><span>' + esc(compactPath(item.rootPath || '')) + '</span></div>',
            '</div>',
            '</div>'
          ].join('');
        }
        const meta = statusMeta(item.status);
        const progress = objectiveProgress(item);
        const active = item.id === state.activeObjectiveId ? ' active' : '';
        const doneClass = String(item.status).toLowerCase() === 'completed' ? ' done' : '';
        let progressText = progress.total ? (progress.done + ' of ' + progress.total + ' done') : meta.label.toLowerCase();
        if (String(item.status).toLowerCase() === 'completed') {
          progressText = 'done · ' + relativeTime(item.updatedAt || item.createdAt);
        } else if (String(item.status).toLowerCase() === 'failed') {
          progressText = 'failed · ' + relativeTime(item.updatedAt || item.createdAt);
        }
        return [
          '<div class="obj-item nested' + active + doneClass + '" data-objective-id="' + esc(item.id) + '">',
          '<div class="obj-dot ' + meta.dot + '"></div>',
          '<div class="obj-info">',
          '<div class="obj-name">' + esc(item.goal || 'Untitled item') + '</div>',
          '<div class="obj-progress">',
          '<div class="obj-prog-bar"><div class="obj-prog-fill ' + meta.fill + '" style="width:' + progress.percent + '%"></div></div>',
          '<span>' + esc(progressText) + '</span>',
          '</div>',
          '</div>',
          '</div>'
        ].join('');
      }).join('');
    };
    els.objectiveList.innerHTML = projects.map((project) => {
      const itemCount = projectObjectives(project.id).length + projectWorkspaces(project.id).length;
      const expanded = state.projectExpansion[project.id] !== false;
      const pathHint = compactPath(project.rootPath || '');
      return [
        '<div class="project-group" data-project-id="' + esc(project.id) + '">',
        '<div class="project-row' + (expanded ? ' expanded' : '') + '">',
        '<button class="project-toggle" type="button" data-project-toggle="' + esc(project.id) + '" aria-label="Toggle ' + esc(project.name || 'project') + '" aria-expanded="' + (expanded ? 'true' : 'false') + '">▾</button>',
        '<div class="project-info" data-project-toggle="' + esc(project.id) + '">',
        '<div class="project-name-row"><div class="project-name">' + esc(project.name || 'Untitled project') + '</div><div class="project-count">' + itemCount + '</div></div>',
        pathHint ? '<div class="project-path">' + esc(pathHint) + '</div>' : '',
        '</div>',
        '<button class="project-add-objective" type="button" data-project-menu="' + esc(project.id) + '" aria-label="Project options for ' + esc(project.name || 'project') + '">\u22EF</button>',
        '</div>',
        expanded ? '<div class="project-objectives">' + (itemCount ? mixedCards(project.id) : '<div class="project-empty">No items yet</div>') + '</div>' : '',
        '</div>'
      ].join('');
    }).join('');
    els.objectiveList.querySelectorAll('[data-project-toggle]').forEach((node) => {
      node.addEventListener('click', () => {
        const projectId = node.getAttribute('data-project-toggle');
        if (!projectId) return;
        state.projectExpansion = Object.assign({}, state.projectExpansion, { [projectId]: !(state.projectExpansion[projectId] !== false) });
        renderSidebar();
      });
    });
    els.objectiveList.querySelectorAll('[data-project-menu]').forEach((node) => {
      node.addEventListener('click', (event) => {
        event.stopPropagation();
        const projectId = node.getAttribute('data-project-menu');
        showProjectMenu(event, projectId);
      });
    });
    els.objectiveList.querySelectorAll('[data-objective-id]').forEach((node) => {
      node.addEventListener('click', () => {
        if (node.dataset.renaming) return;
        const id = node.getAttribute('data-objective-id');
        if (!id) return;
        if (id !== state.activeObjectiveId) {
          state.activeObjectiveId = id;
          loadActiveObjective(true);
        }
        closeSidebar();
      });
    });
    els.objectiveList.querySelectorAll('[data-objective-id]').forEach((node) => {
      node.addEventListener('contextmenu', (e) => {
        showCtxMenu(e, 'objective', node.getAttribute('data-objective-id'));
      });
    });
    els.objectiveList.querySelectorAll('[data-workspace-id]').forEach((node) => {
      node.addEventListener('click', () => {
        if (node.dataset.renaming) return;
        const id = node.getAttribute('data-workspace-id');
        if (!id) return;
        if (id !== state.activeWorkspaceId) {
          state.activeWorkspaceId = id;
          state.activeTargetType = 'workspace';
          loadActiveWorkspace(true);
        }
        closeSidebar();
      });
    });
    els.objectiveList.querySelectorAll('[data-workspace-id]').forEach((node) => {
      node.addEventListener('contextmenu', (e) => {
        showCtxMenu(e, 'workspace', node.getAttribute('data-workspace-id'));
      });
    });
  }

  function renderContext() {
    if (state.activeWorkspace) {
      const workspace = state.activeWorkspace;
      const meta = workspaceMeta(workspace);
      const gitPath = activeGitPath();
      const filesRoot = activeFilesRoot();
      const sessionActive = !!workspace.sessionActive;
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
            '<div class="ctx-mobile-row primary"><div class="ctx-title">' + esc(workspace.name || 'Untitled item') + '</div></div>',
            '<div class="ctx-mobile-row secondary">',
            '<div class="ctx-dot ' + meta.dot + '" title="' + esc(meta.label) + '" aria-label="' + esc(meta.label) + '"></div>',
            '<div class="ctx-meta">' + esc(compactPath(workspace.rootPath || '')) + '</div>',
            '<div class="ctx-session' + (sessionActive ? ' active' : '') + '"><div class="ctx-session-dot"></div><span>' + esc(sessionActive ? 'Session active' : 'Session idle') + '</span></div>',
            '<button class="ctx-git-button' + (state.gitPanelOpen && state.rightPanelMode === 'status' ? ' open' : '') + '" id="statusSummaryButton" type="button">Status</button>',
            gitPath ? '<button class="ctx-git-button' + (state.gitPanelOpen && state.rightPanelMode === 'git' ? ' open' : '') + '" id="gitPanelToggleButton" type="button">' + esc(gitButtonLabel()) + '</button>' : '',
            filesRoot ? '<button class="ctx-git-button" id="filesPanelToggleButton" type="button">📁 Files</button>' : '',
            '</div>',
            '</div>',
            '<div class="ctx-actions">',
            '<button class="' + consoleLogButtonClass + '" id="consoleLogToggleButton" type="button" title="Toggle console logs" aria-label="Toggle console logs">&gt;_' + consoleLogIndicator + '</button>',
            '<button class="' + logButtonClass + '" id="buildLogToggleButton" type="button" title="Toggle build log" aria-label="Toggle build log">⎔' + logIndicator + '</button>',
            '<button class="ctx-icon-button danger" id="clearItemButton" type="button" title="Clear item" aria-label="Clear item">🗑</button>',
            '</div>'
          ].join('')
        : [
            '<div class="ctx-dot ' + meta.dot + '"></div>',
            '<div class="ctx-main">',
            '<div class="ctx-title">' + esc(workspace.name || 'Untitled item') + '</div>',
            '<div class="ctx-secondary"><div class="ctx-meta">' + esc(compactPath(workspace.rootPath || '')) + '</div><div class="ctx-session' + (sessionActive ? ' active' : '') + '"><div class="ctx-session-dot"></div><span>' + esc(sessionActive ? 'Session active' : 'Session idle') + '</span></div></div>',
            '</div>',
            '<div class="ctx-actions">',
            '<button class="ctx-git-button' + (state.gitPanelOpen && state.rightPanelMode === 'status' ? ' open' : '') + '" id="statusSummaryButton" type="button">Status</button>',
            gitPath ? '<button class="ctx-git-button' + (state.gitPanelOpen && state.rightPanelMode === 'git' ? ' open' : '') + '" id="gitPanelToggleButton" type="button">' + esc(gitButtonLabel()) + '</button>' : '',
            filesRoot ? '<button class="ctx-git-button" id="filesPanelToggleButton" type="button">📁 Files</button>' : '',
            '<button class="' + consoleLogButtonClass + '" id="consoleLogToggleButton" type="button" title="Toggle console logs" aria-label="Toggle console logs">&gt;_' + consoleLogIndicator + '</button>',
            '<button class="' + logButtonClass + '" id="buildLogToggleButton" type="button" title="Toggle build log" aria-label="Toggle build log">⎔' + logIndicator + '</button>',
            '<button class="ctx-icon-button danger" id="clearItemButton" type="button" title="Clear item" aria-label="Clear item">🗑</button>',
            '<div class="ctx-badge ' + meta.badge + '">' + esc(meta.label) + '</div>',
            '</div>'
          ].join('');
      const menuButton = document.getElementById('mobileMenuBtn');
      if (menuButton) menuButton.addEventListener('click', toggleSidebar);
      const statusSummaryButton = document.getElementById('statusSummaryButton');
      if (statusSummaryButton) statusSummaryButton.addEventListener('click', toggleStatusPanel);
      const gitButton = document.getElementById('gitPanelToggleButton');
      if (gitButton) gitButton.addEventListener('click', toggleGitPanel);
      const filesButton = document.getElementById('filesPanelToggleButton');
      if (filesButton) filesButton.addEventListener('click', openActiveRootInVSCode);
      const clearButton = document.getElementById('clearItemButton');
      if (clearButton) clearButton.addEventListener('click', deleteActiveItem);
      const buildLogButton = document.getElementById('buildLogToggleButton');
      if (buildLogButton) buildLogButton.addEventListener('click', toggleBuildLog);
      const consoleLogButton = document.getElementById('consoleLogToggleButton');
      if (consoleLogButton) consoleLogButton.addEventListener('click', toggleConsoleLog);
      return;
    }
    const objective = state.activeObjective || sortedObjectives(state.objectives).find((item) => item.id === state.activeObjectiveId);
    if (!objective) {
      els.contextStrip.innerHTML = state.isMobile
        ? [
            '<button class="mobile-menu-btn" id="mobileMenuBtn" type="button" aria-label="Open sidebar" aria-expanded="false">☰</button>',
            '<div class="ctx-main">',
            '<div class="ctx-mobile-row primary"><div class="ctx-title">Nothing selected</div></div>',
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
            '<div class="ctx-title">Nothing selected</div>',
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
    const filesRoot = activeFilesRoot();
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
          '<div class="ctx-title">' + esc(objective.goal || 'Untitled item') + '</div>',
          '</div>',
          '<div class="ctx-mobile-row secondary">',
          '<div class="ctx-dot ' + meta.dot + '" title="' + esc(meta.label) + '" aria-label="' + esc(meta.label) + '"></div>',
          '<div class="ctx-meta">' + esc(taskCount) + '</div>',
          '<div class="ctx-meta">' + esc(elapsed) + '</div>',
          branchName ? '<div class="ctx-meta mono">' + esc(branchName) + '</div>' : '',
          '<div class="ctx-session' + (sessionActive ? ' active' : '') + '"><div class="ctx-session-dot"></div><span>' + esc(sessionActive ? 'Session active' : 'Session idle') + '</span></div>',
          '<button class="ctx-git-button' + (state.gitPanelOpen && state.rightPanelMode === 'status' ? ' open' : '') + '" id="statusSummaryButton" type="button">Status</button>',
          gitPath ? '<button class="ctx-git-button' + (state.gitPanelOpen && state.rightPanelMode === 'git' ? ' open' : '') + '" id="gitPanelToggleButton" type="button">' + esc(gitButtonLabel()) + '</button>' : '',
          filesRoot ? '<button class="ctx-git-button" id="filesPanelToggleButton" type="button">📁 Files</button>' : '',
          '</div>',
          '</div>',
          '<div class="ctx-actions">',
          '<button class="' + consoleLogButtonClass + '" id="consoleLogToggleButton" type="button" title="Toggle console logs" aria-label="Toggle console logs">&gt;_' + consoleLogIndicator + '</button>',
          '<button class="' + logButtonClass + '" id="buildLogToggleButton" type="button" title="Toggle build log" aria-label="Toggle build log">⎔' + logIndicator + '</button>',
          '<button class="ctx-icon-button danger" id="clearItemButton" type="button" title="Clear item" aria-label="Clear item">🗑</button>',
          '</div>'
        ].join('')
      : [
          '<div class="ctx-dot ' + meta.dot + '"></div>',
          '<div class="ctx-main">',
          '<div class="ctx-title">' + esc(objective.goal || 'Untitled item') + '</div>',
          '<div class="ctx-secondary">',
          '<div class="ctx-meta">' + esc(elapsed + ' · ' + taskCount) + '</div>',
          branchName ? '<div class="ctx-meta mono">' + esc(branchName) + '</div>' : '',
          '<div class="ctx-session' + (sessionActive ? ' active' : '') + '"><div class="ctx-session-dot"></div><span>' + esc(sessionActive ? 'Session active' : 'Session idle') + '</span></div>',
          '</div>',
          '</div>',
          '<div class="ctx-actions">',
          '<button class="ctx-git-button' + (state.gitPanelOpen && state.rightPanelMode === 'status' ? ' open' : '') + '" id="statusSummaryButton" type="button">Status</button>',
          gitPath ? '<button class="ctx-git-button' + (state.gitPanelOpen && state.rightPanelMode === 'git' ? ' open' : '') + '" id="gitPanelToggleButton" type="button">' + esc(gitButtonLabel()) + '</button>' : '',
          filesRoot ? '<button class="ctx-git-button" id="filesPanelToggleButton" type="button">📁 Files</button>' : '',
          '<button class="' + consoleLogButtonClass + '" id="consoleLogToggleButton" type="button" title="Toggle console logs" aria-label="Toggle console logs">&gt;_' + consoleLogIndicator + '</button>',
          '<button class="' + logButtonClass + '" id="buildLogToggleButton" type="button" title="Toggle build log" aria-label="Toggle build log">⎔' + logIndicator + '</button>',
          '<button class="ctx-icon-button danger" id="clearItemButton" type="button" title="Clear item" aria-label="Clear item">🗑</button>',
          '<div class="ctx-badge ' + meta.badge + '">' + esc(meta.label) + '</div>',
          '</div>'
        ].join('');
    const statusSummaryButton = document.getElementById('statusSummaryButton');
    if (statusSummaryButton) {
      statusSummaryButton.addEventListener('click', () => {
        toggleStatusPanel();
      });
    }
    const gitButton = document.getElementById('gitPanelToggleButton');
    if (gitButton) {
      gitButton.addEventListener('click', toggleGitPanel);
    }
    const filesButton = document.getElementById('filesPanelToggleButton');
    if (filesButton) {
      filesButton.addEventListener('click', openActiveRootInVSCode);
    }
    const menuButton = document.getElementById('mobileMenuBtn');
    if (menuButton) {
      menuButton.addEventListener('click', toggleSidebar);
    }
    const clearButton = document.getElementById('clearItemButton');
    if (clearButton) {
      clearButton.addEventListener('click', deleteActiveItem);
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

  function renderContractReviewCard(message) {
    const metadata = message.metadata || {};
    const contracts = Array.isArray(metadata.contracts) ? metadata.contracts : [];
    return [
      '<div class="card-plan-review">',
      '<div class="plan-review-head">',
      '<div class="plan-review-title">Contract Review</div>',
      '<div class="plan-review-count">' + esc(contracts.length + ' contract' + (contracts.length === 1 ? '' : 's')) + '</div>',
      '</div>',
      '<div class="plan-review-body">',
      contracts.map(function(contract, index) { return [
        '<div class="plan-review-task">',
        '<div class="plan-review-task-head">',
        '<div class="plan-review-task-number">Task ' + esc(String(index + 1)) + '</div>',
        '<div class="plan-review-task-title">' + esc(contract.title || contract.taskId || ('Task ' + (index + 1))) + '</div>',
        '</div>',
        '<div class="plan-review-row">',
        '<div class="plan-review-label">Acceptance Criteria</div>',
        '<div class="plan-review-checkpoints">' + (contract.acceptanceCriteria
          ? '<div class="plan-review-checkpoint">' + esc(contract.acceptanceCriteria) + '</div>'
          : '<div class="plan-review-checkpoint">None listed.</div>') + '</div>',
        '</div>',
        '<div class="plan-review-row">',
        '<div class="plan-review-label">Build Verification</div>',
        '<div class="plan-review-checkpoints">' + (contract.buildVerification
          ? '<div class="plan-review-checkpoint">' + esc(contract.buildVerification) + '</div>'
          : '<div class="plan-review-checkpoint">None listed.</div>') + '</div>',
        '</div>',
        '<div class="plan-review-row">',
        '<div class="plan-review-label">Functional Test Hints</div>',
        '<div class="plan-review-checkpoints">' + (contract.functionalTestHints
          ? '<div class="plan-review-checkpoint">' + esc(contract.functionalTestHints) + '</div>'
          : '<div class="plan-review-checkpoint">None listed.</div>') + '</div>',
        '</div>',
        '<div class="plan-review-row">',
        '<div class="plan-review-label">Pass/Fail Threshold</div>',
        '<div class="plan-review-checkpoints">' + (contract.passFailThreshold
          ? '<div class="plan-review-checkpoint">' + esc(contract.passFailThreshold) + '</div>'
          : '<div class="plan-review-checkpoint">None listed.</div>') + '</div>',
        '</div>',
        '</div>'
      ].join(''); }).join(''),
      '<div class="plan-review-actions">',
      '<button class="plan-review-approve" type="button" data-contract-action="approve">Approve Contracts</button>',
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
      '<div class="cc-title">Item complete!</div>',
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

  function renderStatusSummaryCard() {
    const loading = state.statusSummaryLoading;
    const error = state.statusSummaryError;
    const summary = state.statusSummary;
    if (loading && !summary) {
      return '<div class="card-status-summary"><div class="status-summary-head"><div><div class="status-summary-title">Status</div><div class="status-summary-meta">Refreshing…</div></div></div><div class="build-log-state"><div class="build-log-spinner"></div><div>Getting the latest status. Give me a min.</div></div></div>';
    }
    if (error && !summary) {
      return '<div class="card-status-summary"><div class="status-summary-head"><div><div class="status-summary-title">Status</div><div class="status-summary-meta">Could not refresh</div></div><button class="status-summary-refresh" type="button" data-status-summary-refresh="true">Retry</button></div><div class="status-summary-error">' + esc(error) + '</div></div>';
    }
    if (!summary) return '';
    const stage = summary.stage || {};
    const signals = summary.signals || {};
    const tasks = signals.tasks || {};
    const approvals = signals.approvals || {};
    const git = signals.git || {};
    const blockers = Array.isArray(summary.blockers) ? summary.blockers : [];
    const summarySource = summary.summarySource || {};
    const refreshedLabel = formatDateTime(summary.generatedAt) || 'just now';
    const refreshedAgo = relativeTime(summary.generatedAt) || 'just now';
    const sourceLabel = summarySource.display ? ' · ' + summarySource.display : '';
    const taskStats = [];
    if (tasks.total) taskStats.push(tasks.completed + '/' + tasks.total + ' tasks done');
    if (tasks.active) taskStats.push(tasks.active + ' active');
    if (git.changedFiles) taskStats.push(git.changedFiles + ' changed files');
    if (approvals.waiting) taskStats.push(approvals.waiting + ' approval' + (approvals.waiting === 1 ? '' : 's') + ' waiting');
    return [
      '<div class="card-status-summary">',
      '<div class="status-summary-head">',
      '<div>',
      '<div class="status-summary-title">Status</div>',
      '<div class="status-summary-meta" title="' + esc(summary.generatedAt || '') + '">Refreshed ' + esc(refreshedAgo) + ' · ' + esc(refreshedLabel) + esc(sourceLabel) + '</div>',
      '</div>',
      '<div class="status-summary-head-actions">',
      loading ? '<span class="status-summary-inline">Refreshing…</span>' : '',
      '<button class="status-summary-refresh" type="button" data-status-summary-refresh="true">Refresh</button>',
      '</div>',
      '</div>',
      '<div class="status-summary-stage-row"><span class="status-summary-stage">' + esc((stage.label || 'Unknown stage')) + '</span>' + (taskStats.length ? '<span class="status-summary-stats">' + esc(taskStats.join(' · ')) + '</span>' : '') + '</div>',
      '<div class="status-summary-tldr">' + esc(summary.tldr || '') + '</div>',
      '<div class="status-summary-grid">',
      '<div class="status-summary-block"><div class="status-summary-label">Just happened</div><div class="status-summary-copy">' + esc(summary.justHappened || 'No recent update yet.') + '</div></div>',
      '<div class="status-summary-block"><div class="status-summary-label">Now</div><div class="status-summary-copy">' + esc(summary.now || 'No active work right now.') + '</div></div>',
      '<div class="status-summary-block"><div class="status-summary-label">Next</div><div class="status-summary-copy">' + esc(summary.next || 'No next step available yet.') + '</div></div>',
      blockers.length ? '<div class="status-summary-block blockers"><div class="status-summary-label">Blockers</div><div class="status-summary-list">' + blockers.map((item) => '<div class="status-summary-list-item">' + esc(item) + '</div>').join('') + '</div></div>' : '',
      '</div>',
      '</div>'
    ].join('');
  }

  function renderApprovalCard(message) {
    const metadata = message.metadata || {};
    const taskId = metadata.task_id || '';
    const severityLevel = metadata.severity_level;
    const toolName = metadata.tool_name || '';
    const toolPreview = metadata.tool_input_preview || '';
    const severityColors = { 4: '#e6a700', 5: '#d32f2f' };
    const severityLabels = { 1: 'Safe', 2: 'Write', 3: 'External', 4: 'Judgment', 5: 'Dangerous' };
    const severityBadge = severityLevel
      ? '<span class="severity-badge" style="background:' + (severityColors[severityLevel] || '#888') + ';color:#fff;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;margin-left:8px;">Level ' + severityLevel + ': ' + esc(severityLabels[severityLevel] || '') + '</span>'
      : '';
    const toolInfo = toolName
      ? '<div class="approval-tool-info" style="font-size:12px;color:#888;margin-top:4px;"><code>' + esc(toolName) + '</code>' + (toolPreview ? ' — <span style="font-family:monospace;font-size:11px;">' + esc(toolPreview.substring(0, 120)) + (toolPreview.length > 120 ? '...' : '') + '</span>' : '') + '</div>'
      : '';
    return [
      '<div class="card-approval">',
      '<div class="approval-title">Approval needed' + severityBadge + '</div>',
      '<div class="approval-body">' + esc(message.content || '') + '</div>',
      toolInfo,
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
    if (item.kind === 'status-summary') {
      return [
        '<div class="msg">',
        '<div class="msg-av av-c">⌘</div>',
        '<div class="msg-body">',
        '<div class="msg-header"><span class="msg-name mn-sys">cmux</span><span class="msg-time">status</span></div>',
        renderStatusSummaryCard(),
        '</div>',
        '</div>'
      ].join('');
    }
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
    if (item.kind === 'contract_review') {
      const time = relativeTime(item.message.timestamp);
      return [
        '<div class="msg' + groupClass + '">',
        grouped ? '' : '<div class="msg-av av-c">⌘</div>',
        '<div class="msg-body">',
        grouped ? '' : '<div class="msg-header"><span class="msg-name mn-sys">cmux</span><span class="msg-time">' + esc(time) + '</span></div>',
        renderContractReviewCard(item.message),
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
    const hasActiveTarget = !!state.activeObjectiveId || !!state.activeWorkspaceId;
    const copy = !state.projects.length
      ? 'Add a project, then choose New or Open.'
      : hasActiveTarget
        ? 'Ready when you are.'
        : 'Choose an item from the sidebar, or start with New or Open.';
    return [
      '<div class="empty-state">',
      '<div class="empty-card">',
      '<div class="empty-kicker">Orchestrator</div>',
      '<div class="empty-title">Open existing work or start something new in the same place.</div>',
      '<div class="empty-copy">' + copy + '</div>',
      '</div>',
      '</div>'
    ].join('');
  }

  function workspaceTurnSubtitle(turn) {
    if (!turn) return 'Thinking through the workspace...';
    const summary = String(turn.progressSummary || '').trim();
    if (summary) return summary;
    const stateName = String(turn.progressState || turn.status || '').toLowerCase();
    if (stateName === 'waiting') return 'Waiting for the workspace session to continue.';
    if (stateName === 'timed_out') return 'Still working. This one is taking longer than usual.';
    return 'Thinking through the workspace...';
  }

  function renderWorkspaceTurnBubble() {
    const turn = state.activeWorkspaceTurn;
    if (!turn) return '';
    const status = String(turn.status || '').toLowerCase();
    const title = status === 'timed_out' ? 'Still Working' : 'Working On It';
    const elapsed = durationFrom(turn.createdAt) || '0s';
    const subtitle = workspaceTurnSubtitle(turn);
    const shimmerClass = subtitle ? ' turn-live-subtitle shimmer' : ' turn-live-subtitle';
    return [
      '<div class="msg">',
      '<div class="msg-av av-c">⌘</div>',
      '<div class="msg-body">',
      '<div class="msg-header"><span class="msg-name mn-sys">cmux</span><span class="msg-time">live</span></div>',
      '<div class="msg-bubble turn-live-bubble">',
      '<div class="turn-live-head">',
      '<div class="turn-live-title">' + esc(title) + '</div>',
      '<div class="turn-live-meta">',
      '<button class="turn-live-peek" type="button" data-workspace-peek="true">Terminal Peek</button>',
      '<div class="turn-live-elapsed">' + esc(elapsed + ' elapsed') + '</div>',
      '</div>',
      '</div>',
      '<div class="' + shimmerClass.trim() + '">' + esc(subtitle) + '</div>',
      '<div class="turn-live-dots"><span></span><span></span><span></span></div>',
      '</div>',
      '</div>',
      '</div>'
    ].join('');
  }

  function renderMessages() {
    const beforeBottom = isNearBottom();
    const oldScrollTop = els.messagesPane.scrollTop;
    const items = normalizeMessages(state.messages);
    let html = '';
    const hasActiveTarget = !!state.activeObjectiveId || !!state.activeWorkspaceId;
    if (!state.projects.length || !hasActiveTarget) {
      els.messageColumn.innerHTML = renderEmptyState();
      return;
    }
    if (!items.length) {
      let waitingCopy = 'Ready when you are.';
      var isStarting = state.activeWorkspace && state.activeWorkspace.status === 'starting';
      var isError = state.activeWorkspace && state.activeWorkspace.status === 'error';
      if (state.activeWorkspaceId && isStarting) {
        waitingCopy = 'Starting workspace\u2026';
      } else if (state.activeWorkspaceId && isError) {
        waitingCopy = 'Workspace failed to start. Try closing and re-opening it.';
      } else if (state.activeWorkspaceId) {
        waitingCopy = 'Ready. Ask about the codebase or make a change.';
      } else if (state.activeObjective) {
        const status = String(state.activeObjective.status || '').toLowerCase();
        waitingCopy = ['planning', 'plan_review', 'negotiating_contracts', 'contract_review', 'executing', 'reviewing', 'rework'].includes(status)
          ? 'Starting the new item...'
          : 'Ready when you are.';
      }
      var startingSpinner = isStarting
        ? '<div class="workspace-starting-spinner"><span class="dot"></span><span class="dot"></span><span class="dot"></span></div>'
        : '';
      html = '<div class="thread-div">now</div><div class="msg"><div class="msg-av av-c">⌘</div><div class="msg-body"><div class="msg-header"><span class="msg-name mn-sys">cmux</span><span class="msg-time">just now</span></div><div class="msg-bubble">' + esc(waitingCopy) + startingSpinner + '</div></div></div>';
    } else {
      html = '<div class="thread-div">now</div>' + items.map((item, index) => renderMessageItem(item, shouldGroupSystemItem(items, index))).join('');
    }
    if (state.activeWorkspaceId && state.activeWorkspaceTurn) {
      html += renderWorkspaceTurnBubble();
    } else if (state.typing) {
      html += '<div class="msg"><div class="msg-av av-c">⌘</div><div class="msg-body"><div class="msg-bubble typing-indicator"><span class="dot"></span><span class="dot"></span><span class="dot"></span></div></div></div>';
    }
    els.messageColumn.innerHTML = html;
    els.messageColumn.querySelectorAll('[data-worker-task-id]').forEach((node) => {
      node.addEventListener('click', (event) => {
        event.stopPropagation();
        openWorkerOutput(node.getAttribute('data-worker-task-id'));
      });
    });
    els.messageColumn.querySelectorAll('[data-workspace-peek]').forEach((node) => {
      node.addEventListener('click', (event) => {
        event.stopPropagation();
        openWorkspaceOutput();
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
    els.messageColumn.querySelectorAll('[data-contract-action="approve"]').forEach((node) => {
      node.addEventListener('click', async () => {
        if (!state.activeObjectiveId) return;
        try {
          await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/approve-contracts', {
            method: 'POST',
            body: JSON.stringify({})
          });
          state.lastMessageTimestamp = null;
          await pollMessages(true);
          await pollActiveObjective(true);
        } catch (error) {
          showToast(error.message || 'Could not approve contracts');
        }
      });
    });
    els.messageColumn.querySelectorAll('[data-copy-path]').forEach((node) => {
      node.addEventListener('click', () => {
        copyText(node.getAttribute('data-copy-path'), 'Path');
      });
    });
    els.messageColumn.querySelectorAll('[data-status-summary-refresh]').forEach((node) => {
      node.addEventListener('click', () => {
        fetchStatusSummary(true);
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

  async function pollActiveWorkspaceTurn(forceRender) {
    if (!state.activeWorkspaceId) {
      state.activeWorkspaceTurn = null;
      if (forceRender) renderMessages();
      return;
    }
    const turn = await api('/api/workspaces/' + encodeURIComponent(state.activeWorkspaceId) + '/active-turn');
    state.activeWorkspaceTurn = turn && typeof turn === 'object' ? turn : null;
    if (state.activeWorkspaceTurn) state.typing = false;
    if (forceRender) renderMessages();
  }

  function renderInputState() {
    if (state.activeWorkspace && state.activeWorkspaceId) {
      var wsStatus = state.activeWorkspace.status;
      if (wsStatus === 'starting') {
        els.chatInput.disabled = true;
        els.inputHint.textContent = 'Workspace is starting\u2026';
        els.chatInput.placeholder = 'Waiting for workspace to start...';
        els.sendButton.disabled = true;
      } else if (wsStatus === 'error') {
        els.chatInput.disabled = true;
        els.inputHint.textContent = 'Workspace failed to start.';
        els.chatInput.placeholder = '';
        els.sendButton.disabled = true;
      } else {
        els.chatInput.disabled = false;
        els.inputHint.textContent = 'Chat about this item.';
        els.chatInput.placeholder = 'Ask about files, code, git status, or make a change...';
        els.sendButton.disabled = state.pendingCreate || state.pendingSend;
      }
      return;
    }
    const objective = state.activeObjective;
    const status = String(objective && objective.status || '').toLowerCase();
    const hasObjective = !!state.activeObjectiveId && !!objective;
    if (!hasObjective) {
      els.inputHint.textContent = state.projects.length
        ? 'Choose New or Open, or select an item from the sidebar.'
        : 'Add a project first, then choose New or Open.';
      els.chatInput.placeholder = 'Nothing selected...';
      els.chatInput.disabled = true;
      els.sendButton.disabled = true;
      return;
    }
    els.chatInput.disabled = false;
    if (status === 'plan_review') {
      els.inputHint.textContent = 'Type feedback in chat or approve the plan above.';
      els.chatInput.placeholder = 'Type plan feedback or approve above...';
    } else if (status === 'contract_review') {
      els.inputHint.textContent = 'Type feedback in chat or approve the contracts above.';
      els.chatInput.placeholder = 'Type contract feedback or approve above...';
    } else if (status === 'completed') {
      els.inputHint.textContent = 'Item complete. Ask questions about the work done.';
      els.chatInput.placeholder = 'Ask about the completed work...';
    } else if (status === 'failed') {
      els.inputHint.textContent = 'Item failed. Type "retry" to restart or ask what happened.';
      els.chatInput.placeholder = 'Type retry or ask what went wrong...';
    } else {
      els.inputHint.textContent = 'Chat about this item.';
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
    const previousWorkspaceId = state.activeWorkspaceId;
    const [objectivesData, projectsData, workspacesData] = await Promise.all([
      api('/api/objectives'),
      api('/api/projects'),
      api('/api/workspaces')
    ]);
    state.objectives = Array.isArray(objectivesData) ? objectivesData : [];
    state.projects = Array.isArray(projectsData) ? projectsData : [];
    state.workspaces = Array.isArray(workspacesData) ? workspacesData : [];
    ensureProjectExpansion();
    if (!findProject(state.draftProjectId)) {
      setDraftProject(selectedProjectId());
    }
    if (!state.draftProjectId && state.projects.length) {
      setDraftProject(selectedProjectId() || (sortedProjects(state.projects)[0] || {}).id || '');
    }
    if (!state.draftProjectDir || !state.draftBaseBranch) {
      setDraftProject(state.draftProjectId || selectedProjectId(), {
        updateBaseBranch: !state.draftBaseBranch
      });
    }
    if (!state.draftWorkflowMode) {
      state.draftWorkflowMode = 'structured';
    }
    ensureSelection();
    if (state.activeObjectiveId && state.activeObjectiveId !== previousActiveId) {
      state.actionButtonState = {};
      await loadActiveObjective(false);
    }
    if (state.activeWorkspaceId && state.activeWorkspaceId !== previousWorkspaceId) {
      await loadActiveWorkspace(false);
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
      resetStatusSummaryState();
      renderBuildLog();
      renderConsoleLog();
      renderFabRail();
      renderFabModal();
      return;
    }
    const previousPath = activeGitPath();
    const objective = await api('/api/objectives/' + encodeURIComponent(state.activeObjectiveId));
    state.activeObjective = objective;
    if (objective && objective.projectId) {
      state.projectExpansion = Object.assign({}, state.projectExpansion, { [objective.projectId]: true });
    }
    await loadActionButtons();
    const nextPath = activeGitPath();
    if (previousPath !== nextPath) {
      state.gitStatus = null;
      if (!nextPath) {
        state.gitPanelOpen = false;
        hideGitContextMenu();
        closeDiffOverlay();
      } else if (state.gitPanelOpen && state.rightPanelMode === 'git') {
        await fetchGitStatus();
      } else if (state.gitPanelOpen && state.rightPanelMode === 'status') {
        await fetchStatusSummary(true);
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
    if (!state.activeObjectiveId && !state.activeWorkspaceId) {
      state.messages = [];
      state.lastMessageTimestamp = null;
      if (forceRender) renderMessages();
      return;
    }
    const query = state.lastMessageTimestamp ? ('?after=' + encodeURIComponent(state.lastMessageTimestamp)) : '';
    const basePath = state.activeWorkspaceId
      ? ('/api/workspaces/' + encodeURIComponent(state.activeWorkspaceId) + '/messages')
      : ('/api/objectives/' + encodeURIComponent(state.activeObjectiveId) + '/messages');
    const incoming = await api(basePath + query);
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
    state.activeTargetType = 'objective';
    state.activeWorkspaceId = null;
    state.activeWorkspace = null;
    state.activeWorkspaceTurn = null;
    state.messages = [];
    state.lastMessageTimestamp = null;
    resetBuildLogState();
    resetConsoleLogState();
    resetStatusSummaryState();
    await Promise.all([
      pollActiveObjective(false),
      pollMessages(false)
    ]);
    if (state.gitPanelOpen && state.rightPanelMode === 'status') {
      await fetchStatusSummary(false);
    }
    if (forceAll) render();
  }

  async function createObjective(options) {
    const payload = {
      goal: options.goal,
      projectId: options.projectId || undefined,
      baseBranch: options.baseBranch || 'main',
      branchName: options.branchName || '',
      workflowMode: options.workflowMode || 'structured'
    };
    if (options.projectDir) {
      payload.projectDir = options.projectDir;
    }
    state.pendingCreate = true;
    renderInputState();
    updateSidebarFormFromState();
    try {
      const objective = await api('/api/objectives', {
        method: 'POST',
        body: JSON.stringify(payload)
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
      updateSidebarFormFromState();
    }
  }

  async function loadActiveWorkspace(forceAll) {
    state.activeTargetType = 'workspace';
    state.activeObjectiveId = null;
    state.activeObjective = null;
    state.actionButtons = [];
    state.actionButtonState = {};
    state.debugEntries = [];
    state.debugHasErrors = false;
    closeDebugModal();
    state.activeWorkspaceTurn = null;
    state.messages = [];
    state.lastMessageTimestamp = null;
    resetBuildLogState();
    resetConsoleLogState();
    resetStatusSummaryState();
    if (!state.activeWorkspaceId) {
      state.activeWorkspace = null;
      if (forceAll) render();
      return;
    }
    const previousPath = activeGitPath();
    state.activeWorkspace = await api('/api/workspaces/' + encodeURIComponent(state.activeWorkspaceId));
    if (state.activeWorkspace && state.activeWorkspace.projectId) {
      state.projectExpansion = Object.assign({}, state.projectExpansion, { [state.activeWorkspace.projectId]: true });
    }
    await Promise.all([
      pollMessages(false),
      pollActiveWorkspaceTurn(false),
      loadActionButtons(),
      fetchDebugErrorState()
    ]);
    const nextPath = activeGitPath();
    if (previousPath !== nextPath) {
      state.gitStatus = null;
      if (!nextPath) {
        state.gitPanelOpen = false;
        hideGitContextMenu();
        closeDiffOverlay();
      } else if (state.gitPanelOpen && state.rightPanelMode === 'git') {
        await fetchGitStatus();
      } else if (state.gitPanelOpen && state.rightPanelMode === 'status') {
        await fetchStatusSummary(true);
      }
    } else if (state.gitPanelOpen && state.rightPanelMode === 'status') {
      await fetchStatusSummary(false);
    }
    if (forceAll) render();
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

  async function pollActiveWorkspace(forceRender) {
    if (!state.activeWorkspaceId) {
      state.activeWorkspace = null;
      state.activeWorkspaceTurn = null;
      state.actionButtons = [];
      state.actionButtonState = {};
      state.fabModalOpen = false;
      resetBuildLogState();
      resetConsoleLogState();
      resetStatusSummaryState();
      renderBuildLog();
      renderConsoleLog();
      renderFabRail();
      renderFabModal();
      return;
    }
    const previousPath = activeGitPath();
    const workspace = await api('/api/workspaces/' + encodeURIComponent(state.activeWorkspaceId));
    state.activeWorkspace = workspace;
    if (workspace && workspace.projectId) {
      state.projectExpansion = Object.assign({}, state.projectExpansion, { [workspace.projectId]: true });
    }
    const index = state.workspaces.findIndex((item) => item.id === workspace.id);
    if (index >= 0) {
      state.workspaces[index] = workspace;
    }
    await Promise.all([
      pollActiveWorkspaceTurn(false),
      loadActionButtons()
    ]);
    await fetchDebugErrorState();
    const nextPath = activeGitPath();
    if (previousPath !== nextPath) {
      state.gitStatus = null;
      if (!nextPath) {
        state.gitPanelOpen = false;
        hideGitContextMenu();
        closeDiffOverlay();
      } else if (state.gitPanelOpen && state.rightPanelMode === 'git') {
        await fetchGitStatus();
      } else if (state.gitPanelOpen && state.rightPanelMode === 'status') {
        await fetchStatusSummary(true);
      }
    }
    if (forceRender) render();
    else {
      renderContext();
      renderBuildLog();
      renderConsoleLog();
      renderSidebar();
      renderMessages();
      renderInputState();
    }
  }

  async function createWorkspace(options) {
    const payload = {
      projectId: options.projectId || undefined,
      rootPath: options.rootPath,
      name: options.name || '',
      source: options.source || 'manual-path'
    };
    state.pendingCreate = true;
    renderInputState();
    updateSidebarFormFromState();
    try {
      const workspace = await api('/api/workspaces', {
        method: 'POST',
        body: JSON.stringify(payload)
      });
      // Fire start in background — don't block the UI
      api('/api/workspaces/' + encodeURIComponent(workspace.id) + '/start', {
        method: 'POST',
        body: JSON.stringify({})
      }).catch(function() {});
      state.activeWorkspaceId = workspace.id;
      state.activeTargetType = 'workspace';
      closeSidebar();
      state.sidebarFormOpen = false;
      state.draftWorkspaceName = '';
      state.draftWorkspaceRootPath = '';
      els.chatInput.value = '';
      autoResizeTextarea();
      await pollObjectives();
      await loadActiveWorkspace(true);
    } finally {
      state.pendingCreate = false;
      renderInputState();
      updateSidebarFormFromState();
    }
  }

  async function submitSidebarObjective() {
    const projectSelectInput = document.getElementById('projectSelectInput');
    const baseBranchInput = document.getElementById('baseBranchInput');
    const branchNameInput = document.getElementById('branchNameInput');
    const sidebarGoalInput = document.getElementById('sidebarGoalInput');
    setDraftProject(projectSelectInput ? projectSelectInput.value.trim() : state.draftProjectId, { updateBaseBranch: false });
    state.draftBaseBranch = baseBranchInput ? (baseBranchInput.value.trim() || 'main') : (state.draftBaseBranch || 'main');
    state.draftBranchName = branchNameInput ? branchNameInput.value.trim() : state.draftBranchName;
    state.draftGoal = sidebarGoalInput ? sidebarGoalInput.value.trim() : state.draftGoal;
    if (!state.draftProjectId || !state.draftGoal) {
      showToast('Project and goal are required');
      return;
    }
    try {
      await createObjective({
        goal: state.draftGoal,
        projectId: state.draftProjectId,
        baseBranch: state.draftBaseBranch,
        branchName: state.draftBranchName,
        workflowMode: state.draftWorkflowMode
      });
    } catch (error) {
      showToast(error.message || 'Could not create objective');
    }
  }

  async function submitSidebarWorkspace() {
    const projectSelectInput = document.getElementById('workspaceProjectSelectInput');
    const workspaceNameInput = document.getElementById('workspaceNameInput');
    setDraftProject(projectSelectInput ? projectSelectInput.value.trim() : state.draftProjectId, { updateBaseBranch: false });
    state.draftWorkspaceName = workspaceNameInput ? workspaceNameInput.value.trim() : state.draftWorkspaceName;
    if (!state.draftProjectId || !state.draftWorkspaceRootPath) {
      showToast('Choose a project and path');
      return;
    }
    try {
      await createWorkspace({
        projectId: state.draftProjectId,
        rootPath: state.draftWorkspaceRootPath,
        name: state.draftWorkspaceName,
        source: 'manual-path'
      });
    } catch (error) {
      showToast(error.message || 'Could not open item');
    }
  }

  async function submitSidebarProject() {
    const projectNameInput = document.getElementById('projectNameInput');
    const projectRootPathInput = document.getElementById('projectRootPathInput');
    const projectRootPathManualInput = document.getElementById('projectRootPathManualInput');
    const projectBaseBranchInput = document.getElementById('projectBaseBranchInput');
    state.draftProjectName = projectNameInput ? projectNameInput.value.trim() : state.draftProjectName;
    state.draftProjectRootPath = projectRootPathManualInput
      ? projectRootPathManualInput.value.trim()
      : (projectRootPathInput ? projectRootPathInput.value.trim() : state.draftProjectRootPath);
    state.draftProjectBaseBranch = projectBaseBranchInput ? (projectBaseBranchInput.value.trim() || 'main') : (state.draftProjectBaseBranch || 'main');
    if (!state.draftProjectRootPath) {
      showToast(state.projectPickerFallback ? 'Project root path is required' : 'Choose a project folder');
      return;
    }
    state.pendingCreate = true;
    renderInputState();
    updateSidebarFormFromState();
    try {
      const project = await api('/api/projects', {
        method: 'POST',
        body: JSON.stringify({
          name: state.draftProjectName,
          rootPath: state.draftProjectRootPath,
          defaultBaseBranch: state.draftProjectBaseBranch || 'main'
        })
      });
      const returnMode = state.projectCreationReturnMode;
      state.projectCreationReturnMode = '';
      setDraftProject(project.id);
      state.draftProjectName = '';
      state.draftProjectRootPath = '';
      state.draftProjectBaseBranch = state.draftBaseBranch || 'main';
      await pollObjectives();
      if (returnMode === 'workspace') {
        openWorkspaceForm(project.id);
      } else if (returnMode === 'objective') {
        openSidebarForm(state.draftGoal, project.id);
      } else {
        openAddKindForm(project.id);
      }
      showToast('Project added');
    } catch (error) {
      showToast(error.message || 'Could not add project');
    } finally {
      state.pendingCreate = false;
      renderInputState();
      updateSidebarFormFromState();
    }
  }

  async function sendMessage() {
    const text = els.chatInput.value.trim();
    if (!text) return;
    if (state.activeWorkspaceId && state.activeWorkspace) {
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
      state.activeWorkspaceTurn = {
        id: 'pending-local',
        status: 'pending',
        createdAt: new Date().toISOString(),
        progressSummary: '',
        progressState: 'working'
      };
      state.typing = false;
      renderMessages();
      try {
        await api('/api/workspaces/' + encodeURIComponent(state.activeWorkspaceId) + '/message', {
          method: 'POST',
          body: JSON.stringify({ message: text })
        });
        await pollActiveWorkspaceTurn(false);
      } catch (error) {
        state.activeWorkspaceTurn = null;
        state.typing = false;
        renderMessages();
        showToast(error.message || 'Could not send message');
      } finally {
        state.pendingSend = false;
        renderInputState();
      }
      return;
    }
    if (!state.activeObjectiveId || !state.activeObjective) {
      showToast(state.projects.length ? 'Nothing selected. Choose New or Open, or pick an item from the sidebar.' : 'No projects yet. Add a project first.');
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
    if (state.pollers.activeTurn) window.clearInterval(state.pollers.activeTurn);
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
        if (state.activeWorkspaceId) await pollActiveWorkspace(false);
        else await pollActiveObjective(false);
      } catch (error) {
        console.error(error);
      }
    }, 5000);

    state.pollers.activeTurn = window.setInterval(async () => {
      try {
        if (state.activeWorkspaceId) await pollActiveWorkspaceTurn(false);
      } catch (error) {
        console.error(error);
      }
    }, 4000);

    state.pollers.git = window.setInterval(async () => {
      try {
        if (state.gitPanelOpen && state.rightPanelMode === 'git') {
          await fetchGitStatus();
        } else if (state.gitPanelOpen && state.rightPanelMode === 'status') {
          await fetchStatusSummary(true);
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

  /* ── Onboarding & Tour ──────────────────────── */

  const TOUR_STEPS = [
    {
      target: 'addProjectButton',
      title: 'Add a Project',
      body: 'Register a git repository directory. Projects organize your objectives and workspaces under one roof.',
      side: 'right'
    },
    {
      target: 'newObjectiveButton',
      title: 'Create an Objective',
      body: 'Set a goal or paste a Jira ticket URL. "Structured" runs multi-step planning with agent review between tasks. "Direct" sends the goal straight to a single worker agent.',
      side: 'right'
    },
    {
      target: 'openWorkspaceButton',
      title: 'Open a Workspace',
      body: 'If you have an existing worktree or feature branch from a project, open it here to start an unstructured Claude Code session.',
      side: 'right'
    },
    {
      target: 'objectiveList',
      title: 'Sidebar Navigation',
      body: 'Projects, objectives, and workspaces appear here grouped by project. Click to select, right-click for rename or delete.',
      side: 'right'
    },
    {
      target: 'contextStrip',
      title: 'Context Strip',
      body: 'Shows the current item\u2019s status, branch, and quick actions. The Git button opens diffs, Status shows a task summary, and Build Log / Console Log stream live output.',
      side: 'bottom'
    },
    {
      target: 'chatInput',
      title: 'Chat Input',
      body: 'Send messages to the active objective or workspace. For objectives, steer the plan or ask what\u2019s happening. The orchestrator updates you as tasks complete.',
      side: 'top'
    },
    {
      target: 'settingsButton',
      title: 'Settings',
      body: 'Configure poll interval (how often we check workspaces), review backend (Claude / Ollama / LM Studio), and the approval severity threshold \u2014 tools below the threshold are auto-approved, at or above are escalated to you.',
      side: 'top'
    },
    {
      target: 'fabRail',
      title: 'Action Buttons',
      body: 'Custom reusable prompt buttons on the right rail (e.g., "Build & Run", "Run Tests"). Define per objective or workspace. The \uD83D\uDC1B debug button is always available for troubleshooting.',
      side: 'left'
    }
  ];

  const ONBOARDING_FEATURES = [
    { icon: '\uD83D\uDCCB', title: 'Projects & Objectives', desc: 'Register repos, set goals, auto-plan into parallel tasks with sprint contracts and acceptance criteria.' },
    { icon: '\uD83D\uDDA5\uFE0F', title: 'Workspaces', desc: 'Unstructured Claude Code sessions for ad-hoc work, exploration, or debugging.' },
    { icon: '\uD83D\uDD12', title: 'Auto-Approval', desc: '5-level severity classifier auto-approves safe tool uses and escalates risky ones to you.' },
    { icon: '\uD83D\uDD0D', title: 'Code Reviews', desc: 'Automated post-task review via Claude, Ollama, or LM Studio with structured feedback.' }
  ];

  function shouldShowOnboarding() {
    try { return !localStorage.getItem('cmux-onboarding-dismissed'); }
    catch (e) { return false; }
  }

  async function checkPrerequisites() {
    try {
      const status = await api('/api/status');
      state.prereqStatus = {
        socketFound: !!status.socketFound,
        connected: !!status.connected,
        ollamaAvailable: status.ollamaAvailable,
        serverRunning: true
      };
    } catch (err) {
      state.prereqStatus = {
        socketFound: false,
        connected: false,
        ollamaAvailable: null,
        serverRunning: true
      };
    }
  }

  function renderOnboardingPrereqs() {
    const s = state.prereqStatus || {};
    const items = [
      {
        ok: s.connected,
        label: 'cmux socket connected',
        hint: s.connected
          ? 'Socket found and communicating.'
          : 'Enable automation mode: cmux Settings \u2192 Automation \u2192 set to <code>automation</code>. Or run: <code>defaults write com.cmuxterm.app socketControlMode -string automation</code> and restart cmux.',
        optional: false
      },
      {
        ok: true,
        label: 'Harness server running',
        hint: 'You\u2019re seeing this page, so the server is working.',
        optional: false
      }
    ];
    els.onboardingPrereqs.innerHTML = items.map(item => {
      const iconClass = item.ok ? 'ok' : (item.optional ? 'opt' : 'err');
      const iconChar = item.ok ? '\u2713' : (item.optional ? '\u25CB' : '\u2717');
      return '<div class="prereq-item">'
        + '<div class="prereq-icon ' + iconClass + '">' + iconChar + '</div>'
        + '<div class="prereq-text">'
        + '<div class="prereq-name">' + esc(item.label) + '</div>'
        + '<div class="prereq-hint">' + item.hint + '</div>'
        + '</div></div>';
    }).join('');
  }

  function renderOnboardingFeatures() {
    els.onboardingFeatures.innerHTML = ONBOARDING_FEATURES.map(f =>
      '<div class="feature-card">'
      + '<div class="feature-card-icon">' + f.icon + '</div>'
      + '<div class="feature-card-title">' + esc(f.title) + '</div>'
      + '<div class="feature-card-desc">' + esc(f.desc) + '</div>'
      + '</div>'
    ).join('');
  }

  function openOnboarding() {
    state.onboardingOpen = true;
    renderOnboardingPrereqs();
    renderOnboardingFeatures();
    els.onboardingOverlay.classList.add('open');
  }

  function closeOnboarding() {
    state.onboardingOpen = false;
    els.onboardingOverlay.classList.remove('open');
    try { localStorage.setItem('cmux-onboarding-dismissed', String(Date.now())); }
    catch (e) { /* localStorage unavailable */ }
  }

  async function recheckPrerequisites() {
    await checkPrerequisites();
    renderOnboardingPrereqs();
  }

  /* ── Spotlight Tour ── */

  function startTour() {
    closeOnboarding();
    state.tourActive = true;
    state.tourStep = 0;
    els.tourOverlay.classList.add('active');
    renderTourStep();
  }

  function renderTourStep() {
    const step = TOUR_STEPS[state.tourStep];
    if (!step) { endTour(); return; }

    // Resolve target element (with fallback)
    let targetEl = els[step.target];
    if ((!targetEl || targetEl.offsetParent === null) && step.fallback) {
      targetEl = els[step.fallback];
    }

    // Remove previous highlight
    document.querySelectorAll('.tour-target-highlight, .tour-target-highlight-fixed').forEach(el => {
      el.classList.remove('tour-target-highlight');
      el.classList.remove('tour-target-highlight-fixed');
    });

    if (targetEl) {
      targetEl.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      const isFixed = window.getComputedStyle(targetEl).position === 'fixed';
      targetEl.classList.add(isFixed ? 'tour-target-highlight-fixed' : 'tour-target-highlight');

      const rect = targetEl.getBoundingClientRect();
      const pad = 8;
      const x1 = Math.max(0, rect.left - pad);
      const y1 = Math.max(0, rect.top - pad);
      const x2 = Math.min(window.innerWidth, rect.right + pad);
      const y2 = Math.min(window.innerHeight, rect.bottom + pad);
      const w = window.innerWidth;
      const h = window.innerHeight;
      els.tourOverlay.style.clipPath =
        'polygon(0 0, ' + w + 'px 0, ' + w + 'px ' + h + 'px, 0 ' + h + 'px, 0 0, '
        + x1 + 'px ' + y1 + 'px, ' + x1 + 'px ' + y2 + 'px, '
        + x2 + 'px ' + y2 + 'px, ' + x2 + 'px ' + y1 + 'px, '
        + x1 + 'px ' + y1 + 'px)';

      positionTourTooltip(rect, step.side);
    } else {
      els.tourOverlay.style.clipPath = '';
      positionTourTooltipCenter();
    }

    const total = TOUR_STEPS.length;
    const current = state.tourStep + 1;
    const isFirst = state.tourStep === 0;
    const isLast = state.tourStep === total - 1;

    els.tourTooltip.innerHTML =
      '<div class="tour-tooltip-title">' + esc(step.title) + '</div>'
      + '<div class="tour-tooltip-body">' + esc(step.body) + '</div>'
      + '<div class="tour-tooltip-footer">'
      + '<span class="tour-step-indicator">' + current + ' of ' + total + '</span>'
      + '<div class="tour-nav">'
      + '<button class="tour-nav-btn skip" id="tourSkipBtn" type="button">Skip</button>'
      + (isFirst ? '' : '<button class="tour-nav-btn back" id="tourBackBtn" type="button">Back</button>')
      + '<button class="tour-nav-btn next" id="tourNextBtn" type="button">'
      + (isLast ? 'Finish' : 'Next') + '</button>'
      + '</div></div>';

    els.tourTooltip.classList.add('active');

    document.getElementById('tourNextBtn').addEventListener('click', advanceTour);
    if (!isFirst) document.getElementById('tourBackBtn').addEventListener('click', retreatTour);
    document.getElementById('tourSkipBtn').addEventListener('click', endTour);
  }

  function positionTourTooltip(rect, side) {
    const tip = els.tourTooltip;
    const gap = 14;
    const tipW = 320;
    const tipH = tip.offsetHeight || 180;

    let left, top;
    switch (side) {
      case 'right':
        left = rect.right + gap;
        top = rect.top + (rect.height / 2) - (tipH / 2);
        break;
      case 'left':
        left = rect.left - tipW - gap;
        top = rect.top + (rect.height / 2) - (tipH / 2);
        break;
      case 'bottom':
        left = rect.left + (rect.width / 2) - (tipW / 2);
        top = rect.bottom + gap;
        break;
      case 'top':
        left = rect.left + (rect.width / 2) - (tipW / 2);
        top = rect.top - tipH - gap;
        break;
      default:
        left = rect.right + gap;
        top = rect.top;
    }

    // Clamp to viewport
    left = Math.max(12, Math.min(left, window.innerWidth - tipW - 12));
    top = Math.max(12, Math.min(top, window.innerHeight - tipH - 12));

    tip.style.left = left + 'px';
    tip.style.top = top + 'px';
  }

  function positionTourTooltipCenter() {
    const tip = els.tourTooltip;
    tip.style.left = '50%';
    tip.style.top = '50%';
    tip.style.transform = 'translate(-50%, -50%)';
  }

  function advanceTour() {
    state.tourStep++;
    if (state.tourStep >= TOUR_STEPS.length) {
      endTour();
    } else {
      renderTourStep();
    }
  }

  function retreatTour() {
    if (state.tourStep > 0) {
      state.tourStep--;
      renderTourStep();
    }
  }

  function endTour() {
    state.tourActive = false;
    state.tourStep = 0;
    els.tourOverlay.classList.remove('active');
    els.tourOverlay.style.clipPath = '';
    els.tourTooltip.classList.remove('active');
    els.tourTooltip.style.transform = '';
    document.querySelectorAll('.tour-target-highlight, .tour-target-highlight-fixed').forEach(el => {
      el.classList.remove('tour-target-highlight');
      el.classList.remove('tour-target-highlight-fixed');
    });
    try { localStorage.setItem('cmux-tour-completed', String(Date.now())); }
    catch (e) { /* localStorage unavailable */ }
  }

  function bindOnboardingEvents() {
    els.onboardingCloseButton.addEventListener('click', closeOnboarding);
    els.onboardingSkipButton.addEventListener('click', closeOnboarding);
    els.onboardingTourButton.addEventListener('click', startTour);
    els.onboardingRecheckButton.addEventListener('click', recheckPrerequisites);
    els.onboardingOverlay.addEventListener('click', (event) => {
      if (event.target === els.onboardingOverlay) closeOnboarding();
    });
    els.tourOverlay.addEventListener('click', (event) => {
      if (event.target === els.tourOverlay) endTour();
    });
    els.helpFab.addEventListener('click', async () => {
      await checkPrerequisites();
      openOnboarding();
    });
  }

  function bindEvents() {
    bindOnboardingEvents();
    els.newObjectiveButton.addEventListener('click', () => {
      openSidebarForm(state.draftGoal);
    });
    els.openWorkspaceButton.addEventListener('click', () => {
      openWorkspaceForm(selectedProjectId());
    });
    els.addProjectButton.addEventListener('click', openProjectForm);
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
    els.gitPanelRefreshButton.addEventListener('click', () => {
      if (state.rightPanelMode === 'status') {
        fetchStatusSummary(true);
      } else {
        fetchGitStatus();
      }
    });
    els.gitPanelCloseButton.addEventListener('click', closeGitPanel);
    els.gitPanelCopyButton.addEventListener('click', () => {
      copyText((state.gitStatus && state.gitStatus.cwd) || activeFilesRoot() || activeGitPath(), 'Path');
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
      if (event.key === 'Escape' && state.tourActive) {
        event.preventDefault();
        endTour();
        return;
      }
      if (event.key === 'Escape' && state.onboardingOpen) {
        event.preventDefault();
        closeOnboarding();
        return;
      }
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
      if (state.tourActive) renderTourStep();
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
    if (shouldShowOnboarding()) {
      await checkPrerequisites();
      openOnboarding();
    }
  }

  boot();
})();
