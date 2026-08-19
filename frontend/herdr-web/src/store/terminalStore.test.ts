import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  openSSE: vi.fn(),
  terminalOutput: vi.fn(),
}));

vi.mock("../api/sse", () => ({
  openSSE: mocks.openSSE,
}));
vi.mock("../api/terminal", () => ({
  terminalOutput: mocks.terminalOutput,
  terminalStreamUrl: (paneId: string, cols: number, rows: number) =>
    `http://127.0.0.1:9092/api/v1/panes/${paneId}/stream?cols=${cols}&rows=${rows}`,
}));

import { ApiError } from "../api/client";
import type { SseConfig } from "../api/sse";
import { makeTerminalFrame } from "../terminal/frame";
import { useTerminalStore } from "./terminalStore";

const TOKEN = "tok";
const PANE_ID = "w1:p1";

function snapshot(text = "line1\nline2", revision = 1) {
  return {
    ok: true,
    output: {
      pane_id: PANE_ID,
      workspace_id: "w1",
      tab_id: "w1:t1",
      source: "recent_unwrapped",
      format: "text",
      text,
      revision,
      truncated: false,
    },
    result: { type: "pane_read" },
    generatedAt: "now",
  };
}

/** The openSSE config from the most recent openPane. */
function sseConfig(): SseConfig {
  const calls = mocks.openSSE.mock.calls;
  const call = calls[calls.length - 1];
  if (!call) {
    throw new Error("openPane did not call openSSE");
  }
  return call[0];
}

function emit(event: string, payload: unknown): void {
  sseConfig().onEvent(event, JSON.stringify(payload), null);
}

function streamState(state: "open" | "reconnecting" | "closed", attempt: number): void {
  sseConfig().onState(state, attempt);
}

function openSseClose(): ReturnType<typeof vi.fn> {
  const results = mocks.openSSE.mock.results;
  return (results[results.length - 1].value as { close: ReturnType<typeof vi.fn> }).close;
}

/** Flush the forced initial snapshot poll (resolved promise → microtasks). */
async function flush(): Promise<void> {
  await vi.advanceTimersByTimeAsync(0);
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  mocks.terminalOutput.mockResolvedValue(snapshot());
  mocks.openSSE.mockImplementation(() => ({ close: vi.fn() }));
});

afterEach(() => {
  useTerminalStore.getState().closePane();
  vi.useRealTimers();
});

describe("terminalStore", () => {
  it("openPane → connecting, forced snapshot, stream wired with the P5 contract", async () => {
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await flush();

    const state = useTerminalStore.getState();
    expect(state.paneId).toBe(PANE_ID);
    expect(state.source).toBe("connecting");
    expect(state.grid).not.toBeNull();

    const config = sseConfig();
    expect(config.cursorKind).toBe("none");
    expect(config.token).toBe(TOKEN);
    expect(config.backoff).toEqual({ initialMs: 650, factor: 1.7, capMs: 5000 });
    expect(config.buildUrl(null)).toBe(
      `http://127.0.0.1:9092/api/v1/panes/${PANE_ID}/stream?cols=100&rows=32`,
    );

    // The forced initial snapshot succeeded → snapshot render source.
    expect(useTerminalStore.getState().snapshotText).toBe("line1\nline2");
    expect(useTerminalStore.getState().snapshotRevision).toBe(1);
    expect(useTerminalStore.getState().renderSource).toBe("snapshot");
  });

  it("ready → live, with the server's cols/rows", async () => {
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await flush();
    streamState("open", 0);
    emit("ready", { paneId: PANE_ID, cols: 120, rows: 40 });

    const state = useTerminalStore.getState();
    expect(state.source).toBe("live");
    expect(state.cols).toBe(120);
    expect(state.rows).toBe(40);
    expect(state.lastError).toBeNull();
  });

  it("terminal.frame → frameSequence advances and the grid updates; a stale frame does not", async () => {
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await flush();
    streamState("open", 0);
    emit("ready", { paneId: PANE_ID, cols: 100, rows: 32 });

    emit("terminal.frame", makeTerminalFrame("hello world\n", true, 7, 100, 32));
    expect(useTerminalStore.getState().frameSequence).toBe(7);
    expect(useTerminalStore.getState().source).toBe("live");
    expect(useTerminalStore.getState().renderSource).toBe("stream");
    expect(useTerminalStore.getState().grid?.plainText).toBe("hello world");

    // Replayed stale delta (seq 5 ≤ 7): apply returns false → no advance.
    emit("terminal.frame", makeTerminalFrame("stale\n", false, 5, 100, 32));
    expect(useTerminalStore.getState().frameSequence).toBe(7);
    expect(useTerminalStore.getState().grid?.plainText).toBe("hello world");
  });

  it("stream drop while snapshots succeed → watching", async () => {
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await flush();
    streamState("open", 0);
    emit("ready", { paneId: PANE_ID, cols: 100, rows: 32 });
    emit("terminal.frame", makeTerminalFrame("hi\n", true, 1, 100, 32));
    expect(useTerminalStore.getState().source).toBe("live");

    streamState("reconnecting", 1);
    expect(useTerminalStore.getState().source).toBe("watching");
  });

  it("both stream and snapshots failing → offline with the error", async () => {
    mocks.terminalOutput.mockRejectedValue(new Error("network down"));
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await vi.advanceTimersByTimeAsync(850); // forced snapshot fails

    const state = useTerminalStore.getState();
    expect(state.source).toBe("offline");
    expect(state.lastError).toBe("network down");
  });

  it("failed snapshot with a fresh stream → stays on the grid, no error pill", async () => {
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await flush();
    streamState("open", 0);
    emit("ready", { paneId: PANE_ID, cols: 100, rows: 32 });
    expect(useTerminalStore.getState().source).toBe("live");

    mocks.terminalOutput.mockRejectedValue(new Error("snapshot 500"));
    await vi.advanceTimersByTimeAsync(850);

    const state = useTerminalStore.getState();
    expect(state.source).toBe("live");
    expect(state.lastError).toBeNull();
  });

  it("503 terminal_observer_unavailable → offline with the server's message verbatim", async () => {
    const message = "Terminal observer unavailable for w1:p1";
    mocks.terminalOutput.mockRejectedValue(
      new ApiError("terminal_observer_unavailable", message, 503),
    );
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await flush();

    const state = useTerminalStore.getState();
    expect(state.source).toBe("offline");
    expect(state.lastError).toBe(message);
  });

  it("terminal.closed → ends the stream, offline with the message", async () => {
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await flush();
    streamState("open", 0);
    emit("ready", { paneId: PANE_ID, cols: 100, rows: 32 });

    emit("terminal.closed", { message: "session ended" });
    expect(openSseClose()).toHaveBeenCalledTimes(1);
    expect(useTerminalStore.getState().source).toBe("offline");
    expect(useTerminalStore.getState().lastError).toBe("session ended");
  });

  it("closePane clears pane, grid, and selection state", async () => {
    useTerminalStore.getState().openPane(PANE_ID, TOKEN);
    await flush();
    useTerminalStore.getState().closePane();

    const state = useTerminalStore.getState();
    expect(state.paneId).toBeNull();
    expect(state.grid).toBeNull();
    expect(state.snapshotText).toBeNull();
    expect(state.lastError).toBeNull();
    expect(openSseClose()).toHaveBeenCalledTimes(1);
  });
});
