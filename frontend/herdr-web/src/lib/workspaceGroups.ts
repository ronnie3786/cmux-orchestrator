/**
 * Workspace grouping + display helpers for the herdr web shell.
 *
 * Rework of Phase-1's workspaceGroups (cmux session grouping) onto the
 * herdr workspace/pane shape (src/types/herdr.ts). Drives the sidebar
 * "chats" tree (workspace → tab sections → chats, plus panes that match no
 * tab), the workspace list filter/search, and the byte-exact status
 * vocabulary (doc 01 §6).
 */

import type { AgentStatus, Pane, Tab, Workspace } from "../types/herdr";

// --- status vocabulary (byte-exact, doc 01 §6) --------------------------------

/** Workspace-level titles: Needs you / Ready / Working / Idle / Shell. */
export const STATUS_TITLE: Record<AgentStatus, string> = {
  blocked: "Needs you",
  done: "Ready",
  working: "Working",
  idle: "Idle",
  unknown: "Shell",
};

/** Compact pane-level: Blocked / Done / Working / Idle / Unknown. */
export const STATUS_COMPACT: Record<AgentStatus, string> = {
  blocked: "Blocked",
  done: "Done",
  working: "Working",
  idle: "Idle",
  unknown: "Unknown",
};

export function statusTitle(status: AgentStatus): string {
  return STATUS_TITLE[status] ?? "Shell";
}

/** Compact title lowercased — the UI's common render. */
export function compactStatus(status: AgentStatus): string {
  return (STATUS_COMPACT[status] ?? "Unknown").toLowerCase();
}

/** iOS `needsAttention`: blocked first, then unseen completions (done). */
export function needsAttention(status: AgentStatus): boolean {
  return status === "blocked" || status === "done";
}

// --- display helpers -------------------------------------------------------------

function pathBasename(value: string): string {
  const parts = value.replace(/\\/g, "/").split("/").filter(Boolean);
  return parts.length > 0 ? (parts[parts.length - 1] ?? "") : value;
}

/** branch/worktree label; "shell" fallback (iOS tokens["branch"] fallback). */
export function branchLabel(workspace: Workspace): string {
  const worktree = workspace.worktree;
  if (!worktree) return "shell";
  if (worktree.is_linked_worktree) {
    const base = pathBasename(worktree.checkout_path);
    if (base) return base;
  }
  return worktree.repo_name || "shell";
}

/** Chat-row display title: label → stripped title → raw title → pane id. */
export function chatDisplayName(pane: Pane): string {
  const label = (pane.label ?? "").trim();
  if (label) return label;
  const title = (pane.terminal_title_stripped ?? pane.terminal_title ?? "").trim();
  if (title) return title;
  return pane.pane_id;
}

// --- grouping ----------------------------------------------------------------------

export interface ChatRow {
  paneId: string;
  workspaceId: string;
  title: string;
  status: AgentStatus;
}

export interface TabSection {
  tab: Tab;
  chats: ChatRow[];
}

export interface WorkspaceGroup {
  workspaceId: string;
  number: number;
  label: string;
  focused: boolean;
  agentStatus: AgentStatus;
  /** Pane count as reported by the snapshot. */
  paneCount: number;
  /** Highest pane revision; null when the workspace has no panes. */
  revision: number | null;
  /** branch/worktree label ("shell" fallback). */
  branch: string;
  tabSections: TabSection[];
  /** Panes whose tab_id matches no tab in the workspace. */
  looseChats: ChatRow[];
  /** Any pane needs attention (blocked or done). */
  needsYou: boolean;
  /** Any pane is working. */
  active: boolean;
  /** Number of attention panes (sidebar capsule). */
  attentionCount: number;
}

function toChatRow(pane: Pane, workspaceId: string): ChatRow {
  return {
    paneId: pane.pane_id,
    workspaceId,
    title: chatDisplayName(pane),
    status: pane.agent_status,
  };
}

export function toGroup(workspace: Workspace): WorkspaceGroup {
  const tabIds = new Set(workspace.tabs.map((tab) => tab.tab_id));
  const tabSections = [...workspace.tabs]
    .sort((a, b) => a.number - b.number)
    .map((tab) => ({
      tab,
      chats: workspace.panes
        .filter((pane) => pane.tab_id === tab.tab_id)
        .map((pane) => toChatRow(pane, workspace.workspace_id)),
    }));
  const looseChats = workspace.panes
    .filter((pane) => !tabIds.has(pane.tab_id))
    .map((pane) => toChatRow(pane, workspace.workspace_id));

  let revision: number | null = null;
  let needsYou = false;
  let active = false;
  let attentionCount = 0;
  for (const pane of workspace.panes) {
    if (revision === null || pane.revision > revision) revision = pane.revision;
    if (needsAttention(pane.agent_status)) {
      needsYou = true;
      attentionCount += 1;
    }
    if (pane.agent_status === "working") active = true;
  }

  return {
    workspaceId: workspace.workspace_id,
    number: workspace.number,
    label: workspace.label,
    focused: workspace.focused,
    agentStatus: workspace.agent_status,
    paneCount: workspace.pane_count,
    revision,
    branch: branchLabel(workspace),
    tabSections,
    looseChats,
    needsYou,
    active,
    attentionCount,
  };
}

/** iOS visibleWorkspaces ordering: sorted by `number`. */
export function groups(workspaces: Workspace[]): WorkspaceGroup[] {
  return [...workspaces].sort((a, b) => a.number - b.number).map(toGroup);
}

// --- filter + search (iOS WorkspaceFilter parity: All / Needs you / Active) -------

export type WorkspaceFilter = "all" | "needsYou" | "active";

/** iOS WorkspaceFilter.allCases labels; the UI renders them lowercased. */
export const WORKSPACE_FILTERS: ReadonlyArray<{
  id: WorkspaceFilter;
  label: string;
  /** Lowercased render (the UI string). */
  rendered: string;
}> = [
  { id: "all", label: "All", rendered: "all" },
  { id: "needsYou", label: "Needs you", rendered: "needs you" },
  { id: "active", label: "Active", rendered: "active" },
];

export function groupMatchesFilter(group: WorkspaceGroup, filter: WorkspaceFilter): boolean {
  switch (filter) {
    case "all":
      return true;
    case "needsYou":
      return group.needsYou;
    case "active":
      return group.active;
  }
}

/**
 * Sidebar-tree search (iOS SidebarTree.query): workspaces by label, tabs by
 * label, chats by display title. An empty query matches everything.
 */
export function groupMatchesSearch(group: WorkspaceGroup, search: string): boolean {
  const query = search.trim().toLowerCase();
  if (!query) return true;
  if (group.label.toLowerCase().includes(query)) return true;
  const chats = group.tabSections.flatMap((section) => section.chats).concat(group.looseChats);
  return (
    group.tabSections.some((section) => section.tab.label.toLowerCase().includes(query)) ||
    chats.some((chat) => chat.title.toLowerCase().includes(query))
  );
}

/** Search AND filter, in that order (iOS visibleWorkspaceGroups parity). */
export function filterGroups(all: WorkspaceGroup[], search: string, filter: WorkspaceFilter): WorkspaceGroup[] {
  return all.filter((group) => groupMatchesFilter(group, filter) && groupMatchesSearch(group, search));
}
