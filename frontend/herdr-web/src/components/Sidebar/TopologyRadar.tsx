import type { Pane } from "../../types/herdr";
import { chatDisplayName, STATUS_COMPACT } from "../../lib/workspaceGroups";

/** 2x2 mini grid — at most four pane cells per workspace card. */
export const RADAR_MAX_CELLS = 4;

/**
 * Radar cell state for a pane. The v1 snapshot has no separate pane error /
 * waiting flag — `agent_status` is server-owned and is the same input Swift
 * feeds its per-pane status dots (`Views/Sidebar/SidebarRowViews.swift:90`,
 * `HerdrStatusDot`, `Models/AgentStatus.swift`). `idle` folds the shell case
 * (`unknown`); `blocked` is Swift's "Needs you" (attention, alert color) and
 * `done` its "Ready". `pi_semantic` presence never changes the state — the
 * bridge capability carries no agent state.
 */
export type RadarState = "idle" | "working" | "blocked" | "done";

export function radarStateForPane(pane: Pane): RadarState {
  switch (pane.agent_status) {
    case "working":
      return "working";
    case "blocked":
      return "blocked";
    case "done":
      return "done";
    case "idle":
    case "unknown":
      return "idle";
  }
}

/**
 * The cells the grid shows: the first RADAR_MAX_CELLS panes in stable
 * pane_id order (Swift sorts panes by paneID, e.g. `firstPane(in:)`); the
 * rest stay reachable via the "N panes" count and the pane list.
 */
export function radarPanes(panes: Pane[]): Pane[] {
  return [...panes]
    .sort((a, b) => a.pane_id.localeCompare(b.pane_id))
    .slice(0, RADAR_MAX_CELLS);
}

interface TopologyRadarProps {
  panes: Pane[];
  selectedPaneId: string | null;
  onSelectPane: (paneId: string) => void;
}

/**
 * 2x2 mini pane grid on a workspace card. Cell tints reuse the sidebar dot
 * palette (`hz-dot-*`); the empty state is the iOS "no panes yet" string
 * (doc 01 §6). Clicking a cell selects that pane (stopPropagation keeps the
 * card's workspace selection from firing).
 */
export function TopologyRadar({ panes, selectedPaneId, onSelectPane }: TopologyRadarProps) {
  const cells = radarPanes(panes);
  if (cells.length === 0) {
    return <span className="hz-radar-empty">no panes yet</span>;
  }
  return (
    <div
      className="hz-radar"
      role="group"
      aria-label={`${panes.length} ${panes.length === 1 ? "pane" : "panes"}`}
    >
      {cells.map((pane) => {
        const state = radarStateForPane(pane);
        return (
          <button
            key={pane.pane_id}
            type="button"
            className={`hz-radar-cell hz-radar-cell-${state}${
              pane.pane_id === selectedPaneId ? " hz-radar-cell-selected" : ""
            }`}
            aria-label={`${chatDisplayName(pane)} (${STATUS_COMPACT[pane.agent_status].toLowerCase()})`}
            title={chatDisplayName(pane)}
            onClick={(event) => {
              event.stopPropagation();
              onSelectPane(pane.pane_id);
            }}
          >
            <span className={`hz-radar-dot hz-dot-${state}`} aria-hidden />
          </button>
        );
      })}
    </div>
  );
}
