import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiError,
  apiRequest,
  configureClient,
  getServerUrl,
  getToken,
  isHostLocal,
  setToken,
} from "./client";

const BASE_URL = "http://127.0.0.1:9092/api/v1";

function installLocalStorage(): Map<string, string> {
  const store = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => {
      store.set(key, value);
    },
    removeItem: (key: string) => {
      store.delete(key);
    },
    clear: () => store.clear(),
    key: (index: number) => [...store.keys()][index] ?? null,
    get length() {
      return store.size;
    },
  });
  return store;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  installLocalStorage();
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
  configureClient({ baseUrl: BASE_URL, onUnauthorized: undefined });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("isHostLocal", () => {
  it("trusts the native wrapper's explicit statement", () => {
    vi.stubGlobal("window", {
      __HERDR_NATIVE_CONFIG__: {
        token: "native-token",
        serverUrl: "https://remote.example",
        hostIsLocal: false,
      },
    });
    expect(isHostLocal()).toBe(false);

    vi.stubGlobal("window", {
      __HERDR_NATIVE_CONFIG__: {
        token: "native-token",
        serverUrl: "https://remote.example",
        hostIsLocal: true,
      },
    });
    expect(isHostLocal()).toBe(true);
  });

  it("falls back to loopback detection for plain browsers", () => {
    vi.stubGlobal("window", {
      location: { hostname: "localhost" },
    });
    expect(isHostLocal()).toBe(true);

    vi.stubGlobal("window", {
      location: { hostname: "Work-Mac.tailnet.example" },
    });
    expect(isHostLocal()).toBe(false);
  });
});

describe("apiRequest", () => {
  it("sends Authorization: Bearer from the herdr.web.token storage key", async () => {
    setToken("sekret");
    expect(getToken()).toBe("sekret");
    fetchMock.mockResolvedValue(jsonResponse({ ok: true }));

    await apiRequest("/health");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe(`${BASE_URL}/health`);
    const headers = init?.headers as Headers;
    expect(headers.get("Authorization")).toBe("Bearer sekret");
  });

  it("prefers memory-only native configuration over persisted settings", async () => {
    setToken("stored-token");
    localStorage.setItem("herdr.web.serverUrl", "https://stored.example");
    vi.stubGlobal("window", {
      __HERDR_NATIVE_CONFIG__: {
        token: "native-token",
        serverUrl: "https://native.example/",
      },
    });
    fetchMock.mockResolvedValue(jsonResponse({ ok: true }));

    expect(getToken()).toBe("native-token");
    expect(getServerUrl()).toBe("https://native.example");
    await apiRequest("/health");

    const headers = fetchMock.mock.calls[0]?.[1]?.headers as Headers;
    expect(headers.get("Authorization")).toBe("Bearer native-token");
    expect(localStorage.getItem("herdr.web.token")).toBe("stored-token");
    expect(localStorage.getItem("herdr.web.serverUrl")).toBe("https://stored.example");
  });

  it("passes through the ok envelope unchanged", async () => {
    setToken("sekret");
    const payload = { ok: true, herdr: { connected: true } };
    fetchMock.mockResolvedValue(jsonResponse(payload));

    const result = await apiRequest<typeof payload>("/health");

    expect(result).toEqual(payload);
  });

  it("rejects error envelopes with the envelope's code + message", async () => {
    setToken("sekret");
    fetchMock.mockResolvedValue(
      jsonResponse({ ok: false, error: { code: "not_found", message: "no such thing" } }, 404),
    );

    const error = await apiRequest("/missing").catch((caught: unknown) => caught);

    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({
      name: "ApiError",
      code: "not_found",
      message: "no such thing",
      status: 404,
    });
  });

  it("fires after the 15 s default timeout and aborts the fetch", async () => {
    vi.useFakeTimers();
    setToken("sekret");
    fetchMock.mockImplementation(
      (_url: string, init: RequestInit) =>
        new Promise((_resolve, reject) => {
          (init?.signal as AbortSignal).addEventListener(
            "abort",
            () => {
              const error = new Error("aborted");
              error.name = "AbortError";
              reject(error);
            },
            { once: true },
          );
        }),
    );

    const promise = apiRequest("/slow");
    const assertion = expect(promise).rejects.toThrow("Request timed out");
    await vi.advanceTimersByTimeAsync(15_000);
    await assertion;
  });

  it("invokes onUnauthorized on 401 (and still rejects)", async () => {
    setToken("stale");
    const onUnauthorized = vi.fn();
    configureClient({ onUnauthorized });
    fetchMock.mockResolvedValue(
      jsonResponse({ ok: false, error: { code: "unauthorized", message: "bad token" } }, 401),
    );

    const error = await apiRequest("/health").catch((caught: unknown) => caught);

    expect(onUnauthorized).toHaveBeenCalledTimes(1);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).status).toBe(401);
    expect((error as ApiError).code).toBe("unauthorized");
  });

  it("does not invoke onUnauthorized for non-401 errors", async () => {
    setToken("sekret");
    const onUnauthorized = vi.fn();
    configureClient({ onUnauthorized });
    fetchMock.mockResolvedValue(
      jsonResponse({ ok: false, error: { code: "boom", message: "boom" } }, 500),
    );

    await apiRequest("/boom").catch(() => {});

    expect(onUnauthorized).not.toHaveBeenCalled();
  });
});
