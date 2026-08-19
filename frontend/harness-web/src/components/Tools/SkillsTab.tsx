import { useCallback, useEffect, useRef, useState } from "react";
import { DollarSign, FileText, MoreHorizontal, RefreshCw, Terminal, Wand2 } from "lucide-react";
import { getSkills } from "../../api/endpoints";
import type { ProjectSkill, SkillsResponse } from "../../api/types";
import { useDraftStore } from "../../store/draftStore";
import { useEscapeLayer } from "../../hooks/useOverlay";

interface SkillsTabProps {
  /** cmux index of the selected session. */
  index: number;
  /** Switch the detail view to the Terminal tab (iOS `detailTab = .terminal`). */
  onJumpToTerminal: () => void;
}

interface SkillsSection {
  title: string;
  skills: ProjectSkill[];
}

/**
 * iOS `SkillsListView` + `HarnessFeatureToolsReducer` skills state parity.
 *
 * - Loaded when the tab is shown (iOS `.detailTabChanged(.skills)` sends
 *   `.loadSkills`); the header refresh button is the web analog of
 *   pull-to-refresh (plan §5: "Pull-to-refresh → explicit refresh buttons").
 * - `isLoadingSkills = !hasSkills` parity: the spinner only shows when
 *   refreshing with no skills yet; an in-flight refresh with existing skills
 *   keeps the list visible.
 * - Sections resolve like iOS `resolvedProjectSkills` / `resolvedUserSkills`:
 *   `projectSkills` ?? `skills` filtered by scope `project` (same for user).
 * - Per-skill menu (iOS `SkillMenuRow` Menu): Claude Code → append `/name`,
 *   Codex CLI → append `$name`, File Path → append `` `skillFilePath` `` —
 *   all via iOS `appendPromptToken` (space-separated, EXACT text,
 *   agent-facing), then jump to the Terminal tab + focus the input row (iOS
 *   sets `detailTab = .terminal` and bumps `detailInputFocusRequest` for all
 *   three).
 */
export function SkillsTab({ index, onJumpToTerminal }: SkillsTabProps) {
  const [projectSkills, setProjectSkills] = useState<ProjectSkill[]>([]);
  const [userSkills, setUserSkills] = useState<ProjectSkill[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** Skill id whose menu is open (null = closed). */
  const [openMenuID, setOpenMenuID] = useState<string | null>(null);

  const hasSkills = projectSkills.length > 0 || userSkills.length > 0;
  /** Mirror `hasSkills` for the load callback without making it depend on it
      (a dependency would re-trigger the mount effect after the first load). */
  const hasSkillsRef = useRef(false);
  hasSkillsRef.current = hasSkills;

  const abortRef = useRef<AbortController | null>(null);

  /** iOS `.loadSkills` (cancellable; success only applies to this index — the
      index-keyed effect aborts the in-flight load on selection/pane change,
      so a stale response can never overwrite a newer index's data). */
  const loadSkills = useCallback(() => {
    abortRef.current?.abort();
    // iOS `state.isLoadingSkills = !state.hasSkills`.
    setLoading(!hasSkillsRef.current);
    setError(null);
    const controller = new AbortController();
    abortRef.current = controller;
    getSkills(index, controller.signal)
      .then((response) => {
        setProjectSkills(resolvedProjectSkills(response));
        setUserSkills(resolvedUserSkills(response));
        setLoading(false);
        setError(null);
      })
      .catch((err) => {
        if (err instanceof Error && err.message === "Request cancelled") return;
        setLoading(false);
        setError(err instanceof Error ? err.message : "Couldn't load skills");
      });
  }, [index]);

  // iOS `.detailTabChanged(.skills)` → `.loadSkills` (the view mounts when the
  // tab is selected). Cancel on unmount (tab switch / workspace change).
  useEffect(() => {
    loadSkills();
    return () => abortRef.current?.abort();
  }, [loadSkills]);

  // Close the row menu on Escape (top-most layer only).
  useEscapeLayer(() => setOpenMenuID(null), openMenuID !== null);

  // iOS `appendSkillInvocation` / `appendCodexSkillInvocation` /
  // `appendSkillFilePath`: exact tokens + terminal + focus request.
  const insertToken = (token: string) => {
    setOpenMenuID(null);
    useDraftStore.getState().appendToken(token);
    useDraftStore.getState().requestFocus();
    onJumpToTerminal();
  };

  const sections: SkillsSection[] = [];
  if (projectSkills.length > 0) sections.push({ title: "Project Skills", skills: projectSkills });
  if (userSkills.length > 0) sections.push({ title: "User Skills", skills: userSkills });

  return (
    <div className="skills-tab">
      <div className="skills-tab-header">
        <span className="skills-tab-title">Skills</span>
        <button
          type="button"
          className="icon-button"
          title="Refresh skills"
          aria-label="Refresh skills"
          disabled={loading}
          onClick={loadSkills}
        >
          <RefreshCw size={14} aria-hidden />
        </button>
      </div>

      <div className="skills-tab-body">
        {loading && !hasSkills ? (
          <div className="tools-modal-spinner-wrap">
            <div className="spinner" aria-label="Loading skills" />
          </div>
        ) : error !== null ? (
          <div className="git-error">
            <span className="git-error-text">{error}</span>
            <button type="button" className="git-error-retry" onClick={loadSkills}>
              <RefreshCw size={13} /> Retry
            </button>
          </div>
        ) : !hasSkills ? (
          <div className="tools-modal-empty">
            <Wand2 size={20} aria-hidden />
            <span>No Skills</span>
          </div>
        ) : (
          sections.map((section) => (
            <div key={section.title} className="skills-section">
              <div className="skills-section-header">{section.title}</div>
              <div className="skills-list">
                {section.skills.map((skill) => (
                  <SkillRow
                    key={skillID(skill)}
                    skill={skill}
                    menuOpen={openMenuID === skillID(skill)}
                    onToggleMenu={() =>
                      setOpenMenuID((current) => (current === skillID(skill) ? null : skillID(skill)))
                    }
                    onCloseMenu={() => setOpenMenuID(null)}
                    onInsertClaude={() => insertToken(`/${skill.name}`)}
                    onInsertCodex={() => insertToken(`$${skill.name}`)}
                    onInsertPath={() => insertToken(`\`${skill.skillFilePath}\``)}
                  />
                ))}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}

function SkillRow({
  skill,
  menuOpen,
  onToggleMenu,
  onCloseMenu,
  onInsertClaude,
  onInsertCodex,
  onInsertPath,
}: {
  skill: ProjectSkill;
  menuOpen: boolean;
  onToggleMenu: () => void;
  onCloseMenu: () => void;
  onInsertClaude: () => void;
  onInsertCodex: () => void;
  onInsertPath: () => void;
}) {
  return (
    <div className="skill-row-wrap">
      <div className="skill-row">
        <div className="skill-row-main">
          <div className="skill-row-name">{skill.name}</div>
          <div className="skill-row-path" title={skill.skillFilePath}>
            {skill.skillFilePath}
          </div>
        </div>
        <button
          type="button"
          className="icon-button skill-row-menu-button"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          aria-label={`Insert ${skill.name} skill`}
          onClick={onToggleMenu}
        >
          <MoreHorizontal size={15} aria-hidden />
        </button>
      </div>
      {menuOpen ? (
        <>
          <div className="menu-backdrop" onClick={onCloseMenu} />
          <div className="skill-row-menu" role="menu">
            <button
              type="button"
              role="menuitem"
              className="menu-item"
              onClick={onInsertClaude}
            >
              <Terminal size={14} className="menu-item-icon" aria-hidden />
              <span className="menu-item-label">Claude Code</span>
            </button>
            <button
              type="button"
              role="menuitem"
              className="menu-item"
              onClick={onInsertCodex}
            >
              <DollarSign size={14} className="menu-item-icon" aria-hidden />
              <span className="menu-item-label">Codex CLI</span>
            </button>
            <button
              type="button"
              role="menuitem"
              className="menu-item"
              onClick={onInsertPath}
            >
              <FileText size={14} className="menu-item-icon" aria-hidden />
              <span className="menu-item-label">File Path</span>
            </button>
          </div>
        </>
      ) : null}
    </div>
  );
}

/** iOS `ProjectSkill.id`: `\(scope ?? "project")|\(name)`. */
function skillID(skill: ProjectSkill): string {
  return `${skill.scope ?? "project"}|${skill.name}`;
}

/** iOS `SkillsResponse.resolvedProjectSkills`. */
function resolvedProjectSkills(response: SkillsResponse): ProjectSkill[] {
  if (response.projectSkills) return response.projectSkills;
  const all = response.skills ?? [];
  return all.filter((skill) => skill.scope === "project");
}

/** iOS `SkillsResponse.resolvedUserSkills`. */
function resolvedUserSkills(response: SkillsResponse): ProjectSkill[] {
  if (response.userSkills) return response.userSkills;
  const all = response.skills ?? [];
  return all.filter((skill) => skill.scope === "user");
}
