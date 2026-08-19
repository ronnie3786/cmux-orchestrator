import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { MoreHorizontal } from "lucide-react";
import { closeWorkspace, createTab, launchWorkspace, renameWorkspace } from "../../api/mutations";
import { canControlNow, useConnectionStore } from "../../store/connectionStore";
import { showToast } from "../../lib/toast";
import { usePopover } from "../../hooks/usePopover";
import "../Sidebar/pane-menu.css";

type Stage = "menu" | "rename" | "confirm";

interface WorkspaceCardMenuProps {
  workspaceId: string;
  label: string;
  paneCount: number;
}

// --- menu model (pure — unit-tested in WorkspaceCardMenu.test.ts) -----------

export type WorkspaceMenuItem =
  | { id: "focus"; label: string; enabled: boolean }
  | { id: "newTab"; label: string; enabled: boolean }
  | { id: "rename"; label: string; enabled: boolean }
  | { id: "close"; label: string; enabled: boolean };

/**
 * Every item is Live-gated ("Reconnect before controlling Herdr"); demo
 * mode disables all of them.
 */
export function workspaceMenuItemsFor(options: { demo: boolean }): WorkspaceMenuItem[] {
  const enabled = !options.demo;
  return [
    { id: "focus", label: "Focus on Mac", enabled },
    { id: "newTab", label: "New tab", enabled },
    { id: "rename", label: "Rename workspace", enabled },
    { id: "close", label: "Close workspace", enabled },
  ];
}

function errorMessage(error: unknown): string {
  return error instanceof Error && error.message ? error.message : "Request failed";
}

/**
 * Workspace card ⋯ menu (iOS "Workspace actions" parity, doc 01 §3):
 * "Focus on Mac" (POST /workspaces/{id}/focus, toast "Workspace focused on
 * Mac"), "New tab" (POST /workspaces/{id}/tabs, toast "Tab created"),
 * "Rename workspace" (PATCH /workspaces/{id} {label}, toast "Workspace
 * renamed"), and "Close workspace" with the doc 01 §6 confirm copy "Close
 * this workspace?" + "All N pane processes in this workspace will stop."
 * (toast "Workspace closed"). All gated to Live connections (P9 composer
 * pattern, "Reconnect before controlling Herdr").
 */
export function WorkspaceCardMenu({ workspaceId, label, paneCount }: WorkspaceCardMenuProps) {
  const popover = usePopover();
  const [stage, setStage] = useState<Stage>("menu");
  const [draft, setDraft] = useState("");

  const demo = useConnectionStore((state) => state.status) === "Demo";
  const items = workspaceMenuItemsFor({ demo });

  // Clicking outside closes the panel without going through close() —
  // reset any sub-stage so the next open starts at the menu.
  useEffect(() => {
    if (!popover.open) setStage("menu");
  }, [popover.open]);

  const close = () => {
    popover.close();
    setStage("menu");
    setDraft("");
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

  const createNewTab = async () => {
    close();
    try {
      await createTab(workspaceId);
      showToast("Tab created");
      // No manual refetch — snapshot.updated arms the debounced /workspaces
      // refetch (eventStream).
    } catch (error) {
      showToast(errorMessage(error));
    }
  };

  const renameWorkspaceAction = async () => {
    const nextLabel = draft.trim();
    if (nextLabel.length === 0) {
      close();
      return;
    }
    close();
    try {
      await renameWorkspace(workspaceId, nextLabel);
      showToast("Workspace renamed");
      // No manual refetch — snapshot.updated arms the debounced /workspaces
      // refetch (eventStream).
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
                  {items.map((item) => (
                    <button
                      key={item.id}
                      type="button"
                      role="menuitem"
                      className={`hz-menu-item${
                        item.id === "close" ? " hz-menu-item-destructive" : ""
                      }${item.enabled ? "" : " hz-menu-item-disabled"}`}
                      onClick={() => {
                        if (!item.enabled || !gate()) return;
                        if (item.id === "focus") void focusWorkspace();
                        else if (item.id === "newTab") void createNewTab();
                        else if (item.id === "rename") {
                          setDraft(label);
                          setStage("rename");
                        } else setStage("confirm");
                      }}
                    >
                      <span className="hz-menu-item-check" aria-hidden />
                      <span>{item.label}</span>
                    </button>
                  ))}
                </>
              ) : null}
              {stage === "rename" ? (
                <>
                  <div className="hz-popover-label">Workspace name</div>
                  <input
                    className="hz-popover-input"
                    type="text"
                    value={draft}
                    placeholder="Workspace name"
                    aria-label="Workspace name"
                    autoFocus
                    onChange={(event) => setDraft(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") void renameWorkspaceAction();
                    }}
                  />
                  <div className="hz-popover-message">
                    The new label appears in Herdr on every connected client.
                  </div>
                  <div className="hz-popover-actions">
                    <button type="button" className="hz-popover-button" onClick={close}>
                      Cancel
                    </button>
                    <button
                      type="button"
                      className="hz-popover-button hz-popover-button-primary"
                      disabled={!draft.trim()}
                      onClick={() => void renameWorkspaceAction()}
                    >
                      Rename
                    </button>
                  </div>
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
