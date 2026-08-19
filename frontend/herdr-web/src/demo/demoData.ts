/**
 * Demo fixtures — port of herdr-harness-ios Models/DemoData.swift (the 3
 * workspaces, tabs, panes, 2 alerts). Shapes follow src/types/herdr.ts
 * (the web API contract) rather than the Swift models: no `tokens`, no
 * `title` (pane display comes from terminal_title), agents arrays are
 * empty (nothing on the web renders them).
 *
 * w1:p1 (Codex) carries a Pi semantic capability so the pane offers Chat;
 * the demo Pi snapshot (below) reports `available: false`, which lands the
 * chat in its "native transcript unavailable" empty state instead of
 * streaming.
 */

import type {
  Alert,
  AlertsResponse,
  Health,
  Pane,
  Workspace,
  WorkspacesResponse,
} from "../types/herdr";

export const DEMO_GENERATED_AT = "2026-08-11T14:45:00Z";

const DEMO_CWD = "/Users/ronnie/Work";

function pane(
  paneId: string,
  tabId: string,
  status: Pane["agent_status"],
  title: string,
  agent: string | null,
  revision: number,
  piSemantic?: Pane["pi_semantic"],
): Pane {
  return {
    pane_id: paneId,
    terminal_id: `term_${paneId.replace(":", "_")}`,
    workspace_id: paneId.split(":")[0] ?? "",
    tab_id: tabId,
    focused: paneId === "w1:p1",
    cwd: DEMO_CWD,
    foreground_cwd: "",
    terminal_title: title,
    terminal_title_stripped: title,
    ...(agent !== null ? { agent } : {}),
    agent_status: status,
    scroll: { offset_from_bottom: 0, max_offset_from_bottom: 0, viewport_rows: 26 },
    revision,
    ...(piSemantic !== undefined ? { pi_semantic: piSemantic } : {}),
  };
}

/**
 * Swift demo tab rule: sorted tab ids, first tab "Agents", the rest
 * "Tests"; per-tab status mirrors the workspace status.
 */
function tabs(workspaceId: string, tabIds: string[], status: Workspace["agent_status"]) {
  return tabIds.map((tabId, index) => {
    const paneCount = workspacePanes.filter((candidate) => candidate.tab_id === tabId).length;
    return {
      tab_id: tabId,
      workspace_id: workspaceId,
      number: index + 1,
      label: index === 0 ? "Agents" : "Tests",
      focused: index === 0,
      pane_count: paneCount,
      agent_status: status,
    };
  });
}

// `tabs()` above counts panes across all demo workspaces by tab id; tab ids
// are workspace-scoped (`w1:t1`), so a global filter is correct.
const workspacePanes: Pane[] = [
  pane("w1:p1", "w1:t1", "working", "Refine member profile", "codex", 184, {
    available: true,
    connected: false,
    protocol_version: 1,
    session_id: "demo-pi-session",
    cursor: 0,
    oldest_cursor: 0,
    capabilities: {
      prompt: true,
      steer: true,
      followUp: true,
      abort: true,
      listModels: false,
      setModel: false,
      setThinkingLevel: false,
      interactionResponse: false,
    },
    generated_at: DEMO_GENERATED_AT,
  }),
  pane("w1:p2", "w1:t1", "blocked", "Auth reducer review", "claude", 97),
  pane("w1:p3", "w1:t2", "unknown", "Unit tests", null, 52),
  pane("w2:p1", "w2:t1", "done", "Pagination contract", "codex", 311),
  pane("w2:p2", "w2:t1", "working", "GraphQL smoke test", "claude", 118),
  pane("w3:p1", "w3:t1", "idle", "Release notes", "codex", 44),
];

/** Swift demo layout rule: 120×36 area, panes tiled left to right. */
function layout(workspaceId: string, tabId: string, paneIds: string[]) {
  const width = 120;
  const paneWidth = width / Math.max(paneIds.length, 1);
  return {
    workspace_id: workspaceId,
    tab_id: tabId,
    zoomed: false,
    area: { x: 0, y: 0, width, height: 36 },
    focused_pane_id: paneIds[0] ?? "",
    panes: paneIds.map((paneId, index) => ({
      pane_id: paneId,
      focused: index === 0,
      rect: { x: index * paneWidth, y: 0, width: paneWidth, height: 36 },
    })),
    splits: [],
  };
}

function workspace(
  workspaceId: string,
  number: number,
  label: string,
  path: string,
  status: Workspace["agent_status"],
  tabIds: string[],
  layoutPaneIds: string[][],
): Workspace {
  const panes = workspacePanes.filter((candidate) => candidate.workspace_id === workspaceId);
  const activeTabId = panes[0]?.tab_id ?? "";
  return {
    workspace_id: workspaceId,
    number,
    label,
    focused: number === 1,
    pane_count: panes.length,
    tab_count: tabIds.length,
    active_tab_id: activeTabId,
    agent_status: status,
    tabs: tabs(workspaceId, tabIds, status),
    panes,
    agents: [],
    layouts: layoutPaneIds.map((paneIds) => layout(workspaceId, activeTabId, paneIds)),
    worktree: {
      repo_key: label.toLowerCase().replace(/ /g, "-"),
      repo_name: label,
      repo_root: path,
      checkout_path: path,
      is_linked_worktree: number === 1,
    },
  };
}

/** Swift `DemoData.workspaces` — attention-ranked workspace status per pane. */
export const demoWorkspaces: Workspace[] = [
  workspace("w1", 1, "iOS Doximity", "/Users/ronnie/Work/iOS-Doximity", "blocked", ["w1:t1", "w1:t2"], [
    ["w1:p1", "w1:p2"],
  ]),
  workspace("w2", 2, "Member API", "/Users/ronnie/Work/member-api", "done", ["w2:t1"], [
    ["w2:p1", "w2:p2"],
  ]),
  workspace("w3", 3, "Release Train", "/Users/ronnie/Work/release", "idle", ["w3:t1"], [
    ["w3:p1"],
  ]),
];

/** Swift `DemoData.alerts`, mapped onto the web Alert shape. */
export const demoAlerts: Alert[] = [
  {
    id: "demo-blocked",
    kind: "agent_blocked",
    status: "blocked",
    previousStatus: "working",
    severity: "warning",
    title: "Auth reducer needs you",
    message: "Claude is waiting for approval to update the sign-in dependency.",
    workspaceId: "w1",
    workspaceLabel: "iOS Doximity",
    tabId: "w1:t1",
    tabLabel: "Agents",
    paneId: "w1:p2",
    paneTitle: "Auth reducer review",
    agentName: "claude",
    createdAt: "2026-08-11T14:42:00Z",
    isRead: false,
    readAt: null,
    action: { type: "open_pane", paneId: "w1:p2" },
  },
  {
    id: "demo-done",
    kind: "agent_done",
    status: "done",
    previousStatus: "working",
    severity: "success",
    title: "Pagination contract is ready",
    message: "Codex finished in the background. Review the final response when ready.",
    workspaceId: "w2",
    workspaceLabel: "Member API",
    tabId: "w2:t1",
    tabLabel: "Agents",
    paneId: "w2:p1",
    paneTitle: "Pagination contract",
    agentName: "codex",
    createdAt: "2026-08-11T14:38:00Z",
    isRead: false,
    readAt: null,
    action: { type: "open_pane", paneId: "w2:p1" },
  },
];

/** Demo /health: a healthy, fully attached herdr. */
export const demoHealth: Health = {
  ok: true,
  service: "herdr-harness",
  session: "default",
  herdr: {
    connected: true,
    requestConnected: true,
    eventsConnected: true,
    socketFound: true,
    version: "0.8.0",
    protocol: 19,
    lastError: null,
  },
  cache: { available: true, stale: false, generatedAt: DEMO_GENERATED_AT },
  alerts: { unread: demoAlerts.length },
  generatedAt: DEMO_GENERATED_AT,
};

export function demoWorkspacesResponse(alerts: Alert[]): WorkspacesResponse {
  return { ok: true, workspaces: demoWorkspaces, alerts, generatedAt: DEMO_GENERATED_AT };
}

export function demoAlertsResponse(alerts: Alert[]): AlertsResponse {
  return {
    ok: true,
    alerts,
    unreadCount: alerts.filter((alert) => !alert.isRead).length,
    generatedAt: DEMO_GENERATED_AT,
  };
}

export function demoWorkspaceResponse(workspaceId: string): Workspace | undefined {
  return demoWorkspaces.find((candidate) => candidate.workspace_id === workspaceId);
}

/**
 * Demo terminal snapshot: always empty. The plan keeps demo terminals
 * streamless — "No terminal output yet." is the expected rendering.
 */
export function demoTerminalOutputResponse(paneId: string): unknown {
  return {
    ok: true,
    output: {
      pane_id: paneId,
      workspace_id: paneId.split(":")[0] ?? "",
      tab_id: "",
      source: "recent_unwrapped",
      format: "text",
      text: "",
      revision: 0,
      truncated: false,
    },
    result: null,
    generatedAt: DEMO_GENERATED_AT,
  };
}

/**
 * Demo Pi snapshot: `available: false` → the follow loop parks in the
 * "native transcript unavailable" state (empty chat, no streaming).
 */
export function demoPiSnapshotResponse(paneId: string): unknown {
  return {
    ok: true,
    protocol: { name: "herdr.pi.semantic", version: 1 },
    paneId,
    available: false,
    connected: false,
    entries: [],
    cursor: null,
    oldestCursor: null,
    truncated: false,
    generatedAt: DEMO_GENERATED_AT,
  };
}
