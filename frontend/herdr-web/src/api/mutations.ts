/**
 * Pane + workspace mutation endpoints (P10-run-B).
 *
 * Route contract from doc 02 §2 (POST / PATCH / DELETE table):
 *  - POST   /panes/{id}/start-agent  `{name, kind}`        → agent.start
 *  - POST   /panes/{id}/send-keys    `{keys: ["ctrl+c"]}`  (menu "Interrupt" —
 *    doc 01 §3: "Interrupt (sends ctrl+c)")
 *  - POST   /panes/{id}/split        `{direction}`         (right (default) | down;
 *    focus/cwd/env/ratio optional)
 *  - POST   /panes/{id}/send-text    `{text}`              (low-level; the Command
 *    Lens uses /run + /prompt instead)
 *  - PATCH  /panes/{id}              `{label}`             → rename pane
 *  - DELETE /panes/{id}                              → close pane
 *  - POST   /workspaces              `{cwd?, label?}`      → workspace.create
 *  - POST   /workspaces/{id}/tabs    `{}`                 → new tab (cwd/label/
 *    focus/env all optional)
 *  - PATCH  /workspaces/{id}         `{label}`             → rename workspace
 *  - POST   /workspaces/{id}/focus                     → workspace.focus
 *  - DELETE /workspaces/{id}                           → workspace.close
 *
 * Mutation results are wrapped `{"ok":true,"result":<herdr result>}`. Pane
 * IDs are concatenated raw (the `:` in `w1:p1` is legal in a path segment).
 */

import { apiRequest } from "./client";

export interface MutationResult {
  ok?: boolean;
  result?: unknown;
}

/** Server-side agent kinds accepted by /start-agent (doc 02 §2, kind enum). */
export type StartableAgent = "codex" | "claude" | "opencode";

function json(method: "POST" | "PATCH" | "DELETE", path: string, body?: unknown): Promise<MutationResult> {
  return apiRequest<MutationResult>(path, {
    method,
    ...(body !== undefined
      ? { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }
      : {}),
  });
}

/**
 * POST /api/v1/panes/{id}/start-agent — spawn an agent in a pane.
 * Body: `{name, kind}` — `name` ^[a-z][a-z0-9_-]{0,31}$, kind the same
 * vocabulary (the iOS app sends one identifier for both).
 */
export function startAgent(paneId: string, agent: StartableAgent): Promise<MutationResult> {
  return json("POST", `/panes/${paneId}/start-agent`, { name: agent, kind: agent });
}

/**
 * Menu "Interrupt": doc 01 §3 implements interrupt as a `ctrl+c` key send.
 * "ctrl+c" satisfies the send-keys whitelist ^[A-Za-z0-9+_-]{1,32}$.
 */
export function interruptAgent(paneId: string): Promise<MutationResult> {
  return json("POST", `/panes/${paneId}/send-keys`, { keys: ["ctrl+c"] });
}

/** PATCH /api/v1/panes/{id} — rename a pane (`{label}`; nullable per doc 02). */
export function renamePane(paneId: string, label: string): Promise<MutationResult> {
  return json("PATCH", `/panes/${paneId}`, { label });
}

/** DELETE /api/v1/panes/{id} — close a pane. */
export function deletePane(paneId: string): Promise<MutationResult> {
  return json("DELETE", `/panes/${paneId}`);
}

/**
 * POST /api/v1/panes/{id}/split — doc 02 body `{direction: right (default) |
 * down, focus? (default true), cwd?, env?, ratio? 0.05-0.95}`; the iOS menu
 * (Split right / Split down) sends just the direction.
 */
export function splitPane(paneId: string, direction: "right" | "down"): Promise<MutationResult> {
  return json("POST", `/panes/${paneId}/split`, { direction });
}

/**
 * POST /api/v1/panes/{id}/send-text — the low-level text route (doc 02 §2).
 * The Command Lens uses /run (shell) + /prompt (agent) instead; this is the
 * API surface for future use, not wired to the composer.
 */
export function paneSendText(paneId: string, text: string): Promise<MutationResult> {
  return json("POST", `/panes/${paneId}/send-text`, { text });
}

export interface CreateWorkspaceInput {
  /** Workspace label (doc 02 body key `label`, ≤120). */
  label?: string;
  /** Absolute existing directory (doc 02 body key `cwd`). */
  cwd?: string;
}

/**
 * POST /api/v1/workspaces — create a workspace. Doc 02 body keys:
 * `{cwd?, label?, focus?, env?}`; the iOS flow (§5: `{label,cwd}`) sends just
 * label + cwd, which is what the modal wires.
 */
export function createWorkspace(input: CreateWorkspaceInput): Promise<MutationResult> {
  return json("POST", "/workspaces", {
    ...(input.label ? { label: input.label } : {}),
    ...(input.cwd ? { cwd: input.cwd } : {}),
  });
}

/**
 * The create result is `{"ok":true,"result":<herdr result>}`; the herdr
 * result shape isn't pinned in the docs, so extract the new workspace id
 * defensively (null when unrecognized — callers fall back to the SSE-driven
 * refresh).
 */
export function workspaceIdFromResult(result: unknown): string | null {
  if (result === null || typeof result !== "object") return null;
  const record = result as Record<string, unknown>;
  for (const key of ["workspace_id", "id"]) {
    const value = record[key];
    if (typeof value === "string" && value) return value;
  }
  const workspace = record.workspace;
  if (workspace !== null && typeof workspace === "object") {
    const id = (workspace as Record<string, unknown>).workspace_id;
    if (typeof id === "string" && id) return id;
  }
  return null;
}

/**
 * "Focus on Mac" (iOS workspace action; doc 01 §6 toast "Workspace focused
 * on Mac") — POST /api/v1/workspaces/{id}/focus. The plan's "launch" action
 * maps to this: doc 02 has no /workspaces/{id}/launch route.
 */
export function launchWorkspace(workspaceId: string): Promise<MutationResult> {
  return json("POST", `/workspaces/${workspaceId}/focus`);
}

/** DELETE /api/v1/workspaces/{id} — close a workspace. */
export function closeWorkspace(workspaceId: string): Promise<MutationResult> {
  return json("DELETE", `/workspaces/${workspaceId}`);
}

/**
 * POST /api/v1/workspaces/{id}/tabs — new tab. Body keys `{cwd?, label?,
 * focus?, env?}` are all optional; the iOS action sends an empty body.
 */
export function createTab(workspaceId: string): Promise<MutationResult> {
  return json("POST", `/workspaces/${workspaceId}/tabs`, {});
}

/** PATCH /api/v1/workspaces/{id} — rename a workspace (`{label}`). */
export function renameWorkspace(workspaceId: string, label: string): Promise<MutationResult> {
  return json("PATCH", `/workspaces/${workspaceId}`, { label });
}
