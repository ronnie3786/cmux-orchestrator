import { useEffect } from "react";
import { parseHash, setHashRoute, subscribeHash } from "../lib/hashRoute";
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
 *   the data lands (the iOS pending-pane pattern).
 */
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
    if (route.workspaceId !== null) {
      store.repairSelection(route.workspaceId, route.paneId);
    } else if (store.selectedWorkspaceId === null) {
      store.repairSelection(null, null);
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

  // hash → selection (manual edits, back/forward).
  useEffect(() => {
    if (!token) return;
    return subscribeHash(() => {
      const route = parseHash(window.location.hash);
      if (route.workspaceId === null) return;
      useWorkspacesStore.getState().repairSelection(route.workspaceId, route.paneId);
    });
  }, [token]);
}
