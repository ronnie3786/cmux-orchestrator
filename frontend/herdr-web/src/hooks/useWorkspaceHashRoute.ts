import { useEffect } from "react";
import {
  parseHash,
  setHashRoute,
  subscribeHash,
  workspaceFromPaneId,
  type HashRoute,
} from "../lib/hashRoute";
import { useWorkspacesStore } from "../store/workspacesStore";

/**
 * `#ws=<id>&pane=<id>` route wiring (Phase-1 useSessionHashRoute pattern).
 *
 * - selection → hash: echo-guarded history.replaceState; unknown params
 *   (#deck=1, …) are carried through untouched.
 * - hash → selection: deep links and manual edits are repaired against the
 *   snapshot — repairSelection prunes dead ids and reselects the first
 *   workspace when the selection vanished (iOS repairNavigation parity).
 *   A `ws` id that arrived before the first snapshot is re-applied once
 *   the data lands (the iOS pending-pane pattern). A pane-only deep link
 *   (`#pane=wB:p1`, no `#ws=`) resolves the workspace from the pane id
 *   prefix the same way, so the pending-pane queue works without a ws id.
 */

/** The repairSelection arguments a hash route implies ("none" = no-op). */
export type RouteRepair =
  | { workspaceId: string | null; paneId: string | null }
  | "none";

/**
 * Pure route guard (the data→repair and hashchange effects share it):
 * `#ws=` wins; a pane-only `#pane=` resolves its workspace from the pane id
 * prefix (workspaceFromPaneId — null keeps the repairSelection first-
 * workspace fallback for unresolvable ids); with no ids in the URL a
 * missing selection is repaired to the first workspace.
 */
export function repairArgsForRoute(
  route: HashRoute,
  selectedWorkspaceId: string | null,
): RouteRepair {
  if (route.workspaceId !== null) {
    return { workspaceId: route.workspaceId, paneId: route.paneId };
  }
  if (route.paneId !== null) {
    return { workspaceId: workspaceFromPaneId(route.paneId), paneId: route.paneId };
  }
  return selectedWorkspaceId === null ? { workspaceId: null, paneId: null } : "none";
}

export function useWorkspaceHashRoute(token: string): void {
  const data = useWorkspacesStore((state) => state.data);
  const selectedWorkspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const selectedPaneId = useWorkspacesStore((state) => state.selectedPaneId);

  // data → repair selection from the hash (pending deep link). MUST be
  // declared before the selection→hash echo below: when the first snapshot
  // lands, the repair runs first in the effect phase, so the echo sees the
  // corrected selection through getState() instead of clobbering the URL.
  useEffect(() => {
    if (!token || data === null) return;
    const route = parseHash(window.location.hash);
    const store = useWorkspacesStore.getState();
    const args = repairArgsForRoute(route, store.selectedWorkspaceId);
    if (args !== "none") {
      store.repairSelection(args.workspaceId, args.paneId);
    }
  }, [token, data]);

  // selection → hash. Reads the store fresh (getState) because on the
  // snapshot-landing commit the repair above has already updated the store
  // while the hook closure still holds the pre-repair values. While no
  // snapshot has loaded yet, a null selection means "pending deep link" —
  // the URL's ws/pane must be preserved verbatim (writing them through the
  // hook's nulls would clobber the deep link before the repair can read it).
  useEffect(() => {
    if (!token) return;
    const store = useWorkspacesStore.getState();
    if (store.selectedWorkspaceId === null && store.selectedPaneId === null && store.data === null) {
      return;
    }
    setHashRoute({
      workspaceId: store.selectedWorkspaceId,
      paneId: store.selectedPaneId,
      params: parseHash(window.location.hash).params,
    });
  }, [token, selectedWorkspaceId, selectedPaneId, data]);

  // hash → selection (manual edits, back/forward) — same guard as the
  // data→repair effect, so a manually typed `#pane=wB:p1` also resolves.
  useEffect(() => {
    if (!token) return;
    return subscribeHash(() => {
      const store = useWorkspacesStore.getState();
      const args = repairArgsForRoute(parseHash(window.location.hash), store.selectedWorkspaceId);
      if (args !== "none") {
        store.repairSelection(args.workspaceId, args.paneId);
      }
    });
  }, [token]);
}
