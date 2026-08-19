/**
 * Terminal store (P5) — ONE pane at a time (the server caps concurrent
 * terminal observers; the web shell watches only the selected pane).
 *
 * Mirrors PaneSessionView.swift's wiring (doc 01 §4.5): on pane change →
 * reset → forced initial snapshot (GET /panes/{id}/output) → a task group of
 * the frame stream (SSE /panes/{id}/stream?cols=100&rows=32, backoff
 * 0.65 s ×1.7 cap 5 s) and the 850 ms snapshot poll, arbitrated by
 * TerminalRefreshPolicy (ported in ../terminal/refreshPolicy.ts).
 *
 * Source states (Models/TerminalSource.swift): connecting / live / watching
 * / offline. "watching" = snapshot polling only (the stream is down but
 * snapshots succeed); "offline" = both paths failing (or a terminal.closed /
 * terminal.error / 503 terminal_observer_unavailable).
 *
 * renderSource decides what the view renders: "stream" → the grid (styled
 * runs); "snapshot" → the plain snapshot lines. When the policy says the
 * snapshot wins, the grid is ALSO updated by applying the snapshot text as a
 * synthetic full frame, so stream frames can resume seamlessly (a reconnect
 * always begins with a full frame anyway).
 */

import { create } from "zustand";
import { ApiError } from "../api/client";
import { terminalOutput, terminalStreamUrl } from "../api/terminal";
import { openSSE, type SseHandle, type SseState } from "../api/sse";
import { makeTerminalFrame, type TerminalFrame } from "../terminal/frame";
import { TerminalGrid } from "../terminal/grid";
import { isStreamStale, shouldDisplaySnapshot } from "../terminal/refreshPolicy";
import { TerminalSSEParser, TerminalStreamError } from "../terminal/sseParser";

export type TerminalSource = "connecting" | "live" | "watching" | "offline";

/** doc 01 §4.5: snapshot poll every 850 ms. */
export const SNAPSHOT_POLL_MS = 850;
/** doc 01 §4.5: the stream attach dimension. */
export const STREAM_COLS = 100;
export const STREAM_ROWS = 32;
/** doc 01 §4.5: reconnect backoff 0.65 s ×1.7 cap 5 s. */
export const STREAM_BACKOFF = { initialMs: 650, factor: 1.7, capMs: 5000 };

interface TerminalStoreState {
  paneId: string | null;
  source: TerminalSource;
  frameSequence: number;
  cols: number;
  rows: number;
  snapshotRevision: number | null;
  snapshotText: string | null;
  renderSource: "stream" | "snapshot";
  lastError: string | null;
  /** The live grid handle (replaced on each openPane; mutated in place). */
  grid: TerminalGrid | null;

  openPane: (paneId: string, token: string) => void;
  closePane: () => void;
  /** Forced snapshot poll (the toolbar "refresh" button). */
  refreshNow: () => void;
}

// One pane at a time, so module-scoped handles are safe. The session
// generation guards callbacks from a superseded pane.
let session = 0;
let sseHandle: SseHandle | null = null;
let pollTimer: ReturnType<typeof setInterval> | null = null;
let pollInFlight = false;
let lastStreamActivityAt: number | null = null;
let lastSnapshotText = "";
let snapshotHealthy = true;

function parseJson(data: string): unknown {
  try {
    return JSON.parse(data);
  } catch {
    return null;
  }
}

/** Best-effort extraction of the server's message from a terminal.closed / terminal.error payload. */
function streamEndMessage(data: string): string {
  const payload = parseJson(data);
  if (payload !== null && typeof payload === "object" && !Array.isArray(payload)) {
    const obj = payload as Record<string, unknown>;
    if (typeof obj.message === "string" && obj.message) {
      return obj.message;
    }
    const nested = obj.error;
    if (nested !== null && typeof nested === "object") {
      const message = (nested as { message?: unknown }).message;
      if (typeof message === "string" && message) {
        return message;
      }
    }
  }
  return data.trim() !== "" ? data : "Terminal stream closed.";
}

export const useTerminalStore = create<TerminalStoreState>()((set, get) => {
  const stopPoll = (): void => {
    if (pollTimer !== null) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  };

  /**
   * Stream state changed to "down" (reconnecting): snapshots are the only
   * source left. Snapshot healthy → watching; both failing → offline.
   * Snapshot failing while the stream is still fresh → no error pill (stay).
   */
  const onStreamDown = (): void => {
    if (get().paneId === null) {
      return;
    }
    if (snapshotHealthy) {
      set({ source: "watching" });
    } else if (isStreamStale(lastStreamActivityAt)) {
      set({
        source: "offline",
        lastError: get().lastError ?? "Terminal stream disconnected.",
      });
    }
  };

  const handleReady = (data: string): void => {
    // The parser discards ready's payload; cols/rows come from the raw data.
    const payload = parseJson(data) as
      | { paneId?: unknown; cols?: unknown; rows?: unknown }
      | null;
    lastStreamActivityAt = Date.now();
    const cols =
      payload !== null && Number.isFinite(payload.cols) ? (payload.cols as number) : STREAM_COLS;
    const rows =
      payload !== null && Number.isFinite(payload.rows) ? (payload.rows as number) : STREAM_ROWS;
    set({ cols, rows, source: "live", lastError: null });
  };

  const handleFrame = (expectedSession: number, frame: TerminalFrame): void => {
    if (expectedSession !== session) {
      return;
    }
    lastStreamActivityAt = Date.now();
    const grid = get().grid;
    if (grid === null) {
      return;
    }
    // A rejected stale/invalid frame is a no-op, not an error: only an
    // applied frame advances frameSequence.
    const applied = grid.apply(frame);
    if (applied) {
      set({ frameSequence: frame.seq, renderSource: "stream", source: "live" });
    }
  };

  /** terminal.closed / terminal.error — the parser ends the stream here. */
  const handleStreamEnd = (expectedSession: number, data: string): void => {
    if (expectedSession !== session) {
      return;
    }
    const message = streamEndMessage(data);
    sseHandle?.close();
    sseHandle = null;
    set({ source: "offline", lastError: message });
  };

  const handleEvent = (
    expectedSession: number,
    parser: TerminalSSEParser,
    event: string,
    data: string,
  ): void => {
    if (expectedSession !== session) {
      return;
    }
    // The ported parser is the single frame-parsing path (1:1 with the
    // Swift TerminalSSEParser): feed the block back as SSE lines and route
    // its dispatched events to the store handlers.
    let parsed: ReturnType<TerminalSSEParser["consume"]> = null;
    try {
      if (event !== "message") parser.consume(`event: ${event}`);
      for (const line of data.split("\n")) {
        parsed = parser.consume(`data: ${line}`) ?? parsed;
      }
      parsed = parser.consume("") ?? parsed;
    } catch (error) {
      if (error instanceof TerminalStreamError && error.code === "streamEnded") {
        handleStreamEnd(expectedSession, data);
        return;
      }
      // "invalidResponse": an undecodable frame — a no-op, not an error
      // (matches the pre-parser inline behavior for malformed frames).
      return;
    }
    switch (parsed?.kind) {
      case "ready":
        handleReady(data);
        break;
      case "frame":
        handleFrame(expectedSession, parsed.frame);
        break;
      case "activity":
      default:
        // Heartbeats / unknown events are keep-alives — nothing to do.
        break;
    }
  };

  const handleState = (expectedSession: number, state: SseState): void => {
    if (expectedSession !== session) {
      return;
    }
    if (state === "open") {
      // First byte of a (re)connected stream — fresh activity.
      lastStreamActivityAt = Date.now();
    } else if (state === "reconnecting") {
      onStreamDown();
    }
    // "closed" is our own closePane — nothing to do.
  };

  const poll = async (force: boolean, expectedSession: number): Promise<void> => {
    const paneId = get().paneId;
    if (paneId === null || pollInFlight || expectedSession !== session) {
      return;
    }
    pollInFlight = true;
    const seqBefore = get().frameSequence;
    try {
      const response = await terminalOutput(paneId);
      if (expectedSession !== session) {
        return;
      }
      const text = response.output.text;
      const advanced = get().frameSequence !== seqBefore;
      const replace = shouldDisplaySnapshot({
        force,
        streamAdvancedDuringRequest: advanced,
        snapshotChangedWithoutFrame: text !== lastSnapshotText && !advanced,
        lastStreamActivityAt,
      });
      const grid = get().grid;
      if (replace && grid !== null) {
        // Snapshot wins: swap the grid to the snapshot content as a synthetic
        // full frame (seq pinned at lastSequence so no frame is made "stale"
        // by the replacement).
        grid.apply(
          makeTerminalFrame(text, true, grid.lastSequence, grid.columns, grid.rows),
        );
      }
      lastSnapshotText = text;
      snapshotHealthy = true;
      set({
        snapshotText: text,
        snapshotRevision: response.output.revision,
        renderSource: replace ? "snapshot" : get().renderSource,
      });
    } catch (error) {
      if (expectedSession !== session) {
        return;
      }
      snapshotHealthy = false;
      const message = error instanceof Error ? error.message : "Snapshot unavailable.";
      if (
        error instanceof ApiError &&
        error.status === 503 &&
        error.code === "terminal_observer_unavailable"
      ) {
        // Server's message verbatim.
        set({ source: "offline", lastError: message });
      } else if (isStreamStale(lastStreamActivityAt)) {
        // Both paths failing — surface the error.
        set({ source: "offline", lastError: message });
      }
      // Snapshot failing while the stream is fresh: no error pill — the grid
      // stays as the source of truth.
    } finally {
      if (expectedSession === session) {
        pollInFlight = false;
      }
    }
  };

  return {
    paneId: null,
    source: "connecting",
    frameSequence: 0,
    cols: STREAM_COLS,
    rows: STREAM_ROWS,
    snapshotRevision: null,
    snapshotText: null,
    renderSource: "stream",
    lastError: null,
    grid: null,

    openPane: (paneId, token) => {
      get().closePane();
      session += 1;
      const expectedSession = session;
      const grid = new TerminalGrid(STREAM_COLS, STREAM_ROWS);
      lastStreamActivityAt = null;
      lastSnapshotText = "";
      snapshotHealthy = true;
      pollInFlight = false;
      set({
        paneId,
        source: "connecting",
        frameSequence: 0,
        cols: STREAM_COLS,
        rows: STREAM_ROWS,
        snapshotRevision: null,
        snapshotText: null,
        renderSource: "stream",
        lastError: null,
        grid,
      });
      const parser = new TerminalSSEParser();
      sseHandle = openSSE({
        cursorKind: "none",
        token,
        backoff: STREAM_BACKOFF,
        buildUrl: () => terminalStreamUrl(paneId, STREAM_COLS, STREAM_ROWS),
        onEvent: (event, data) => handleEvent(expectedSession, parser, event, data),
        onState: (state) => handleState(expectedSession, state),
      });
      pollTimer = setInterval(() => {
        void poll(false, expectedSession);
      }, SNAPSHOT_POLL_MS);
      // Forced initial snapshot (iOS refreshOutput(forceSnapshot: true)).
      void poll(true, expectedSession);
    },

    closePane: () => {
      session += 1;
      sseHandle?.close();
      sseHandle = null;
      stopPoll();
      pollInFlight = false;
      set({
        paneId: null,
        source: "connecting",
        frameSequence: 0,
        cols: STREAM_COLS,
        rows: STREAM_ROWS,
        snapshotRevision: null,
        snapshotText: null,
        renderSource: "stream",
        lastError: null,
        grid: null,
      });
    },

    refreshNow: () => {
      void poll(true, session);
    },
  };
});
