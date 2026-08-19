/**
 * Global SSE stream owner.
 *
 * One authenticated stream on /api/v1/events ("int-header" cursor: the
 * Last-Event-ID header carries the remembered id across reconnects). The
 * stream is the backbone of the app: instead of parsing individual journal
 * events (hundreds per second of pi.* traffic), every "something changed"
 * signal funnels into ONE debounced (~500 ms) /workspaces refetch.
 *
 * Dispatch rules (exact):
 *  - "ready"                 → record lastEventId, mark connected.
 *  - "stream.reset"          → the NORMAL resync path (replay_gap /
 *                              backend_restarted): cancel any pending
 *                              debounced refetch and do EXACTLY ONE silent
 *                              /workspaces refresh. No user-visible error.
 *  - "snapshot.updated"      → arm the debounced refetch.
 *  - "connection.changed"    → connectionStore.
 *  - "alert.created" /
 *    "alert.updated"         → alertsStore.upsert (the broker envelope nests
 *                              the alert at payload.data).
 *  - pi bridge lifecycle
 *    (bridge.connection, session_start, session_shutdown,
 *    session_info_changed, session_tree) → arm the debounced refetch.
 *  - "push.*"                → ignored.
 *  - EVERYTHING else (raw herdr events, all pi.* journal re-publications)
 *    → the same debounced refetch arm. Never parsed into global state.
 */

import { create } from "zustand";
import { openSSE } from "../api/sse";
import type { SseHandle, SseState } from "../api/sse";
import { HERDR_BASE_URL } from "../api/herdr";
import { useAlertsStore } from "./alertsStore";
import { useConnectionStore } from "./connectionStore";
import { useWorkspacesStore } from "./workspacesStore";
import type { Alert } from "../types/herdr";

/** Debounce window for snapshot/journal-driven refetches. */
const REFETCH_DEBOUNCE_MS = 500;

export interface EventStreamState {
  started: boolean;
  /** True after a "ready" payload on the live stream. */
  connected: boolean;
  /** lastEventId from the latest "ready" payload (debug/tests). */
  lastEventId: number | null;
  /** Monotonic debug/test counter of /workspaces refetches triggered here. */
  refetchCount: number;

  /** Opens the global stream (idempotent — stops any existing one first). */
  start: (token: string) => void;
  /** Closes the stream and any pending refetch. */
  stop: () => void;
}

let handle: SseHandle | null = null;
let refetchTimer: ReturnType<typeof setTimeout> | null = null;

function cancelPendingRefetch(): void {
  if (refetchTimer !== null) {
    clearTimeout(refetchTimer);
    refetchTimer = null;
  }
}

function bumpRefetchCount(): void {
  useEventStreamStore.setState((state) => ({ refetchCount: state.refetchCount + 1 }));
}

/** The single refetch arm: at most one /workspaces fetch per window. */
function armRefetch(): void {
  if (refetchTimer !== null) {
    return;
  }
  refetchTimer = setTimeout(() => {
    refetchTimer = null;
    void useWorkspacesStore.getState().refresh();
    bumpRefetchCount();
  }, REFETCH_DEBOUNCE_MS);
}

function stopAll(): void {
  handle?.close();
  handle = null;
  cancelPendingRefetch();
  useConnectionStore.getState().setStreamOpen(false);
}

function asAlert(value: unknown): Alert | null {
  if (value !== null && typeof value === "object") {
    const candidate = value as Partial<Alert>;
    if (
      typeof candidate.id === "string" &&
      typeof candidate.kind === "string" &&
      typeof candidate.isRead === "boolean"
    ) {
      return value as Alert;
    }
  }
  return null;
}

/** Alerts arrive as a broker envelope {id, event, data: <alert>, generatedAt}. */
function extractAlert(payload: unknown): Alert | null {
  const direct = asAlert(payload);
  if (direct !== null) {
    return direct;
  }
  if (payload !== null && typeof payload === "object") {
    return asAlert((payload as { data?: unknown }).data);
  }
  return null;
}

function dispatch(event: string, data: string): void {
  let payload: unknown;
  try {
    payload = JSON.parse(data);
  } catch {
    return; // Malformed frame — drop it; never surface.
  }

  if (event === "ready") {
    const ready = payload as { lastEventId?: unknown };
    useEventStreamStore.setState({
      connected: true,
      ...(typeof ready.lastEventId === "number" ? { lastEventId: ready.lastEventId } : {}),
    });
    return;
  }

  if (event === "stream.reset") {
    // The normal resync path: the server dropped our cursor (replay gap or
    // backend restart) and replayed from a fresh baseline. Silent, exactly
    // one refresh — and it supersedes whatever the replay batch already armed.
    const reason = (payload as { reason?: unknown }).reason;
    if (reason === "replay_gap" || reason === "backend_restarted") {
      cancelPendingRefetch();
      void useWorkspacesStore.getState().refresh();
      bumpRefetchCount();
    }
    return;
  }

  if (event === "connection.changed") {
    // Broker envelope: {state, error} arrives nested at payload.data.
    const inner = (payload as { data?: unknown } | null)?.data;
    const body =
      inner !== null && typeof inner === "object" && "state" in inner ? inner : payload;
    useConnectionStore
      .getState()
      .applyConnectionChanged(body as { state?: string; error?: string | null });
    return;
  }

  if (event === "alert.created" || event === "alert.updated") {
    const alert = extractAlert(payload);
    if (alert !== null) {
      useAlertsStore.getState().upsert(alert);
    }
    return;
  }

  if (event.startsWith("push.")) {
    // Push delivery bookkeeping — not our business.
    return;
  }

  // "snapshot.updated", the named pi bridge/session lifecycle events, raw
  // herdr events, and every pi.* journal re-publication share this arm.
  armRefetch();
}

function handleState(state: SseState): void {
  useConnectionStore.getState().setStreamOpen(state === "open");
}

export const useEventStreamStore = create<EventStreamState>()((set) => ({
  started: false,
  connected: false,
  lastEventId: null,
  refetchCount: 0,

  start: (token) => {
    stopAll();
    set({ started: true, connected: false, lastEventId: null, refetchCount: 0 });
    handle = openSSE({
      buildUrl: () => `${HERDR_BASE_URL}/events`,
      token,
      cursorKind: "int-header",
      onEvent: dispatch,
      onState: handleState,
    });
  },

  stop: () => {
    stopAll();
    set({ started: false, connected: false });
  },
}));
