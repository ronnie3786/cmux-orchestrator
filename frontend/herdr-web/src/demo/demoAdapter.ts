/**
 * Demo mode adapter — answers the app's API calls from DemoData.swift's
 * port instead of the network. The seam lives in api/client.ts
 * (`setDemoRequestHandler`): while demo mode is on, every `apiRequest`
 * consults `demoRequest()` before fetching.
 *
 * Contract:
 *  - GET workspaces / alerts / health / single workspace → demo data
 *    (alerts are mutable — mark-read converges the badge).
 *  - terminal snapshot → empty output (streamless demo terminals); Pi
 *    snapshot → `available: false` (empty chat state).
 *  - anything else → a benign 501 rejection, NEVER a live fetch: a real
 *    request with no token would 401 and the onUnauthorized hook would
 *    eject the user back to onboarding mid-demo.
 */

import { ApiError } from "../api/client";
import { useAlertsStore } from "../store/alertsStore";
import { useConnectionStore } from "../store/connectionStore";
import { useEventStreamStore } from "../store/eventStream";
import { useWorkspacesStore } from "../store/workspacesStore";
import type { Alert } from "../types/herdr";
import {
  demoAlerts,
  demoAlertsResponse,
  demoHealth,
  demoPiSnapshotResponse,
  demoTerminalOutputResponse,
  demoWorkspaceResponse,
  demoWorkspacesResponse,
} from "./demoData";

/** The single demo-mode flag — connectionStore.status derives "Demo" from it. */
export function demoEnabled(): boolean {
  return useConnectionStore.getState().demo;
}

/** Mutable alert journal for the current demo session (cloned on enable). */
let sessionAlerts: Alert[] = [];

function unreadCount(alerts: Alert[]): number {
  return alerts.filter((alert) => !alert.isRead).length;
}

function markRead(alerts: Alert[], id: string): Alert | undefined {
  const index = alerts.findIndex((alert) => alert.id === id);
  if (index === -1) return undefined;
  const current = alerts[index];
  if (current === undefined) return undefined;
  const updated: Alert = { ...current, isRead: true, readAt: current.readAt ?? new Date().toISOString() };
  alerts[index] = updated;
  return updated;
}

/** Route one request path (relative, e.g. "/workspaces") to demo data. */
export function demoRequest(path: string): unknown {
  if (!demoEnabled()) {
    return undefined;
  }
  // Lazily seeded so any request path (not just enableDemoMode) serves the
  // journal; re-cloned after disableDemoMode resets it.
  if (sessionAlerts.length === 0) {
    sessionAlerts = demoAlerts.map((alert) => ({ ...alert }));
  }
  const route = path.split("?")[0] ?? path;

  if (route === "/health") {
    return { ...demoHealth, alerts: { unread: unreadCount(sessionAlerts) } };
  }
  if (route === "/workspaces") {
    return demoWorkspacesResponse(sessionAlerts);
  }
  if (route.startsWith("/workspaces/")) {
    const id = decodeURIComponent(route.slice("/workspaces/".length));
    const workspace = demoWorkspaceResponse(id);
    if (workspace !== undefined) {
      return { ok: true, workspace };
    }
  }
  if (route === "/alerts") {
    return demoAlertsResponse(sessionAlerts);
  }
  if (route === "/alerts/read-all") {
    sessionAlerts = sessionAlerts.map((alert) => ({
      ...alert,
      isRead: true,
      readAt: alert.readAt ?? new Date().toISOString(),
    }));
    return demoAlertsResponse(sessionAlerts);
  }
  if (route.startsWith("/alerts/") && route.endsWith("/read")) {
    const id = decodeURIComponent(route.slice("/alerts/".length, -"/read".length));
    const alert = markRead(sessionAlerts, id);
    if (alert !== undefined) {
      return { ok: true, alert, unreadCount: unreadCount(sessionAlerts) };
    }
  }
  const outputMatch = route.match(/^\/panes\/([^/]+)\/output$/);
  if (outputMatch !== null) {
    return demoTerminalOutputResponse(decodeURIComponent(outputMatch[1]!));
  }
  const piMatch = route.match(/^\/panes\/([^/]+)\/pi\/snapshot$/);
  if (piMatch !== null) {
    return demoPiSnapshotResponse(decodeURIComponent(piMatch[1]!));
  }

  throw new ApiError(
    "not_available",
    "Not available in demo mode",
    501,
  );
}

/**
 * Enter demo mode: pin the status to "Demo", stop the live SSE stream,
 * seed the workspaces + alerts stores through the normal paths (so the
 * seam is what feeds them — no parallel state), and select the first
 * workspace/pane.
 */
export function enableDemoMode(): void {
  sessionAlerts = demoAlerts.map((alert) => ({ ...alert }));
  useConnectionStore.getState().setDemo(true);
  useEventStreamStore.getState().stop();
  useAlertsStore.getState().sync(demoAlertsResponse(sessionAlerts));
  void useWorkspacesStore
    .getState()
    .refresh()
    .then(() => {
      useWorkspacesStore.getState().repairSelection(null, null);
    });
}

/** Leave demo mode: clear the demo snapshot so live data lands cleanly. */
export function disableDemoMode(): void {
  sessionAlerts = [];
  useConnectionStore.getState().setDemo(false);
  useWorkspacesStore.setState({ data: null, lastUpdated: null });
  useAlertsStore.setState({ alerts: [], unreadCount: 0 });
}
