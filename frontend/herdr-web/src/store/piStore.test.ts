import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  openSSE: vi.fn(),
  piSnapshot: vi.fn(),
  piModels: vi.fn(),
  piPrompt: vi.fn(),
  piSteer: vi.fn(),
  piFollowUp: vi.fn(),
  piAbort: vi.fn(),
  piSetModel: vi.fn(),
  piSetThinkingLevel: vi.fn(),
  piRespond: vi.fn(),
}));

vi.mock("../api/sse", () => ({
  openSSE: mocks.openSSE,
}));
vi.mock("../api/pi", () => ({
  piSnapshot: mocks.piSnapshot,
  piModels: mocks.piModels,
  piPrompt: mocks.piPrompt,
  piSteer: mocks.piSteer,
  piFollowUp: mocks.piFollowUp,
  piAbort: mocks.piAbort,
  piSetModel: mocks.piSetModel,
  piSetThinkingLevel: mocks.piSetThinkingLevel,
  piRespond: mocks.piRespond,
  piEventsUrl: (paneId: string, after: string | number | null = null) =>
    `http://127.0.0.1:9092/api/v1/panes/${paneId}/pi/events${
      after !== null && after !== "" ? `?after=${encodeURIComponent(String(after))}` : ""
    }`,
}));

import { ApiError } from "../api/client";
import type { SseConfig } from "../api/sse";
import type { PiSemanticCapability } from "../pi/types";
import { usePiStore } from "./piStore";

const TOKEN = "tok";
const PANE_ID = "w1:p1";
const BASE = `http://127.0.0.1:9092/api/v1/panes/${PANE_ID}/pi/events`;

/** Wire envelope shape (doc 02 §3.3): event name `pi.<type>`, bare type inside. */
function envelope(
  cursor: string,
  sessionID: string | null,
  type: string,
  extra: Record<string, unknown> = {},
  connected = true,
) {
  return {
    protocol: { name: "herdr.pi.semantic", version: 1 },
    pane_id: PANE_ID,
    session_id: sessionID,
    cursor,
    connected,
    event: { type, ...extra },
    generated_at: "t",
  };
}

function snapshot(overrides: Record<string, unknown> = {}) {
  return {
    ok: true,
    protocol: { name: "herdr.pi.semantic", version: 1 },
    pane_id: PANE_ID,
    connected: true,
    available: true,
    session: { id: "sess-1" },
    // Reports context usage (the `context` key is present) → live SSE path.
    state: { working: false, context: { tokens: 10, contextWindow: 1000, percent: 1 } },
    entries: [],
    pending_interactions: [],
    cursor: "100",
    oldest_cursor: "1",
    truncated: false,
    generated_at: "t0",
    ...overrides,
  };
}

/** Legacy-bridge snapshot: no `state.context` key. */
function legacySnapshot(overrides: Record<string, unknown> = {}) {
  return snapshot({ state: { working: false }, ...overrides });
}

const PI_SEMANTIC: PiSemanticCapability = {
  available: true,
  connected: true,
  protocolVersion: 1,
  sessionID: "sess-1",
  cursor: null,
  oldestCursor: null,
  capabilities: {
    prompt: true,
    steer: true,
    followUp: true,
    abort: true,
    listModels: false,
    setModel: true,
    setThinkingLevel: false,
    interactionResponse: true,
  },
  generatedAt: null,
};

const sseConfigs: SseConfig[] = [];
function lastSseConfig(): SseConfig {
  const config = sseConfigs[sseConfigs.length - 1];
  if (!config) throw new Error("openSSE was not called");
  return config;
}
function feedSse(config: SseConfig, eventName: string, payload: unknown, id: string | null): void {
  config.onEvent(eventName, JSON.stringify(payload), id);
}
async function flush(): Promise<void> {
  await vi.advanceTimersByTimeAsync(0);
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  sseConfigs.length = 0;
  mocks.openSSE.mockImplementation((config: SseConfig) => {
    sseConfigs.push(config);
    return { close: vi.fn() };
  });
});

afterEach(() => {
  usePiStore.getState().stop(PANE_ID);
  vi.useRealTimers();
});

describe("piStore", () => {
  it("fresh bridge: snapshot (reports context usage) → SSE from the snapshot cursor, events flow to the reducer", async () => {
    mocks.piSnapshot.mockResolvedValue(snapshot());

    usePiStore.getState().follow(PANE_ID, TOKEN, PI_SEMANTIC);
    await flush();

    expect(mocks.piSnapshot).toHaveBeenCalledTimes(1);
    expect(sseConfigs).toHaveLength(1);
    const config = sseConfigs[0];
    expect(config.cursorKind).toBe("opaque-after");
    expect(config.token).toBe(TOKEN);
    expect(config.backoff).toEqual({ initialMs: 650, factor: 1.7, capMs: 6000 });
    expect(config.buildUrl(null)).toBe(`${BASE}?after=100`);
    expect(usePiStore.getState().supportsPiSemanticChat).toBe(true);
    expect(usePiStore.getState().connection).toEqual({ state: "connected" });

    feedSse(config, "pi.turn_start", envelope("101", "sess-1", "turn_start"), "101");
    feedSse(
      config,
      "pi.message_start",
      envelope("102", "sess-1", "message_start", {
        message: { id: "m1", role: "user", content: [{ type: "text", text: "hello" }] },
      }),
      "102",
    );
    feedSse(config, "pi.agent_settled", envelope("103", "sess-1", "agent_settled"), "103");
    await flush();

    const state = usePiStore.getState();
    expect(state.turns).toHaveLength(1);
    expect(state.turns[0].user?.text).toBe("hello");
    expect(state.phase).toBe("idle");
    expect(state.lastError).toBeNull();
  });

  it("legacy bridge (no state.context): 2 s poll loop, auto-upgrades to SSE from the snapshot cursor", async () => {
    mocks.piSnapshot
      .mockResolvedValueOnce(legacySnapshot())
      .mockResolvedValueOnce(legacySnapshot())
      .mockResolvedValue(snapshot({ cursor: "120" }));

    usePiStore.getState().follow(PANE_ID, TOKEN, PI_SEMANTIC);
    await flush();

    // Legacy path: no SSE yet, still showing the transcript.
    expect(sseConfigs).toHaveLength(0);
    expect(mocks.piSnapshot).toHaveBeenCalledTimes(1);
    expect(usePiStore.getState().connection).toEqual({ state: "connected" });

    await vi.advanceTimersByTimeAsync(2000); // poll 1 — still legacy, unchanged
    expect(mocks.piSnapshot).toHaveBeenCalledTimes(2);
    expect(sseConfigs).toHaveLength(0);

    await vi.advanceTimersByTimeAsync(2000); // poll 2 — new bridge appears → upgrade
    await flush();

    // Upgrade re-fetches the snapshot (call 3) and opens SSE from its cursor.
    expect(mocks.piSnapshot).toHaveBeenCalledTimes(4);
    expect(sseConfigs).toHaveLength(1);
    expect(lastSseConfig().cursorKind).toBe("opaque-after");
    expect(lastSseConfig().buildUrl(null)).toBe(`${BASE}?after=120`);
    expect(usePiStore.getState().connection).toEqual({ state: "connected" });
  });

  it("stream.reset → exactly ONE snapshot reload, then streaming resumes from the new cursor", async () => {
    mocks.piSnapshot
      .mockResolvedValueOnce(snapshot())
      .mockResolvedValue(snapshot({ cursor: "200" }));

    usePiStore.getState().follow(PANE_ID, TOKEN, PI_SEMANTIC);
    await flush();
    expect(sseConfigs).toHaveLength(1);
    expect(sseConfigs[0].buildUrl(null)).toBe(`${BASE}?after=100`);

    const config = sseConfigs[0];
    feedSse(config, "pi.stream.reset", envelope("200", "sess-1", "stream.reset", { reason: "backend_restarted" }), "200");
    await flush();

    // One authoritative reload (snapshot call 2) and one fresh stream (call 2).
    expect(mocks.piSnapshot).toHaveBeenCalledTimes(2);
    expect(sseConfigs).toHaveLength(2);
    expect(sseConfigs[1].buildUrl(null)).toBe(`${BASE}?after=200`);

    // No further spontaneous reloads.
    await vi.advanceTimersByTimeAsync(1000);
    expect(mocks.piSnapshot).toHaveBeenCalledTimes(2);
    expect(sseConfigs).toHaveLength(2);
  });

  it("stream drop → 650 ms backoff, attempt 1, reconnect from the snapshot (lastId) cursor", async () => {
    mocks.piSnapshot
      .mockResolvedValueOnce(snapshot())
      .mockResolvedValue(snapshot({ cursor: "150" }));

    usePiStore.getState().follow(PANE_ID, TOKEN, PI_SEMANTIC);
    await flush();
    const config = sseConfigs[0];
    feedSse(config, "pi.bridge.connection", envelope("150", "sess-1", "bridge.connection", { connected: true }), "150");

    // The stream drops: openSSE reports reconnecting → the follow loop owns the backoff.
    config.onState("reconnecting", 1);
    await flush();

    expect(usePiStore.getState().connection).toEqual({ state: "reconnecting", attempt: 1 });
    expect(sseConfigs).toHaveLength(1);

    await vi.advanceTimersByTimeAsync(649);
    expect(sseConfigs).toHaveLength(1); // not yet — backoff is 650 ms
    await vi.advanceTimersByTimeAsync(1);
    await flush();

    expect(mocks.piSnapshot).toHaveBeenCalledTimes(2);
    expect(sseConfigs).toHaveLength(2);
    expect(sseConfigs[1].buildUrl(null)).toBe(`${BASE}?after=150`);
  });

  it("protocol v2 snapshot → .unavailable with the byte-exact message, no streams opened", async () => {
    mocks.piSnapshot.mockResolvedValue(
      snapshot({ protocol: { name: "herdr.pi.semantic", version: 2 } }),
    );

    usePiStore.getState().follow(PANE_ID, TOKEN, PI_SEMANTIC);
    await flush();

    const state = usePiStore.getState();
    expect(state.connection).toEqual({ state: "unavailable" });
    expect(state.lastError).toBe(
      "This Pi session does not expose a compatible native transcript.",
    );
    expect(mocks.openSSE).not.toHaveBeenCalled();
  });

  it("commands: prompt posts trimmed {text}, follow-up queues, 501 surfaces the byte-exact message", async () => {
    mocks.piSnapshot.mockResolvedValue(snapshot());
    mocks.piPrompt.mockResolvedValue({ ok: true });
    mocks.piSetModel.mockRejectedValue(
      new ApiError("unsupported", "model_switching not supported", 501),
    );

    usePiStore.getState().follow(PANE_ID, TOKEN, PI_SEMANTIC);
    await flush();
    const config = lastSseConfig();
    feedSse(config, "pi.bridge.connection", envelope("101", "sess-1", "bridge.connection", { connected: true }), "101");

    await usePiStore.getState().prompt("  hello  ");
    expect(mocks.piPrompt).toHaveBeenCalledWith(PANE_ID, { text: "hello" });
    expect(usePiStore.getState().commandNotice).toBeNull();

    mocks.piFollowUp.mockResolvedValue({ success: true });
    await usePiStore.getState().followUp("next");
    expect(mocks.piFollowUp).toHaveBeenCalledWith(PANE_ID, { text: "next" });
    expect(usePiStore.getState().commandNotice).toBe("Follow-up queued");

    await usePiStore.getState().setModel("fireworks", "deepseek-v4-flash-0731");
    expect(mocks.piSetModel).toHaveBeenCalledWith(PANE_ID, {
      provider: "fireworks",
      id: "deepseek-v4-flash-0731",
    });
    expect(usePiStore.getState().lastError).toBe(
      "Model switching isn't supported by this Pi session",
    );
  });
});
