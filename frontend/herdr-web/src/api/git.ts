/**
 * Workspace Git endpoints (P11-run-A), cmux-proxied (doc 02 §2). All use
 * the 30 s tool timeout (doc 01 §5: "15 s default · 30 s git/skills/
 * files/jira").
 *
 * File-entry field names mirror the Phase-1 harness-web types
 * (`GitFile {status, file}`, `untracked: string[]`); the live probe
 * returned empty arrays, so the non-empty shape is unverified.
 */

import { apiRequest } from "./client";

const GIT_TIMEOUT_MS = 30_000;

/** File row in the staged/unstaged sections. */
export interface GitFile {
  status: string;
  file: string;
}

/** Recent commit row. */
export interface GitCommit {
  hash: string;
  message: string;
}

/** GET /api/v1/workspaces/{id}/git (live probe: empty arrays for a clean repo). */
export interface WorkspaceGitResponse {
  ok: boolean;
  workspace_id: string;
  root_path?: string | null;
  branch?: string | null;
  /** Absent in the live probe; an empty branch is also treated as detached. */
  detached?: boolean | null;
  staged: GitFile[];
  unstaged: GitFile[];
  /** Untracked rows are bare paths (Phase-1 parity). */
  untracked: string[];
  commits: GitCommit[];
  error?: string | null;
}

export function workspaceGit(workspaceId: string, signal?: AbortSignal): Promise<WorkspaceGitResponse> {
  return apiRequest<WorkspaceGitResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/git`,
    { signal },
    GIT_TIMEOUT_MS,
  );
}

export type GitSection = "staged" | "unstaged";

/** GET /api/v1/workspaces/{id}/git/diff?file&section (live-verified). */
export interface WorkspaceGitDiffResponse {
  ok: boolean;
  workspace_id: string;
  file: string;
  section: GitSection;
  diff: string;
  truncated?: boolean | null;
}

export function workspaceGitDiff(
  workspaceId: string,
  file: string,
  section: GitSection,
  signal?: AbortSignal,
): Promise<WorkspaceGitDiffResponse> {
  const params = new URLSearchParams({ file, section });
  return apiRequest<WorkspaceGitDiffResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/git/diff?${params.toString()}`,
    { signal },
    GIT_TIMEOUT_MS,
  );
}

/** POST /api/v1/workspaces/{id}/git/stage | unstage body. */
export interface GitMutateResponse {
  ok: boolean;
  error?: string | null;
}

export function gitStage(
  workspaceId: string,
  file: string,
  signal?: AbortSignal,
): Promise<GitMutateResponse> {
  return apiRequest<GitMutateResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/git/stage`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ file }),
      signal,
    },
    GIT_TIMEOUT_MS,
  );
}

export function gitUnstage(
  workspaceId: string,
  file: string,
  signal?: AbortSignal,
): Promise<GitMutateResponse> {
  return apiRequest<GitMutateResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/git/unstage`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ file }),
      signal,
    },
    GIT_TIMEOUT_MS,
  );
}
