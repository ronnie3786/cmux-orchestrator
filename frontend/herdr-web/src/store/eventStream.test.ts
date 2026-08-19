import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  openSSE: vi.fn(),
  workspaces: vi.fn().mockResolvedValue({ ok: true, workspaces: [], alerts: [], generatedAt: "now" }),
  alertRead: vi.fn().mockResolvedValue({ ok: true, alert: {}, unreadCount: 0 }),
  alertsReadAll: vi.fn().mockResolvedValue({ ok: true, alerts: [], unreadCount: 0 }),
  health: vi.fn().mockResolvedValue({ ok: true }),
}));

vi.mock("../api/sse", () => ({
  openSSE: mocks.openSSE,
}));
vi.mock("../api/herdr", () => ({
  HERDR_BASE_URL: "http://127.0.0.1:9092/api/v1",
  eventsUrl: () => "http://127.0.0.1:9092/api/v1/events",
  health: mocks.health,
  workspaces: mocks.workspaces,
  workspace: vi.fn(),
  alerts: vi.fn(),
  alertRead: mocks.alertRead,
  alertsReadAll: mocks.alertsReadAll,
}));

import type { SseConfig } from "../api/sse";
import { useAlertsStore } from "./alertsStore";
import { useConnectionStore } from "./connectionStore";
import { useEventStreamStore } from "./eventStream";
import { useWorkspacesStore } from "./workspacesStore";
import type { Alert } from "../types/herdr";

function sseConfig(): SseConfig {
  const call = mocks.openSSE.mock.calls[0];
  if (!call) {
    throw new Error("start() did not call openSSE");
  }
  return call[0];
}

/** Feed one SSE frame into the stream's onEvent, as the parser would. */
function emit(event: string, payload: unknown): void {
  sseConfig().onEvent(event, JSON.stringify(payload), "1");
}

const sampleAlert: Alert = {
  id: "alert_test_1",
  kind: "agent_done",
  status: "done",
  previousStatus: "working",
  severity: "success",
  title: "pi finished",
  message: "Work completed in Test: Do a thing.",
  workspaceId: "w1",
  workspaceLabel: "Test",
  tabId: "w1:t1",
  tabLabel: "t1",
  paneId: "w1:p1",
  paneTitle: "Do a thing",
  agentName: "pi",
  createdAt: "2026-01-01T00:00:00.000Z",
  isRead: false,
  readAt: null,
  action: { type: "open_pane", paneId: "w1:p1" },
};

beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
});

afterEach(() => {
  useEventStreamStore.getState().stop();
  vi.useRealTimers();
  // Reset store data between tests.
  useWorkspacesStore.setState({
    data: null,
    lastUpdated: null,
    refreshing: false,
    selectedWorkspaceId: null,
    selectedPaneId: null,
  });
  useAlertsStore.setState({ alerts: [], unreadCount: 0 });
  useConnectionStore.setState({
    status: "Offline",
    streamOpen: false,
    herdr: null,
    herdrEventsConnected: null,
    lastProbeAt: null,
    demo: false,
  });
});

describe("eventStream", () => {
  it("start() opens the stream on /events with the int-header cursor", () => {
    useEventStreamStore.getState().start("tok");
    expect(mocks.openSSE).toHaveBeenCalledTimes(1);
    const config = sseConfig();
    expect(config.cursorKind).toBe("int-header");
    expect(config.token).toBe("tok");
    expect(config.buildUrl(null)).toBe("http://127.0.0.1:9092/api/v1/events");
  });

  it("ready → replay batch → stream.reset(replay_gap) → exactly ONE silent refetch", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    useEventStreamStore.getState().start("tok");
    sseConfig().onState("open", 0);
    expect(useConnectionStore.getState().streamOpen).toBe(true);

    emit("ready", { event: "ready", generatedAt: "g", lastEventId: 100, oldestEventId: 90 });
    expect(useEventStreamStore.getState().connected).toBe(true);
    expect(useEventStreamStore.getState().lastEventId).toBe(100);

    // Replay batch: journal events arriving right after the reset baseline.
    for (let i = 0; i < 5; i += 1) {
      emit("pi.message_update", {
        id: 91 + i,
        event: "pi.message_update",
        data: { protocol: { name: "herdr.pi.semantic", version: 1 }, pane_id: "w1:p1", event: {} },
      });
    }
    expect(mocks.workspaces).not.toHaveBeenCalled();

    emit("stream.reset", {
      event: "stream.reset",
      reason: "replay_gap",
      resumeAfter: 90,
      generatedAt: "g",
    });

    // Exactly one silent refetch — immediate, not debounced.
    expect(mocks.workspaces).toHaveBeenCalledTimes(1);
    expect(useEventStreamStore.getState().refetchCount).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(useWorkspacesStore.getState().data).toEqual({
      ok: true,
      workspaces: [],
      alerts: [],
      generatedAt: "now",
    });

    // The replay batch had armed a debounced refetch — stream.reset must
    // have superseded it, not added to it.
    vi.advanceTimersByTime(5_000);
    expect(mocks.workspaces).toHaveBeenCalledTimes(1);
    expect(errorSpy).not.toHaveBeenCalled();

    // The stream state never flipped to Offline for the reset.
    expect(useConnectionStore.getState().status).toBe("Live");
  });

  it("3 snapshot.updated within 500 ms → exactly 1 refetch", () => {
    useEventStreamStore.getState().start("tok");
    sseConfig().onState("open", 0);

    emit("snapshot.updated", { id: 1, event: "snapshot.updated", data: { generatedAt: "g" } });
    vi.advanceTimersByTime(100);
    emit("snapshot.updated", { id: 2, event: "snapshot.updated", data: { generatedAt: "g" } });
    vi.advanceTimersByTime(100);
    emit("snapshot.updated", { id: 3, event: "snapshot.updated", data: { generatedAt: "g" } });
    expect(mocks.workspaces).not.toHaveBeenCalled();

    vi.advanceTimersByTime(500);
    expect(mocks.workspaces).toHaveBeenCalledTimes(1);
    expect(useEventStreamStore.getState().refetchCount).toBe(1);

    vi.advanceTimersByTime(10_000);
    expect(mocks.workspaces).toHaveBeenCalledTimes(1);
  });

  it("100 pi.message_update events → one debounced refetch, zero errors", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    useEventStreamStore.getState().start("tok");
    sseConfig().onState("open", 0);

    for (let i = 0; i < 100; i += 1) {
      emit("pi.message_update", {
        id: i,
        event: "pi.message_update",
        data: { protocol: { name: "herdr.pi.semantic", version: 1 }, pane_id: "w1:p1", event: {} },
      });
    }
    // Still within the debounce window: nothing yet.
    expect(mocks.workspaces).not.toHaveBeenCalled();

    vi.advanceTimersByTime(500);
    expect(mocks.workspaces).toHaveBeenCalledTimes(1);
    expect(useEventStreamStore.getState().refetchCount).toBe(1);

    vi.advanceTimersByTime(10_000);
    expect(mocks.workspaces).toHaveBeenCalledTimes(1);
    expect(errorSpy).not.toHaveBeenCalled();
  });

  it("push.* events are ignored entirely", () => {
    useEventStreamStore.getState().start("tok");
    sseConfig().onState("open", 0);

    emit("push.delivery", { id: 1, event: "push.delivery", data: { ok: true } });
    emit("push.approval", { id: 2, event: "push.approval", data: { token: "x" } });

    vi.advanceTimersByTime(10_000);
    expect(mocks.workspaces).not.toHaveBeenCalled();
    expect(useEventStreamStore.getState().refetchCount).toBe(0);
  });

  it("alert.created upserts into alertsStore and bumps the unread badge", () => {
    useEventStreamStore.getState().start("tok");
    useAlertsStore.getState().sync({
      ok: true,
      alerts: [],
      unreadCount: 0,
      generatedAt: "now",
    });

    emit("alert.created", { id: 10, event: "alert.created", data: sampleAlert });
    expect(useAlertsStore.getState().alerts).toEqual([sampleAlert]);
    expect(useAlertsStore.getState().unreadCount).toBe(1);
    // Alerts must not arm a workspaces refetch.
    vi.advanceTimersByTime(10_000);
    expect(mocks.workspaces).not.toHaveBeenCalled();
  });

  it("connection.changed updates connectionStore", () => {
    useEventStreamStore.getState().start("tok");
    emit("connection.changed", { id: 1, event: "connection.changed", data: { state: "connected", error: null } });
    expect(useConnectionStore.getState().herdrEventsConnected).toBe(true);
    expect(useConnectionStore.getState().status).toBe("Live");

    emit("connection.changed", { id: 2, event: "connection.changed", data: { state: "disconnected", error: "boom" } });
    expect(useConnectionStore.getState().herdrEventsConnected).toBe(false);
    expect(useConnectionStore.getState().status).toBe("Unavailable");
  });
});

describe("connection issue alert (P12-run-B)", () => {
  it("sets the issue on stream drop and clears it on reopen", () => {
    useEventStreamStore.getState().start("tok");
    sseConfig().onState("open", 0);
    expect(useEventStreamStore.getState().issue).toBeNull();

    sseConfig().onState("reconnecting", 1);
    expect(useEventStreamStore.getState().issue).toBe("Live stream dropped — reconnecting");

    sseConfig().onState("open", 1);
    expect(useEventStreamStore.getState().issue).toBeNull();
  });

  it("sets the issue from a herdr drop with the error as detail", () => {
    useEventStreamStore.getState().start("tok");
    sseConfig().onState("open", 0);

    emit("connection.changed", {
      id: 1,
      event: "connection.changed",
      data: { state: "disconnected", error: "herdr socket closed" },
    });
    expect(useEventStreamStore.getState().issue).toBe("herdr socket closed");

    emit("connection.changed", {
      id: 2,
      event: "connection.changed",
      data: { state: "connected", error: null },
    });
    expect(useEventStreamStore.getState().issue).toBeNull();
  });

  it("uses the fallback detail when the drop carries no error", () => {
    useEventStreamStore.getState().start("tok");
    sseConfig().onState("open", 0);

    emit("connection.changed", {
      id: 1,
      event: "connection.changed",
      data: { state: "disconnected", error: null },
    });
    expect(useEventStreamStore.getState().issue).toBe("herdr event stream disconnected");
  });
});
