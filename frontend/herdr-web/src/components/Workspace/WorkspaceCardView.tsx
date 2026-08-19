import { statusTitle, type WorkspaceGroup } from "../../lib/workspaceGroups";
import "./workspace.css";

interface WorkspaceCardViewProps {
  group: WorkspaceGroup;
  selected: boolean;
  onSelect: () => void;
}

/**
 * One workspace card (iOS WorkspaceCardView parity): status dot, mono label
 * + "active" when focused + the workspace-level status title; detail line
 * with the branch/worktree label ("shell" fallback), "rev N" (highest pane
 * revision — workspaces carry no revision field of their own) and the pane
 * count.
 */
export function WorkspaceCardView({ group, selected, onSelect }: WorkspaceCardViewProps) {
  return (
    <button type="button" className={`hz-ws-card${selected ? " hz-ws-card-selected" : ""}`} onClick={onSelect}>
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
    </button>
  );
}
