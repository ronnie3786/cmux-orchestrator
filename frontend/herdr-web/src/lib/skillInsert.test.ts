import { describe, expect, it } from "vitest";
import { skillInsertToken } from "./skillInsert";

// The two skills from the live 9092 probe of GET /workspaces/{id}/skills.
const TRIAGE_PRS = {
  name: "triage-prs",
  skill_file_path: ".claude/skills/triage-prs/SKILL.md",
};
const AGENT_BENCHMARK = {
  name: "agent-benchmark",
  skill_file_path: "~/.claude/skills/agent-benchmark/SKILL.md",
};

describe("skillInsertToken (byte-exact, iOS SkillInsertionStyle.token)", () => {
  it("Claude Code → /name", () => {
    expect(skillInsertToken(TRIAGE_PRS, "claude")).toBe("/triage-prs");
    expect(skillInsertToken(AGENT_BENCHMARK, "claude")).toBe("/agent-benchmark");
  });

  it("Codex CLI → $name", () => {
    expect(skillInsertToken(TRIAGE_PRS, "codex")).toBe("$triage-prs");
    expect(skillInsertToken(AGENT_BENCHMARK, "codex")).toBe("$agent-benchmark");
  });

  it("Skill file path → backticked skill_file_path", () => {
    expect(skillInsertToken(TRIAGE_PRS, "path")).toBe(
      "`.claude/skills/triage-prs/SKILL.md`",
    );
    expect(skillInsertToken(AGENT_BENCHMARK, "path")).toBe(
      "`~/.claude/skills/agent-benchmark/SKILL.md`",
    );
  });
});
