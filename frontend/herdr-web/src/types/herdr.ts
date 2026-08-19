/**
 * Types for the herdr harness API (v1), derived strictly from live captures:
 *  - src/__fixtures__/workspaces.json  (GET /api/v1/workspaces)
 *  - src/__fixtures__/alerts.json      (GET /api/v1/alerts)
 *  - src/__fixtures__/events-sample.json (GET /api/v1/events)
 *  - GET /api/v1/health (live curl)
 * Optionals mark fields that are absent on at least one record in the
 * fixtures. `AgentStatus` includes "blocked" because the attention-ranking
 * contract requires it even though the current capture only shows the other
 * four values.
 */

export type AgentStatus = "blocked" | "done" | "working" | "idle" | "unknown";

export interface HerdrRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface PaneScroll {
  offset_from_bottom: number;
  max_offset_from_bottom: number;
  viewport_rows: number;
}

export interface AgentSession {
  source: string;
  agent: string;
  kind: string;
  value: string;
}

export interface PiSemanticCapabilities {
  prompt: boolean;
  steer: boolean;
  followUp: boolean;
  abort: boolean;
  listModels: boolean;
  setModel: boolean;
  setThinkingLevel: boolean;
  interactionResponse: boolean;
}

export interface PiSemantic {
  available: boolean;
  connected: boolean;
  protocol_version: number;
  session_id: string;
  cursor: number;
  oldest_cursor: number;
  capabilities: PiSemanticCapabilities;
  generated_at: string;
}

export interface Pane {
  pane_id: string;
  terminal_id: string;
  workspace_id: string;
  tab_id: string;
  focused: boolean;
  cwd: string;
  foreground_cwd: string;
  /** Absent on some panes in the capture. */
  label?: string;
  /** Absent on panes with no detected agent. */
  agent?: string;
  /** Absent when there is no terminal title. */
  terminal_title?: string;
  terminal_title_stripped?: string;
  agent_status: AgentStatus;
  /** Absent when no agent session is attached. */
  agent_session?: AgentSession;
  scroll: PaneScroll;
  /** Monotonic per-pane change counter (tie-break for attention ranking). */
  revision: number;
  /** Absent when the Pi semantic bridge is not attached. */
  pi_semantic?: PiSemantic;
}

export interface Tab {
  tab_id: string;
  workspace_id: string;
  number: number;
  label: string;
  focused: boolean;
  pane_count: number;
  agent_status: AgentStatus;
}

export interface Worktree {
  repo_key: string;
  repo_name: string;
  repo_root: string;
  checkout_path: string;
  is_linked_worktree: boolean;
}

export interface Agent {
  terminal_id: string;
  name?: string;
  agent: string;
  terminal_title?: string;
  terminal_title_stripped?: string;
  agent_status: AgentStatus;
  screen_detection_skipped?: boolean;
  agent_session?: AgentSession;
  workspace_id: string;
  tab_id: string;
  pane_id: string;
  focused: boolean;
  interactive_ready?: boolean;
  state_change_seq: number;
  cwd: string;
  foreground_cwd: string;
  revision: number;
}

export interface LayoutPane {
  pane_id: string;
  focused: boolean;
  rect: HerdrRect;
}

export interface LayoutSplit {
  id: string;
  direction: "right" | "down";
  ratio: number;
  rect: HerdrRect;
}

export interface Layout {
  workspace_id: string;
  tab_id: string;
  zoomed: boolean;
  area: HerdrRect;
  focused_pane_id: string;
  panes: LayoutPane[];
  splits: LayoutSplit[];
}

export interface Workspace {
  workspace_id: string;
  number: number;
  label: string;
  focused: boolean;
  pane_count: number;
  tab_count: number;
  active_tab_id: string;
  agent_status: AgentStatus;
  tabs: Tab[];
  panes: Pane[];
  agents: Agent[];
  layouts: Layout[];
  /** Absent on workspaces with no git worktree. */
  worktree?: Worktree;
}

/** One alert as captured in the alerts fixture (camelCase — server-owned). */
export interface AlertAction {
  /** Only "open_pane" appears in the captures; kept open for future kinds. */
  type: string;
  paneId: string;
}

export interface Alert {
  id: string;
  kind: string;
  status: string;
  previousStatus: string;
  severity: string;
  title: string;
  message: string;
  workspaceId: string;
  workspaceLabel: string;
  tabId: string;
  tabLabel: string;
  paneId: string;
  paneTitle: string;
  agentName: string;
  createdAt: string;
  isRead: boolean;
  /** Null until the alert is marked read. */
  readAt: string | null;
  action: AlertAction;
}

export interface WorkspacesResponse {
  ok: boolean;
  workspaces: Workspace[];
  alerts: Alert[];
  generatedAt: string;
}

export interface WorkspaceSingleResponse {
  ok: boolean;
  workspace: Workspace;
}

export interface AlertsResponse {
  ok: boolean;
  alerts: Alert[];
  unreadCount: number;
  generatedAt: string;
}

/** GET /api/v1/alerts/{id}/read (verified against herdr_harness/service.py). */
export interface AlertReadResponse {
  ok: boolean;
  alert: Alert;
  unreadCount: number;
}

/** GET /api/v1/alerts/read-all (verified against herdr_harness/service.py). */
export interface AlertsReadAllResponse {
  ok: boolean;
  alerts: Alert[];
  unreadCount: number;
}

export interface Health {
  ok: boolean;
  service: string;
  session: string;
  herdr: {
    connected: boolean;
    requestConnected: boolean;
    eventsConnected: boolean;
    socketFound: boolean;
    version: string;
    protocol: number;
    lastError: string | null;
  };
  cache: {
    available: boolean;
    stale: boolean;
    generatedAt: string;
  };
  alerts: {
    unread: number;
  };
  generatedAt: string;
}

/** GET /api/v1/push/status (live-verified 2026-08-19). */
export interface PushStatus {
  ok: boolean;
  apns: {
    configured: boolean;
    environment: string;
    topicConfigured: boolean;
    deviceCount: number;
    liveActivityCount: number;
    /** Present when unconfigured — why the credentials are missing. */
    reason?: string;
  };
  generatedAt: string;
}
