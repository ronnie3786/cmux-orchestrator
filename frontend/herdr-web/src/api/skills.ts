/**
 * Workspace skills endpoint (P11-run-B) — proxied to the cmux server
 * (doc 02 §2). Response shape live-verified against 9092.
 */

import { apiRequest } from "./client";

export interface ProjectSkill {
  name: string;
  skill_file_path: string;
  scope?: string | null;
}

export interface WorkspaceSkillsResponse {
  ok: boolean;
  workspace_id: string;
  root_path?: string | null;
  skills_directory?: string | null;
  user_skills_directory?: string | null;
  project_skills?: ProjectSkill[] | null;
  user_skills?: ProjectSkill[] | null;
  /** Fallback bucket — resolved by scope when the split lists are absent. */
  skills?: ProjectSkill[] | null;
  error?: string | null;
}

/** GET /api/v1/workspaces/{id}/skills (live-verified; 30 s per doc 01 §6). */
export function workspaceSkills(
  workspaceId: string,
  signal?: AbortSignal,
): Promise<WorkspaceSkillsResponse> {
  return apiRequest<WorkspaceSkillsResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills`,
    { signal },
    30_000,
  );
}
