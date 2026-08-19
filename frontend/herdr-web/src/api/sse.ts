/**
 * SSE-over-fetch client for the herdr harness.
 *
 * Unlike `EventSource` (no auth headers, fixed retry, no cursor support),
 * this opens the stream with a bearer-authenticated `fetch`, reads
 * `response.body` with a reader + TextDecoder, and implements the harness's
 * cursor semantics per `cursorKind`:
 *
 *  - "int-header":    Last-Event-ID request header carries the remembered id;
 *                     the URL never changes (buildUrl(null) every time).
 *  - "none":          no replay — every connection (including reconnects) is
 *                     a fresh attach: buildUrl(null), no Last-Event-ID.
 *  - "opaque-after":  buildUrl(lastId) so the caller can append
 *                     `?after=<lastId>`, AND the Last-Event-ID header set to
 *                     the same value.
 *
 * Backoff: exponential (default 2 s → ×2 → cap 15 s), reset after a stream
 * that stayed open ≥ 30 s. A `retry:` field in the stream overrides the delay
 * for the next reconnect. Hiding the tab closes the fetch without scheduling
 * a reconnect; becoming visible again reopens with cursor semantics when the
 * stream was open before hiding.
 */

export type SseCursorKind = "int-header" | "none" | "opaque-after";
export type SseState = "open" | "closed" | "reconnecting";

export interface SseBackoff {
  initialMs: number;
  factor: number;
  capMs: number;
}

export interface SseConfig {
  /**
   * Builds the stream URL for a connection. Receives the remembered `id`
   * (or null on the first connection / fresh attach) so the caller can
   * encode opaque cursors into the URL ("opaque-after").
   */
  buildUrl: (lastId: string | null) => string;
  token: string;
  cursorKind: SseCursorKind;
  backoff?: Partial<SseBackoff>;
  /** Every parsed event, including "ready" and "stream.reset". */
  onEvent: (event: string, data: string, id: string | null) => void;
  /** State transitions; `attempt` is the reconnect attempt (0 on first connect). */
  onState: (state: SseState, attempt: number) => void;
}

export interface SseHandle {
  /** Idempotent: stops the fetch, all timers, and all callbacks (except a final "closed"). */
  close(): void;
}

const DEFAULT_BACKOFF: SseBackoff = { initialMs: 2000, factor: 2, capMs: 15_000 };
/** A stream open this long resets the backoff delay on its next drop. */
const STABLE_OPEN_MS = 30_000;

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

export function openSSE(config: SseConfig): SseHandle {
  const backoff: SseBackoff = { ...DEFAULT_BACKOFF, ...config.backoff };

  let closed = false;
  let suspended = false;
  let wasOpenBeforeHide = false;
  let lastId: string | null = null;
  let attempt = 0;
  let retryOverrideMs: number | null = null;
  let openAt: number | null = null;
  let controller: AbortController | null = null;
  let sleepDone: (() => void) | null = null;
  let resumeDone: (() => void) | null = null;

  const nextDelayMs = (): number => {
    if (retryOverrideMs !== null) {
      return retryOverrideMs;
    }
    return Math.min(backoff.initialMs * backoff.factor ** attempt, backoff.capMs);
  };

  const wait = (ms: number) =>
    new Promise<void>((resolve) => {
      sleepDone = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        sleepDone = null;
        resolve();
      }, ms);
    });

  /** Runs one connection: fetch + full SSE parse. Returns when it drops. */
  async function connect(): Promise<void> {
    const current = new AbortController();
    controller = current;
    openAt = null;

    const headers: Record<string, string> = { Authorization: `Bearer ${config.token}` };
    let url: string;
    if (config.cursorKind === "int-header") {
      // Cursor travels in the header; the URL never changes.
      url = config.buildUrl(null);
      if (lastId !== null) {
        headers["Last-Event-ID"] = lastId;
      }
    } else if (config.cursorKind === "opaque-after") {
      url = config.buildUrl(lastId);
      if (lastId !== null) {
        headers["Last-Event-ID"] = lastId;
      }
    } else {
      // "none": fresh attach, no replay at all.
      url = config.buildUrl(null);
    }

    let response: Response;
    try {
      response = await fetch(url, { headers, signal: current.signal });
    } catch {
      // Network failure or abort — the loop's reconnect path handles both.
      return;
    }
    if (!response.ok || response.body === null) {
      return;
    }
    await pump(response.body, current);
  }

  async function pump(body: ReadableStream<Uint8Array>, current: AbortController): Promise<void> {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let eventName = "message";
    let dataLines: string[] = [];

    const dispatch = (): void => {
      config.onEvent(eventName, dataLines.join("\n"), lastId);
      eventName = "message";
      dataLines = [];
    };

    // One SSE block (the lines between `\n\n` separators).
    const handleBlock = (block: string): void => {
      for (const rawLine of block.split("\n")) {
        const line = rawLine.replace(/\r$/, "");
        if (line === "" || line.startsWith(":")) {
          // Comment lines (heartbeats) are ignored entirely.
          continue;
        }
        const colon = line.indexOf(":");
        const field = colon === -1 ? line : line.slice(0, colon);
        let value = colon === -1 ? "" : line.slice(colon + 1);
        if (value.startsWith(" ")) {
          value = value.slice(1);
        }
        switch (field) {
          case "id":
            lastId = value;
            break;
          case "event":
            eventName = value;
            break;
          case "data":
            dataLines.push(value);
            break;
          case "retry": {
            const ms = Number(value);
            if (Number.isFinite(ms) && ms >= 0) {
              retryOverrideMs = ms;
            }
            break;
          }
          default:
            break;
        }
      }
      // Per the SSE spec, a block with no data field dispatches nothing.
      if (dataLines.length > 0) {
        dispatch();
      }
    };

    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          return;
        }
        if (openAt === null) {
          // "open" is reported on the first byte of the stream.
          openAt = Date.now();
          config.onState("open", attempt);
        }
        buffer += decoder.decode(value, { stream: true });
        let separator = buffer.indexOf("\n\n");
        while (separator !== -1) {
          handleBlock(buffer.slice(0, separator));
          buffer = buffer.slice(separator + 2);
          separator = buffer.indexOf("\n\n");
        }
      }
    } catch (error) {
      if (isAbortError(error)) {
        return;
      }
      if (current.signal.aborted) {
        // Aborted out from under us (close/visibility) — not a real error.
        return;
      }
      throw error;
    }
  }

  async function loop(): Promise<void> {
    for (;;) {
      if (closed) {
        return;
      }
      if (suspended) {
        // Tab hidden — park until visibilitychange (or close) wakes us.
        await new Promise<void>((resolve) => {
          resumeDone = resolve;
        });
        if (closed) {
          return;
        }
        continue;
      }
      if (attempt > 0) {
        config.onState("reconnecting", attempt);
      }
      try {
        await connect();
      } catch {
        // Unexpected pump failure — treat like a dropped stream.
      }
      controller = null;
      if (closed) {
        return;
      }
      if (suspended) {
        // Dropped because the tab hid — no backoff, park in the gate above.
        continue;
      }
      if (openAt !== null && Date.now() - openAt >= STABLE_OPEN_MS) {
        // Stream was healthy — reset the backoff ladder.
        attempt = 0;
        retryOverrideMs = null;
      }
      attempt += 1;
      await wait(nextDelayMs());
    }
  }

  const onVisibilityChange = (): void => {
    if (closed) {
      return;
    }
    if (document.visibilityState === "hidden") {
      suspended = true;
      wasOpenBeforeHide = openAt !== null;
      controller?.abort(); // close the fetch, no reconnect while hidden
      sleepDone?.(); // cancel any pending backoff sleep
    } else if (document.visibilityState === "visible" && suspended) {
      if (wasOpenBeforeHide) {
        // Reopen with cursor semantics (lastId is still remembered).
        suspended = false;
        resumeDone?.();
      }
      // Otherwise stay parked: it was never live, so nothing to resume.
    }
  };

  if (typeof document !== "undefined") {
    document.addEventListener("visibilitychange", onVisibilityChange);
  }

  void loop();

  return {
    close(): void {
      if (closed) {
        return;
      }
      closed = true;
      suspended = false;
      controller?.abort();
      controller = null;
      sleepDone?.();
      resumeDone?.();
      if (typeof document !== "undefined") {
        document.removeEventListener("visibilitychange", onVisibilityChange);
      }
      config.onState("closed", attempt);
    },
  };
}
