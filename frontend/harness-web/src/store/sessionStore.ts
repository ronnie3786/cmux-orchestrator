import { create } from "zustand";
import { getScreen } from "../api/endpoints";
import { workspaceID } from "../lib/workspaceGroups";
import { useWorkspacesStore } from "./workspacesStore";

/**
 * Terminal screen state for the selected session.
 *
 * Polling mirrors the iOS app's `.screenTick` effect (HarnessFeatureEffects):
 * 500 ms cadence, 200 lines per poll (the iOS line count; the server caps at
 * 500), an in-flight guard that skips ticks instead of stacking requests,
 * and an immediate catch-up poll when the tab becomes visible again.
 */
export const SCREEN_POLL_MS = 500;
export const SCREEN_LINES = 200;

interface SessionState {
  /** Raw screen text for the selected session (ANSI escapes included). */
  screenText: string | null;
  /** Line count reported by the last screen response. */
  screenLines: number;
  /** Epoch ms of the last successful screen poll. */
  lastScreenAt: number | null;
  /**
   * Error message from the latest failed screen poll (null when healthy).
   * The terminal panel shows a retry strip while this is set (Phase 7: every
   * data surface gets a retry path).
   */
  screenError: string | null;
  isPolling: boolean;
  /**
   * Feed request IDs with a reply currently in flight. Held here (not in
   * component state) so Phase 2b can dedupe reply sends across re-renders —
   * the same guard the iOS reducer applies via `replyToFeed`.
   */
  feedReplyPendingIDs: Set<string>;

  /** Resets the screen state, fires one immediate poll, then ticks every 500 ms. */
  startPolling: () => void;
  stopPolling: () => void;
  /** One-off poll (used for the visibility catch-up). */
  pollNow: () => Promise<void>;

  /**
   * Marks a feed reply as in flight. Returns false when the ID is already
   * pending, so callers can skip the duplicate send.
   */
  beginFeedReply: (requestID: string) => boolean;
  finishFeedReply: (requestID: string) => void;
}

let intervalID: number | null = null;
let inFlight = false;

async function pollOnce(): Promise<void> {
  // Skip the tick when the previous poll is still in flight (iOS
  // `.cancellable(id:cancelInFlight: true)` behavior).
  if (inFlight) return;
  // Pause while the tab is hidden; the visibility listener re-polls on wake.
  if (document.hidden) return;

  const selectedID = useWorkspacesStore.getState().selectedWorkspaceID;
  if (!selectedID) return;
  const workspace = useWorkspacesStore
    .getState()
    .workspaces.find((w) => workspaceID(w) === selectedID);
  if (!workspace) return;

  inFlight = true;
  try {
    const res = await getScreen(workspace.index, SCREEN_LINES);
    // Drop the result if the selection changed mid-flight.
    if (useWorkspacesStore.getState().selectedWorkspaceID !== selectedID) return;
    useSessionStore.setState({
      screenText: res.screen,
      screenLines: res.lines ?? SCREEN_LINES,
      lastScreenAt: Date.now(),
      screenError: null,
    });
  } catch (error) {
    // The screen is a convenience signal — a failed tick waits for the next
    // one — but the failure is surfaced (retry strip) instead of swallowed.
    const message = error instanceof Error ? error.message : "Screen poll failed";
    if (useSessionStore.getState().screenError !== message) {
      useSessionStore.setState({ screenError: message });
    }
  } finally {
    inFlight = false;
  }
}

export const useSessionStore = create<SessionState>()((set) => ({
  screenText: null,
  screenLines: 0,
  lastScreenAt: null,
  screenError: null,
  isPolling: false,
  feedReplyPendingIDs: new Set<string>(),

  startPolling: () => {
    if (intervalID !== null) {
      window.clearInterval(intervalID);
      intervalID = null;
    }
    // A newly selected session starts with no screen (iOS clears
    // fullScreenText on selection), then the immediate tick fills it in.
    set({ screenText: null, screenLines: 0, lastScreenAt: null, screenError: null, isPolling: true });
    void pollOnce();
    intervalID = window.setInterval(() => {
      void pollOnce();
    }, SCREEN_POLL_MS);
  },

  stopPolling: () => {
    if (intervalID !== null) {
      window.clearInterval(intervalID);
      intervalID = null;
    }
    set({ isPolling: false });
  },

  pollNow: async () => {
    await pollOnce();
  },

  beginFeedReply: (requestID: string) => {
    const current = useSessionStore.getState().feedReplyPendingIDs;
    if (current.has(requestID)) return false;
    const next = new Set(current);
    next.add(requestID);
    set({ feedReplyPendingIDs: next });
    return true;
  },

  finishFeedReply: (requestID: string) => {
    const current = useSessionStore.getState().feedReplyPendingIDs;
    if (!current.has(requestID)) return;
    const next = new Set(current);
    next.delete(requestID);
    set({ feedReplyPendingIDs: next });
  },
}));

// Catch-up poll when the tab becomes visible again (the 500 ms interval keeps
// running in the background, but ticks are skipped while hidden).
if (typeof document !== "undefined") {
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && useSessionStore.getState().isPolling) {
      void useSessionStore.getState().pollNow();
    }
  });
}
