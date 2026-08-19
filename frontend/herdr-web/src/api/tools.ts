/**
 * Command Lens tool endpoints (P9-run-B): workspace file search, Jira, and
 * base64 attachment uploads. All proxied server-side to the cmux harness
 * (doc 02 §2). Response shapes live-verified against 9092.
 */

import { apiRequest } from "./client";

/**
 * Chunked base64 encoding (no DOM dependency beyond globalThis.btoa, which
 * exists in browsers and Node ≥16). Chunked because
 * `String.fromCharCode.apply` over a 20 MB array would blow the call stack.
 */
export function bytesToBase64(bytes: Uint8Array): string {
  const CHUNK = 0x8000;
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + CHUNK));
  }
  return btoa(binary);
}

export interface WorkspaceFileMatch {
  path: string;
}

/** GET /api/v1/workspaces/{id}/files (live-verified). */
export interface WorkspaceFilesResponse {
  ok: boolean;
  workspace_id: string;
  root_path?: string | null;
  query: string;
  files: WorkspaceFileMatch[];
  truncated?: boolean | null;
  limit?: number | null;
}

/** GET /api/v1/workspaces/{id}/files?q&limit=80. */
export function workspaceFiles(
  workspaceId: string,
  query: string,
  signal?: AbortSignal,
): Promise<WorkspaceFilesResponse> {
  const params = new URLSearchParams({ q: query, limit: "80" });
  return apiRequest<WorkspaceFilesResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/files?${params.toString()}`,
    { signal },
  );
}

/** Jira ticket shape (live-verified: snake_case, 9092 proxy). */
export interface JiraTicket {
  key: string;
  project_key?: string | null;
  title: string;
  status: string;
  priority: string;
  issue_type?: string | null;
  url: string;
}

/** GET /api/v1/jira/assigned?limit=50 (live-verified). */
export interface JiraAssignedResponse {
  ok: boolean;
  project?: string | null;
  projects?: string[] | null;
  site?: string | null;
  tickets: JiraTicket[];
}

/** GET /api/v1/jira/issue?q (live-verified; 502 envelope on upstream failure). */
export interface JiraIssueResponse {
  ok: boolean;
  site?: string | null;
  ticket?: JiraTicket | null;
  error?: string | null;
}

export function jiraAssigned(signal?: AbortSignal): Promise<JiraAssignedResponse> {
  return apiRequest<JiraAssignedResponse>("/jira/assigned?limit=50", { signal });
}

export function jiraIssue(query: string, signal?: AbortSignal): Promise<JiraIssueResponse> {
  const params = new URLSearchParams({ q: query });
  return apiRequest<JiraIssueResponse>(`/jira/issue?${params.toString()}`, { signal });
}

export interface UploadedAttachment {
  id: string;
  filename: string;
  original_filename: string;
  content_type: string;
  size: number;
  path: string;
  workspace_id: string;
  created_at: string;
}

export interface AttachmentUploadResponse {
  ok: boolean;
  attachment?: UploadedAttachment | null;
  error?: string | null;
}

/** POST /api/v1/workspaces/{id}/attachments — base64 JSON, ≤20 MB, 90 s. */
export function uploadWorkspaceAttachment(
  workspaceId: string,
  params: { filename: string; contentType?: string; data: Uint8Array },
  signal?: AbortSignal,
): Promise<AttachmentUploadResponse> {
  const body: Record<string, unknown> = {
    filename: params.filename,
    data_base64: bytesToBase64(params.data),
  };
  if (params.contentType !== undefined) {
    body.content_type = params.contentType;
  }
  return apiRequest<AttachmentUploadResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/attachments`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal,
    },
    90_000,
  );
}
