/**
 * Terminal endpoints (P5).
 *
 * The /output response shape was verified live against
 * GET /api/v1/panes/{id}/output?source=recent_unwrapped&lines=160 (P5
 * investigation; the `result.read` object duplicates `output` field-for-field
 * and is left untyped here).
 */

import { apiRequest } from "./client";
import { HERDR_BASE_URL } from "./herdr";

export interface TerminalOutputPayload {
  pane_id: string;
  workspace_id: string;
  tab_id: string;
  source: string;
  format: string;
  text: string;
  revision: number;
  truncated: boolean;
}

export interface TerminalOutputResponse {
  ok: boolean;
  output: TerminalOutputPayload;
  /** Duplicates `output` (`{type: "pane_read", read: {...}}`) — untyped. */
  result: unknown;
  generatedAt: string;
}

/** Snapshot poll parameters (doc 01 §4.5: `?source=recent_unwrapped&lines=160`). */
export const SNAPSHOT_SOURCE = "recent_unwrapped";
export const SNAPSHOT_LINES = 160;

export function terminalOutput(paneId: string): Promise<TerminalOutputResponse> {
  return apiRequest<TerminalOutputResponse>(
    `/panes/${encodeURIComponent(paneId)}/output?source=${SNAPSHOT_SOURCE}&lines=${SNAPSHOT_LINES}`,
  );
}

/**
 * Stream URL for the terminal frame SSE (`cursorKind: "none"` — fresh attach
 * on every connection; the first frame of an attach is always full).
 */
export function terminalStreamUrl(paneId: string, cols = 100, rows = 32): string {
  return `${HERDR_BASE_URL}/panes/${encodeURIComponent(paneId)}/stream?cols=${cols}&rows=${rows}`;
}
