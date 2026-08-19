/**
 * Connection state store.
 *
 * State is driven by three inputs:
 *  - the initial /health probe (`probe()`): herdr.connected decides Live vs
 *    Unavailable, a network/auth failure is Offline;
 *  - SSE "connection.changed" events (payload {state, error} from
 *    herdr_harness/service.py — `state === "connected"` means the herdr
 *    event stream is attached);
 *  - eventStream liveness: an open SSE stream means the backend is reachable,
 *    so "Offline" is at least upgraded away.
 *
 * "Demo" is a manual mode (setDemo) that suppresses probe-driven transitions.
 */

import { create } from "zustand";
import { health as fetchHealth } from "../api/herdr";
import { setToken as persistToken } from "../api/client";
import type { Health } from "../types/herdr";

export type ConnectionStatus = "Offline" | "Connecting" | "Live" | "Demo" | "Unavailable";

/** herdr_harness/service.py publishes {state, error} on "connection.changed". */
export interface ConnectionChangedPayload {
  state?: string;
  error?: string | null;
}

interface ConnectionStoreState {
  status: ConnectionStatus;
  /** True while the global SSE stream is open (from eventStream). */
  streamOpen: boolean;
  /** herdr block from the last successful /health probe. */
  herdr: Health["herdr"] | null;
  /** Last herdr event-stream state seen via "connection.changed". */
  herdrEventsConnected: boolean | null;
  /** Epoch ms of the last successful /health probe. */
  lastProbeAt: number | null;
  demo: boolean;

  /** Persists the bearer token (client.ts localStorage) for the API layer. */
  setToken: (token: string) => void;
  /** Manual demo mode: pins the status to "Demo" and skips probe upgrades. */
  setDemo: (demo: boolean) => void;
  /** Called by the global SSE stream on open/closed transitions. */
  setStreamOpen: (open: boolean) => void;
  /** Applies an SSE "connection.changed" payload. */
  applyConnectionChanged: (payload: ConnectionChangedPayload) => void;
  /** Initial (or retry) /health probe. */
  probe: () => Promise<void>;
}

export const useConnectionStore = create<ConnectionStoreState>()((set, get) => ({
  status: "Offline",
  streamOpen: false,
  herdr: null,
  herdrEventsConnected: null,
  lastProbeAt: null,
  demo: false,

  setToken: (token) => {
    persistToken(token);
  },

  setDemo: (demo) => {
    set({ demo, status: demo ? "Demo" : "Offline" });
  },

  setStreamOpen: (open) => {
    const { status } = get();
    // A live stream means the backend answered an authenticated request —
    // at least not Offline.
    set({
      streamOpen: open,
      ...(open && status === "Offline" && !get().demo ? { status: "Live" as const } : {}),
    });
  },

  applyConnectionChanged: (payload) => {
    const connected = payload.state === "connected";
    const { demo, status } = get();
    if (demo) {
      set({ herdrEventsConnected: connected });
      return;
    }
    // The stream itself is our connectivity signal: "connected" upgrades any
    // degraded status; a drop demotes a good status to Unavailable.
    let next = status;
    if (connected) {
      next = "Live";
    } else if (status === "Live" || status === "Connecting") {
      next = "Unavailable";
    }
    set({ herdrEventsConnected: connected, status: next });
  },

  probe: async () => {
    if (get().demo) {
      return;
    }
    set({ status: "Connecting" });
    try {
      const result = await fetchHealth();
      set({
        herdr: result.herdr,
        lastProbeAt: Date.now(),
        status: result.herdr?.connected ? "Live" : "Unavailable",
      });
    } catch {
      // Network/auth failure — the backend is unreachable from here.
      set({ status: "Offline" });
    }
  },
}));
