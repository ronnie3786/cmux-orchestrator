import { useEffect, useRef } from "react";
import { parseSessionHash, serializeSessionHash } from "../lib/hashRoute";
import { workspaceID } from "../lib/workspaceGroups";
import { useWorkspacesStore } from "../store/workspacesStore";

/**
 * `#/sessions/<id>` deep links (Phase 7).
 *
 * - After the first status load, a hash session id selects that row when it
 *   is a known workspace row; an unknown id falls back to no selection
 *   (iOS `pendingPushApproval` likewise never force-selects).
 * - Selection changes rewrite the hash with `history.replaceState` (no
 *   history spam) and skip when the hash already matches (echo guard).
 * - `hashchange`/`popstate` re-select from the URL. Ids that arrive before
 *   the first status load are held in a ref and applied once it lands (the
 *   iOS pending-selection pattern).
 *
 * The `#token=…` bootstrap fragment is a different shape and is handled by
 * App's token effect; the two never collide (parseSessionHash only matches
 * `#/sessions/…`).
 */
export function useSessionHashRoute(): void {
  const selectedWorkspaceID = useWorkspacesStore((s) => s.selectedWorkspaceID);
  const hasReceivedStatus = useWorkspacesStore((s) => s.hasReceivedStatus);
  const pendingHashRef = useRef<string | null>(null);

  // Selection → hash (echo-guarded replaceState).
  useEffect(() => {
    if (!hasReceivedStatus) return;
    const target = serializeSessionHash(selectedWorkspaceID);
    const current = window.location.hash;
    if (current === target) return;
    const base = window.location.pathname + window.location.search;
    window.history.replaceState(null, "", base + target);
  }, [selectedWorkspaceID, hasReceivedStatus]);

  // URL → selection (manual hash edits, popstate, initial load).
  useEffect(() => {
    const clearSelection = () => {
      // Mirrors applyStatus's stale-selection clear (the store has no
      // deselect action; selection is otherwise only set via selectWorkspace).
      useWorkspacesStore.setState({ selectedGroupID: null, selectedWorkspaceID: null });
    };
    const apply = (rawHash: string) => {
      const store = useWorkspacesStore.getState();
      const id = parseSessionHash(rawHash);
      if (id === null) {
        if (store.selectedWorkspaceID !== null) clearSelection();
        return;
      }
      if (!store.hasReceivedStatus) {
        pendingHashRef.current = id;
        return;
      }
      const known = store.workspaces.some((workspace) => workspaceID(workspace) === id);
      if (known) {
        store.selectWorkspace(id);
      } else if (store.selectedWorkspaceID !== null) {
        // Unknown id → no selection (plan: fall back to nothing; the
        // selection → hash effect then clears the stale hash).
        clearSelection();
      }
    };
    apply(window.location.hash);
    const onHashChange = () => apply(window.location.hash);
    window.addEventListener("hashchange", onHashChange);
    window.addEventListener("popstate", onHashChange);
    return () => {
      window.removeEventListener("hashchange", onHashChange);
      window.removeEventListener("popstate", onHashChange);
    };
  }, []);

  // Apply a hash id that arrived before the first status load.
  useEffect(() => {
    if (!hasReceivedStatus) return;
    const pending = pendingHashRef.current;
    pendingHashRef.current = null;
    if (pending === null) return;
    const store = useWorkspacesStore.getState();
    const known = store.workspaces.some((workspace) => workspaceID(workspace) === pending);
    if (known) store.selectWorkspace(pending);
  }, [hasReceivedStatus]);
}
