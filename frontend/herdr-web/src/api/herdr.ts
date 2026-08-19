/**
 * Thin wrappers over api/client.ts for the herdr harness endpoints.
 *
 * GET endpoints (health / workspaces / workspace / alerts) were verified
 * against the live server before being finalized. The POST alert endpoints
 * return the shapes from herdr_harness/service.py (POSTs were not run live).
 */

import { apiRequest, getApiBaseUrl } from "./client";
import type {
  AlertReadResponse,
  AlertsReadAllResponse,
  AlertsResponse,
  Health,
  PushStatus,
  WorkspaceSingleResponse,
  WorkspacesResponse,
} from "../types/herdr";

/**
 * Same default as client.ts's (non-exported) DEFAULT_BASE_URL — keep in sync.
 * Exported so the SSE stream (store/eventStream.ts) builds its URL from the
 * client's configured base rather than a second hardcoded copy.
 */
export const HERDR_BASE_URL = "http://127.0.0.1:9092/api/v1";

export function health(): Promise<Health> {
  return apiRequest<Health>("/health");
}

export function workspaces(): Promise<WorkspacesResponse> {
  return apiRequest<WorkspacesResponse>("/workspaces");
}

export function workspace(id: string): Promise<WorkspaceSingleResponse> {
  return apiRequest<WorkspaceSingleResponse>(`/workspaces/${encodeURIComponent(id)}`);
}

/** GET /api/v1/push/status (live shape: {ok, apns: {...}, generatedAt}). */
export function pushStatus(): Promise<PushStatus> {
  return apiRequest<PushStatus>("/push/status");
}

export interface AlertQuery {
  unread?: boolean;
  limit?: number;
  status?: string;
}

export function alerts(opts?: AlertQuery): Promise<AlertsResponse> {
  const params = new URLSearchParams();
  if (opts?.unread !== undefined) {
    params.set("unread", String(opts.unread));
  }
  if (opts?.limit !== undefined) {
    params.set("limit", String(opts.limit));
  }
  if (opts?.status) {
    params.set("status", opts.status);
  }
  const query = params.toString();
  return apiRequest<AlertsResponse>(query ? `/alerts?${query}` : "/alerts");
}

export function alertRead(alertId: string): Promise<AlertReadResponse> {
  return apiRequest<AlertReadResponse>(`/alerts/${encodeURIComponent(alertId)}/read`, {
    method: "POST",
  });
}

export function alertsReadAll(): Promise<AlertsReadAllResponse> {
  return apiRequest<AlertsReadAllResponse>("/alerts/read-all", { method: "POST" });
}

/** Global topology SSE stream URL (base follows the configured server). */
export function eventsUrl(): string {
  return `${getApiBaseUrl()}/events`;
}
