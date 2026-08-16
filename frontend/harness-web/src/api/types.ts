/**
 * Typed request/response models for the harness server API.
 *
 * Ported from cmux-harness-ios Models/*.swift. Field names match the server's
 * JSON exactly (stdlib Python dicts in cmux_harness/server.py). Where the live
 * server returns fields the Swift model doesn't declare (Decodable ignores
 * unknown keys), they are included here and marked "server extras".
 *
 * The iOS models use snake_case CodingKeys for notifications/log entries; the
 * JSON keys are used directly here (e.g. `is_read`, `session_id`).
 */

export type WorkspaceAutoMode = "off" | "auto" | "super";

/** GET /api/status — workspace entry. Mirrors Workspace in Models/WorkspaceModels.swift. */
export interface Workspace {
  hasClaude: boolean;
  index: number;
  name: string;
  uuid: string;
  enabled: boolean;
  autoMode?: WorkspaceAutoMode | null;
  starred?: boolean;
  autoEnabledAt?: number | null;
  autoExpiresAt?: number | null;
  customName?: string | null;
  lastCheck?: string | null;
  screenTail?: string | null;
  screenFull?: string | null;
  cwd?: string | null;
  branch?: string | null;
  sessionStart?: number | null;
  sessionCost?: string | null;
  surfaceId?: string | null;
  surfaceUuid?: string | null;
  surfaceLabel?: string | null;
  surfaceTitle?: string | null;
  gitDirty?: boolean | null;
  surfaceCreatedAt?: string | null;
  surfaceAge?: number | null;
}

/** GET /api/status. Mirrors HarnessStatus in Models/WorkspaceModels.swift. */
export interface HarnessStatus {
  enabled: boolean;
  workspaces: Workspace[];
  pollInterval: number;
  socketFound: boolean;
  model?: string | null;
  reviewEnabled?: boolean | null;
  reviewModel?: string | null;
  reviewBackend?: string | null;
  contractReviewEnabled?: boolean | null;
  connected?: boolean | null;
  lastSuccessfulPoll?: number | null;
  connectionLostAt?: number | null;
  staleData?: boolean | null;
  ollamaAvailable?: boolean | null;
  // Server extras (verified against the live server; not in the Swift model).
  approvalThreshold?: number | null;
  autoPolicyProvider?: string | null;
  autoPolicyModel?: string | null;
  autoPolicyRates?: AutoPolicyRates | null;
}

export interface AutoPolicyRates {
  inputPerMillionUSD?: number | null;
  outputPerMillionUSD?: number | null;
}

/** GET /api/log — array element. Mirrors LogEntry in Models/WorkspaceModels.swift. */
export interface LogEntry {
  timestamp?: string | null;
  workspace?: number | null;
  workspaceName?: string | null;
  promptType?: string | null;
  action?: string | null;
  reason?: string | null;
  key?: string | null;
  surfaceId?: string | null;
  /** Server JSON key is snake_case (Swift CodingKeys: sessionID = "session_id"). */
  session_id?: string | null;
}

/** GET /api/notifications — element. Mirrors CmuxNotification in Models/NotificationModels.swift. */
export interface CmuxNotification {
  id: string;
  title?: string | null;
  body?: string | null;
  subtitle?: string | null;
  created_at?: string | null;
  is_read: boolean;
  workspace_id?: string | null;
  workspace_ref?: string | null;
  surface_id?: string | null;
  surface_ref?: string | null;
  tab_title?: string | null;
}

/** GET /api/notifications. Mirrors NotificationsResponse. */
export interface NotificationsResponse {
  ok: boolean;
  notifications: CmuxNotification[];
  error?: string | null;
}

/**
 * POST /api/notifications/read.
 * Server accepts `workspaceId`/`surfaceId` (camelCase) — at least one required.
 */
export interface MarkNotificationsReadRequest {
  workspaceId?: string | null;
  surfaceId?: string | null;
}

/** GET /api/screen. Mirrors ScreenResponse in Models/HarnessResponseModels.swift. */
export interface ScreenResponse {
  ok: boolean;
  screen: string;
  lines?: number | null;
  error?: string | null;
}

/** Generic success envelope. Mirrors BasicResponse. */
export interface BasicResponse {
  ok: boolean;
  error?: string | null;
}

/** POST /api/toggle response: {ok, enabled}. */
export interface ToggleResponse extends BasicResponse {
  enabled: boolean;
}

/** POST /api/workspace response: {ok, enabled, autoMode}. */
export interface WorkspaceToggleResponse extends BasicResponse {
  enabled: boolean;
  autoMode: WorkspaceAutoMode;
}

/** POST /api/workspace-star response: {ok, starred}. */
export interface WorkspaceStarResponse extends BasicResponse {
  starred: boolean;
}

/** POST /api/push/clear response: {ok, cleared, clearedIDs}. */
export interface PushClearResponse extends BasicResponse {
  cleared?: boolean;
  clearedIDs?: string[];
}

/** Feed item option (question choice). */
export interface FeedOption {
  id: string;
  label: string;
  description?: string | null;
}

/** Feed item question (question wizard step). */
export interface FeedQuestion {
  id: string;
  header?: string | null;
  question: string;
  multiSelect: boolean;
  options: FeedOption[];
}

/** GET /api/feed — element. Mirrors FeedItem in Models/HarnessResponseModels.swift. */
export interface FeedItem {
  requestID: string;
  kind: string;
  title?: string | null;
  message?: string | null;
  command?: string | null;
  workspaceID?: string | null;
  surfaceID?: string | null;
  agent?: string | null;
  createdAt?: string | null;
  options?: string[] | null;
  permissionType?: string | null;
  patterns?: string[] | null;
  questions?: FeedQuestion[] | null;
  // Server extras (verified against the live server; not in the Swift model).
  status?: string | null;
  raw?: Record<string, unknown> | null;
}

/** GET /api/feed. Mirrors FeedResponse. */
export interface FeedResponse {
  ok: boolean;
  items: FeedItem[];
  error?: string | null;
}

/**
 * POST /api/feed/reply.
 * action: approve | allow | deny | reject | answer ... (server normalizes).
 * mode: once | always | all | bypass | deny | autoAccept | manual | ultraplan ...
 */
export interface FeedReplyRequest {
  requestID: string;
  kind: string;
  action?: string | null;
  mode?: string | null;
  selections?: string[] | null;
}

/** GET|POST /api/integrations/opencode. Mirrors OpenCodeIntegrationResponse. */
export interface OpenCodeIntegrationResponse {
  ok: boolean;
  status?: string | null;
  installed?: boolean | null;
  cmuxAvailable?: boolean | null;
  needsInstall?: boolean | null;
  needsRestart?: boolean | null;
  summary?: string | null;
  error?: string | null;
  // Server extras (verified against the live server; not in the Swift model).
  pluginExists?: boolean | null;
  pluginPath?: string | null;
  cmuxPath?: string | null;
  cmuxSource?: string | null;
}

/** POST /api/toggle. */
export interface ToggleRequest {
  enabled: boolean;
}

/** POST /api/workspace. */
export interface WorkspaceToggleRequest {
  index: number;
  enabled: boolean;
  autoMode?: WorkspaceAutoMode | null;
}

/** POST /api/workspace-star. */
export interface WorkspaceStarRequest {
  index: number;
  starred: boolean;
}

/** POST /api/rename. */
export interface RenameRequest {
  index: number;
  name: string;
}

/**
 * Keys accepted by POST /api/send (server whitelist _HARNESS_ALLOWED_KEYS).
 */
export type HarnessKey =
  | "up"
  | "down"
  | "left"
  | "right"
  | "tab"
  | "enter"
  | "escape"
  | "backspace";

/** POST /api/send — either `text` or `key` (or both empty → 400). */
export interface SendRequest {
  index: number;
  text?: string | null;
  key?: HarnessKey | string | null;
  surfaceId?: string | null;
}

/** POST /api/new-session. */
export interface NewSessionRequest {
  projectPath?: string;
  branchName?: string;
  jiraUrl?: string;
  prompt?: string;
  command?: string;
  sessionName?: string;
}

/** POST /api/new-session response. Mirrors NewSessionResponse. */
export interface NewSessionResponse {
  ok: boolean;
  workspace?: { index?: number | null; uuid?: string | null } | null;
  worktreePath?: string | null;
  branchName?: string | null;
  error?: string | null;
}

/** POST /api/git-stage | /api/git-unstage. */
export interface GitFileRequest {
  index: number;
  file: string;
}

export type GitDiffSection = "unstaged" | "staged" | "untracked";

/** POST /api/git-diff. */
export interface GitDiffRequest {
  index: number;
  file: string;
  section?: GitDiffSection;
}

/** POST /api/git-diff response. Mirrors GitDiffResponse. */
export interface GitDiffResponse {
  ok: boolean;
  diff?: string | null;
  error?: string | null;
}

/** GET /api/git-status — file row. Mirrors GitFile. */
export interface GitFile {
  status: string;
  file: string;
}

/** GET /api/git-status — commit row. Mirrors GitCommit. */
export interface GitCommit {
  hash: string;
  message: string;
}

/**
 * GET /api/git-status. Mirrors GitStatus.
 * `editorTargets` is a server extra (verified against the live server).
 */
export interface GitStatus {
  ok?: boolean | null;
  branch?: string | null;
  cwd?: string | null;
  staged: GitFile[];
  unstaged: GitFile[];
  untracked: string[];
  commits: GitCommit[];
  error?: string | null;
  editorTargets?: GitEditorTargets | null;
}

export interface GitEditorTargets {
  vscode?: GitEditorTarget | null;
  xcode?: GitEditorTarget | null;
}

export interface GitEditorTarget {
  available: boolean;
  targetPath?: string | null;
  targetType?: string | null;
}

/** GET /api/github/pr-comments. Mirrors GitHubPRCommentsResponse in Models/GitHubPRModels.swift. */
export interface GitHubPRCommentsResponse {
  ok: boolean;
  cwd?: string | null;
  repository?: GitHubRepository | null;
  pullRequest?: GitHubPullRequest | null;
  includeResolved: boolean;
  threads: GitHubPRThread[];
  files: GitHubPRFileGroup[];
  totalThreadCount: number;
  returnedThreadCount: number;
  resolvedThreadCount: number;
  hiddenResolvedCount: number;
  error?: string | null;
}

export interface GitHubRepository {
  owner: string;
  name: string;
  url: string;
}

export interface GitHubPullRequest {
  number: number;
  title: string;
  url: string;
  headRefName?: string | null;
  baseRefName?: string | null;
  state?: string | null;
  author?: string | null;
}

export interface GitHubPRFileGroup {
  path: string;
  threadCount: number;
  threads: GitHubPRThread[];
}

export interface GitHubPRThread {
  id: string;
  path: string;
  line?: number | null;
  originalLine?: number | null;
  startLine?: number | null;
  originalStartLine?: number | null;
  diffSide: string;
  startDiffSide: string;
  subjectType: string;
  isResolved: boolean;
  isOutdated: boolean;
  url: string;
  codeContext?: GitHubPRCodeContext | null;
  comments: GitHubPRComment[];
}

export interface GitHubPRCodeContext {
  path: string;
  source: string;
  startLine: number;
  endLine: number;
  lines: GitHubPRCodeLine[];
}

export interface GitHubPRCodeLine {
  number: number;
  text: string;
  isTarget: boolean;
}

export interface GitHubPRComment {
  id: string;
  author: string;
  body: string;
  bodyText: string;
  createdAt: string;
  updatedAt: string;
  url: string;
  diffHunk: string;
  path: string;
  line?: number | null;
  originalLine?: number | null;
}

/** GET /api/skills. Mirrors SkillsResponse in Models/SkillsFileJiraAttachmentModels.swift. */
export interface SkillsResponse {
  ok: boolean;
  rootPath?: string | null;
  skillsDirectory?: string | null;
  userSkillsDirectory?: string | null;
  projectSkills?: ProjectSkill[] | null;
  userSkills?: ProjectSkill[] | null;
  skills?: ProjectSkill[] | null;
  error?: string | null;
}

export interface ProjectSkill {
  name: string;
  skillFilePath: string;
  scope?: string | null;
}

/** GET /api/file-search. Mirrors FileSearchResponse. */
export interface FileSearchResponse {
  ok: boolean;
  rootPath?: string | null;
  query: string;
  files: ProjectFileMatch[];
  truncated?: boolean | null;
  limit?: number | null;
  error?: string | null;
}

export interface ProjectFileMatch {
  path: string;
}

/** GET /api/jira/assigned. Mirrors JiraTicketsResponse. */
export interface JiraTicketsResponse {
  ok: boolean;
  project?: string | null;
  projects?: string[] | null;
  site?: string | null;
  tickets: JiraTicket[];
  error?: string | null;
}

/** GET /api/jira/issue. Mirrors JiraTicketResponse. */
export interface JiraTicketResponse {
  ok: boolean;
  site?: string | null;
  ticket?: JiraTicket | null;
  error?: string | null;
}

export interface JiraTicket {
  key: string;
  projectKey?: string | null;
  title: string;
  status: string;
  priority: string;
  issueType: string;
  url: string;
}

/** POST /api/attachments response — uploaded file. Mirrors UploadedAttachment. */
export interface UploadedAttachment {
  id: string;
  filename: string;
  originalFilename: string;
  contentType: string;
  size: number;
  path: string;
  workspaceKey: string;
  createdAt: string;
}

/** POST /api/attachments response. Mirrors AttachmentUploadResponse. */
export interface AttachmentUploadResponse {
  ok: boolean;
  attachment?: UploadedAttachment | null;
  error?: string | null;
}

/** POST /api/push/clear. workspaceID is `<uuid>|<surfaceId>` when a surface is known. */
export interface PushApprovalClearRequest {
  workspaceID: string;
  workspaceUUID?: string | null;
  surfaceID?: string | null;
}
