/**
 * Headless Pi agent runs (the same engine behind the Mac HUD). The Git
 * workbench uses these for inline "ask about this code" conversations: runs
 * are created pane-scoped so the agent starts in the pane's working directory,
 * then polled until they reach a terminal status.
 */

import { apiRequest } from "./client";

const RUN_TIMEOUT_MS = 20_000;

export type AgentRunStatus =
  | "queued"
  | "running"
  | "completed"
  | "failed"
  | "cancelled"
  | "promoted";

export interface AgentRunStep {
  toolCallId: string;
  toolName: string;
  argsPreview: string;
  resultPreview: string;
  isError: boolean;
  startedAt: string | null;
  finishedAt: string | null;
}

export interface AgentRun {
  id: string;
  status: AgentRunStatus;
  mode: string;
  model: string | null;
  thinkingLevel: string | null;
  prompt: string;
  response: string | null;
  error: string | null;
  createdAt: string;
  startedAt: string | null;
  finishedAt: string | null;
  threadRootRunId: string;
  sessionId: string;
  sessionFile: string | null;
  costUSD: number;
  attachments: string[];
  steps?: AgentRunStep[];
  stepsTruncated?: boolean;
}

export interface AgentRunEnvelope {
  ok: boolean;
  run: AgentRun;
}

export interface StartAgentRunOptions {
  prompt: string;
  mode?: "ask" | "act";
  label?: string;
  /** Scopes the agent to this pane's working directory. */
  paneId?: string;
  continueFromRunId?: string;
}

export function startAgentRun(
  options: StartAgentRunOptions,
  signal?: AbortSignal,
): Promise<AgentRunEnvelope> {
  const body: Record<string, unknown> = { prompt: options.prompt };
  if (options.mode !== undefined) body.mode = options.mode;
  if (options.label !== undefined) body.label = options.label;
  if (options.paneId !== undefined) body.paneId = options.paneId;
  if (options.continueFromRunId !== undefined) {
    body.continueFromRunId = options.continueFromRunId;
  }
  return apiRequest<AgentRunEnvelope>("/agent-runs", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  }, RUN_TIMEOUT_MS);
}

export function getAgentRun(
  runId: string,
  signal?: AbortSignal,
): Promise<AgentRunEnvelope> {
  return apiRequest<AgentRunEnvelope>(`/agent-runs/${encodeURIComponent(runId)}`, {
    signal,
  }, RUN_TIMEOUT_MS);
}

export function cancelAgentRun(
  runId: string,
  signal?: AbortSignal,
): Promise<AgentRunEnvelope> {
  return apiRequest<AgentRunEnvelope>(
    `/agent-runs/${encodeURIComponent(runId)}/cancel`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
      signal,
    },
    RUN_TIMEOUT_MS,
  );
}

export function isTerminalRunStatus(status: AgentRunStatus): boolean {
  return (
    status === "completed" ||
    status === "failed" ||
    status === "cancelled" ||
    status === "promoted"
  );
}