/**
 * Pane-scoped Git endpoints. A pane owns its working directory, so the server
 * resolves the repository from the pane id instead of accepting a filesystem
 * path from the browser.
 */

import { apiRequest } from "./client";

const GIT_TIMEOUT_MS = 30_000;

export interface GitFile {
  status: string;
  file: string;
}

export interface GitCommit {
  hash: string;
  message: string;
}

export interface PaneGitResponse {
  ok: boolean;
  pane_id?: string;
  /** Current servers expose `cwd`; `root_path` keeps the client tolerant of older builds. */
  cwd?: string | null;
  root_path?: string | null;
  branch?: string | null;
  detached?: boolean | null;
  staged: GitFile[];
  unstaged: GitFile[];
  untracked: string[];
  commits: GitCommit[];
}

export function paneGit(paneId: string, signal?: AbortSignal): Promise<PaneGitResponse> {
  return apiRequest<PaneGitResponse>(
    `/panes/${encodeURIComponent(paneId)}/git`,
    { signal },
    GIT_TIMEOUT_MS,
  );
}

export type GitSection = "staged" | "unstaged" | "untracked";

export interface PaneGitDiffResponse {
  ok: boolean;
  pane_id?: string;
  file: string;
  section: GitSection;
  diff: string;
  truncated?: boolean | null;
}

export function paneGitDiff(
  paneId: string,
  file: string,
  section: GitSection,
  expectedRoot: string,
  signal?: AbortSignal,
): Promise<PaneGitDiffResponse> {
  const params = new URLSearchParams({ file, section, expected_root: expectedRoot });
  return apiRequest<PaneGitDiffResponse>(
    `/panes/${encodeURIComponent(paneId)}/git/diff?${params.toString()}`,
    { signal },
    GIT_TIMEOUT_MS,
  );
}

export interface GitMutateResponse {
  ok: boolean;
  pane_id?: string;
  file?: string;
}

export function gitStage(
  paneId: string,
  file: string,
  expectedRoot: string,
  signal?: AbortSignal,
): Promise<GitMutateResponse> {
  return apiRequest<GitMutateResponse>(
    `/panes/${encodeURIComponent(paneId)}/git/stage`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ file, expected_root: expectedRoot }),
      signal,
    },
    GIT_TIMEOUT_MS,
  );
}

export function gitUnstage(
  paneId: string,
  file: string,
  expectedRoot: string,
  signal?: AbortSignal,
): Promise<GitMutateResponse> {
  return apiRequest<GitMutateResponse>(
    `/panes/${encodeURIComponent(paneId)}/git/unstage`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ file, expected_root: expectedRoot }),
      signal,
    },
    GIT_TIMEOUT_MS,
  );
}

export interface PaneGitCommitFilesResponse {
  ok: boolean;
  pane_id?: string;
  hash?: string;
  files: GitFile[];
}

export function paneGitCommitFiles(
  paneId: string,
  hash: string,
  expectedRoot: string,
  signal?: AbortSignal,
): Promise<PaneGitCommitFilesResponse> {
  const params = new URLSearchParams({ hash, expected_root: expectedRoot });
  return apiRequest<PaneGitCommitFilesResponse>(
    `/panes/${encodeURIComponent(paneId)}/git/commit-files?${params.toString()}`,
    { signal },
    GIT_TIMEOUT_MS,
  );
}

export interface PaneGitCommitDiffResponse {
  ok: boolean;
  pane_id?: string;
  hash?: string;
  file?: string;
  diff: string;
  truncated?: boolean | null;
}

export function paneGitCommitDiff(
  paneId: string,
  hash: string,
  file: string,
  expectedRoot: string,
  signal?: AbortSignal,
): Promise<PaneGitCommitDiffResponse> {
  const params = new URLSearchParams({ hash, file, expected_root: expectedRoot });
  return apiRequest<PaneGitCommitDiffResponse>(
    `/panes/${encodeURIComponent(paneId)}/git/commit-diff?${params.toString()}`,
    { signal },
    GIT_TIMEOUT_MS,
  );
}
