const TOKEN_STORAGE_KEY = "harness-web:token";
const DEFAULT_TIMEOUT_MS = 15_000;
/** Attachment uploads get a longer window (iOS HarnessAPI parity: 60 s). */
export const UPLOAD_TIMEOUT_MS = 60_000;

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

function errorFromPayload(payload: unknown, status: number): string {
  if (payload !== null && typeof payload === "object" && "error" in payload) {
    const value = (payload as { error?: unknown }).error;
    if (typeof value === "string" && value) {
      return value;
    }
  }
  return `HTTP ${status}`;
}

/**
 * Same-origin fetch wrapper for the harness server.
 * Injects X-Cmux-Token from localStorage on every request and enforces a
 * 15 s timeout via AbortController (overridable per-call, e.g. uploads).
 * Throws Error with the server's error string on non-2xx responses.
 */
export async function apiRequest<T>(
  path: string,
  init: RequestInit = {},
  timeoutMs: number = DEFAULT_TIMEOUT_MS,
): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const headers = new Headers(init.headers);
  const token = getToken();
  if (token) {
    headers.set("X-Cmux-Token", token);
  }
  try {
    const response = await fetch(path, { ...init, headers, signal: controller.signal });
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
      throw new Error(errorFromPayload(payload, response.status));
    }
    return payload as T;
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      throw new Error("Request timed out");
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}
