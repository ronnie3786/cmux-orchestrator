/**
 * Endpoint functions for the harness server API.
 *
 * Same-origin only: all paths are relative (the web app is served from the
 * server at /harness-web/). The server host is display/bookkeeping info in the
 * connection store — never part of fetch URLs.
 *
 * Request bodies match the dicts the server reads in cmux_harness/server.py.
 */

import { apiRequest, UPLOAD_TIMEOUT_MS } from "./client";
import type {
  AttachmentUploadResponse,
  BasicResponse,
  FeedReplyRequest,
  FeedResponse,
  FileSearchResponse,
  GitDiffRequest,
  GitDiffResponse,
  GitFileRequest,
  GitStatus,
  GitHubPRCommentsResponse,
  HarnessStatus,
  JiraTicketResponse,
  JiraTicketsResponse,
  LogEntry,
  MarkNotificationsReadRequest,
  NewSessionRequest,
  NewSessionResponse,
  NotificationsResponse,
  OpenCodeIntegrationResponse,
  PushApprovalClearRequest,
  PushClearResponse,
  RenameRequest,
  ScreenResponse,
  SendRequest,
  SkillsResponse,
  ToggleRequest,
  ToggleResponse,
  WorkspaceStarRequest,
  WorkspaceToggleRequest,
  WorkspaceToggleResponse,
  WorkspaceStarResponse,
} from "./types";

export type {
  Workspace,
  WorkspaceAutoMode,
  HarnessStatus,
  LogEntry,
  CmuxNotification,
  NotificationsResponse,
  MarkNotificationsReadRequest,
  ScreenResponse,
  BasicResponse,
  ToggleResponse,
  WorkspaceToggleResponse,
  WorkspaceStarResponse,
  PushClearResponse,
  FeedOption,
  FeedQuestion,
  FeedItem,
  FeedResponse,
  FeedReplyRequest,
  OpenCodeIntegrationResponse,
  ToggleRequest,
  WorkspaceToggleRequest,
  WorkspaceStarRequest,
  RenameRequest,
  HarnessKey,
  SendRequest,
  NewSessionRequest,
  NewSessionResponse,
  GitFileRequest,
  GitDiffSection,
  GitDiffRequest,
  GitDiffResponse,
  GitFile,
  GitCommit,
  GitStatus,
  GitEditorTargets,
  GitEditorTarget,
  GitHubPRCommentsResponse,
  GitHubRepository,
  GitHubPullRequest,
  GitHubPRFileGroup,
  GitHubPRThread,
  GitHubPRCodeContext,
  GitHubPRCodeLine,
  GitHubPRComment,
  SkillsResponse,
  ProjectSkill,
  FileSearchResponse,
  ProjectFileMatch,
  JiraTicketsResponse,
  JiraTicketResponse,
  JiraTicket,
  UploadedAttachment,
  AttachmentUploadResponse,
  PushApprovalClearRequest,
  AutoPolicyRates,
} from "./types";

// --- status / log / notifications / feed -----------------------------------

/** GET /api/status */
export function getStatus(): Promise<HarnessStatus> {
  return apiRequest<HarnessStatus>("/api/status");
}

/** GET /api/log — newest first (server returns reversed approval log). */
export function getLog(): Promise<LogEntry[]> {
  return apiRequest<LogEntry[]>("/api/log");
}

/** GET /api/notifications — newest first. */
export function getNotifications(): Promise<NotificationsResponse> {
  return apiRequest<NotificationsResponse>("/api/notifications");
}

/**
 * POST /api/notifications/read — marks all unread notifications read.
 * Pass workspaceId or surfaceId to mark only that workspace/surface (at least
 * one required; both optional in the type since the caller picks which to set).
 */
export function markNotificationsRead(request: MarkNotificationsReadRequest): Promise<BasicResponse> {
  return apiRequest<BasicResponse>("/api/notifications/read", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/** GET /api/feed */
export function getFeed(): Promise<FeedResponse> {
  return apiRequest<FeedResponse>("/api/feed");
}

/** POST /api/feed/reply */
export function replyToFeed(request: FeedReplyRequest): Promise<BasicResponse> {
  return apiRequest<BasicResponse>("/api/feed/reply", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

// --- integrations / screen ---------------------------------------------------

/** GET /api/integrations/opencode */
export function getOpenCodeIntegration(): Promise<OpenCodeIntegrationResponse> {
  return apiRequest<OpenCodeIntegrationResponse>("/api/integrations/opencode");
}

/**
 * POST /api/integrations/opencode — installs the cmux OpenCode event bridge.
 * (The server has no /install variant; GET and POST share this path —
 * verified against cmux_harness/server.py and the iOS client.)
 */
export function installOpenCodeIntegration(): Promise<OpenCodeIntegrationResponse> {
  return apiRequest<OpenCodeIntegrationResponse>("/api/integrations/opencode", { method: "POST" });
}

/** GET /api/screen?index=N&lines=L */
export function getScreen(index: number, lines = 200): Promise<ScreenResponse> {
  const query = new URLSearchParams({ index: String(index), lines: String(lines) });
  return apiRequest<ScreenResponse>(`/api/screen?${query.toString()}`);
}

// --- engine / workspace controls ---------------------------------------------

/** POST /api/toggle — global engine enable/disable. */
export function toggleEngine(enabled: boolean): Promise<ToggleResponse> {
  const request: ToggleRequest = { enabled };
  return apiRequest<ToggleResponse>("/api/toggle", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/** POST /api/workspace — per-workspace enable + auto mode. */
export function setWorkspaceToggle(
  index: number,
  enabled: boolean,
  autoMode: WorkspaceToggleRequest["autoMode"] = null,
): Promise<WorkspaceToggleResponse> {
  const request: WorkspaceToggleRequest = { index, enabled, autoMode };
  return apiRequest<WorkspaceToggleResponse>("/api/workspace", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/** POST /api/workspace-star */
export function starWorkspace(index: number, starred: boolean): Promise<WorkspaceStarResponse> {
  const request: WorkspaceStarRequest = { index, starred };
  return apiRequest<WorkspaceStarResponse>("/api/workspace-star", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/** POST /api/rename */
export function renameWorkspace(index: number, name: string): Promise<BasicResponse> {
  const request: RenameRequest = { index, name };
  return apiRequest<BasicResponse>("/api/rename", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/** POST /api/send — send text or a whitelisted key to a workspace/surface. */
export function sendTextOrKey(request: SendRequest): Promise<BasicResponse> {
  return apiRequest<BasicResponse>("/api/send", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/** POST /api/new-session */
export function newSession(request: NewSessionRequest): Promise<NewSessionResponse> {
  return apiRequest<NewSessionResponse>("/api/new-session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/**
 * POST /api/push/clear — fire-and-forget when a session is selected (iOS
 * clearPushApprovalEffect). workspaceID is `<uuid>|<surfaceId>` when the
 * surface is known.
 */
export function clearPushApproval(request: PushApprovalClearRequest): Promise<PushClearResponse> {
  return apiRequest<PushClearResponse>("/api/push/clear", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

// --- git ---------------------------------------------------------------------

/** GET /api/git-status?index=N */
export function getGitStatus(index: number): Promise<GitStatus> {
  const query = new URLSearchParams({ index: String(index) });
  return apiRequest<GitStatus>(`/api/git-status?${query.toString()}`);
}

/** POST /api/git-stage */
export function gitStage(request: GitFileRequest): Promise<BasicResponse> {
  return apiRequest<BasicResponse>("/api/git-stage", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/** POST /api/git-unstage */
export function gitUnstage(request: GitFileRequest): Promise<BasicResponse> {
  return apiRequest<BasicResponse>("/api/git-unstage", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

/** POST /api/git-diff */
export function getGitDiff(request: GitDiffRequest): Promise<GitDiffResponse> {
  return apiRequest<GitDiffResponse>("/api/git-diff", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
}

// --- github PR comments --------------------------------------------------------

/** GET /api/github/pr-comments?index=N&includeResolved=true|false */
export function getPRComments(index: number, includeResolved = false): Promise<GitHubPRCommentsResponse> {
  const query = new URLSearchParams({
    index: String(index),
    includeResolved: includeResolved ? "true" : "false",
  });
  return apiRequest<GitHubPRCommentsResponse>(`/api/github/pr-comments?${query.toString()}`);
}

// --- skills / file search / jira -------------------------------------------------

/** GET /api/skills?index=N. `signal` cancels on unmount (iOS `loadSkills` task). */
export function getSkills(index: number, signal?: AbortSignal): Promise<SkillsResponse> {
  const query = new URLSearchParams({ index: String(index) });
  return apiRequest<SkillsResponse>(`/api/skills?${query.toString()}`, { signal });
}

/**
 * GET /api/file-search?index=N&q=...
 * Pass `signal` to cancel a per-keystroke in-flight request (iOS
 * `fileSearchCancelID` parity — only the latest query's results render).
 */
export function fileSearch(
  index: number,
  query: string,
  signal?: AbortSignal,
): Promise<FileSearchResponse> {
  const params = new URLSearchParams({ index: String(index), q: query });
  return apiRequest<FileSearchResponse>(`/api/file-search?${params.toString()}`, { signal });
}

/** GET /api/jira/assigned?limit=N[&project=KEY]. `signal` cancels on close (iOS `jiraTicketsCancelID`). */
export function getJiraAssigned(
  limit = 50,
  project?: string,
  signal?: AbortSignal,
): Promise<JiraTicketsResponse> {
  const params = new URLSearchParams({ limit: String(limit) });
  if (project) {
    params.set("project", project);
  }
  return apiRequest<JiraTicketsResponse>(`/api/jira/assigned?${params.toString()}`, { signal });
}

/** GET /api/jira/issue?q=TICKET-123 (or a browse URL — the server parses it). `signal` cancels on close (iOS `jiraLookupCancelID`). */
export function getJiraIssue(query: string, signal?: AbortSignal): Promise<JiraTicketResponse> {
  const params = new URLSearchParams({ q: query });
  return apiRequest<JiraTicketResponse>(`/api/jira/issue?${params.toString()}`, { signal });
}

// --- attachments ---------------------------------------------------------------

export interface UploadAttachmentParams {
  index: number;
  /** Workspace UUID (sent as X-Cmux-Workspace-UUID; "" when unknown). */
  uuid?: string | null;
  filename: string;
  data: Blob;
  contentType?: string;
}

/**
 * POST /api/attachments — raw body upload with X-Cmux-* headers (60 s timeout,
 * iOS HarnessAPI.uploadAttachment parity).
 */
export function uploadAttachment(params: UploadAttachmentParams): Promise<AttachmentUploadResponse> {
  const headers: Record<string, string> = {
    "Content-Type": params.contentType ?? "application/octet-stream",
    "X-Cmux-Workspace-Index": String(params.index),
    "X-Cmux-Workspace-UUID": params.uuid ?? "",
    "X-Cmux-Filename": encodeURIComponent(params.filename),
  };
  return apiRequest<AttachmentUploadResponse>(
    "/api/attachments",
    { method: "POST", body: params.data, headers },
    UPLOAD_TIMEOUT_MS,
  );
}
