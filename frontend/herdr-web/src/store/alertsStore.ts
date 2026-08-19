/**
 * Alerts store.
 *
 * `unreadCount` tracks the server's total (the /alerts list is capped, e.g.
 * 20 rows but unreadCount 198), so it is seeded from responses and adjusted
 * locally on upsert/markRead/readAll instead of recomputed from `alerts`.
 * API failures are absorbed (the next sync or SSE event re-converges) — this
 * store never surfaces errors.
 */

import { create } from "zustand";
import { alertRead, alertsReadAll } from "../api/herdr";
import type { Alert, AlertsResponse } from "../types/herdr";

interface AlertsStoreState {
  alerts: Alert[];
  /** Server-wide unread total (not just the visible page of alerts). */
  unreadCount: number;

  /** Applies a GET /alerts response (seed + full local re-sync). */
  sync: (response: AlertsResponse) => void;
  /** Applies an SSE alert.created / alert.updated alert. */
  upsert: (alert: Alert) => void;
  /** Optimistic mark-read + POST /alerts/{id}/read. */
  markRead: (id: string) => Promise<void>;
  /** POST /alerts/read-all + clear local unread. */
  readAll: () => Promise<void>;
}

export const useAlertsStore = create<AlertsStoreState>()((set, get) => ({
  alerts: [],
  unreadCount: 0,

  sync: (response) => {
    set({ alerts: response.alerts, unreadCount: response.unreadCount });
  },

  upsert: (alert) => {
    set((state) => {
      const index = state.alerts.findIndex((item) => item.id === alert.id);
      const alerts =
        index === -1
          ? [alert, ...state.alerts]
          : state.alerts.map((item) => (item.id === alert.id ? alert : item));
      const wasUnread = index !== -1 && !state.alerts[index]?.isRead;
      const delta = alert.isRead ? (wasUnread ? -1 : 0) : wasUnread ? 0 : 1;
      return { alerts, unreadCount: state.unreadCount + delta };
    });
  },

  markRead: async (id) => {
    const target = get().alerts.find((alert) => alert.id === id);
    const wasUnread = target !== undefined && !target.isRead;
    // Optimistic: flip locally now, confirm with the API after.
    set((state) => ({
      alerts: state.alerts.map((alert) =>
        alert.id === id ? { ...alert, isRead: true, readAt: alert.readAt ?? new Date().toISOString() } : alert,
      ),
      unreadCount: state.unreadCount - (wasUnread ? 1 : 0),
    }));
    try {
      await alertRead(id);
    } catch {
      // Keep the optimistic flip; the next sync/SSE re-converges.
    }
  },

  readAll: async () => {
    try {
      const response = await alertsReadAll();
      set((state) => ({
        alerts: state.alerts.map((alert) => ({
          ...alert,
          isRead: true,
          readAt: alert.readAt ?? new Date().toISOString(),
        })),
        unreadCount: response.unreadCount,
      }));
    } catch {
      // Silent: a failed read-all just leaves the badge as-is.
    }
  },
}));
