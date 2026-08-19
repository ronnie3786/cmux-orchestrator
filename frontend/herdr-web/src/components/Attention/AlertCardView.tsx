import { compactStatus } from "../../lib/workspaceGroups";
import type { Alert, Pane } from "../../types/herdr";
import "./attention.css";

/**
 * One alert card (iOS AlertCardView parity): status dot + lowercase compact
 * status, "NEW" capsule when unread, title + message, agent label or
 * "Closed pane · <paneID>", relative timestamp, deep link (open_pane
 * action) and an explicit "mark read" action.
 *
 * The status is joined from the workspace snapshot's pane `agent_status` —
 * a missing pane ranks/renders as unknown (byte-exact §6 vocabulary).
 */
export interface AlertCardViewProps {
  alert: Alert;
  /** The pane in the current snapshot, or null when it no longer exists. */
  pane: Pane | null;
  onMarkRead: (id: string) => void;
}

/**
 * Simplest clean relative format: "now", "2m ago", "3h ago", "5d ago".
 * Future timestamps clamp to "now" (clock skew); unparseable → "".
 */
export function formatRelativeTime(iso: string, now: number = Date.now()): string {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return "";
  let seconds = Math.round((now - then) / 1000);
  if (seconds < 0) seconds = 0;
  if (seconds < 60) return "now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

export function AlertCardView({ alert, pane, onMarkRead }: AlertCardViewProps) {
  const status = pane?.agent_status ?? "unknown";
  const closed = pane === null;
  const href =
    alert.action?.type === "open_pane"
      ? `#ws=${encodeURIComponent(alert.workspaceId)}&pane=${encodeURIComponent(alert.paneId)}`
      : null;

  return (
    <article
      className={`hz-alert-card${alert.isRead ? " hz-alert-card-read" : ""}`}
      data-pane-id={alert.paneId}
    >
      <header className="hz-alert-card-top">
        <span className={`hz-dot hz-dot-${status}`} aria-hidden />
        <span className="hz-alert-card-status">{compactStatus(status)}</span>
        {alert.isRead ? null : <span className="hz-alert-card-new">NEW</span>}
        <span className="hz-alert-card-time">{formatRelativeTime(alert.createdAt)}</span>
      </header>
      <p className="hz-alert-card-title">{alert.title}</p>
      <p className="hz-alert-card-message">{alert.message}</p>
      <footer className="hz-alert-card-footer">
        <span className="hz-alert-card-pane" title={alert.paneId}>
          {closed ? (
            <>
              Closed pane · <span className="mono">{alert.paneId}</span>
            </>
          ) : (
            <>
              {alert.agentName ? <>{alert.agentName} · </> : null}
              <span className="mono">{alert.paneId}</span>
            </>
          )}
        </span>
        {href ? (
          <a className="hz-alert-card-open" href={href}>
            open pane
          </a>
        ) : null}
        {alert.isRead ? null : (
          <button type="button" className="hz-alert-card-mark" onClick={() => onMarkRead(alert.id)}>
            mark read
          </button>
        )}
      </footer>
    </article>
  );
}
