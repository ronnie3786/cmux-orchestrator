/**
 * Generic cmux-proxy failure card (P11-run-A): "<Tool> unavailable" + the
 * server error message + Try again. Used for Git / Skills / Jira views
 * (byte-exact strings per doc 01 §6: "Git unavailable" / "Skills
 * unavailable" / "Jira unavailable", "Try again").
 */

import { CloudOff } from "lucide-react";
import { ApiError } from "../../api/client";
import "./tool-error-card.css";

/**
 * Upstream = the cmux proxy couldn't reach its tool (502/503/504) or the
 * request timed out / was aborted — vs a plain application-level error.
 */
export function isUpstreamError(error: unknown): boolean {
  if (error instanceof ApiError) {
    return error.status === 502 || error.status === 503 || error.status === 504;
  }
  const message = error instanceof Error ? error.message : "";
  return message === "Request timed out" || message === "Request cancelled";
}

export interface ToolErrorCardProps {
  /** Tool name: "Git" / "Skills" / "Jira" → renders `<Tool> unavailable`. Omit for a message-only card. */
  tool?: string;
  /** Server error message (muted line). */
  message: string;
  onRetry: () => void;
  /** Defaults to "Try again"; the file-search/Jira sheets say "Retry" (doc 01 §6). */
  retryLabel?: string;
}

export function ToolErrorCard({ tool, message, onRetry, retryLabel = "Try again" }: ToolErrorCardProps) {
  return (
    <div className="hz-tool-error" role="alert">
      <span className="hz-tool-error-icon" aria-hidden>
        <CloudOff size={22} />
      </span>
      <div className="hz-tool-error-body">
        {tool !== undefined ? (
          <span className="hz-tool-error-title">{tool} unavailable</span>
        ) : null}
        <span className="hz-tool-error-message">{message}</span>
      </div>
      <button type="button" className="hz-tool-error-retry" onClick={onRetry}>
        {retryLabel}
      </button>
    </div>
  );
}
