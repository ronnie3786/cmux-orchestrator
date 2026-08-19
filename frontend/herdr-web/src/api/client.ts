const TOKEN_STORAGE_KEY = "herdr.web.token";
const SERVER_URL_STORAGE_KEY = "herdr.web.serverUrl";
export const DEFAULT_SERVER_URL = "http://127.0.0.1:9092";
const DEFAULT_TIMEOUT_MS = 15_000;

/**
 * Error thrown for any non-2xx response (or timeout/abort). Carries the
 * envelope's `error.code` when the server sent `{ok:false,error:{code,message}}`.
 */
export class ApiError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
  }
}

export interface ApiClientOptions {
  /**
   * Full API base override (tests). Wins over the stored/default server URL.
   * Default: `${serverUrl}/api/v1`.
   */
  baseUrl?: string;
  /** Invoked on any 401 so the app can re-enter onboarding. */
  onUnauthorized?: () => void;
}

let clientOptions: ApiClientOptions = {};

export function configureClient(options: ApiClientOptions): void {
  clientOptions = { ...clientOptions, ...options };
}

// --- demo seam ---------------------------------------------------------------
// When installed (App mount), `apiRequest` consults it BEFORE fetching. A
// returned value (anything but undefined) short-circuits the request; a thrown
// error becomes the request's rejection (demo mode uses this to answer
// unhandled routes with a benign 501 instead of a 401 that would kick the
// user back to onboarding).

type DemoRequestHandler = (path: string) => unknown;

let demoRequestHandler: DemoRequestHandler | null = null;

export function setDemoRequestHandler(handler: DemoRequestHandler | null): void {
  demoRequestHandler = handler;
}

export function getToken(): string {
  try {
    return localStorage.getItem(TOKEN_STORAGE_KEY) ?? "";
  } catch {
    return "";
  }
}

export function setToken(token: string): void {
  try {
    if (token) {
      localStorage.setItem(TOKEN_STORAGE_KEY, token);
    } else {
      localStorage.removeItem(TOKEN_STORAGE_KEY);
    }
  } catch {
    // Storage unavailable (e.g. private browsing) — the token just won't persist.
  }
}

function errorFromPayload(payload: unknown, status: number): ApiError {
  if (payload !== null && typeof payload === "object" && "error" in payload) {
    const value = (payload as { error?: unknown }).error;
    if (value !== null && typeof value === "object") {
      const err = value as { code?: unknown; message?: unknown };
      const message = typeof err.message === "string" && err.message ? err.message : `HTTP ${status}`;
      const code = typeof err.code === "string" && err.code ? err.code : "error";
      return new ApiError(code, message, status);
    }
    if (typeof value === "string" && value) {
      return new ApiError("error", value, status);
    }
  }
  return new ApiError("error", `HTTP ${status}`, status);
}

/**
 * The persisted server root, or null when the app targets the default.
 * Settings renders "This origin" for the unset case.
 */
export function getStoredServerUrl(): string | null {
  try {
    return localStorage.getItem(SERVER_URL_STORAGE_KEY);
  } catch {
    return null;
  }
}

/**
 * Configured server root (no /api/v1): the persisted URL (Settings /
 * onboarding "Save and reconnect") or the loopback default.
 */
export function getServerUrl(): string {
  return getStoredServerUrl() ?? DEFAULT_SERVER_URL;
}

/**
 * Persists the server root (Settings "Save and reconnect" / onboarding
 * Connect). Trailing slashes are stripped; an empty value clears the
 * override.
 */
export function setServerUrl(url: string): void {
  const trimmed = url.trim().replace(/\/+$/, "");
  try {
    if (trimmed) {
      localStorage.setItem(SERVER_URL_STORAGE_KEY, trimmed);
    } else {
      localStorage.removeItem(SERVER_URL_STORAGE_KEY);
    }
  } catch {
    // Storage unavailable — the override just won't persist.
  }
}

/** Full API base: the test override, else `<serverUrl>/api/v1`. */
export function getApiBaseUrl(): string {
  if (clientOptions.baseUrl) {
    return clientOptions.baseUrl;
  }
  return `${getServerUrl()}/api/v1`;
}

function resolveUrl(path: string): string {
  if (/^https?:\/\//i.test(path)) {
    return path;
  }
  const baseUrl = getApiBaseUrl();
  return baseUrl + (path.startsWith("/") ? path : `/${path}`);
}

/**
 * Fetch wrapper for the herdr harness server.
 * Injects `Authorization: Bearer <token>` from localStorage on every request
 * and enforces a 15 s timeout via AbortController. Throws `ApiError` with the
 * envelope's `{code, message}` on non-2xx responses, and invokes the
 * configured `onUnauthorized` callback on 401.
 *
 * Pass `signal` in `init` to support caller-side cancellation: the external
 * signal aborts the internal controller, and the rejection reads
 * "Request cancelled" (vs "Request timed out" for the internal timeout).
 */
export async function apiRequest<T>(
  path: string,
  init: RequestInit = {},
  timeoutMs: number = DEFAULT_TIMEOUT_MS,
): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const externalSignal = init.signal ?? null;
  const onExternalAbort = () => controller.abort();
  if (externalSignal) {
    if (externalSignal.aborted) {
      controller.abort();
    } else {
      externalSignal.addEventListener("abort", onExternalAbort, { once: true });
    }
  }
  if (demoRequestHandler !== null) {
    const demo = demoRequestHandler(path);
    if (demo !== undefined) {
      return demo as T;
    }
  }
  const headers = new Headers(init.headers);
  const token = getToken();
  if (token) {
    headers.set("Authorization", `Bearer ${token}`);
  }
  try {
    const response = await fetch(resolveUrl(path), { ...init, headers, signal: controller.signal });
    const text = await response.text();
    let payload: unknown = null;
    if (text) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = text;
      }
    }
    if (!response.ok) {
      if (response.status === 401) {
        clientOptions.onUnauthorized?.();
      }
      throw errorFromPayload(payload, response.status);
    }
    return payload as T;
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      throw new Error(externalSignal?.aborted ? "Request cancelled" : "Request timed out");
    }
    throw error;
  } finally {
    clearTimeout(timer);
    externalSignal?.removeEventListener("abort", onExternalAbort);
  }
}
