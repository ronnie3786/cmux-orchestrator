import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useConnectionStore } from "./connectionStore";
import type { HarnessStatus } from "../api/types";

function installLocalStorage() {
  const store = new Map<string, string>();
  (globalThis as { localStorage?: unknown }).localStorage = {
    getItem: (key: string) => (store.has(key) ? store.get(key) : null),
    setItem: (key: string, value: string) => {
      store.set(key, String(value));
    },
    removeItem: (key: string) => {
      store.delete(key);
    },
    clear: () => store.clear(),
  };
  return store;
}

function status(overrides: Partial<HarnessStatus> = {}): HarnessStatus {
  return {
    enabled: true,
    workspaces: [],
    pollInterval: 2,
    socketFound: true,
    connected: true,
    ...overrides,
  };
}

const INITIAL = {
  connection: "checking" as const,
  lastUpdated: null,
  errorMessage: null,
  engineEnabled: null,
  isTogglingEngine: false,
  manualDisconnect: false,
  consecutivePollFailures: 0,
};

describe("connectionStore", () => {
  beforeEach(() => {
    installLocalStorage();
    useConnectionStore.setState(INITIAL);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("maps status to connection states (connected / reconnecting / noSocket)", () => {
    const store = useConnectionStore;
    store.getState().markStatus(status({ connected: true }));
    expect(store.getState().connection).toBe("connected");
    expect(store.getState().engineEnabled).toBe(true);
    expect(store.getState().lastUpdated).toBeTypeOf("number");
    expect(store.getState().errorMessage).toBeNull();

    store.getState().markStatus(status({ connected: false, socketFound: true }));
    expect(store.getState().connection).toBe("reconnecting");

    store.getState().markStatus(status({ connected: false, socketFound: false }));
    expect(store.getState().connection).toBe("noSocket");
  });

  it("degrades connected → reconnecting only after repeated poll failures", () => {
    const store = useConnectionStore;
    store.getState().markStatus(status({ connected: true }));

    store.getState().markPollError("boom");
    expect(store.getState().connection).toBe("connected");
    expect(store.getState().errorMessage).toBe("boom");

    store.getState().markPollError("boom again");
    expect(store.getState().connection).toBe("reconnecting");

    // A successful poll recovers.
    store.getState().markStatus(status({ connected: true }));
    expect(store.getState().connection).toBe("connected");
    expect(store.getState().consecutivePollFailures).toBe(0);
  });

  it("persists the server host (display/bookkeeping only)", () => {
    const store = installLocalStorage();
    useConnectionStore.getState().setServerHost("10.0.0.5:9091");
    expect(useConnectionStore.getState().serverHost).toBe("10.0.0.5:9091");
    expect(store.get("harness-web:serverHost")).toBe("10.0.0.5:9091");
  });

  it("toggles the engine with an optimistic update and server confirmation", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, _init?: RequestInit) =>
        new Response(JSON.stringify({ ok: true, enabled: false }), { status: 200 }),
      ),
    );
    useConnectionStore.getState().markStatus(status({ enabled: false }));

    await useConnectionStore.getState().setEngineEnabled(true);

    expect(useConnectionStore.getState().engineEnabled).toBe(false); // server confirmed
    expect(useConnectionStore.getState().errorMessage).toBeNull();
  });

  it("reverts the optimistic toggle and reports the error on failure", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, _init?: RequestInit) =>
        new Response(JSON.stringify({ ok: false, error: "denied" }), { status: 403 }),
      ),
    );
    useConnectionStore.getState().markStatus(status({ enabled: true }));

    await useConnectionStore.getState().setEngineEnabled(false);

    expect(useConnectionStore.getState().engineEnabled).toBe(true); // reverted
    expect(useConnectionStore.getState().errorMessage).toBe("denied");
  });
});
