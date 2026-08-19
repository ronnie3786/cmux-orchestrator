/**
 * Skill insert tokens (P11-run-B) — byte-exact port of iOS
 * `SkillInsertionStyle.token(for:)` (WorkspaceToolModels.swift):
 * `/name`, `$name`, and the backticked `skill_file_path`. Tokens carry no
 * trailing space; draft spacing is the composer's job (appendPromptToken).
 */

import type { ProjectSkill } from "../api/skills";

export type SkillInsertStyle = "claude" | "codex" | "path";

export function skillInsertToken(
  skill: Pick<ProjectSkill, "name" | "skill_file_path">,
  style: SkillInsertStyle,
): string {
  switch (style) {
    case "claude":
      return `/${skill.name}`;
    case "codex":
      return `$${skill.name}`;
    case "path":
      return `\`${skill.skill_file_path}\``;
  }
}
