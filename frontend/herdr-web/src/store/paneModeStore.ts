/**
 * Per-pane view-mode override (P10-run-B): "chat" | "terminal".
 *
 * The auto default stays in App routing (Pi-capable pane → Chat); a stored
 * override wins. Persisted per pane in localStorage under
 * `herdr-web.pane-mode.<workspaceId>:<paneId>`.
 */

import { create } from "zustand";
import type { Pane } from "../types/herdr";

export type PaneMode = "chat" | "terminal";

const KEY_PREFIX = "herdr-web.pane-mode.";

function storageKey(workspaceId: string, paneId: string): string {
  return `${KEY_PREFIX}${workspaceId}:${paneId}`;
}

function readFromStorage(workspaceId: string, paneId: string): PaneMode | null {
  try {
    const value = localStorage.getItem(storageKey(workspaceId, paneId));
    return value === "chat" || value === "terminal" ? value : null;
  } catch {
    return null;
  }
}

function writeToStorage(workspaceId: string, paneId: string, mode: PaneMode): void {
  try {
    localStorage.setItem(storageKey(workspaceId, paneId), mode);
  } catch {
    // Storage unavailable — the override just won't persist.
  }
}

interface PaneModeStoreState {
  /** In-memory override cache (paneId → mode), seeded lazily from storage. */
  overrides: Record<string, PaneMode>;
  /** Bumped on every setMode so selectors re-evaluate (storage fallback). */
  version: number;
  /** The override for a pane, or null (auto default applies). */
  modeFor: (pane: Pick<Pane, "pane_id" | "workspace_id">) => PaneMode | null;
  setMode: (workspaceId: string, paneId: string, mode: PaneMode) => void;
}

export const usePaneModeStore = create<PaneModeStoreState>()((set, get) => ({
  overrides: {},
  version: 0,

  modeFor: (pane) => {
    const cached = get().overrides[pane.pane_id];
    if (cached !== undefined) return cached;
    return readFromStorage(pane.workspace_id, pane.pane_id);
  },

  setMode: (workspaceId, paneId, mode) => {
    writeToStorage(workspaceId, paneId, mode);
    set((state) => ({
      overrides: { ...state.overrides, [paneId]: mode },
      version: state.version + 1,
    }));
  },
}));
