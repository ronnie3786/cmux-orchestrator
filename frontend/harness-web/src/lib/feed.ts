/**
 * Feed item display + matching helpers.
 *
 * Port of the FeedItem computed properties and the
 * WorkspaceDetailView.feedItem(_:matches:) predicate from
 * cmux-harness-ios/Models/HarnessResponseModels.swift and
 * cmux-harness-ios/Views/Workspace/WorkspaceDetailViews.swift.
 */

import type { FeedItem, Workspace } from "../api/types";
import { workspaceID } from "./workspaceGroups";

/** Mirror of FeedItem.displayTitle. */
export function feedItemDisplayTitle(item: FeedItem): string {
  const title = (item.title ?? "").trim();
  if (title.length > 0) {
    return title;
  }
  switch (item.kind) {
    case "permission":
      return "Permission Request";
    case "plan":
      return "Plan Approval";
    case "question":
      return "Question";
    default:
      return "cmux Feed";
  }
}

/** Mirror of FeedItem.summary: trimmed message, else trimmed command, else displayTitle. */
export function feedItemSummary(item: FeedItem): string {
  const text = (item.message ?? "").trim();
  if (text.length > 0) {
    return text;
  }
  const commandText = (item.command ?? "").trim();
  return commandText.length > 0 ? commandText : feedItemDisplayTitle(item);
}

/** Mirror of FeedItem.supportsNativeReply: every kind replies natively except questions with a multiSelect question. */
export function feedItemSupportsNativeReply(item: FeedItem): boolean {
  return item.kind !== "question" || !(item.questions ?? []).some((question) => question.multiSelect);
}

/**
 * Mirror of WorkspaceDetailView.groupedQuestionFallbackNote: shown on the
 * terminal fallback card when any matched feed item cannot be answered
 * natively (the prompt stays in OpenCode's terminal).
 */
export function groupedQuestionFallbackNote(matchedItems: FeedItem[]): string | null {
  if (!matchedItems.some((item) => !feedItemSupportsNativeReply(item))) return null;
  return (
    "This question supports multiple selections. The current cmux bridge cannot safely preserve grouped answers, so this stays in OpenCode's terminal."
  );
}

/**
 * Mirror of HarnessFeatureHelpers.feedItem(_:matches:) — the exact predicate
 * that decides which feed items attach to the selected session.
 *
 * Attribution rules (verbatim from iOS):
 *  - workspaceMatches = item.workspaceID (trimmed, non-empty) equals
 *    workspace.uuid OR the row id (uuid / "index-N" [+ "|surfaceId"])
 *  - surfaceMatches   = item.surfaceID (trimmed, non-empty) equals
 *    workspace.surfaceId OR workspace.surfaceUuid
 *  - item has a surfaceID  -> it must match, and (when the item also carries
 *    a workspaceID) that must match too
 *  - item has no surfaceID -> matches only when it carries a matching
 *    workspaceID. Unattributed items (both empty) match NO workspace.
 */
export function feedItemMatches(item: FeedItem, workspace: Workspace): boolean {
  const trimmedNonEmpty = (value: string | null | undefined): string | null => {
    const trimmed = (value ?? "").trim();
    return trimmed.length > 0 ? trimmed : null;
  };

  const itemWorkspaceID = trimmedNonEmpty(item.workspaceID);
  const itemSurfaceID = trimmedNonEmpty(item.surfaceID);

  const workspaceMatches =
    itemWorkspaceID != null
      ? itemWorkspaceID === workspace.uuid || itemWorkspaceID === workspaceID(workspace)
      : null;
  const surfaceMatches =
    itemSurfaceID != null
      ? itemSurfaceID === workspace.surfaceId || itemSurfaceID === workspace.surfaceUuid
      : null;

  if (surfaceMatches != null) {
    if (!surfaceMatches) return false;
    return workspaceMatches ?? true;
  }
  return workspaceMatches ?? false;
}
