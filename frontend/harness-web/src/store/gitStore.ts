import { create } from "zustand";
import {
  getGitDiff,
  getGitStatus,
  gitStage,
  gitUnstage,
  getPRComments,
} from "../api/endpoints";
import type { GitDiffSection, GitStatus, GitHubPRCommentsResponse } from "../api/types";
import { useConnectionStore } from "./connectionStore";
import { useWorkspacesStore } from "./workspacesStore";

/**
 * Git tab state for the selected workspace.
 *
 * Mirrors the iOS app's `HarnessFeatureGitReducer` + `gitPollingEffect`:
 * 10 s status poll (iOS `gitPollingEffect` cadence) that only runs while the
 * Git tab is active AND on the Status segment; stage/unstage fire an
 * immediate tick (iOS `.gitTick` after a successful stage/unstage); PR
 * comments load on demand (iOS `.loadPRComments`, no timer) with the
 * include-resolved toggle re-loading.
 */
export const GIT_POLL_MS = 10_000;

/** iOS `GitDetailSegment`. */
export type GitSegment = "status" | "prComments";

/** iOS `DiffSheet` state. */
export interface DiffSheetState {
  file: string;
  section: GitDiffSection;
  diff: string;
  isLoading: boolean;
  error: string | null;
}

interface GitStoreState {
  gitSegment: GitSegment;
  gitStatus: GitStatus | null;
  gitError: string | null;
  isLoadingGit: boolean;
  includeResolved: boolean;
  prComments: GitHubPRCommentsResponse | null;
  prCommentsError: string | null;
  isLoadingPRComments: boolean;
  diffSheet: DiffSheetState | null;

  /** iOS `.gitSegmentChanged` — the detail view's effect reacts to the change. */
  setSegment: (segment: GitSegment) => void;
  /** iOS `gitPollingEffect` for the current workspace: immediate tick + 10 s interval. */
  startStatusPolling: (index: number) => void;
  /** Stops the 10 s interval (tab switch / segment change away from Status). */
  stopStatusPolling: () => void;
  /** iOS `.gitTick`. */
  pollNow: () => Promise<void>;
  /** iOS `.stageFile` — stage, then refresh status; failure → shared error banner. */
  stageFile: (index: number, file: string) => Promise<void>;
  /** iOS `.unstageFile`. */
  unstageFile: (index: number, file: string) => Promise<void>;
  /** iOS `.requestDiff` — opens the diff sheet and fetches the single-section diff. */
  requestDiff: (index: number, file: string, section: GitDiffSection) => void;
  /** iOS `.closeDiff`. */
  closeDiff: () => void;
  /** iOS `.loadPRComments` for the given workspace index. */
  loadPRComments: (index: number) => void;
  /** iOS `.setPRCommentsIncludeResolved` — no-op when unchanged, else reload. */
  setIncludeResolved: (includeResolved: boolean) => void;
  /** iOS `.workspaceSelected` git reset (new session selection). */
  resetForSelection: () => void;
  /** iOS `.selectWorkspacePane` git reset (pane switch keeps segment/toggle). */
  resetPane: () => void;
}

let intervalID: number | null = null;
let gitInFlight = false;
let prInFlight = false;
/** Index of the workspace the Git tab is bound to (set by every entry point). */
let pollIndex: number | null = null;

function isTabVisible(): boolean {
  return typeof document === "undefined" || !document.hidden;
}

/** iOS `.gitTick` fetch, with the web in-flight + visibility guards. */
async function tickGitStatus(index?: number): Promise<void> {
  if (gitInFlight) return;
  if (!isTabVisible()) return;
  const target = index ?? pollIndex;
  if (target === null) return;
  // Drop the result if the selection changed mid-flight (iOS
  // `.gitSucceeded(workspaceID:)` guard).
  const selectedID = useWorkspacesStore.getState().selectedWorkspaceID;

  gitInFlight = true;
  // iOS: `state.isLoadingGit = state.gitStatus == nil` (first load only).
  if (useGitStore.getState().gitStatus === null) {
    useGitStore.setState({ isLoadingGit: true });
  }
  try {
    const status = await getGitStatus(target);
    if (useWorkspacesStore.getState().selectedWorkspaceID !== selectedID) return;
    useGitStore.setState({ gitStatus: status, gitError: null, isLoadingGit: false });
  } catch (err) {
    if (useWorkspacesStore.getState().selectedWorkspaceID !== selectedID) return;
    useGitStore.setState({
      gitError: err instanceof Error ? err.message : "Couldn't load git status",
      isLoadingGit: false,
    });
  } finally {
    gitInFlight = false;
  }
}

export const useGitStore = create<GitStoreState>()((set, get) => ({
  gitSegment: "status",
  gitStatus: null,
  gitError: null,
  isLoadingGit: false,
  includeResolved: false,
  prComments: null,
  prCommentsError: null,
  isLoadingPRComments: false,
  diffSheet: null,

  setSegment: (segment) => set({ gitSegment: segment }),

  startStatusPolling: (index) => {
    pollIndex = index;
    if (intervalID !== null) {
      if (typeof window !== "undefined") {
        window.clearInterval(intervalID);
      }
      intervalID = null;
    }
    void tickGitStatus();
    if (typeof window !== "undefined") {
      intervalID = window.setInterval(() => {
        void tickGitStatus();
      }, GIT_POLL_MS);
    }
  },

  stopStatusPolling: () => {
    if (intervalID !== null) {
      if (typeof window !== "undefined") {
        window.clearInterval(intervalID);
      }
      intervalID = null;
    }
  },

  pollNow: async () => {
    await tickGitStatus();
  },

  stageFile: async (index, file) => {
    try {
      await gitStage({ index, file });
      // iOS `.stageFile` success → `.gitTick` (also clears any stale error).
      useConnectionStore.getState().clearError();
      await tickGitStatus(index);
    } catch (err) {
      // iOS: `.requestFailed` → shared error banner.
      useConnectionStore.setState({
        errorMessage: err instanceof Error ? err.message : "Couldn't stage file",
      });
    }
  },

  unstageFile: async (index, file) => {
    try {
      await gitUnstage({ index, file });
      useConnectionStore.getState().clearError();
      await tickGitStatus(index);
    } catch (err) {
      useConnectionStore.setState({
        errorMessage: err instanceof Error ? err.message : "Couldn't unstage file",
      });
    }
  },

  requestDiff: (index, file, section) => {
    // iOS `.requestDiff` opens the sheet immediately with isLoading: true.
    set({ diffSheet: { file, section, diff: "", isLoading: true, error: null } });
    void (async () => {
      try {
        const response = await getGitDiff({ index, file, section });
        const sheet = get().diffSheet;
        // iOS `.diffSucceeded(file:section:)` guard: ignore stale responses.
        if (!sheet || sheet.file !== file || sheet.section !== section) return;
        const diff = response.diff ?? "";
        set({
          diffSheet: { ...sheet, diff: diff === "" ? "(empty diff)" : diff, isLoading: false, error: null },
        });
      } catch (err) {
        const sheet = get().diffSheet;
        if (!sheet || sheet.file !== file || sheet.section !== section) return;
        set({
          diffSheet: {
            ...sheet,
            isLoading: false,
            error: err instanceof Error ? err.message : "Couldn't load diff",
          },
        });
      }
    })();
  },

  closeDiff: () => set({ diffSheet: null }),

  loadPRComments: (index) => {
    pollIndex = index;
    // iOS `.loadPRComments`: loading only while no response is shown yet.
    set({ isLoadingPRComments: get().prComments === null, prCommentsError: null });
    if (prInFlight) return;
    prInFlight = true;
    const includeResolved = get().includeResolved;
    const selectedID = useWorkspacesStore.getState().selectedWorkspaceID;
    void (async () => {
      try {
        const response = await getPRComments(index, includeResolved);
        if (useWorkspacesStore.getState().selectedWorkspaceID !== selectedID) return;
        set({ prComments: response, prCommentsError: null, isLoadingPRComments: false });
      } catch (err) {
        if (useWorkspacesStore.getState().selectedWorkspaceID !== selectedID) return;
        set({
          prCommentsError: err instanceof Error ? err.message : "Couldn't load PR comments",
          isLoadingPRComments: false,
        });
      } finally {
        prInFlight = false;
      }
    })();
  },

  setIncludeResolved: (includeResolved) => {
    // iOS `.setPRCommentsIncludeResolved` guard: no-op when unchanged.
    if (get().includeResolved === includeResolved) return;
    set({ includeResolved, prCommentsError: null });
    if (pollIndex !== null) {
      get().loadPRComments(pollIndex);
    }
  },

  resetForSelection: () => {
    set({
      gitSegment: "status",
      gitStatus: null,
      gitError: null,
      isLoadingGit: false,
      includeResolved: false,
      prComments: null,
      prCommentsError: null,
      isLoadingPRComments: false,
      diffSheet: null,
    });
  },

  resetPane: () => {
    set({
      gitStatus: null,
      gitError: null,
      isLoadingGit: false,
      prComments: null,
      prCommentsError: null,
      isLoadingPRComments: false,
      diffSheet: null,
    });
  },
}));

// Catch-up poll when the tab becomes visible again (iOS pauses no polling,
// but the web mirrors sessionStore's hidden-tab behavior for parity).
if (typeof document !== "undefined") {
  document.addEventListener("visibilitychange", () => {
    if (isTabVisible() && intervalID !== null) {
      void tickGitStatus();
    }
  });
}
