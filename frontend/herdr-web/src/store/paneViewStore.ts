/**
 * Per-pane view-mode for non-Pi panes (P11-run-A): "terminal" | "git" | "skills".
 *
 * The default ("terminal") stays in App routing; a stored override wins.
 * Persisted per pane in localStorage under
 * `herdr-web.pane-view.<workspaceId>:<paneId>` — sibling of paneModeStore.
 */

import { create } from "zustand";
import type { Pane } from "../types/herdr";

export type PaneView = "terminal" | "git" | "skills";

const KEY_PREFIX = "herdr-web.pane-view.";

function storageKey(workspaceId: string, paneId: string): string {
  return `${KEY_PREFIX}${workspaceId}:${paneId}`;
}

function readFromStorage(workspaceId: string, paneId: string): PaneView | null {
  try {
    const value = localStorage.getItem(storageKey(workspaceId, paneId));
    return value === "terminal" || value === "git" || value === "skills" ? value : null;
  } catch {
    return null;
  }
}

function writeToStorage(workspaceId: string, paneId: string, view: PaneView): void {
  try {
    localStorage.setItem(storageKey(workspaceId, paneId), view);
  } catch {
    // Storage unavailable — the override just won't persist.
  }
}

interface PaneViewStoreState {
  /** In-memory override cache (paneId → view), seeded lazily from storage. */
  overrides: Record<string, PaneView>;
  /** Bumped on every setView so selectors re-evaluate (storage fallback). */
  version: number;
  /** The override for a pane, or null (default "terminal" applies). */
  viewFor: (pane: Pick<Pane, "pane_id" | "workspace_id">) => PaneView | null;
  setView: (workspaceId: string, paneId: string, view: PaneView) => void;
}

export const usePaneViewStore = create<PaneViewStoreState>()((set, get) => ({
  overrides: {},
  version: 0,

  viewFor: (pane) => {
    const cached = get().overrides[pane.pane_id];
    if (cached !== undefined) return cached;
    return readFromStorage(pane.workspace_id, pane.pane_id);
  },

  setView: (workspaceId, paneId, view) => {
    writeToStorage(workspaceId, paneId, view);
    set((state) => ({
      overrides: { ...state.overrides, [paneId]: view },
      version: state.version + 1,
    }));
  },
}));
