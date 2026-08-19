/**
 * Approval banner derivation — web port of the iOS `approval_required` push
 * behavior (PushNotificationBridge / HarnessRootView PushApprovalBanner).
 *
 * iOS receives an APNs push with `event == "approval_required"` and shows a
 * banner for it. The web app cannot receive pushes; the closest source of
 * truth is the 2 s `/api/notifications` poll (cmux workspace notifications),
 * so the banner is derived from the most recent *unread* cmux notification
 * whose text indicates a pending approval/permission.
 *
 * The patterns below are deliberately narrow: the live cmux string for a
 * pane blocked on a permission prompt is "Permission needs input"
 * (verified against the running server); "approval"-style wording covers
 * plan-approval flows. Notifications like "Session done" must NOT match.
 *
 * Everything here is pure (unit-tested); the React wiring lives in
 * `components/ApprovalBanner.tsx`.
 */

import type { CmuxNotification, PushApprovalClearRequest, Workspace } from "../api/types";
import { nonEmptyTrimmed } from "./workspaceDisplay";
import { displayName, workspaceID } from "./workspaceGroups";

/** Text patterns that mark an unread notification as an approval prompt. */
const APPROVAL_PATTERNS: RegExp[] = [
  /needs input/i, // cmux live string: "Permission needs input"
  /approval/i, // e.g. "Plan approval"
  /needs your answer/i,
  /approve this/i,
];

/** True when an unread notification looks like a pending approval. */
export function isApprovalNotification(notification: CmuxNotification): boolean {
  if (notification.is_read) return false;
  const text = [
    notification.title ?? "",
    notification.subtitle ?? "",
    notification.body ?? "",
    notification.tab_title ?? "",
  ].join("\n");
  return APPROVAL_PATTERNS.some((pattern) => pattern.test(text));
}

function parseCreated(value: string | null | undefined): number {
  if (value == null || value.length === 0) return Number.NaN;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Number.NaN;
}

/**
 * The banner item: the most recent unread approval notification, or null.
 *
 * The server returns notifications newest-first, but recency is decided by
 * `created_at` when present (unparseable timestamps sort oldest) so the
 * result does not depend on server ordering.
 */
export function newestApprovalNotification(
  notifications: CmuxNotification[],
): CmuxNotification | null {
  let best: CmuxNotification | null = null;
  let bestTime = Number.NaN;
  for (const notification of notifications) {
    if (!isApprovalNotification(notification)) continue;
    const time = parseCreated(notification.created_at);
    if (
      best === null ||
      (!Number.isFinite(bestTime) && Number.isFinite(time)) ||
      (Number.isFinite(time) && (Number.isFinite(bestTime) ? time > bestTime : true))
    ) {
      best = notification;
      bestTime = time;
    }
  }
  return best;
}

export interface ApprovalMatch {
  /** Sidebar row id to select (`uuid` or `uuid|surfaceId`). */
  rowID: string;
  /** Workspace uuid (for the clear payload + mark-as-read). */
  workspaceUUID: string;
  /** Workspace surface ref, e.g. `surface:28` (null for single-surface). */
  surfaceID: string | null;
  /** Display name shown in the banner (custom name or cmux workspace name). */
  workspaceName: string;
}

/**
 * Match a notification to a status workspace (port of iOS
 * `matchingWorkspaceID`): the workspace whose uuid equals
 * `notification.workspace_id`; when the notification carries a
 * `surface_id` (a surface *uuid*), prefer the pane whose `surfaceUuid`
 * matches.
 */
export function matchApprovalWorkspace(
  notification: CmuxNotification,
  workspaces: Workspace[],
): ApprovalMatch | null {
  const uuid = notification.workspace_id;
  if (uuid == null || uuid.length === 0) return null;
  const candidates = workspaces.filter((workspace) => workspace.uuid === uuid);
  if (candidates.length === 0) return null;
  const preferred =
    notification.surface_id != null && notification.surface_id.length > 0
      ? candidates.find((workspace) => workspace.surfaceUuid === notification.surface_id)
      : undefined;
  const workspace = preferred ?? candidates[0];
  return {
    rowID: workspaceID(workspace),
    workspaceUUID: workspace.uuid,
    surfaceID: workspace.surfaceId ?? null,
    workspaceName: displayName(workspace),
  };
}

/**
 * POST /api/push/clear payload. Mirrors the server's stored shape
 * (`<uuid>|<surfaceId>` workspaceID) so the lenient uuid match in
 * `_matches_workspace` is exercised exactly like the iOS flow.
 */
export function approvalClearPayload(
  notification: CmuxNotification,
  match: ApprovalMatch | null,
): PushApprovalClearRequest {
  const workspaceUUID = notification.workspace_id ?? "";
  const surfaceID = match?.surfaceID ?? null;
  return {
    workspaceID: surfaceID != null && workspaceUUID.length > 0 ? `${workspaceUUID}|${surfaceID}` : workspaceUUID,
    workspaceUUID: workspaceUUID.length > 0 ? workspaceUUID : undefined,
    surfaceID,
  };
}

export interface ApprovalBannerText {
  /** Primary line: workspace name (or fallbacks). */
  title: string;
  /** Secondary line: what needs approval; null when it duplicates the title. */
  detail: string | null;
}

/** Banner copy (iOS: workspaceName + request-with-reason-fallback). */
export function approvalBannerText(
  notification: CmuxNotification,
  match: ApprovalMatch | null,
): ApprovalBannerText {
  const title =
    match?.workspaceName ??
    nonEmptyTrimmed(notification.tab_title) ??
    nonEmptyTrimmed(notification.title) ??
    "Approval needed";
  const detailRaw = nonEmptyTrimmed(notification.body) ?? nonEmptyTrimmed(notification.title);
  const detail =
    detailRaw != null && detailRaw !== title ? detailRaw : null;
  return { title, detail: detail ?? null };
}

/**
 * Age label for the banner. The server stores `created_at` as UTC
 * ISO-8601 — `Z`-suffixed in the current build, naive in earlier ones (both
 * verified against the live server) — so naive strings are parsed as UTC.
 * Returns null when the timestamp is unusable; the banner then shows no age
 * (the server has no per-notification expiry, so this is elapsed time, not
 * a countdown).
 */
export function approvalAgeLabel(
  createdAt: string | null | undefined,
  now: number,
): string | null {
  const time = parseAsUtc(createdAt);
  if (!Number.isFinite(time)) return null;
  const seconds = Math.max(0, Math.floor((now - time) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

/** Parse an ISO string as UTC (appends `Z` when no offset/Z is present). */
function parseAsUtc(value: string | null | undefined): number {
  if (value == null || value.length === 0) return Number.NaN;
  if (/[zZ]|[+-]\d{2}:?\d{2}$/.test(value)) return parseCreated(value);
  const parsed = Date.parse(`${value}Z`);
  return Number.isFinite(parsed) ? parsed : Number.NaN;
}
