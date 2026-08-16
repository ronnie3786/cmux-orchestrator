import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { apiRequest, getToken, setToken } from "./client";

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
}

describe("harness-web API client", () => {
  beforeEach(() => {
    installLocalStorage();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("stores and clears the token under harness-web:token", () => {
    expect(getToken()).toBe("");
    setToken("abc123");
    expect(getToken()).toBe("abc123");
    expect(
      (globalThis as unknown as { localStorage: { getItem: (k: string) => string | null } }).localStorage.getItem(
        "harness-web:token"
      )
    ).toBe("abc123");
    setToken("");
    expect(getToken()).toBe("");
  });

  it("injects X-Cmux-Token on every request and parses JSON", async () => {
    setToken("secret-token");
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const data = await apiRequest<{ ok: boolean }>("/api/status");

    expect(data.ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/api/status");
    expect(new Headers(init.headers).get("X-Cmux-Token")).toBe("secret-token");
  });

  it("sends no X-Cmux-Token header when no token is stored", async () => {
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    await apiRequest<{ ok: boolean }>("/api/status");

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(new Headers(init.headers).get("X-Cmux-Token")).toBeNull();
  });

  it("throws with the server's error string on non-2xx", async () => {
    vi.stubGlobal(
      "fetch",
      async (_url: string, _init?: RequestInit) =>
        new Response(JSON.stringify({ ok: false, error: "unauthorized" }), { status: 401 })
    );

    await expect(apiRequest<unknown>("/api/status")).rejects.toThrow("unauthorized");
  });
});
