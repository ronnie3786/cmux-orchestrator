import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { MoreHorizontal } from "lucide-react";
import { closeWorkspace, launchWorkspace } from "../../api/mutations";
import { canControlNow } from "../../store/connectionStore";
import { showToast } from "../../lib/toast";
import { usePopover } from "../../hooks/usePopover";
import "../Sidebar/pane-menu.css";

type Stage = "menu" | "confirm";

interface WorkspaceCardMenuProps {
  workspaceId: string;
  label: string;
  paneCount: number;
}

function errorMessage(error: unknown): string {
  return error instanceof Error && error.message ? error.message : "Request failed";
}

/**
 * Workspace card ⋯ menu (iOS "Workspace actions" parity, doc 01 §3):
 * "Focus on Mac" (POST /workspaces/{id}/focus, toast "Workspace focused on
 * Mac") and "Close workspace" with the doc 01 §6 confirm copy "Close this
 * workspace?" + "All N pane processes in this workspace will stop."
 * (toast "Workspace closed"). Both are gated to Live connections
 * (P9 composer pattern, "Reconnect before controlling Herdr").
 */
export function WorkspaceCardMenu({ workspaceId, label, paneCount }: WorkspaceCardMenuProps) {
  const popover = usePopover();
  const [stage, setStage] = useState<Stage>("menu");

  // Clicking outside closes the panel without going through close() —
  // reset any sub-stage so the next open starts at the menu.
  useEffect(() => {
    if (!popover.open) setStage("menu");
  }, [popover.open]);

  const close = () => {
    popover.close();
    setStage("menu");
  };

  const gate = (): boolean => {
    if (canControlNow()) return true;
    showToast("Reconnect before controlling Herdr");
    return false;
  };

  const focusWorkspace = async () => {
    close();
    try {
      await launchWorkspace(workspaceId);
      showToast("Workspace focused on Mac");
    } catch (error) {
      showToast(errorMessage(error));
    }
  };

  const closeWorkspaceAction = async () => {
    close();
    try {
      await closeWorkspace(workspaceId);
      showToast("Workspace closed");
      // No manual refetch — snapshot.updated arms the debounced /workspaces
      // refetch (eventStream).
    } catch (error) {
      showToast(errorMessage(error));
    }
  };

  return (
    <>
      <button
        type="button"
        className="icon-button hz-ws-card-menu-toggle"
        aria-label="Workspace actions"
        aria-expanded={popover.open}
        onClick={(event) => {
          event.stopPropagation();
          popover.toggle(event.currentTarget);
        }}
      >
        <MoreHorizontal size={14} aria-hidden />
      </button>
      {popover.open && popover.style !== null
        ? createPortal(
            <div
              ref={popover.panelRef}
              className="hz-popover"
              style={popover.style}
              role="menu"
              aria-label={`Workspace actions, ${label}`}
              onClick={(event) => event.stopPropagation()}
            >
              {stage === "menu" ? (
                <>
                  <button
                    type="button"
                    role="menuitem"
                    className="hz-menu-item"
                    onClick={() => {
                      if (gate()) void focusWorkspace();
                    }}
                  >
                    <span className="hz-menu-item-check" aria-hidden />
                    <span>Focus on Mac</span>
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    className="hz-menu-item hz-menu-item-destructive"
                    onClick={() => {
                      if (gate()) setStage("confirm");
                    }}
                  >
                    <span className="hz-menu-item-check" aria-hidden />
                    <span>Close workspace</span>
                  </button>
                </>
              ) : null}
              {stage === "confirm" ? (
                <>
                  <div className="hz-popover-label">Close this workspace?</div>
                  <div className="hz-popover-message">
                    All {paneCount} pane processes in this workspace will stop.
                  </div>
                  <div className="hz-popover-actions">
                    <button
                      type="button"
                      className="hz-popover-button"
                      onClick={() => setStage("menu")}
                    >
                      Cancel
                    </button>
                    <button
                      type="button"
                      className="hz-popover-button hz-popover-button-destructive"
                      onClick={() => void closeWorkspaceAction()}
                    >
                      Close workspace
                    </button>
                  </div>
                </>
              ) : null}
            </div>,
            document.body,
          )
        : null}
    </>
  );
}
