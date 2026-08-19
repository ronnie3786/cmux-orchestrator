import { useConnectionStore } from "../../store/connectionStore";
import { useEventStreamStore } from "../../store/eventStream";
import "./connection-issue.css";

/**
 * "Connection issue" alert (iOS AppRootView error-alert parity): a
 * top-right card above the toast, shown when the LIVE global stream drops
 * or herdr reports itself disconnected (eventStream `issue`). Live mode
 * only — the demo never runs the stream, and the per-pane terminal
 * reconnect pill is a separate, per-pane surface. `Dismiss` clears the
 * current issue; the next drop re-raises it.
 */
export function ConnectionIssue() {
  const issue = useEventStreamStore((state) => state.issue);
  const demo = useConnectionStore((state) => state.demo);
  if (demo || issue === null) return null;
  return (
    <div className="hz-connection-issue" role="alert">
      <div className="hz-connection-issue-title">Connection issue</div>
      <div className="hz-connection-issue-detail">{issue}</div>
      <button
        type="button"
        className="hz-connection-issue-dismiss"
        onClick={() => useEventStreamStore.setState({ issue: null })}
      >
        Dismiss
      </button>
    </div>
  );
}
