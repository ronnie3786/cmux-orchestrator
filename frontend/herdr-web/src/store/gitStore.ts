/** Pane-scoped Git workbench state. */

import { create } from "zustand";
import {
  gitStage,
  gitUnstage,
  paneGit,
  paneGitCommitDiff,
  paneGitCommitFiles,
  paneGitDiff,
  type GitCommit,
  type GitFile,
  type GitSection,
} from "../api/git";
import { ApiError } from "../api/client";
import { showToast } from "../lib/toast";

export interface GitSnapshot {
  branch: string;
  rootPath: string;
  detached: boolean;
  staged: GitFile[];
  unstaged: GitFile[];
  untracked: string[];
  commits: GitCommit[];
}

export interface CommitFilesEntry {
  files: GitFile[];
  loading: boolean;
  error: string | null;
}

export interface GitEntry {
  snapshot: GitSnapshot | null;
  noRepo: boolean;
  loading: boolean;
  /** A failed background refresh can coexist with the last good snapshot. */
  error: string | null;
  expandedCommitHash: string | null;
  commitFiles: Record<string, CommitFilesEntry>;
}

export type DiffSection = GitSection | "commit";

export interface DiffSheetState {
  paneId: string;
  file: string;
  section: DiffSection;
  commitHash: string | null;
  diff: string;
  /** The server capped this patch, so the visible diff is incomplete. */
  truncated: boolean;
  isLoading: boolean;
  error: string | null;
}

export const EMPTY_GIT_ENTRY: GitEntry = {
  snapshot: null,
  noRepo: false,
  loading: false,
  error: null,
  expandedCommitHash: null,
  commitFiles: {},
};

interface GitStoreState {
  byPane: Record<string, GitEntry>;
  diffSheet: DiffSheetState | null;
  load: (paneId: string, options?: { force?: boolean }) => Promise<void>;
  stage: (paneId: string, file: string) => Promise<void>;
  unstage: (paneId: string, file: string) => Promise<void>;
  diff: (paneId: string, file: string, section: GitSection) => void;
  toggleCommit: (paneId: string, hash: string, options?: { force?: boolean }) => void;
  commitDiff: (paneId: string, hash: string, file: string) => void;
  closeDiff: () => void;
}

const loadInFlight = new Map<string, Promise<void>>();

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

function isNoRepoError(error: unknown): boolean {
  return (
    error instanceof ApiError &&
    error.status === 404 &&
    error.code === "git_repository_not_found"
  );
}

function isRepositoryChangedError(error: unknown): boolean {
  return (
    error instanceof ApiError &&
    error.status === 409 &&
    error.code === "git_repository_changed"
  );
}

function looksLikeNoRepo(response: {
  ok: boolean;
  cwd?: string | null;
  root_path?: string | null;
  branch?: string | null;
}): boolean {
  const rootPath = response.cwd ?? response.root_path;
  return response.ok === false || (rootPath == null && (response.branch == null || response.branch === ""));
}

function entryFor(state: GitStoreState, paneId: string): GitEntry {
  return state.byPane[paneId] ?? EMPTY_GIT_ENTRY;
}

function withoutStaleInspectors(
  state: GitStoreState,
  paneId: string,
): Pick<GitStoreState, "byPane" | "diffSheet"> {
  const entry = entryFor(state, paneId);
  return {
    byPane: {
      ...state.byPane,
      [paneId]: {
        ...entry,
        expandedCommitHash: null,
        commitFiles: {},
      },
    },
    diffSheet: state.diffSheet?.paneId === paneId ? null : state.diffSheet,
  };
}

function sheetMatches(
  sheet: DiffSheetState | null,
  paneId: string,
  file: string,
  section: DiffSection,
  commitHash: string | null,
): sheet is DiffSheetState {
  return (
    sheet !== null &&
    sheet.paneId === paneId &&
    sheet.file === file &&
    sheet.section === section &&
    sheet.commitHash === commitHash
  );
}

export const useGitStore = create<GitStoreState>()((set, get) => ({
  byPane: {},
  diffSheet: null,

  load: (paneId, options) => {
    const pending = loadInFlight.get(paneId);
    if (pending !== undefined) {
      return options?.force === true
        ? pending.then(() => get().load(paneId))
        : pending;
    }

    const current = entryFor(get(), paneId);
    set({
      byPane: {
        ...get().byPane,
        [paneId]: {
          ...current,
          loading: true,
        },
      },
    });

    const request = paneGit(paneId)
      .then((response) => {
        const previous = entryFor(get(), paneId);
        const noRepo = looksLikeNoRepo(response);
        const rootPath = response.cwd ?? response.root_path ?? "";
        const repositoryChanged =
          previous.snapshot !== null && previous.snapshot.rootPath !== rootPath;
        const snapshot: GitSnapshot | null = noRepo
          ? null
          : {
              branch: response.branch ?? "",
              rootPath,
              detached:
                response.detached === true ||
                response.branch == null ||
                response.branch === "" ||
                response.branch === "HEAD",
              staged: response.staged ?? [],
              unstaged: response.unstaged ?? [],
              untracked: response.untracked ?? [],
              commits: response.commits ?? [],
            };
        set((state) => ({
          byPane: {
            ...state.byPane,
            [paneId]: {
              ...previous,
              snapshot,
              noRepo,
              loading: false,
              error: null,
              expandedCommitHash: repositoryChanged ? null : previous.expandedCommitHash,
              commitFiles: repositoryChanged ? {} : previous.commitFiles,
            },
          },
          diffSheet:
            repositoryChanged && state.diffSheet?.paneId === paneId
              ? null
              : state.diffSheet,
        }));
      })
      .catch((error: unknown) => {
        const previous = entryFor(get(), paneId);
        set({
          byPane: {
            ...get().byPane,
            [paneId]: isNoRepoError(error)
              ? {
                  ...previous,
                  snapshot: null,
                  noRepo: true,
                  loading: false,
                  error: null,
                }
              : {
                  ...previous,
                  noRepo: false,
                  loading: false,
                  error: errorMessage(error, "Couldn't load Git status"),
                },
          },
        });
      })
      .finally(() => {
        loadInFlight.delete(paneId);
      });

    loadInFlight.set(paneId, request);
    return request;
  },

  stage: async (paneId, file) => {
    const expectedRoot = entryFor(get(), paneId).snapshot?.rootPath ?? "";
    if (!expectedRoot.trim()) {
      showToast("Refreshing Git status before staging files");
      await get().load(paneId, { force: true });
      return;
    }
    try {
      await gitStage(paneId, file, expectedRoot);
      showToast(`Staged ${file}`);
      await get().load(paneId, { force: true });
    } catch (error) {
      showToast(errorMessage(error, "Couldn't stage file"));
      if (isRepositoryChangedError(error)) {
        await get().load(paneId, { force: true });
      }
    }
  },

  unstage: async (paneId, file) => {
    const expectedRoot = entryFor(get(), paneId).snapshot?.rootPath ?? "";
    if (!expectedRoot.trim()) {
      showToast("Refreshing Git status before unstaging files");
      await get().load(paneId, { force: true });
      return;
    }
    try {
      await gitUnstage(paneId, file, expectedRoot);
      showToast(`Unstaged ${file}`);
      await get().load(paneId, { force: true });
    } catch (error) {
      showToast(errorMessage(error, "Couldn't unstage file"));
      if (isRepositoryChangedError(error)) {
        await get().load(paneId, { force: true });
      }
    }
  },

  diff: (paneId, file, section) => {
    const expectedRoot = entryFor(get(), paneId).snapshot?.rootPath ?? "";
    if (!expectedRoot.trim()) {
      set(withoutStaleInspectors(get(), paneId));
      showToast("Refreshing Git status before loading diffs");
      void get().load(paneId, { force: true });
      return;
    }
    set({
      diffSheet: {
        paneId,
        file,
        section,
        commitHash: null,
        diff: "",
        truncated: false,
        isLoading: true,
        error: null,
      },
    });
    void paneGitDiff(paneId, file, section, expectedRoot)
      .then((response) => {
        const sheet = get().diffSheet;
        if (!sheetMatches(sheet, paneId, file, section, null)) return;
        set({
          diffSheet: {
            ...sheet,
            diff: response.diff ?? "",
            truncated: response.truncated === true,
            isLoading: false,
            error: null,
          },
        });
      })
      .catch((error: unknown) => {
        if (isRepositoryChangedError(error)) {
          set(withoutStaleInspectors(get(), paneId));
          showToast(errorMessage(error, "The pane's Git repository changed"));
          void get().load(paneId, { force: true });
          return;
        }
        const sheet = get().diffSheet;
        if (!sheetMatches(sheet, paneId, file, section, null)) return;
        set({
          diffSheet: {
            ...sheet,
            isLoading: false,
            error: errorMessage(error, "Couldn't load diff"),
          },
        });
      });
  },

  toggleCommit: (paneId, hash, options) => {
    const current = entryFor(get(), paneId);
    if (current.expandedCommitHash === hash && options?.force !== true) {
      set({
        byPane: {
          ...get().byPane,
          [paneId]: { ...current, expandedCommitHash: null },
        },
      });
      return;
    }

    const expectedRoot = current.snapshot?.rootPath ?? "";
    if (!expectedRoot.trim()) {
      set(withoutStaleInspectors(get(), paneId));
      showToast("Refreshing Git status before loading commit history");
      void get().load(paneId, { force: true });
      return;
    }

    const cached = current.commitFiles[hash];
    set({
      byPane: {
        ...get().byPane,
        [paneId]: {
          ...current,
          expandedCommitHash: hash,
          commitFiles: {
            ...current.commitFiles,
            [hash]:
              cached !== undefined && cached.error === null && options?.force !== true
                ? cached
                : { files: [], loading: true, error: null },
          },
        },
      },
    });

    if (cached !== undefined && cached.error === null && options?.force !== true) return;

    void paneGitCommitFiles(paneId, hash, expectedRoot)
      .then((response) => {
        const latest = entryFor(get(), paneId);
        set({
          byPane: {
            ...get().byPane,
            [paneId]: {
              ...latest,
              commitFiles: {
                ...latest.commitFiles,
                [hash]: { files: response.files ?? [], loading: false, error: null },
              },
            },
          },
        });
      })
      .catch((error: unknown) => {
        if (isRepositoryChangedError(error)) {
          set(withoutStaleInspectors(get(), paneId));
          showToast(errorMessage(error, "The pane's Git repository changed"));
          void get().load(paneId, { force: true });
          return;
        }
        const latest = entryFor(get(), paneId);
        set({
          byPane: {
            ...get().byPane,
            [paneId]: {
              ...latest,
              commitFiles: {
                ...latest.commitFiles,
                [hash]: {
                  files: [],
                  loading: false,
                  error: errorMessage(error, "Couldn't load commit files"),
                },
              },
            },
          },
        });
      });
  },

  commitDiff: (paneId, hash, file) => {
    const expectedRoot = entryFor(get(), paneId).snapshot?.rootPath ?? "";
    if (!expectedRoot.trim()) {
      set(withoutStaleInspectors(get(), paneId));
      showToast("Refreshing Git status before loading commit diffs");
      void get().load(paneId, { force: true });
      return;
    }
    set({
      diffSheet: {
        paneId,
        file,
        section: "commit",
        commitHash: hash,
        diff: "",
        truncated: false,
        isLoading: true,
        error: null,
      },
    });
    void paneGitCommitDiff(paneId, hash, file, expectedRoot)
      .then((response) => {
        const sheet = get().diffSheet;
        if (!sheetMatches(sheet, paneId, file, "commit", hash)) return;
        set({
          diffSheet: {
            ...sheet,
            diff: response.diff ?? "",
            truncated: response.truncated === true,
            isLoading: false,
            error: null,
          },
        });
      })
      .catch((error: unknown) => {
        if (isRepositoryChangedError(error)) {
          set(withoutStaleInspectors(get(), paneId));
          showToast(errorMessage(error, "The pane's Git repository changed"));
          void get().load(paneId, { force: true });
          return;
        }
        const sheet = get().diffSheet;
        if (!sheetMatches(sheet, paneId, file, "commit", hash)) return;
        set({
          diffSheet: {
            ...sheet,
            isLoading: false,
            error: errorMessage(error, "Couldn't load commit diff"),
          },
        });
      });
  },

  closeDiff: () => set({ diffSheet: null }),
}));
