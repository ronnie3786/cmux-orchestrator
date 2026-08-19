import type { Workspace } from "../../types/herdr";
import "./detail.css";

/**
 * Right-column placeholder (P3-run-A). Pane topology and the live session
 * land here in later phases.
 */
export function DetailPlaceholder({ workspace }: { workspace: Workspace | null }) {
  return (
    <main className="hz-detail-col">
      <div className="hz-detail-placeholder">
        {workspace === null ? (
          <>
            <p className="hz-detail-placeholder-title">Choose a workspace</p>
            <p className="hz-detail-placeholder-sub">Its tabs and panes will appear here.</p>
          </>
        ) : (
          <>
            <p className="hz-detail-placeholder-title">Choose a pane</p>
            <p className="hz-detail-placeholder-sub">Open a terminal or agent session.</p>
          </>
        )}
      </div>
    </main>
  );
}
