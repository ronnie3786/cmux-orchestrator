import { useCallback, useEffect, useState } from "react";
import {
  Activity,
  Check,
  Folder,
  GitBranch,
  Info,
  MoreHorizontal,
  Pencil,
  Plus,
  Sparkles,
  Star,
  Terminal,
  Timer,
  X,
} from "lucide-react";
import { renameWorkspace, setWorkspaceToggle } from "../../api/endpoints";
import type { Workspace, WorkspaceAutoMode } from "../../api/types";
import {
  displayName,
  paneLabel,
  paneDisplayName,
  resolvedAutoMode,
  workspaceID,
  workspaceNeedsYou,
  type WorkspaceSessionGroup,
} from "../../lib/workspaceGroups";
import {
  autoExpirationLabel,
  autoModeLabel,
  branchValue,
  costColorClass,
  directoryValue,
  nonEmptyTrimmed,
  worktreeValue,
} from "../../lib/workspaceDisplay";
import { useSessionStore } from "../../store/sessionStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import { MinimalInputRow } from "../Terminal/MinimalInputRow";
import { TerminalView } from "../Terminal/TerminalView";

type DetailTab = "terminal" | "git" | "activity" | "skills";

const DETAIL_TABS: Array<{ id: DetailTab; label: string; icon: typeof Terminal }> = [
  { id: "terminal", label: "Session", icon: Terminal },
  { id: "git", label: "Git", icon: GitBranch },
  { id: "activity", label: "Activity", icon: Activity },
  { id: "skills", label: "Skills", icon: Sparkles },
];

const AUTO_MODES: WorkspaceAutoMode[] = ["off", "auto", "super"];

const EASY_MODE_STORAGE_KEY = "cmux-harness:easyMode";

function readEasyMode(): boolean {
  try {
    return window.localStorage.getItem(EASY_MODE_STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}

function writeEasyMode(enabled: boolean): void {
  try {
    window.localStorage.setItem(EASY_MODE_STORAGE_KEY, enabled ? "1" : "0");
  } catch {
    // localStorage unavailable (private mode) — easy mode stays session-only.
  }
}

interface WorkspaceDetailViewProps {
  workspace: Workspace;
  group: WorkspaceSessionGroup;
}

export function WorkspaceDetailView({ workspace, group }: WorkspaceDetailViewProps) {
  const notifications = useWorkspacesStore((s) => s.notifications);
  const feedItems = useWorkspacesStore((s) => s.feedItems);
  const selectedWorkspaceID = useWorkspacesStore((s) => s.selectedWorkspaceID);
  const selectWorkspace = useWorkspacesStore((s) => s.selectWorkspace);
  const toggleStar = useWorkspacesStore((s) => s.toggleStar);
  const screenText = useSessionStore((s) => s.screenText);

  const [tab, setTab] = useState<DetailTab>("terminal");
  const [easyMode, setEasyMode] = useState(readEasyMode);
  const [menuOpen, setMenuOpen] = useState(false);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [renameOpen, setRenameOpen] = useState(false);
  const [renameValue, setRenameValue] = useState("");
  const [actionError, setActionError] = useState<string | null>(null);
  const [busyAction, setBusyAction] = useState<string | null>(null);

  const id = workspaceID(workspace);
  const title = group.displayName;
  const needsYou = workspaceNeedsYou(workspace, notifications, feedItems);
  const autoMode = resolvedAutoMode(workspace);

  // iOS parity: easy mode forces the terminal tab, and switching away from
  // the terminal tab turns easy mode off.
  const setTabAndMaybeDisableEasy = useCallback(
    (next: DetailTab) => {
      setTab(next);
      if (next !== "terminal") {
        setEasyMode((previous) => {
          if (previous) writeEasyMode(false);
          return false;
        });
      }
    },
    [],
  );

  const setEasyModePersisted = useCallback((enabled: boolean) => {
    writeEasyMode(enabled);
    setEasyMode(enabled);
    if (enabled) setTab("terminal");
  }, []);

  const setAutoMode = useCallback(
    async (mode: WorkspaceAutoMode) => {
      setBusyAction(`auto:${mode}`);
      setActionError(null);
      try {
        await setWorkspaceToggle(workspace.index, mode !== "off", mode);
      } catch (err) {
        setActionError(err instanceof Error ? err.message : "Couldn't update auto mode");
      } finally {
        setBusyAction(null);
      }
    },
    [workspace.index],
  );

  const submitRename = useCallback(async () => {
    const value = renameValue.trim();
    setBusyAction("rename");
    setActionError(null);
    try {
      // iOS: empty string clears the custom name (server stores "" → nil).
      await renameWorkspace(workspace.index, value);
      setRenameOpen(false);
    } catch (err) {
      setActionError(err instanceof Error ? err.message : "Couldn't rename session");
    } finally {
      setBusyAction(null);
    }
  }, [renameValue, workspace.index]);

  // Close menus/dialogs on Escape.
  useEffect(() => {
    if (!menuOpen && !renameOpen && !detailsOpen) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      setMenuOpen(false);
      setRenameOpen(false);
      setDetailsOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [menuOpen, renameOpen, detailsOpen]);

  return (
    <main className="detail">
      {/* Header */}
      <div className="detail-header">
        <div className="detail-title-row">
          {needsYou ? <span className="needs-you-dot" title="Needs you" /> : null}
          <h1 className="detail-title" title={title}>
            {title}
          </h1>
          {needsYou ? (
            <span className="chip chip-needs">Needs You</span>
          ) : (
            <span className="chip chip-muted">Active</span>
          )}
          <div className="detail-header-actions">
            <button
              type="button"
              className="icon-button"
              title="Session actions"
              aria-haspopup="menu"
              aria-expanded={menuOpen}
              onClick={() => setMenuOpen((open) => !open)}
            >
              <MoreHorizontal size={16} />
            </button>
          </div>
        </div>
        <div className="detail-meta">
          <span className="meta-chip" title={workspace.cwd ?? undefined}>
            <Folder size={12} />
            {directoryValue(workspace, title)}
          </span>
          <span className="meta-chip" title={workspace.branch ?? undefined}>
            <GitBranch size={12} />
            {branchValue(workspace)}
          </span>
          {nonEmptyTrimmed(workspace.sessionCost) != null ? (
            <span className={`meta-chip mono ${costColorClass(workspace.sessionCost as string)}`}>
              {workspace.sessionCost}
            </span>
          ) : null}
          {workspace.autoExpiresAt && workspace.autoExpiresAt > 0 ? (
            <span className="meta-chip mono" title="Auto mode expiration">
              <Timer size={12} />
              {autoExpirationLabel(workspace.autoExpiresAt, Date.now(), autoMode)}
            </span>
          ) : null}
        </div>
      </div>

      {/* Pane pills (multi-surface groups) */}
      {group.hasMultiplePanes ? (
        <div className="pane-pills" role="tablist" aria-label="Panes">
          {group.workspaces.map((pane, offset) => {
            const paneID = workspaceID(pane);
            const active = paneID === selectedWorkspaceID;
            return (
              <button
                key={paneID}
                type="button"
                role="tab"
                aria-selected={active}
                className={`pane-pill${active ? " pane-pill-active" : ""}`}
                title={paneDisplayName(pane)}
                onClick={() => selectWorkspace(paneID)}
              >
                {paneLabel(group, pane, offset)}
              </button>
            );
          })}
        </div>
      ) : null}

      {/* Detail tab bar */}
      <div className="detail-tab-bar" role="tablist" aria-label="Session details">
        {DETAIL_TABS.map(({ id: tabID, label, icon: Icon }) => (
          <button
            key={tabID}
            type="button"
            role="tab"
            aria-selected={tab === tabID}
            className={`detail-tab${tab === tabID ? " detail-tab-active" : ""}`}
            onClick={() => setTabAndMaybeDisableEasy(tabID)}
          >
            <Icon size={13} />
            {label}
          </button>
        ))}
      </div>

      {actionError ? <div className="detail-error">{actionError}</div> : null}

      {/* Content */}
      <div className="detail-content">
        {tab === "terminal" ? (
          <div className={`terminal-layout${easyMode ? " terminal-layout-easy" : ""}`}>
            <div className="terminal-panel">
              <TerminalView text={screenText ?? ""} sessionID={id} />
            </div>
            <MinimalInputRow index={workspace.index} />
          </div>
        ) : (
          <div className="tab-placeholder">
            <p>{DETAIL_TABS.find((t) => t.id === tab)?.label} arrives in Phase 2b.</p>
            <p className="tab-placeholder-hint">
              The screen polling, input row, and this layout are already wired.
            </p>
          </div>
        )}

        <div className="metadata-card">
          <div className="metadata-row">
            <span className="metadata-label">Worktree</span>
            <span className="metadata-value mono" title={workspace.cwd ?? undefined}>
              {worktreeValue(workspace, title)}
            </span>
          </div>
          <div className="metadata-row">
            <span className="metadata-label">Branch</span>
            <span className="metadata-value mono" title={workspace.branch ?? undefined}>
              {branchValue(workspace)}
            </span>
          </div>
          <div className="metadata-row">
            <span className="metadata-label">Directory</span>
            <span className="metadata-value mono" title={workspace.cwd ?? undefined}>
              {directoryValue(workspace, title)}
            </span>
          </div>
          <div className="metadata-row">
            <span className="metadata-label">Auto</span>
            <span className="metadata-value">{autoModeLabel(autoMode)}</span>
          </div>
        </div>
      </div>

      {/* Actions menu */}
      {menuOpen ? (
        <>
          <div className="menu-backdrop" onClick={() => setMenuOpen(false)} />
          <div className="menu" role="menu">
            <div className="menu-section">Auto Mode</div>
            {AUTO_MODES.map((mode) => (
              <button
                key={mode}
                type="button"
                role="menuitemradio"
                aria-checked={autoMode === mode}
                className="menu-item"
                disabled={busyAction != null}
                onClick={() => void setAutoMode(mode)}
              >
                <span className="menu-item-label">
                  {autoModeLabel(mode)}
                  {mode === "super" ? " (all)" : ""}
                </span>
                {autoMode === mode ? <Check size={14} className="menu-item-check" /> : null}
                {busyAction === `auto:${mode}` ? <span className="menu-item-busy">…</span> : null}
              </button>
            ))}
            <div className="menu-separator" />
            <button
              type="button"
              role="menuitemcheckbox"
              aria-checked={easyMode}
              className="menu-item"
              onClick={() => setEasyModePersisted(!easyMode)}
            >
              <span className="menu-item-label">Easy Mode</span>
              {easyMode ? <Check size={14} className="menu-item-check" /> : null}
            </button>
            <button
              type="button"
              role="menuitemcheckbox"
              aria-checked={Boolean(workspace.starred)}
              className="menu-item"
              onClick={() => {
                toggleStar(workspace.index, !workspace.starred);
                setMenuOpen(false);
              }}
            >
              <Star size={14} className={`menu-item-icon${workspace.starred ? " menu-item-icon-active" : ""}`} />
              <span className="menu-item-label">{workspace.starred ? "Unstar" : "Star"}</span>
            </button>
            <button
              type="button"
              role="menuitem"
              className="menu-item"
              onClick={() => {
                setRenameValue(workspace.customName ?? "");
                setRenameOpen(true);
                setMenuOpen(false);
              }}
            >
              <Pencil size={14} className="menu-item-icon" />
              <span className="menu-item-label">Rename…</span>
            </button>
            <button
              type="button"
              role="menuitem"
              className="menu-item"
              onClick={() => {
                setDetailsOpen(true);
                setMenuOpen(false);
              }}
            >
              <Info size={14} className="menu-item-icon" />
              <span className="menu-item-label">Details</span>
            </button>
            <div className="menu-separator" />
            <button
              type="button"
              role="menuitem"
              className="menu-item menu-item-disabled"
              disabled
              title="Phase 2b"
            >
              <Plus size={14} className="menu-item-icon" />
              <span className="menu-item-label">New Session</span>
            </button>
          </div>
        </>
      ) : null}

      {/* Rename dialog */}
      {renameOpen ? (
        <div className="dialog-backdrop" onClick={() => setRenameOpen(false)}>
          <div className="dialog" onClick={(e) => e.stopPropagation()}>
            <div className="dialog-title">
              <span>Rename Session</span>
              <button
                type="button"
                className="icon-button"
                aria-label="Close"
                onClick={() => setRenameOpen(false)}
              >
                <X size={14} />
              </button>
            </div>
            <input
              className="dialog-input"
              type="text"
              value={renameValue}
              placeholder={displayName(workspace)}
              autoFocus
              onChange={(e) => setRenameValue(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void submitRename();
              }}
              aria-label="Custom session name"
            />
            <p className="dialog-hint">Leave empty to clear the custom name.</p>
            <div className="dialog-actions">
              <button type="button" className="btn btn-secondary" onClick={() => setRenameOpen(false)}>
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busyAction === "rename"}
                onClick={() => void submitRename()}
              >
                {busyAction === "rename" ? "Saving…" : "Save"}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {/* Details dialog (metadata sheet) */}
      {detailsOpen ? (
        <div className="dialog-backdrop" onClick={() => setDetailsOpen(false)}>
          <div className="dialog dialog-wide" onClick={(e) => e.stopPropagation()}>
            <div className="dialog-title">
              <span>Session Details</span>
              <button
                type="button"
                className="icon-button"
                aria-label="Close"
                onClick={() => setDetailsOpen(false)}
              >
                <X size={14} />
              </button>
            </div>
            <div className="dialog-body">
              <div className="metadata-row">
                <span className="metadata-label">Worktree</span>
                <span className="metadata-value mono" title={workspace.cwd ?? undefined}>
                  {worktreeValue(workspace, title)}
                </span>
              </div>
              <div className="metadata-row">
                <span className="metadata-label">Branch</span>
                <span className="metadata-value mono" title={workspace.branch ?? undefined}>
                  {branchValue(workspace)}
                </span>
              </div>
              <div className="metadata-row">
                <span className="metadata-label">Directory</span>
                <span className="metadata-value mono" title={workspace.cwd ?? undefined}>
                  {directoryValue(workspace, title)}
                </span>
              </div>
              <div className="metadata-row">
                <span className="metadata-label">Session</span>
                <span className="metadata-value">
                  {needsYou ? "Needs you" : "Active"}
                  {nonEmptyTrimmed(workspace.sessionCost) != null
                    ? ` · ${workspace.sessionCost}`
                    : ""}
                </span>
              </div>
              <div className="metadata-row">
                <span className="metadata-label">Auto</span>
                <span className="metadata-value">
                  {autoModeLabel(autoMode)}
                  {workspace.autoExpiresAt && workspace.autoExpiresAt > 0
                    ? ` · ${autoExpirationLabel(workspace.autoExpiresAt, Date.now(), autoMode)}`
                    : ""}
                </span>
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </main>
  );
}
