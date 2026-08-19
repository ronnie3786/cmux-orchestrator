/**
 * Pane command endpoints (P9-run-A: Command Lens).
 *
 * Route contract from doc 02 §2 (POST table):
 *  - /panes/{id}/run      `{command}`            → pane.send_input + ["enter"]
 *  - /panes/{id}/prompt   `{text, wait?, until?, timeoutMs?}` → agent.prompt
 *  - /panes/{id}/send-keys `{keys: [...]}` (1–64 entries,
 *    each ^[A-Za-z0-9+_-]{1,32}$)
 *
 * The composer sends a bare `{text}` prompt — mirrors the iOS app's simple
 * send (HerdrAPIClient.promptPane posts APIActionBody(text:) with no
 * wait/until/timeoutMs).
 *
 * Pane IDs are concatenated raw (the `:` in `w1:p1` is legal in a path
 * segment, matching pi.ts).
 */

import { apiRequest } from "./client";

export interface PaneCommandResponse {
  ok?: boolean;
  result?: unknown;
}

function postJson(path: string, body: unknown): Promise<PaneCommandResponse> {
  return apiRequest<PaneCommandResponse>(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/** POST /api/v1/panes/{id}/run — run a shell command (the server appends enter). */
export function paneRun(paneId: string, command: string): Promise<PaneCommandResponse> {
  return postJson(`/panes/${paneId}/run`, { command });
}

/** POST /api/v1/panes/{id}/prompt — prompt a detected agent (bare {text}). */
export function panePrompt(paneId: string, text: string): Promise<PaneCommandResponse> {
  return postJson(`/panes/${paneId}/prompt`, { text });
}

/** POST /api/v1/panes/{id}/send-keys — send named keys. */
export function paneSendKeys(paneId: string, keys: string[]): Promise<PaneCommandResponse> {
  return postJson(`/panes/${paneId}/send-keys`, { keys });
}
