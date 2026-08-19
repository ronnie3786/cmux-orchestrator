/**
 * Pi semantic endpoints (P7).
 *
 * GET routes (pi/snapshot, pi/models, pi/events) verified live against
 * 127.0.0.1:9092; POST routes come from doc 02 §2 (only GETs were called
 * live — the command bodies below are the contract, verbatim):
 *  - pi/prompt · pi/steer · pi/follow-up → `{text}`
 *  - pi/abort                            → `{}`
 *  - pi/model                            → EXACTLY `{provider, id}` (no aliases)
 *  - pi/thinking-level                   → EXACTLY `{level}`
 *  - pi/interactions/{id}/respond        → subset of `{value, confirmed, cancelled}`
 *
 * Pane IDs are concatenated raw (the `:` in `w1:p1` is legal in a path
 * segment, matching terminal.ts).
 */

import { apiRequest, getApiBaseUrl } from "./client";
import type { PiInteractionResponseBody, PiJSONValue } from "../pi/types";

export type PiCommandPayload = {
  ok?: boolean;
  success?: boolean;
  result?: PiJSONValue;
  error?: { code?: string; message?: string };
};

function postJson(path: string, body: unknown): Promise<PiCommandPayload> {
  return apiRequest<PiCommandPayload>(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/** GET /api/v1/panes/{id}/pi/snapshot (404 if the pane is not Pi-detected). */
export function piSnapshot(paneId: string): Promise<PiJSONValue> {
  return apiRequest<PiJSONValue>(`/panes/${paneId}/pi/snapshot`);
}

/**
 * Stream URL for the Pi semantic journal SSE. `after` is the opaque cursor
 * (`openSSE` cursorKind "opaque-after" appends it AND sends Last-Event-ID).
 */
export function piEventsUrl(paneId: string, after: string | number | null = null): string {
  const query =
    after !== null && after !== "" ? `?after=${encodeURIComponent(String(after))}` : "";
  return `${getApiBaseUrl()}/panes/${paneId}/pi/events${query}`;
}

/** GET /api/v1/panes/{id}/pi/models — bridge `list_models` passthrough. */
export function piModels(paneId: string): Promise<PiJSONValue> {
  return apiRequest<PiJSONValue>(`/panes/${paneId}/pi/models`);
}

export function piPrompt(paneId: string, body: { text: string }): Promise<PiCommandPayload> {
  return postJson(`/panes/${paneId}/pi/prompt`, body);
}

export function piSteer(paneId: string, body: { text: string }): Promise<PiCommandPayload> {
  return postJson(`/panes/${paneId}/pi/steer`, body);
}

export function piFollowUp(paneId: string, body: { text: string }): Promise<PiCommandPayload> {
  return postJson(`/panes/${paneId}/pi/follow-up`, body);
}

export function piAbort(paneId: string, body: {}): Promise<PiCommandPayload> {
  return postJson(`/panes/${paneId}/pi/abort`, body);
}

export function piSetModel(
  paneId: string,
  body: { provider: string; id: string },
): Promise<PiCommandPayload> {
  return postJson(`/panes/${paneId}/pi/model`, body);
}

export function piSetThinkingLevel(
  paneId: string,
  body: { level: string },
): Promise<PiCommandPayload> {
  return postJson(`/panes/${paneId}/pi/thinking-level`, body);
}

/**
 * Wire body carries ONLY the present fields — mirrors the Swift
 * `PiInteractionResponseBody` Encodable (nil optionals are omitted):
 * `{value}` | `{confirmed}` | `{cancelled}`.
 */
export function piInteractionWireBody(body: PiInteractionResponseBody): PiJSONValue {
  const out: Record<string, unknown> = {};
  if (body.value !== null) out.value = body.value;
  if (body.confirmed !== null) out.confirmed = body.confirmed;
  if (body.cancelled !== null) out.cancelled = body.cancelled;
  return out as unknown as PiJSONValue;
}

export function piRespond(
  paneId: string,
  interactionId: string,
  body: PiInteractionResponseBody,
): Promise<PiCommandPayload> {
  return postJson(
    `/panes/${paneId}/pi/interactions/${encodeURIComponent(interactionId)}/respond`,
    piInteractionWireBody(body),
  );
}
