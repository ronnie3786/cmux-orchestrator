import { describe, expect, it } from "vitest";
import { skillsBodyState, skillsFoundCount } from "../../store/skillsStore";

const TRIAGE_PRS = {
  name: "triage-prs",
  skill_file_path: ".claude/skills/triage-prs/SKILL.md",
  scope: "project",
};
const AGENT_BENCHMARK = {
  name: "agent-benchmark",
  skill_file_path: "~/.claude/skills/agent-benchmark/SKILL.md",
  scope: "user",
};

describe("skillsFoundCount (doc 01 §6 `N found`)", () => {
  it("sums project and user skills", () => {
    expect(skillsFoundCount([TRIAGE_PRS], [AGENT_BENCHMARK])).toBe(2);
  });

  it("is zero for empty scopes", () => {
    expect(skillsFoundCount([], [])).toBe(0);
  });
});

describe("skillsBodyState (iOS WorkspaceSkillsView ordering)", () => {
  it("loading on the first fetch", () => {
    expect(
      skillsBodyState({ projectSkills: [], userSkills: [], loading: true, error: null }),
    ).toBe("loading");
  });

  it("error when the fetch fails with no data", () => {
    expect(
      skillsBodyState({
        projectSkills: [],
        userSkills: [],
        loading: false,
        error: "upstream down",
      }),
    ).toBe("error");
  });

  it("empty after a successful fetch with no skills", () => {
    expect(
      skillsBodyState({ projectSkills: [], userSkills: [], loading: false, error: null }),
    ).toBe("empty");
  });

  it("content once any skill is cached, even mid-refresh or after a failed refresh", () => {
    expect(
      skillsBodyState({ projectSkills: [TRIAGE_PRS], userSkills: [], loading: true, error: null }),
    ).toBe("content");
    expect(
      skillsBodyState({
        projectSkills: [TRIAGE_PRS],
        userSkills: [],
        loading: false,
        error: "upstream down",
      }),
    ).toBe("content");
  });
});
