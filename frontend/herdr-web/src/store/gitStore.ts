/**
 * Workspace Git state (P11-run-A). Phase-1 harness-web gitStore ported and
 * re-pointed at the 9092 cmux-proxied routes (doc 02 §2).
 *
 * Per-workspace cache: the selected pane's workspace is bound by `load`;
 * `stage` / `unstage` / `diff` act on the bound workspace (Phase-1
 * `pollIndex` pattern). No auto-poll in this run — `load` + the
 * `Refresh Git` button drive refresh (flagged: Phase-1 polled every 10 s).
 */

import { create } from "zustand";
import {
  gitStage,
  gitUnstage,
  workspaceGit,
  workspaceGitDiff,
  type GitCommit,
  type GitFile,
  type GitSection,
} from "../api/git";
import { showToast } from "../lib/toast";

/** One successful /git snapshot for a workspace. */
export interface GitSnapshot {
  branch: string;
  rootPath: string;
  /** `detached` field from the server, or an empty branch (git detached HEAD). */
  detached: boolean;
  staged: GitFile[];
  unstaged: GitFile[];
  /** Bare paths (Phase-1 parity). */
  untracked: string[];
  commits: GitCommit[];
}

/** Cache entry per workspace. */
export interface GitEntry {
  /** null = no successful fetch yet (or the last fetch failed). */
  snapshot: GitSnapshot | null;
  /** Server reports the workspace has no git repository. */
  noRepo: boolean;
  loading: boolean;
  /** Server error message (fed to the "Git unavailable" card). */
  error: string | null;
}

/** Diff sheet state (Phase-1 `DiffSheetState` port). */
export interface DiffSheetState {
  file: string;
  section: GitSection;
  diff: string;
  isLoading: boolean;
  error: string | null;
}

export const EMPTY_GIT_ENTRY: GitEntry = {
  snapshot: null,
  noRepo: false,
  loading: false,
  error: null,
};

interface GitStoreState {
  byWorkspace: Record<string, GitEntry>;
  diffSheet: DiffSheetState | null;
  /** Fetch /git for the workspace and bind the store to it. */
  load: (workspaceId: string) => Promise<void>;
  /** POST git/stage on the bound workspace, toast `Staged <file>`, reload. */
  stage: (file: string) => Promise<void>;
  /** POST git/unstage on the bound workspace, toast `Unstaged <file>`, reload. */
  unstage: (file: string) => Promise<void>;
  /** Open the diff sheet and fetch the single-section diff. */
  diff: (file: string, section: GitSection) => void;
  closeDiff: () => void;
}

/** Workspace the store is bound to (set by every `load`). */
let boundWorkspaceId: string | null = null;
const loadInFlight: Record<string, boolean> = {};

function errorMessage(err: unknown, fallback: string): string {
  return err instanceof Error && err.message ? err.message : fallback;
}

/** ok:false, or no repo root AND no branch → the workspace is not a repo. */
function looksLikeNoRepo(res: {
  ok: boolean;
  root_path?: string | null;
  branch?: string | null;
}): boolean {
  return res.ok === false || (res.root_path == null && (res.branch == null || res.branch === ""));
}

export const useGitStore = create<GitStoreState>()((set, get) => ({
  byWorkspace: {},
  diffSheet: null,

  load: (workspaceId) => {
    if (boundWorkspaceId !== workspaceId) {
      boundWorkspaceId = workspaceId;
      // A stale sheet from another workspace would show the wrong diff.
      set({ diffSheet: null });
    }
    if (loadInFlight[workspaceId]) return Promise.resolve();
    const entry = get().byWorkspace[workspaceId] ?? EMPTY_GIT_ENTRY;
    loadInFlight[workspaceId] = true;
    // Loading spinner only on the first fetch (Phase-1 `isLoadingGit` parity).
    set({
      byWorkspace: {
        ...get().byWorkspace,
        [workspaceId]: { ...entry, loading: entry.snapshot === null && entry.error === null },
      },
    });
    return workspaceGit(workspaceId)
      .then((res) => {
        if (boundWorkspaceId !== workspaceId) return;
        set({
          byWorkspace: {
            ...get().byWorkspace,
            [workspaceId]: {
              snapshot: {
                branch: res.branch ?? "",
                rootPath: res.root_path ?? "",
                detached: res.detached === true || res.branch == null || res.branch === "",
                staged: res.staged ?? [],
                unstaged: res.unstaged ?? [],
                untracked: res.untracked ?? [],
                commits: res.commits ?? [],
              },
              noRepo: looksLikeNoRepo(res),
              loading: false,
              error: null,
            },
          },
        });
      })
      .catch((err) => {
        if (boundWorkspaceId !== workspaceId) return;
        set({
          byWorkspace: {
            ...get().byWorkspace,
            [workspaceId]: {
              snapshot: null,
              noRepo: false,
              loading: false,
              error: errorMessage(err, "Couldn't load git status"),
            },
          },
        });
      })
      .finally(() => {
        loadInFlight[workspaceId] = false;
      });
  },

  stage: (file) => {
    const workspaceId = boundWorkspaceId;
    if (workspaceId === null) return Promise.resolve();
    return gitStage(workspaceId, file)
      .then(() => {
        showToast(`Staged ${file}`);
        return get().load(workspaceId);
      })
      .catch((err) => {
        showToast(errorMessage(err, "Couldn't stage file"));
      });
  },

  unstage: (file) => {
    const workspaceId = boundWorkspaceId;
    if (workspaceId === null) return Promise.resolve();
    return gitUnstage(workspaceId, file)
      .then(() => {
        showToast(`Unstaged ${file}`);
        return get().load(workspaceId);
      })
      .catch((err) => {
        showToast(errorMessage(err, "Couldn't unstage file"));
      });
  },

  diff: (file, section) => {
    const workspaceId = boundWorkspaceId;
    if (workspaceId === null) return;
    // The sheet opens immediately with isLoading: true (Phase-1 parity).
    set({ diffSheet: { file, section, diff: "", isLoading: true, error: null } });
    void workspaceGitDiff(workspaceId, file, section)
      .then((res) => {
        const sheet = get().diffSheet;
        // Ignore stale responses for a different file/section (Phase-1 guard).
        if (sheet === null || sheet.file !== file || sheet.section !== section) return;
        set({ diffSheet: { ...sheet, diff: res.diff ?? "", isLoading: false, error: null } });
      })
      .catch((err) => {
        const sheet = get().diffSheet;
        if (sheet === null || sheet.file !== file || sheet.section !== section) return;
        set({
          diffSheet: { ...sheet, isLoading: false, error: errorMessage(err, "Couldn't load diff") },
        });
      });
  },

  closeDiff: () => set({ diffSheet: null }),
}));
