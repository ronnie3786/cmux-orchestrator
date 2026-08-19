import { afterEach, describe, expect, it, vi } from "vitest";
import { openSSE } from "./sse";
import type { SseState } from "./sse";

const encoder = new TextEncoder();
const FAST_BACKOFF = { initialMs: 5, factor: 2, capMs: 50 };

function abortError(): Error {
  const error = new Error("The operation was aborted.");
  error.name = "AbortError";
  return error;
}

/** Fake SSE byte source that reacts to the fetch's AbortSignal. */
function makeSseSource(signal?: AbortSignal) {
  let controller: ReadableStreamDefaultController<Uint8Array>;
  let settled = false;
  const onAbort = () => {
    if (settled) {
      return;
    }
    settled = true;
    try {
      controller.error(abortError());
    } catch {
      // Stream already closed — the reader already saw done.
    }
  };
  if (signal) {
    signal.addEventListener("abort", onAbort, { once: true });
  }
  const stream = new ReadableStream<Uint8Array>({
    start(c) {
      controller = c;
      if (signal?.aborted) {
        onAbort();
      }
    },
  });
  return {
    stream,
    send: (text: string) => {
      if (settled) {
        return;
      }
      controller.enqueue(encoder.encode(text));
    },
    end: () => {
      if (settled) {
        return;
      }
      settled = true;
      controller.close();
    },
  };
}

type SseSource = ReturnType<typeof makeSseSource>;

function makeDocument() {
  const listeners: Record<string, Array<() => void>> = {};
  return {
    visibilityState: "visible" as "visible" | "hidden",
    addEventListener: (name: string, listener: () => void) => {
      (listeners[name] ??= []).push(listener);
    },
    removeEventListener: (name: string, listener: () => void) => {
      listeners[name] = (listeners[name] ?? []).filter((fn) => fn !== listener);
    },
    fire: (name: string) => (listeners[name] ?? []).slice().forEach((fn) => fn()),
  };
}

function setup() {
  const doc = makeDocument();
  vi.stubGlobal("document", doc);
  const fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
  const sources: SseSource[] = [];
  fetchMock.mockImplementation((_url: string, init: RequestInit) => {
    const source = makeSseSource(init?.signal as AbortSignal | undefined);
    sources.push(source);
    return Promise.resolve({ ok: true, status: 200, body: source.stream });
  });
  const calls = () =>
    fetchMock.mock.calls.map((call) => ({
      url: call[0] as string,
      headers: (call[1]?.headers ?? {}) as Record<string, string>,
    }));
  return { doc, fetchMock, sources, calls };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("openSSE", () => {
  it("parses id/event/data, joins multi-line data, drops comments, remembers id", async () => {
    const { fetchMock, sources } = setup();
    const events: Array<[string, string, string | null]> = [];
    const states: SseState[] = [];
    const handle = openSSE({
      buildUrl: () => "http://x/stream",
      token: "tok",
      cursorKind: "none",
      backoff: FAST_BACKOFF,
      onEvent: (event, data, id) => events.push([event, data, id]),
      onState: (state) => states.push(state),
    });

    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    sources[0]!.send("id: 1\nevent: hello\ndata: line1\ndata: line2\n\n: heartbeat\n\ndata: plain\n\n");
    await vi.waitFor(() => expect(events).toHaveLength(2));

    expect(events[0]).toEqual(["hello", "line1\nline2", "1"]);
    expect(events[1]).toEqual(["message", "plain", "1"]);
    expect(states).toContain("open");
    handle.close();
  });

  it("honors retry: as the reconnect delay instead of the backoff delay", async () => {
    const { fetchMock, sources } = setup();
    openSSE({
      buildUrl: () => "http://x/stream",
      token: "tok",
      cursorKind: "none",
      backoff: { initialMs: 10, factor: 2, capMs: 100 },
      onEvent: () => {},
      onState: () => {},
    });

    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    sources[0]!.send("retry: 300\n\n");
    sources[0]!.end();

    // The 10 ms backoff delay would have fired long ago; 300 ms has not.
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  });

  const cursorCases = [
    { kind: "int-header" as const, urlId: null, headerId: "42" },
    { kind: "none" as const, urlId: null, headerId: null },
    { kind: "opaque-after" as const, urlId: "42", headerId: "42" },
  ];

  it.each(cursorCases)("$kind: initial connect is fresh, reconnect carries the right cursor", async ({ kind, urlId, headerId }) => {
    const { fetchMock, sources, calls } = setup();
    const buildIds: Array<string | null> = [];
    const gotEvent = vi.fn();
    const handle = openSSE({
      buildUrl: (lastId) => {
        buildIds.push(lastId);
        return `http://x/stream?cursor=${lastId ?? "none"}`;
      },
      token: "tok",
      cursorKind: kind,
      backoff: FAST_BACKOFF,
      onEvent: gotEvent,
      onState: () => {},
    });

    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    const first = calls()[0]!;
    expect(buildIds[0]).toBeNull();
    expect(first.headers["Authorization"]).toBe("Bearer tok");
    expect(first.headers["Last-Event-ID"]).toBeUndefined();

    sources[0]!.send("id: 42\ndata: tick\n\n");
    await vi.waitFor(() => expect(gotEvent).toHaveBeenCalledTimes(1));
    sources[0]!.end();
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));

    const second = calls()[1]!;
    expect(buildIds[1]).toBe(urlId);
    if (headerId === null) {
      expect(second.headers["Last-Event-ID"]).toBeUndefined();
    } else {
      expect(second.headers["Last-Event-ID"]).toBe(headerId);
    }
    handle.close();
  });

  it("hidden: closes the fetch without reconnecting; visible: reopens with cursor", async () => {
    const { doc, fetchMock, sources, calls } = setup();
    const buildIds: Array<string | null> = [];
    const gotEvent = vi.fn();
    const handle = openSSE({
      buildUrl: (lastId) => {
        buildIds.push(lastId);
        return `http://x/stream/${buildIds.length}`;
      },
      token: "tok",
      cursorKind: "int-header",
      backoff: FAST_BACKOFF,
      onEvent: gotEvent,
      onState: () => {},
    });

    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    sources[0]!.send("id: 7\ndata: live\n\n");
    await vi.waitFor(() => expect(gotEvent).toHaveBeenCalledTimes(1));

    doc.visibilityState = "hidden";
    doc.fire("visibilitychange");
    // A (wrong) backoff-driven reconnect would appear here.
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(fetchMock).toHaveBeenCalledTimes(1);

    doc.visibilityState = "visible";
    doc.fire("visibilitychange");
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    const second = calls()[1]!;
    expect(second.headers["Authorization"]).toBe("Bearer tok");
    expect(second.headers["Last-Event-ID"]).toBe("7");
    expect(buildIds[1]).toBeNull();
    handle.close();
  });

  it("close() is idempotent and reports closed exactly once", async () => {
    const { fetchMock } = setup();
    const states: SseState[] = [];
    const handle = openSSE({
      buildUrl: () => "http://x/stream",
      token: "tok",
      cursorKind: "none",
      backoff: FAST_BACKOFF,
      onEvent: () => {},
      onState: (state) => states.push(state),
    });

    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    handle.close();
    handle.close();

    expect(states.filter((state) => state === "closed")).toHaveLength(1);
  });
});
