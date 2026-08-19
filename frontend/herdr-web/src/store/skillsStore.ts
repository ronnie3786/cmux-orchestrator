/**
 * Per-workspace skills cache (P11-run-B) — GET /workspaces/{id}/skills
 * (doc 02 §2). View mounts → load; the header refresh button re-loads
 * (web analog of iOS pull-to-refresh, plan §5).
 */

import { create } from "zustand";
import { workspaceSkills, type ProjectSkill } from "../api/skills";

export interface SkillsEntry {
  projectSkills: ProjectSkill[];
  userSkills: ProjectSkill[];
  rootPath: string;
  skillsDirectory: string;
  userSkillsDirectory: string;
  loading: boolean;
  error: string | null;
}

export const EMPTY_SKILLS_ENTRY: SkillsEntry = {
  projectSkills: [],
  userSkills: [],
  rootPath: "",
  skillsDirectory: "",
  userSkillsDirectory: "",
  loading: false,
  error: null,
};

/** Header `N found` (iOS: resolvedProjectSkills.count + resolvedUserSkills.count). */
export function skillsFoundCount(
  projectSkills: ProjectSkill[],
  userSkills: ProjectSkill[],
): number {
  return projectSkills.length + userSkills.length;
}

export type SkillsBodyState = "loading" | "error" | "empty" | "content";

/**
 * Body state selection — mirrors iOS WorkspaceSkillsView: the loading and
 * error cards only show while no skills are cached, so an in-flight or
 * failed refresh over existing data keeps the list visible.
 */
export function skillsBodyState(
  entry: Pick<SkillsEntry, "projectSkills" | "userSkills" | "loading" | "error">,
): SkillsBodyState {
  const hasData = entry.projectSkills.length > 0 || entry.userSkills.length > 0;
  if (hasData) return "content";
  if (entry.loading) return "loading";
  if (entry.error !== null) return "error";
  return "empty";
}

/**
 * iOS `resolvedProjectSkills` / `resolvedUserSkills`: the split list when
 * present, else the `skills` bucket filtered by scope.
 */
function resolveScopes(res: {
  project_skills?: ProjectSkill[] | null;
  user_skills?: ProjectSkill[] | null;
  skills?: ProjectSkill[] | null;
}): { projectSkills: ProjectSkill[]; userSkills: ProjectSkill[] } {
  const bucket = res.skills ?? [];
  return {
    projectSkills: res.project_skills ?? bucket.filter((skill) => skill.scope === "project"),
    userSkills: res.user_skills ?? bucket.filter((skill) => skill.scope === "user"),
  };
}

interface SkillsStoreState {
  byWorkspace: Record<string, SkillsEntry>;
  load: (workspaceId: string) => Promise<void>;
}

const loadInFlight: Record<string, boolean> = {};

export const useSkillsStore = create<SkillsStoreState>()((set, get) => ({
  byWorkspace: {},
  load: (workspaceId) => {
    if (loadInFlight[workspaceId]) return Promise.resolve();
    loadInFlight[workspaceId] = true;
    set({
      byWorkspace: {
        ...get().byWorkspace,
        [workspaceId]: { ...(get().byWorkspace[workspaceId] ?? EMPTY_SKILLS_ENTRY), loading: true, error: null },
      },
    });
    return workspaceSkills(workspaceId)
      .then((res) => {
        const { projectSkills, userSkills } = resolveScopes(res);
        set({
          byWorkspace: {
            ...get().byWorkspace,
            [workspaceId]: {
              projectSkills,
              userSkills,
              rootPath: res.root_path ?? "",
              skillsDirectory: res.skills_directory ?? "",
              userSkillsDirectory: res.user_skills_directory ?? "",
              loading: false,
              error: res.error ?? null,
            },
          },
        });
      })
      .catch((err) => {
        set({
          byWorkspace: {
            ...get().byWorkspace,
            [workspaceId]: {
              ...(get().byWorkspace[workspaceId] ?? EMPTY_SKILLS_ENTRY),
              loading: false,
              error: err instanceof Error && err.message !== "" ? err.message : "Couldn't load skills",
            },
          },
        });
      })
      .finally(() => {
        loadInFlight[workspaceId] = false;
      });
  },
}));
