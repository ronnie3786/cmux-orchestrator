/**
 * Session grouping + display helpers.
 *
 * Port of WorkspaceSessionGroup / Workspace display logic from
 * cmux-harness-ios Models/WorkspaceModels.swift. Grouping key is the workspace
 * UUID (all cmux surfaces for one claude session share a UUID).
 */

import type { CmuxNotification, FeedItem, Workspace, WorkspaceAutoMode } from "../api/types";

/** Stable per-row id. Mirrors Workspace.id. */
export function workspaceID(workspace: Workspace): string {
  const stableID = workspace.uuid ? workspace.uuid : `index-${workspace.index}`;
  // Single-surface refs can appear or change as cmux metadata warms.
  // Multi-surface rows need the surface ref to remain distinct.
  if (workspace.surfaceLabel != null && workspace.surfaceId) {
    return `${stableID}|${workspace.surfaceId}`;
  }
  return stableID;
}

/** Grouping key: uuid, falling back to the row id. Mirrors Workspace.sessionGroupID. */
export function sessionGroupID(workspace: Workspace): string {
  const trimmedUUID = workspace.uuid.trim();
  return trimmedUUID ? trimmedUUID : workspaceID(workspace);
}

function pathBasename(value: string): string {
  const normalized = value.replace(/\\/g, "/");
  const components = normalized.split("/").filter(Boolean);
  return components.length > 0 ? components[components.length - 1] : value;
}

/**
 * iOS shortenedFallbackTitle: for non-custom display names, collapse the
 * leading path to its basename (keeping a " : " suffix when present).
 */
function shortenedFallbackTitle(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return trimmed;
  const separator = " : ";
  const range = trimmed.indexOf(separator);
  if (range >= 0) {
    const leading = trimmed.slice(0, range);
    const trailing = trimmed.slice(range + separator.length);
    return pathBasename(leading) + separator + trailing;
  }
  return pathBasename(trimmed);
}

/** Mirrors Workspace.displayName. */
export function displayName(workspace: Workspace): string {
  const hasCustomName = (workspace.customName ?? "").trim().length > 0;
  const rawValue = workspace.surfaceLabel ?? workspace.customName ?? workspace.name;
  const value = rawValue ? rawValue : `workspace-${workspace.index}`;
  return hasCustomName ? value : shortenedFallbackTitle(value);
}

/** Mirrors Workspace.sessionDisplayName (group title). */
export function sessionDisplayName(workspace: Workspace): string {
  const hasCustomName = (workspace.customName ?? "").trim().length > 0;
  const rawValue = workspace.customName ?? workspace.name;
  const value = rawValue ? rawValue : `workspace-${workspace.index}`;
  return hasCustomName ? value : shortenedFallbackTitle(value);
}

/** Mirrors Workspace.paneDisplayName (pane row title). */
export function paneDisplayName(workspace: Workspace): string {
  const surfaceLabel = (workspace.surfaceLabel ?? "").trim();
  if (surfaceLabel) {
    const separator = " : ";
    const range = surfaceLabel.indexOf(separator);
    if (range >= 0) {
      const trailing = surfaceLabel.slice(range + separator.length).trim();
      if (trailing) return trailing;
    }
    return surfaceLabel;
  }
  const surfaceTitle = (workspace.surfaceTitle ?? "").trim();
  if (surfaceTitle) return surfaceTitle;
  return "Pane";
}

/** Mirrors Workspace.resolvedAutoMode. */
export function resolvedAutoMode(workspace: Workspace): WorkspaceAutoMode {
  return workspace.autoMode ?? (workspace.enabled ? "auto" : "off");
}

export interface WorkspaceSessionGroup {
  id: string;
  workspaces: Workspace[];
  primaryWorkspace: Workspace;
  displayName: string;
  paneCount: number;
  hasMultiplePanes: boolean;
}

function sortPanes(lhs: Workspace, rhs: Workspace): number {
  if (lhs.index !== rhs.index) return lhs.index - rhs.index;
  const a = paneDisplayName(lhs).toLowerCase();
  const b = paneDisplayName(rhs).toLowerCase();
  if (a < b) return -1;
  if (a > b) return 1;
  const idA = workspaceID(lhs);
  const idB = workspaceID(rhs);
  return idA < idB ? -1 : idA > idB ? 1 : 0;
}

function sortGroups(lhs: WorkspaceSessionGroup, rhs: WorkspaceSessionGroup): number {
  const left = lhs.primaryWorkspace;
  const right = rhs.primaryWorkspace;
  if (Boolean(left.starred) !== Boolean(right.starred)) {
    return left.starred ? -1 : 1;
  }
  const a = lhs.displayName.toLowerCase();
  const b = rhs.displayName.toLowerCase();
  if (a < b) return -1;
  if (a > b) return 1;
  const idA = lhs.id.toLowerCase();
  const idB = rhs.id.toLowerCase();
  if (idA < idB) return -1;
  if (idA > idB) return 1;
  return left.index - right.index;
}

/** Mirrors WorkspaceSessionGroup.groups(from:). */
export function groups(from: Workspace[]): WorkspaceSessionGroup[] {
  const byKey = new Map<string, Workspace[]>();
  for (const workspace of from) {
    const key = sessionGroupID(workspace);
    const bucket = byKey.get(key);
    if (bucket) {
      bucket.push(workspace);
    } else {
      byKey.set(key, [workspace]);
    }
  }
  const result: WorkspaceSessionGroup[] = [];
  for (const [id, workspaces] of byKey) {
    const sorted = [...workspaces].sort(sortPanes);
    const primary = sorted[0];
    if (!primary) continue;
    result.push({
      id,
      workspaces: sorted,
      primaryWorkspace: primary,
      displayName: sessionDisplayName(primary),
      paneCount: sorted.length,
      hasMultiplePanes: sorted.length > 1,
    });
  }
  return result.sort(sortGroups);
}

/** Mirrors WorkspaceSessionGroup.containsWorkspace. */
export function groupContains(group: WorkspaceSessionGroup, workspaceIDValue: string | null): boolean {
  if (!workspaceIDValue) return false;
  return group.workspaces.some((workspace) => workspaceID(workspace) === workspaceIDValue);
}

/** Mirrors WorkspaceSessionGroup.preferredWorkspaceID. */
export function preferredWorkspaceID(
  group: WorkspaceSessionGroup,
  selectedWorkspaceID: string | null,
): string {
  if (selectedWorkspaceID && groupContains(group, selectedWorkspaceID)) {
    return selectedWorkspaceID;
  }
  return workspaceID(group.primaryWorkspace);
}

/** Mirrors WorkspaceSessionGroup.paneLabel. */
export function paneLabel(_group: WorkspaceSessionGroup, workspace: Workspace, offset: number): string {
  const label = paneDisplayName(workspace).trim();
  return label === "Pane" || label.length === 0 ? `Pane ${offset + 1}` : label;
}

/**
 * Mirrors Workspace.matchesSearch (iOS Models/SessionStateModels.swift):
 * case-insensitive substring match against the display name, raw name,
 * custom name, cwd, branch, surface label, and surface title.
 * `query` must already be trimmed + lowercased (see groupMatchesSearch).
 */
function workspaceMatchesSearch(workspace: Workspace, query: string): boolean {
  return [
    displayName(workspace),
    workspace.name,
    workspace.customName,
    workspace.cwd,
    workspace.branch,
    workspace.surfaceLabel,
    workspace.surfaceTitle,
  ].some((value) => value != null && value.toLowerCase().includes(query));
}

/**
 * Mirrors WorkspaceSessionGroup.matchesSearch (iOS Models/WorkspaceModels.swift):
 * the group display name, any member's searchable fields (see
 * workspaceMatchesSearch), or any pane label.
 */
export function groupMatchesSearch(group: WorkspaceSessionGroup, searchText: string): boolean {
  const query = searchText.trim().toLowerCase();
  if (!query) return true;
  if (group.displayName.toLowerCase().includes(query)) return true;
  return group.workspaces.some(
    (workspace) =>
      workspaceMatchesSearch(workspace, query) ||
      paneDisplayName(workspace).toLowerCase().includes(query),
  );
}

// --- notification / feed derivation (Phase 1 badges) --------------------------

/** Unread notifications matching a workspace (uuid) or its surface. */
export function unreadCountForWorkspace(
  workspace: Workspace,
  notifications: CmuxNotification[],
): number {
  return notifications.filter(
    (notification) =>
      !notification.is_read &&
      (notification.workspace_id === workspace.uuid ||
        (Boolean(notification.surface_id) && notification.surface_id === workspace.surfaceUuid)),
  ).length;
}

/** Unread notifications for a session group (any pane matches). */
export function unreadCountForGroup(
  group: WorkspaceSessionGroup,
  notifications: CmuxNotification[],
): number {
  return group.workspaces.reduce(
    (total, workspace) => total + unreadCountForWorkspace(workspace, notifications),
    0,
  );
}

/**
 * "Needs You" for a workspace: unread notifications or a pending feed item
 * (approval/question) pointing at it. Feed items carry workspaceID/surfaceID
 * when the server resolves them.
 */
export function workspaceNeedsYou(
  workspace: Workspace,
  notifications: CmuxNotification[],
  feedItems: FeedItem[],
): boolean {
  if (unreadCountForWorkspace(workspace, notifications) > 0) return true;
  return feedItems.some(
    (item) =>
      (Boolean(item.workspaceID) && item.workspaceID === workspace.uuid) ||
      (Boolean(item.surfaceID) && item.surfaceID === workspace.surfaceUuid),
  );
}

/** "Needs You" for a session group (any pane matches). */
export function groupNeedsYou(
  group: WorkspaceSessionGroup,
  notifications: CmuxNotification[],
  feedItems: FeedItem[],
): boolean {
  return group.workspaces.some((workspace) =>
    workspaceNeedsYou(workspace, notifications, feedItems),
  );
}

// --- session filter (iOS SessionFilter parity) ---------------------------------

/** Mirrors SessionFilter (iOS Models/SessionStateModels.swift). */
export type SessionFilter = "all" | "needsYou" | "auto";

/** Mirrors SessionFilter.allCases with its labels ("All" / "Needs You" / "Auto"). */
export const SESSION_FILTERS: ReadonlyArray<{ id: SessionFilter; label: string }> = [
  { id: "all", label: "All" },
  { id: "needsYou", label: "Needs You" },
  { id: "auto", label: "Auto" },
];

/**
 * Row data a filter needs beyond the group itself. iOS derives "needs you"
 * from log entries (latest action containing "human"); the web derives it
 * from unread notifications + pending feed items — the exact source of the
 * sidebar "Needs You" badge (see workspaceNeedsYou) — so the filter and the
 * badge can never disagree.
 */
export interface SessionFilterRowState {
  notifications: CmuxNotification[];
  feedItems: FeedItem[];
}

/**
 * Mirrors iOS `resolvedAutoMode.isEnabled`: `autoMode ?? (enabled ? .auto :
 * .off)`, enabled when the resolved mode is not .off.
 */
export function workspaceAutoEnabled(workspace: Workspace): boolean {
  return resolvedAutoMode(workspace) !== "off";
}

/**
 * Mirrors `sessionFilterIncludes(group)` (iOS Feature/HarnessFeature.swift):
 * - "all" → true
 * - "needsYou" → group state is .waiting (web parity: groupNeedsYou, the
 *   badge predicate)
 * - "auto" → any pane's resolved auto mode is enabled (iOS:
 *   `group.workspaces.contains { $0.resolvedAutoMode.isEnabled }`)
 */
export function groupMatchesFilter(
  group: WorkspaceSessionGroup,
  filter: SessionFilter,
  rowState: SessionFilterRowState,
): boolean {
  switch (filter) {
    case "all":
      return true;
    case "needsYou":
      return groupNeedsYou(group, rowState.notifications, rowState.feedItems);
    case "auto":
      return group.workspaces.some((workspace) => workspaceAutoEnabled(workspace));
  }
}

/**
 * Mirrors `visibleWorkspaceGroups` (iOS Feature/HarnessFeature.swift):
 * search AND filter, in that order.
 */
export function filterGroups(
  all: WorkspaceSessionGroup[],
  search: string,
  filter: SessionFilter,
  rowState: SessionFilterRowState,
): WorkspaceSessionGroup[] {
  return all.filter(
    (group) => groupMatchesFilter(group, filter, rowState) && groupMatchesSearch(group, search),
  );
}
