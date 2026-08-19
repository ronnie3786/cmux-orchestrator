import { statusTitle, type WorkspaceGroup } from "../../lib/workspaceGroups";
import type { Pane } from "../../types/herdr";
import { TopologyRadar } from "../Sidebar/TopologyRadar";
import "./workspace.css";

interface WorkspaceCardViewProps {
  group: WorkspaceGroup;
  selected: boolean;
  onSelect: () => void;
  /** Raw snapshot panes for the topology radar (2x2 mini grid, P10-run-A). */
  panes: Pane[];
  selectedPaneId: string | null;
  onSelectPane: (paneId: string) => void;
}

/**
 * One workspace card (iOS WorkspaceCardView parity): status dot, mono label
 * + "active" when focused + the workspace-level status title; detail line
 * with the branch/worktree label ("shell" fallback), "rev N" (highest pane
 * revision — workspaces carry no revision field of their own) and the pane
 * count. The 2x2 topology radar sits on the right (P10-run-A).
 *
 * Role=button div (not a nested <button>) so the radar cells can carry
 * their own click handlers — same pattern as the sidebar project rows.
 */
export function WorkspaceCardView({
  group,
  selected,
  onSelect,
  panes,
  selectedPaneId,
  onSelectPane,
}: WorkspaceCardViewProps) {
  return (
    <div
      className={`hz-ws-card${selected ? " hz-ws-card-selected" : ""}`}
      role="button"
      tabIndex={0}
      aria-label={`${group.label}, ${statusTitle(group.agentStatus)}, ${group.paneCount} ${
        group.paneCount === 1 ? "pane" : "panes"
      }`}
      onClick={onSelect}
      onKeyDown={(event) => {
        if (event.target !== event.currentTarget) return;
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSelect();
        }
      }}
    >
      <div className="hz-ws-card-main">
        <div className="hz-ws-card-row">
          <span className={`hz-dot hz-dot-${group.agentStatus}`} aria-hidden />
          <span className="hz-ws-card-label">{group.label}</span>
          {group.focused ? <span className="hz-ws-card-active">active</span> : null}
          <span className={`hz-ws-card-status hz-ws-card-status-${group.agentStatus}`}>
            {statusTitle(group.agentStatus)}
          </span>
        </div>
        <div className="hz-ws-card-detail">
          <span className="hz-ws-card-branch">{group.branch}</span>
          <span aria-hidden>·</span>
          {group.revision !== null ? <span className="hz-ws-card-rev">rev {group.revision}</span> : null}
          {group.revision !== null ? <span aria-hidden>·</span> : null}
          <span className="hz-ws-card-panes">
            {group.paneCount} {group.paneCount === 1 ? "pane" : "panes"}
          </span>
        </div>
      </div>
      <TopologyRadar panes={panes} selectedPaneId={selectedPaneId} onSelectPane={onSelectPane} />
    </div>
  );
}
