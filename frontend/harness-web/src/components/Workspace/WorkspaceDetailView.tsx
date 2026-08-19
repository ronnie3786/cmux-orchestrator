import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
import { renameWorkspace, replyToFeed, sendTextOrKey, setWorkspaceToggle, installOpenCodeIntegration } from "../../api/endpoints";
import type { HarnessKey, Workspace, WorkspaceAutoMode } from "../../api/types";
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
import {
  feedItemMatches,
  feedItemSupportsNativeReply,
  groupedQuestionFallbackNote,
} from "../../lib/feed";
import { detect } from "../../terminal/detector";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import { useConnectionStore } from "../../store/connectionStore";
import { useGitStore } from "../../store/gitStore";
import { useNewSessionStore } from "../../store/newSessionStore";
import { useSessionStore } from "../../store/sessionStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import { GitStatusView } from "../Git/GitStatusView";
import { TerminalView } from "../Terminal/TerminalView";
import { EasyModeKeyboard } from "../Input/EasyModeKeyboard";
import { InputBar } from "../Input/InputBar";
import { FileSearchModal } from "../Tools/FileSearchModal";
import { JiraModal } from "../Tools/JiraModal";
import { SkillsTab } from "../Tools/SkillsTab";
import { ActivityTab } from "./ActivityTab";
import { FeedInteractionCard, type FeedReplyAction, type FeedReplyMode } from "./FeedInteractionCard";
import { OpenCodeFallbackCard } from "./OpenCodeFallbackCard";

type DetailTab = "terminal" | "git" | "activity" | "skills";

const DETAIL_TABS: Array<{ id: DetailTab; label: string; icon: typeof Terminal }> = [
  { id: "terminal", label: "Session", icon: Terminal },
  { id: "git", label: "Git", icon: GitBranch },
  { id: "activity", label: "Activity", icon: Activity },
  { id: "skills", label: "Skills", icon: Sparkles },
];

const AUTO_MODES: WorkspaceAutoMode[] = ["off", "auto", "super"];

/**
 * Easy-mode persistence. iOS keeps easy mode in TCA state only (in-memory,
 * not persisted). Web: persist per workspace row id in localStorage so each
 * session remembers its own easy mode (plan: client-side per-workspace).
 */
const EASY_MODE_KEY_PREFIX = "harness-web:easyMode:";
const LEGACY_EASY_MODE_KEY = "cmux-harness:easyMode";

// One-time migration: easy mode used to be a single global flag.
try {
  window.localStorage.removeItem(LEGACY_EASY_MODE_KEY);
} catch {
  // No window (test env) — nothing to migrate.
}

function readEasyMode(rowID: string): boolean {
  try {
    return window.localStorage.getItem(EASY_MODE_KEY_PREFIX + rowID) === "1";
  } catch {
    return false;
  }
}

function writeEasyMode(rowID: string, enabled: boolean): void {
  try {
    if (enabled) {
      window.localStorage.setItem(EASY_MODE_KEY_PREFIX + rowID, "1");
    } else {
      window.localStorage.removeItem(EASY_MODE_KEY_PREFIX + rowID);
    }
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
  const screenError = useSessionStore((s) => s.screenError);
  const feedReplyPendingIDs = useSessionStore((s) => s.feedReplyPendingIDs);
  const openCodeIntegration = useWorkspacesStore((s) => s.openCodeIntegration);

  const [tab, setTab] = useState<DetailTab>("terminal");
  // Phase 5 tools modals (iOS isShowingFileSearch / isShowingJiraTickets).
  // Owned here — not by the InputBar — so they stay open across tab switches
  // and inserts can jump to the Terminal tab (iOS append* actions set
  // detailTab = .terminal + bump detailInputFocusRequest, then close).
  const [toolsModal, setToolsModal] = useState<"fileSearch" | "jira" | null>(null);
  // The view remounts per workspace (keyed in App), so reading the
  // per-workspace flag on init gives per-session easy mode.
  const [easyMode, setEasyMode] = useState(() => readEasyMode(workspaceID(workspace)));
  const [menuOpen, setMenuOpen] = useState(false);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [renameOpen, setRenameOpen] = useState(false);
  const [renameValue, setRenameValue] = useState("");
  const [actionError, setActionError] = useState<string | null>(null);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [isInstallingIntegration, setIsInstallingIntegration] = useState(false);

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
          if (previous) writeEasyMode(id, false);
          return false;
        });
      }
    },
    [id],
  );

  const setEasyModePersisted = useCallback((enabled: boolean) => {
    writeEasyMode(id, enabled);
    setEasyMode(enabled);
    if (enabled) setTab("terminal");
  }, [id]);

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
      // iOS parity: set the custom name immediately, then refresh
      // (commitRename sets customName, the effect sends .refresh).
      useWorkspacesStore.getState().applyCustomName(workspace.index, value);
      // Empty string clears the custom name (server stores "" → nil).
      await renameWorkspace(workspace.index, value);
      setRenameOpen(false);
      useConnectionStore.getState().requestTick();
    } catch (err) {
      setActionError(err instanceof Error ? err.message : "Couldn't rename session");
      // Refresh to restore the server's truth.
      useConnectionStore.getState().requestTick();
    } finally {
      setBusyAction(null);
    }
  }, [renameValue, workspace.index]);

  // Close menus/dialogs on Escape — one layer for all three (only one can be
  // open at a time; opening a dialog closes the menu). Top-most layer only.
  const anyOverlayOpen = menuOpen || renameOpen || detailsOpen;
  useEscapeLayer(
    () => {
      setMenuOpen(false);
      setRenameOpen(false);
      setDetailsOpen(false);
    },
    anyOverlayOpen,
  );
  useScrollLock(anyOverlayOpen);

  // --- Git tab lifecycle (iOS HarnessFeatureGitReducer parity) --------------
  //
  // The view remounts on every selection change (keyed by workspace in App),
  // so a mount-time reset mirrors iOS `workspaceSelected`: fresh status/PR
  // data, status segment, no sheet open.
  const gitSegment = useGitStore((s) => s.gitSegment);
  useEffect(() => {
    useGitStore.getState().resetForSelection();
    return () => {
      useGitStore.getState().stopStatusPolling();
    };
  }, []);

  // --- Pane switch (iOS selectWorkspacePane parity) ------------------------
  //
  // Multi-surface panes share the workspace uuid, so switching panes does NOT
  // remount this view. iOS nils the per-pane data (git status, PR comments,
  // skills) and re-ticks; we clear the git store the same way. The current
  // tab/segment is kept. SkillsTab remounts via its key below.
  const paneKey = workspace.surfaceId ?? "__default__";
  const isFirstPaneRender = useRef(true);
  useEffect(() => {
    if (isFirstPaneRender.current) {
      isFirstPaneRender.current = false;
      return;
    }
    useGitStore.getState().resetPane();
  }, [paneKey]);

  // Status segment: 10 s poll (iOS gitPollingEffect) with an immediate tick.
  // PR Comments segment: one-shot load (iOS `.loadPRComments`). Leaving the
  // git tab cancels the poll (iOS `detailTabChanged`).
  useEffect(() => {
    const git = useGitStore.getState();
    if (tab === "git" && gitSegment === "status") {
      git.startStatusPolling(workspace.index);
      return () => git.stopStatusPolling();
    }
    if (tab === "git" && gitSegment === "prComments") {
      git.loadPRComments(workspace.index);
      return;
    }
    git.stopStatusPolling();
  }, [tab, gitSegment, workspace.index]);

  // --- active interaction (iOS DetailTerminalLayout parity) ------------------
  //
  // terminalText mirrors the iOS detector input: the latest raw screen text,
  // or the iOS placeholder when the terminal has no data yet.
  const terminalText = useMemo(() => {
    const raw = screenText ?? "";
    return raw.length > 0 ? raw : "(no terminal data yet)";
  }, [screenText]);

  const workspaceFeedItems = useMemo(
    () => feedItems.filter((item) => feedItemMatches(item, workspace)),
    [feedItems, workspace],
  );

  const nativeFeedItem = useMemo(
    () => workspaceFeedItems.find((item) => feedItemSupportsNativeReply(item)) ?? null,
    [workspaceFeedItems],
  );

  // The detector only runs when no native feed item exists (iOS guard).
  const terminalInteraction = useMemo(() => {
    if (nativeFeedItem !== null) return null;
    return detect(terminalText);
  }, [nativeFeedItem, terminalText]);

  const hasActiveInteraction = nativeFeedItem !== null || terminalInteraction !== null;

  const fallbackNote = useMemo(() => groupedQuestionFallbackNote(workspaceFeedItems), [workspaceFeedItems]);

  // Pane-pill unread counts (iOS: pane.unreadCount > 0 && !isSelected) —
  // unread notifications whose surface_id matches the pane's surfaceUuid,
  // from the existing 2 s notifications poll (no new polling).
  const unreadBySurface = useMemo(() => {
    const counts = new Map<string, number>();
    for (const notification of notifications) {
      if (!notification.is_read && notification.surface_id) {
        counts.set(notification.surface_id, (counts.get(notification.surface_id) ?? 0) + 1);
      }
    }
    return counts;
  }, [notifications]);

  const isSubmittingNative = nativeFeedItem !== null && feedReplyPendingIDs.has(nativeFeedItem.requestID);

  /** Port of the replyToFeed action: dedupe, POST, optimistic remove + refresh. */
  const handleFeedReply = useCallback(
    async (action: FeedReplyAction, mode: FeedReplyMode | null, selections: string[] | null) => {
      if (nativeFeedItem === null) return;
      const requestID = nativeFeedItem.requestID;
      const session = useSessionStore.getState();
      if (!session.beginFeedReply(requestID)) return;
      try {
        await replyToFeed({
          requestID,
          kind: nativeFeedItem.kind,
          action,
          mode,
          selections,
        });
        session.finishFeedReply(requestID);
        // iOS removes the answered item from state immediately; the next
        // 2 s global tick re-syncs from the server.
        useWorkspacesStore.setState((state) => ({
          feedItems: state.feedItems.filter((item) => item.requestID !== requestID),
        }));
        useConnectionStore.getState().clearError();
      } catch (err) {
        session.finishFeedReply(requestID);
        useConnectionStore.setState({
          errorMessage: err instanceof Error ? err.message : "Couldn't send response",
        });
      }
    },
    [nativeFeedItem],
  );

  /** Port of the sendKey action: POST /api/send, then an immediate screen tick. */
  const handleSendKey = useCallback(
    async (key: HarnessKey) => {
      try {
        await sendTextOrKey({
          index: workspace.index,
          key,
          surfaceId: workspace.surfaceId ?? null,
        });
        useConnectionStore.getState().clearError();
        void useSessionStore.getState().pollNow();
      } catch (err) {
        useConnectionStore.setState({
          errorMessage: err instanceof Error ? err.message : "Couldn't send key",
        });
      }
    },
    [workspace.index, workspace.surfaceId],
  );

  /** Port of the sendKeys action: sequential sends, stop at the first error. */
  const handleSendKeys = useCallback(
    async (keys: string[]) => {
      if (keys.length === 0) return;
      try {
        for (const key of keys) {
          await sendTextOrKey({
            index: workspace.index,
            key: key as HarnessKey,
            surfaceId: workspace.surfaceId ?? null,
          });
        }
        useConnectionStore.getState().clearError();
        void useSessionStore.getState().pollNow();
      } catch (err) {
        useConnectionStore.setState({
          errorMessage: err instanceof Error ? err.message : "Couldn't send keys",
        });
      }
    },
    [workspace.index, workspace.surfaceId],
  );

  /** Port of the installOpenCodeIntegration action. */
  const handleInstallIntegration = useCallback(async () => {
    if (isInstallingIntegration) return;
    setIsInstallingIntegration(true);
    try {
      const response = await installOpenCodeIntegration();
      useWorkspacesStore.getState().applyOpenCodeIntegration(response);
      useConnectionStore.getState().clearError();
    } catch (err) {
      useConnectionStore.setState({
        errorMessage: err instanceof Error ? err.message : "Couldn't enable native controls",
      });
    } finally {
      setIsInstallingIntegration(false);
    }
  }, [isInstallingIntegration]);

  return (
    <main className="detail">
      {/* Header */}
      <div className="detail-header">
        <div className="detail-title-row">
          <h1 className="detail-title" title={title}>
            {title}
          </h1>
          {/* iOS `SessionBadge`: green "Session" / orange "Needs You". */}
          {needsYou ? (
            <span className="state-badge state-badge-needs-you">Needs You</span>
          ) : (
            <span className="state-badge state-badge-session">Session</span>
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

      {/* Pane pills (multi-surface groups) — hidden in easy mode (iOS parity) */}
      {!easyMode && group.hasMultiplePanes ? (
        <div className="pane-pills" role="tablist" aria-label="Panes">
          {group.workspaces.map((pane, offset) => {
            const paneID = workspaceID(pane);
            const active = paneID === selectedWorkspaceID;
            const paneUnread = (pane.surfaceUuid ? unreadBySurface.get(pane.surfaceUuid) : undefined) ?? 0;
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
                {pane.gitDirty === true ? (
                  <span className="pane-pill-dirty" title="Uncommitted changes" aria-label="Uncommitted changes" />
                ) : null}
                {!active && paneUnread > 0 ? (
                  <span className="unread-badge">{paneUnread}</span>
                ) : null}
              </button>
            );
          })}
        </div>
      ) : null}

      {/* Detail tab bar — hidden in easy mode (iOS parity) */}
      {!easyMode ? (
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
      ) : null}

      {actionError ? <div className="detail-error">{actionError}</div> : null}

      {/* Content */}
      <div className="detail-content">
        {tab === "terminal" ? (
          <div className={`terminal-layout${easyMode ? " terminal-layout-easy" : ""}`}>
            <div className="terminal-panel">
              {screenError !== null ? (
                <div className="screen-error" role="alert">
                  <span className="screen-error-text">Screen poll failing: {screenError}</span>
                  <button
                    type="button"
                    className="screen-error-retry"
                    onClick={() => void useSessionStore.getState().pollNow()}
                  >
                    Retry
                  </button>
                </div>
              ) : null}
              <TerminalView text={screenText ?? ""} sessionID={id} />
            </div>
            {nativeFeedItem !== null ? (
              <FeedInteractionCard
                key={nativeFeedItem.requestID}
                item={nativeFeedItem}
                isSubmitting={isSubmittingNative}
                onReply={handleFeedReply}
                onSendKey={(key) => void handleSendKey(key as HarnessKey)}
              />
            ) : terminalInteraction !== null ? (
              <OpenCodeFallbackCard
                interaction={terminalInteraction}
                fallbackNote={fallbackNote}
                integrationStatus={openCodeIntegration}
                isInstallingIntegration={isInstallingIntegration}
                onSendKey={(key) => void handleSendKey(key as HarnessKey)}
                onSendKeys={(keys) => void handleSendKeys(keys)}
                onInstallIntegration={() => void handleInstallIntegration()}
              />
            ) : null}
            {!hasActiveInteraction ? (
              easyMode ? (
                // iOS DetailTerminalLayout: easy mode replaces the whole input
                // bar with the 2×4 keyboard (only when no interaction card is
                // showing).
                <EasyModeKeyboard onSendKey={(key) => void handleSendKey(key)} />
              ) : (
                <InputBar
                  index={workspace.index}
                  surfaceId={workspace.surfaceId ?? null}
                  workspaceID={workspaceID(workspace)}
                  workspaceUUID={workspace.uuid}
                  onOpenTools={(tool) => setToolsModal(tool)}
                />
              )
            ) : null}
          </div>
        ) : tab === "git" ? (
          <GitStatusView
            workspace={workspace}
            onJumpToTerminal={() => setTabAndMaybeDisableEasy("terminal")}
          />
        ) : tab === "activity" ? (
          <div className="activity-tab-panel">
            <ActivityTab workspace={workspace} />
          </div>
        ) : (
          <div className="skills-tab-panel">
            <SkillsTab
              key={paneKey}
              index={workspace.index}
              onJumpToTerminal={() => setTabAndMaybeDisableEasy("terminal")}
            />
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

      {/* Phase 5 tools modals (iOS sheetPresented: fileSearch / jiraTickets) */}
      {toolsModal === "fileSearch" ? (
        <FileSearchModal
          index={workspace.index}
          onJumpToTerminal={() => setTabAndMaybeDisableEasy("terminal")}
          onClose={() => setToolsModal(null)}
        />
      ) : null}
      {toolsModal === "jira" ? (
        <JiraModal
          onJumpToTerminal={() => setTabAndMaybeDisableEasy("terminal")}
          onClose={() => setToolsModal(null)}
        />
      ) : null}

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
                // iOS: renameText = workspace.displayName (prompt with the
                // current name).
                setRenameValue(displayName(workspace));
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
              className="menu-item"
              onClick={() => {
                setMenuOpen(false);
                useNewSessionStore.getState().open();
              }}
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
              placeholder="Session name"
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
