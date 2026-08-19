/**
 * Connection state store.
 *
 * The browser is same-origin with the server, so "connected" means: the last
 * successful /api/status poll reported the engine is attached to the cmux
 * socket. The server host is display/bookkeeping only — never part of fetch
 * URLs.
 *
 * State model (iOS parity, HarnessFeature.ConnectionCard):
 *  - status poll success + status.connected      -> "connected"
 *  - status poll success + !connected + socket   -> "reconnecting"
 *  - status poll success + !connected + no socket-> "noSocket"
 *  - status poll failure while connected         -> "reconnecting" after
 *    RECONNECTING_FAILURE_THRESHOLD consecutive failures (iOS shows the error
 *    banner immediately; the dot flips once failures persist).
 */

import { create } from "zustand";
import type { HarnessStatus } from "../api/types";
import { toggleEngine } from "../api/endpoints";

const SERVER_HOST_STORAGE_KEY = "harness-web:serverHost";
export const DEFAULT_SERVER_HOST = "localhost:9091";

/**
 * Consecutive status-poll failures before a "connected" session degrades to
 * "reconnecting". 2 failures ≈ one poll cadence of margin (2 s cadence → ~4 s).
 */
const RECONNECTING_FAILURE_THRESHOLD = 2;

export type ConnectionState = "checking" | "connected" | "reconnecting" | "noSocket";

export interface ConnectionStoreState {
  /** Display/bookkeeping only (persisted). Never used in fetch URLs. */
  serverHost: string;
  connection: ConnectionState;
  /** Epoch ms of the last successful /api/status poll (drives "Updated HH:MM"). */
  lastUpdated: number | null;
  errorMessage: string | null;
  /** Global engine enabled flag from the last status (drives the chip). */
  engineEnabled: boolean | null;
  /** True while a user-initiated toggleEngine call is in flight. */
  isTogglingEngine: boolean;
  /**
   * Monotonic counter bumped by features that want an immediate status poll
   * (e.g. the new-session catch-up refresh, 750 ms after creation — iOS
   * `.refresh` parity). App's polling loop watches it and runs one tick.
   */
  tickRequestCount: number;
  requestTick: () => void;
  /** When true the polling tick is skipped until connect() is called again. */
  manualDisconnect: boolean;
  consecutivePollFailures: number;

  setServerHost: (host: string) => void;
  /** Trigger an immediate re-check (error banner Retry). */
  connect: () => void;
  /** Pause polling (user-initiated). */
  disconnect: () => void;
  markStatus: (status: HarnessStatus) => void;
  markPollError: (message: string) => void;
  clearError: () => void;
  setEngineEnabled: (enabled: boolean) => Promise<void>;
}

function readStoredServerHost(): string {
  try {
    return localStorage.getItem(SERVER_HOST_STORAGE_KEY) ?? DEFAULT_SERVER_HOST;
  } catch {
    return DEFAULT_SERVER_HOST;
  }
}

export const useConnectionStore = create<ConnectionStoreState>()((set, get) => ({
  serverHost: readStoredServerHost(),
  connection: "checking",
  lastUpdated: null,
  errorMessage: null,
  engineEnabled: null,
  isTogglingEngine: false,
  tickRequestCount: 0,
  requestTick: () => {
    set({ tickRequestCount: get().tickRequestCount + 1 });
  },
  manualDisconnect: false,
  consecutivePollFailures: 0,

  setServerHost: (host: string) => {
    const trimmed = host.trim();
    try {
      if (trimmed) {
        localStorage.setItem(SERVER_HOST_STORAGE_KEY, trimmed);
      } else {
        localStorage.removeItem(SERVER_HOST_STORAGE_KEY);
      }
    } catch {
      // Storage unavailable — the host just won't persist.
    }
    set({ serverHost: trimmed || DEFAULT_SERVER_HOST });
  },

  connect: () => {
    set({ manualDisconnect: false, consecutivePollFailures: 0 });
  },

  disconnect: () => {
    set({ manualDisconnect: true });
  },

  markStatus: (status: HarnessStatus) => {
    const connection: ConnectionState =
      status.connected === true
        ? "connected"
        : status.socketFound
          ? "reconnecting"
          : "noSocket";
    set({
      connection,
      lastUpdated: Date.now(),
      errorMessage: null,
      engineEnabled: status.enabled,
      consecutivePollFailures: 0,
    });
  },

  markPollError: (message: string) => {
    const { connection, consecutivePollFailures } = get();
    const failures = consecutivePollFailures + 1;
    const nextConnection: ConnectionState =
      connection === "connected" && failures >= RECONNECTING_FAILURE_THRESHOLD
        ? "reconnecting"
        : connection;
    // The error banner shows immediately; the dot only flips to
    // "reconnecting" once failures persist (iOS parity: error banner now,
    // card state from the last good status).
    set({
      errorMessage: message,
      consecutivePollFailures: failures,
      connection: nextConnection,
    });
  },

  clearError: () => {
    set({ errorMessage: null });
  },

  setEngineEnabled: async (enabled: boolean) => {
    if (get().isTogglingEngine) return;
    const previous = get().engineEnabled;
    set({ engineEnabled: enabled, isTogglingEngine: true });
    try {
      const response = await toggleEngine(enabled);
      set({ engineEnabled: response.enabled, isTogglingEngine: false });
    } catch (error) {
      // Revert the optimistic flip and surface the error (banner shows it).
      set({
        engineEnabled: previous ?? !enabled,
        isTogglingEngine: false,
        errorMessage: error instanceof Error ? error.message : "Couldn't update auto reconnect",
      });
    }
  },
}));
