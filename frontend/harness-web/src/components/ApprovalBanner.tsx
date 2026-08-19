import { useCallback } from "react";
import { Bell, X } from "lucide-react";
import { clearPushApproval } from "../api/endpoints";
import {
  approvalAgeLabel,
  approvalBannerText,
  approvalClearPayload,
  matchApprovalWorkspace,
  newestApprovalNotification,
} from "../lib/approvalNotification";
import { useConnectionStore } from "../store/connectionStore";
import { useWorkspacesStore } from "../store/workspacesStore";

/**
 * Approval banner — web port of the iOS `PushApprovalBanner`
 * (HarnessRootView) over `PushNotificationBridge`.
 *
 * iOS shows the banner for the latest APNs `event == "approval_required"`
 * push; the web app cannot receive pushes, so the banner is derived from the
 * 2 s `/api/notifications` poll — the most recent unread cmux notification
 * whose text looks like a pending approval (see lib/approvalNotification).
 *
 * Behavior parity:
 * - One banner, latest item (iOS `pushApproval` is a single optional).
 * - Tap opens the matched session (iOS `openPushApproval`), falling back to
 *   a plain clear when no status workspace matches (iOS stores a pending
 *   approval and waits for the workspace; the web has no pending slot, so
 *   the clear fires immediately and the next poll confirms).
 * - Both tap and ✕ fire the iOS side effects — `clearPushApproval`
 *   (fire-and-forget) + optimistic `markNotificationsRead`. Unlike iOS, a
 *   plain local hide is not enough here: the poll would re-derive the banner
 *   from the still-unread notification within 2 s. The hide is optimistic —
 *   if the server still reports the notification unread on the next poll the
 *   banner reappears (same rollback path as the sidebar's mark-as-read).
 */
export function ApprovalBanner() {
  const hasReceivedStatus = useWorkspacesStore((s) => s.hasReceivedStatus);
  const notifications = useWorkspacesStore((s) => s.notifications);
  const workspaces = useWorkspacesStore((s) => s.workspaces);
  const selectWorkspace = useWorkspacesStore((s) => s.selectWorkspace);

  const notification = newestApprovalNotification(notifications);
  if (!hasReceivedStatus || notification === null) return null;

  const match = matchApprovalWorkspace(notification, workspaces);
  const text = approvalBannerText(notification, match);

  /** Direct clear (unmatched workspace, or ✕ dismiss): iOS effect order. */
  const clear = useCallback(() => {
    void clearPushApproval(approvalClearPayload(notification, match)).catch(() => undefined);
    // Optimistic is_read flip hides the banner immediately; the next poll
    // re-syncs (reappears if the server still reports it unread).
    useWorkspacesStore
      .getState()
      .markNotificationsRead(notification.workspace_id ?? "", notification.surface_id ?? null);
    useConnectionStore.getState().clearError();
  }, [notification, match]);

  const handleOpen = useCallback(() => {
    if (match !== null) {
      // selectWorkspace performs the iOS effect order internally:
      // clearPushApproval (fire-and-forget) + optimistic mark-as-read.
      selectWorkspace(match.rowID);
      return;
    }
    clear();
  }, [match, selectWorkspace, clear]);

  const age = approvalAgeLabel(notification.created_at, Date.now());

  return (
    <div className="approval-banner" role="status" aria-live="polite">
      <button
        type="button"
        className="approval-banner-open"
        onClick={handleOpen}
        title="Open session"
        aria-label={`Open session: ${text.title}${text.detail !== null ? ` — ${text.detail}` : ""}`}
      >
        <Bell size={15} className="approval-banner-icon" />
        <span className="approval-banner-lines">
          <span className="approval-banner-title">{text.title}</span>
          {text.detail !== null ? <span className="approval-banner-detail">{text.detail}</span> : null}
        </span>
      </button>
      {age !== null ? <span className="approval-banner-age mono">{age}</span> : null}
      <button
        type="button"
        className="approval-banner-close"
        onClick={clear}
        aria-label="Dismiss approval banner"
        title="Dismiss"
      >
        <X size={14} />
      </button>
    </div>
  );
}
