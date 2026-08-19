/**
 * Workspaces store.
 *
 * Holds the last GET /api/v1/workspaces snapshot. Data only flows in via
 * `refresh()`, which the global SSE stream arms (debounced) — refresh is
 * silent by contract: a failed refresh keeps the last good snapshot and
 * surfaces nothing.
 *
 * Selection (`selectedWorkspaceId` / `selectedPaneId`) is pruned against the
 * snapshot by `repairSelection`, which returns the corrected selection (used
 * by callers to fix URLs/state when a workspace or pane dies).
 */

import { create } from "zustand";
import { workspaces as fetchWorkspaces } from "../api/herdr";
import type { AgentStatus, Pane, WorkspacesResponse } from "../types/herdr";

export interface Selection {
  workspaceId: string | null;
  paneId: string | null;
}

interface WorkspacesStoreState {
  data: WorkspacesResponse | null;
  /** Epoch ms of the last successful refresh. */
  lastUpdated: number | null;
  refreshing: boolean;
  selectedWorkspaceId: string | null;
  selectedPaneId: string | null;

  /** Silent /workspaces refetch (never surfaces failures). */
  refresh: () => Promise<void>;
  /**
   * Prunes a selection against the current snapshot: dead pane id reselects
   * the workspace's first pane; dead workspace id reselects the first
   * workspace. Also stores the corrected selection and returns it.
   */
  repairSelection: (selectedWorkspaceId: string | null, selectedPaneId: string | null) => Selection;
}

// A refresh() fired while one is in flight re-arms EXACTLY ONE trailing
// refresh after the in-flight one settles (module-scoped — the store is a
// singleton). This keeps the eventStream "exactly one refresh on
// stream.reset" contract when the reset lands mid-flight.
let trailingRefreshArmed = false;

export const useWorkspacesStore = create<WorkspacesStoreState>()((set, get) => ({
  data: null,
  lastUpdated: null,
  refreshing: false,
  selectedWorkspaceId: null,
  selectedPaneId: null,

  refresh: async () => {
    if (get().refreshing) {
      trailingRefreshArmed = true;
      return;
    }
    set({ refreshing: true });
    try {
      const data = await fetchWorkspaces();
      set({ data, lastUpdated: Date.now() });
      // repairNavigation guard: a pane/workspace closed out from under us is
      // pruned against the fresh snapshot (the current selection is the
      // source of truth; the hash is kept in sync by the route hook).
      const { selectedWorkspaceId, selectedPaneId } = get();
      if (selectedWorkspaceId !== null || selectedPaneId !== null) {
        get().repairSelection(selectedWorkspaceId, selectedPaneId);
      }
    } catch {
      // Silent: keep the last good snapshot; the next event re-arms.
    } finally {
      const trailing = trailingRefreshArmed;
      trailingRefreshArmed = false;
      set({ refreshing: false });
      if (trailing) {
        void get().refresh();
      }
    }
  },

  repairSelection: (selectedWorkspaceId, selectedPaneId) => {
    const workspaces = get().data?.workspaces ?? [];
    let workspace = selectedWorkspaceId
      ? (workspaces.find((candidate) => candidate.workspace_id === selectedWorkspaceId) ?? null)
      : null;
    if (workspace === null) {
      workspace = workspaces[0] ?? null;
    }
    let pane: Pane | null = null;
    if (workspace !== null) {
      pane = selectedPaneId
        ? (workspace.panes.find((candidate) => candidate.pane_id === selectedPaneId) ?? null)
        : null;
      if (pane === null) {
        pane = workspace.panes[0] ?? null;
      }
    }
    const selection: Selection = {
      workspaceId: workspace?.workspace_id ?? null,
      paneId: pane?.pane_id ?? null,
    };
    set({ selectedWorkspaceId: selection.workspaceId, selectedPaneId: selection.paneId });
    return selection;
  },
}));

/** Attention rank: lower is more urgent (plan contract). */
const ATTENTION_RANK: Record<AgentStatus, number> = {
  blocked: 0,
  done: 1,
  working: 2,
  idle: 3,
  unknown: 4,
};

/**
 * All panes, ranked blocked → done → working → idle → unknown, ties broken by
 * `revision` descending (most recently changed pane first).
 */
export function attentionPanes(state: WorkspacesStoreState): Pane[] {
  const panes = (state.data?.workspaces ?? []).flatMap((workspace) => workspace.panes);
  return [...panes].sort((a, b) => {
    const rank = (ATTENTION_RANK[a.agent_status] ?? 4) - (ATTENTION_RANK[b.agent_status] ?? 4);
    if (rank !== 0) {
      return rank;
    }
    return b.revision - a.revision;
  });
}

/**
 * True once a live snapshot has loaded — i.e. the backend is reachable and
 * the UI may issue commands against panes. (Flagged interpretation: the plan
 * did not pin a more specific definition.)
 */
export function canControl(state: WorkspacesStoreState): boolean {
  return state.data !== null;
}
