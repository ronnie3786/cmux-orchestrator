/**
 * Workspaces / notifications / feed store.
 *
 * Data flows in from the 2 s poll tick (App): applyStatus / applyNotifications /
 * applyFeed. Selection follows iOS HarnessFeatureSessionReducer: selecting a
 * session fires a fire-and-forget POST /api/push/clear, and marks the session's
 * notifications read optimistically (confirmed by the API call, re-synced by
 * the next poll).
 */

import { create } from "zustand";
import {
  clearPushApproval,
  markNotificationsRead as apiMarkNotificationsRead,
  starWorkspace,
} from "../api/endpoints";
import type {
  CmuxNotification,
  FeedItem,
  FeedResponse,
  HarnessStatus,
  LogEntry,
  NotificationsResponse,
  OpenCodeIntegrationResponse,
  Workspace,
} from "../api/types";
import { sessionGroupID, unreadCountForWorkspace, workspaceID } from "../lib/workspaceGroups";
import { useAttachmentsStore } from "./attachmentsStore";
import { useConnectionStore } from "./connectionStore";
import { useDraftStore } from "./draftStore";
import { useNewSessionStore } from "./newSessionStore";

interface WorkspacesStoreState {
  workspaces: Workspace[];
  notifications: CmuxNotification[];
  /** Pending feed items (approvals/questions) from /api/feed. */
  feedItems: FeedItem[];
  /** Approval/action log from /api/log (server order: newest first, iOS parity). */
  logEntries: LogEntry[];
  /** OpenCode integration status from /api/integrations/opencode (2 s poll). */
  openCodeIntegration: OpenCodeIntegrationResponse | null;
  /** Epoch ms of the last successful status poll. */
  lastUpdated: number | null;
  hasReceivedStatus: boolean;
  /** Selected session group (uuid). */
  selectedGroupID: string | null;
  /** Selected pane row id (uuid, or `uuid|surfaceId` for multi-surface rows). */
  selectedWorkspaceID: string | null;

  applyStatus: (status: HarnessStatus) => void;
  applyNotifications: (response: NotificationsResponse) => void;
  applyFeed: (response: FeedResponse) => void;
  applyLog: (entries: LogEntry[]) => void;
  applyOpenCodeIntegration: (response: OpenCodeIntegrationResponse) => void;
  /** Select a session group (keeps the selected pane, else picks primary). */
  selectGroup: (groupID: string) => void;
  /** Select a specific pane row. */
  selectWorkspace: (workspaceIDValue: string) => void;
  /** Optimistic star toggle + POST /api/workspace-star. */
  toggleStar: (index: number, starred: boolean) => void;
  /** Optimistic rename (iOS sets customName immediately, then refreshes). */
  applyCustomName: (index: number, name: string) => void;
  /** Optimistic mark-read + POST /api/notifications/read. */
  markNotificationsRead: (workspaceId?: string | null, surfaceId?: string | null) => void;
}

function reportError(message: string): void {
  useConnectionStore.setState({ errorMessage: message });
}

function pushWorkspaceID(workspace: Workspace): string {
  if (workspace.surfaceId) {
    return `${workspace.uuid}|${workspace.surfaceId}`;
  }
  return workspace.uuid;
}

function matchesNotification(
  notification: CmuxNotification,
  workspaceId?: string | null,
  surfaceId?: string | null,
): boolean {
  const workspaceMatch = workspaceId != null && workspaceId !== "" && notification.workspace_id === workspaceId;
  const surfaceMatch = surfaceId != null && surfaceId !== "" && notification.surface_id === surfaceId;
  return workspaceMatch || surfaceMatch;
}

export const useWorkspacesStore = create<WorkspacesStoreState>()((set, get) => ({
  workspaces: [],
  notifications: [],
  feedItems: [],
  logEntries: [],
  openCodeIntegration: null,
  lastUpdated: null,
  hasReceivedStatus: false,
  selectedGroupID: null,
  selectedWorkspaceID: null,

  applyStatus: (status: HarnessStatus) => {
    const workspaces = status.workspaces ?? [];
    const state = get();
    // Stale selection: the selected row disappeared from status.
    const selectionCleared =
      state.selectedWorkspaceID != null &&
      !workspaces.some((workspace) => workspaceID(workspace) === state.selectedWorkspaceID);
    set({
      workspaces,
      lastUpdated: Date.now(),
      hasReceivedStatus: true,
      ...(selectionCleared ? { selectedGroupID: null, selectedWorkspaceID: null } : {}),
    });
    // iOS `trimDrafts`: drop persisted drafts for workspaces that vanished.
    useDraftStore.getState().trimDrafts(workspaces.map((workspace) => workspaceID(workspace)));
    // Attachments are ephemeral per-workspace state — drop them the same way.
    useAttachmentsStore.getState().trim(workspaces.map((workspace) => workspaceID(workspace)));

    // iOS `refreshSucceeded`: while a new session is being created, auto-select
    // it as soon as it appears in a status poll (uuid first, then index).
    const newSession = useNewSessionStore.getState();
    if (newSession.pendingSelection) {
      const matched = newSession.resolvePendingSelection(workspaces);
      if (matched) {
        newSession.finishSelection();
        get().selectWorkspace(matched);
      }
    }
  },

  applyNotifications: (response: NotificationsResponse) => {
    set({ notifications: response.notifications ?? [] });
  },

  applyFeed: (response: FeedResponse) => {
    set({ feedItems: response.items ?? [] });
  },

  applyLog: (entries) => {
    set({ logEntries: entries });
  },

  applyOpenCodeIntegration: (response) => {
    set({ openCodeIntegration: response });
  },

  selectWorkspace: (workspaceIDValue: string) => {
    const { workspaces } = get();
    const workspace = workspaces.find((candidate) => workspaceID(candidate) === workspaceIDValue);
    set({
      selectedWorkspaceID: workspaceIDValue,
      selectedGroupID: workspace ? sessionGroupID(workspace) : null,
    });
    // iOS `loadDetailDraft`: bind the input row to the selected workspace's draft.
    useDraftStore.getState().selectDraft(workspaceIDValue);
    // ...and its attachments (terminalAttachments[workspaceID]).
    useAttachmentsStore.getState().selectWorkspace(workspaceIDValue);
    if (!workspace) return;

    // Fire-and-forget: clear any pending push approval for this session
    // (iOS clearPushApprovalEffect).
    void clearPushApproval({
      workspaceID: pushWorkspaceID(workspace),
      workspaceUUID: workspace.uuid || null,
      surfaceID: workspace.surfaceId || null,
    }).catch(() => {
      // Best effort — the next poll re-syncs.
    });

    if (unreadCountForWorkspace(workspace, get().notifications) > 0) {
      get().markNotificationsRead(workspace.uuid, workspace.surfaceUuid ?? null);
    }
  },

  selectGroup: (groupID: string) => {
    const { workspaces, selectedWorkspaceID } = get();
    const members = workspaces.filter((workspace) => sessionGroupID(workspace) === groupID);
    if (members.length === 0) return;
    const membersSorted = [...members].sort((a, b) => a.index - b.index);
    const primary = membersSorted[0];
    const preferred =
      selectedWorkspaceID && members.some((workspace) => workspaceID(workspace) === selectedWorkspaceID)
        ? selectedWorkspaceID
        : workspaceID(primary);
    get().selectWorkspace(preferred);
  },

  toggleStar: (index: number, starred: boolean) => {
    const { workspaces } = get();
    const target = workspaces.find((workspace) => workspace.index === index);
    if (!target) return;
    const uuid = target.uuid;
    const previousStarred = target.starred ?? false;

    const flip = (value: boolean) =>
      set((state) => ({
        workspaces: state.workspaces.map((workspace) =>
          workspace.uuid === uuid || workspace.index === index ? { ...workspace, starred: value } : workspace,
        ),
      }));

    flip(starred);
    starWorkspace(index, starred).catch((error: unknown) => {
      flip(previousStarred);
      reportError(error instanceof Error ? error.message : "Couldn't update star");
    });
  },

  applyCustomName: (index: number, name: string) => {
    set((state) => ({
      workspaces: state.workspaces.map((workspace) =>
        workspace.index === index ? { ...workspace, customName: name } : workspace,
      ),
    }));
  },

  markNotificationsRead: (workspaceId, surfaceId) => {
    // Optimistic: mark matching notifications read now (iOS parity).
    set((state) => ({
      notifications: state.notifications.map((notification) =>
        matchesNotification(notification, workspaceId, surfaceId) && !notification.is_read
          ? { ...notification, is_read: true }
          : notification,
      ),
    }));
    const request: Record<string, string> = {};
    if (workspaceId) request.workspaceId = workspaceId;
    if (surfaceId) request.surfaceId = surfaceId;
    if (Object.keys(request).length === 0) return;
    apiMarkNotificationsRead(request).catch((error: unknown) => {
      // Keep the optimistic read (the next poll re-syncs); surface the error.
      reportError(error instanceof Error ? error.message : "Couldn't mark notifications read");
    });
  },
}));
