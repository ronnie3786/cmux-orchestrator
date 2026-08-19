/**
 * Skills pane view (P11-run-B) — port of iOS WorkspaceSkillsView (doc 01 §4):
 * `workspace skills` header (N found + Refresh skills + root path), project /
 * user sections with per-skill insert menus (Claude Code / Codex CLI /
 * Skill file path — tokens byte-exact per SkillInsertionStyle), loading /
 * error (ToolErrorCard) / empty states. Strings byte-exact per doc 01 §6.
 *
 * Selecting a style inserts the token into this view's Command Lens dock
 * and switches the pane to the terminal view (iOS: appendToken + focus +
 * detailTab = .terminal).
 */

import { createPortal } from "react-dom";
import { useEffect, useRef } from "react";
import {
  DollarSign,
  FileText,
  Package,
  RefreshCw,
  Terminal,
  UserRound,
  Wand2,
} from "lucide-react";
import type { ProjectSkill } from "../../api/skills";
import {
  EMPTY_SKILLS_ENTRY,
  skillsBodyState,
  skillsFoundCount,
  useSkillsStore,
} from "../../store/skillsStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import { usePaneViewStore } from "../../store/paneViewStore";
import type { SkillInsertStyle } from "../../lib/skillInsert";
import { usePopover } from "../../hooks/usePopover";
import { ToolErrorCard } from "../Shared/ToolErrorCard";
import { CommandLensDock, type CommandLensDockHandle } from "../Pane/CommandLensDock";
import "./skills.css";

/** Menu styles in iOS SkillInsertionStyle order (labels byte-exact). */
const INSERT_STYLES: readonly { style: SkillInsertStyle; label: string }[] = [
  { style: "claude", label: "Claude Code" },
  { style: "codex", label: "Codex CLI" },
  { style: "path", label: "Skill file path" },
];

export function SkillsView() {
  const workspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const paneId = useWorkspacesStore((state) => state.selectedPaneId);
  const data = useWorkspacesStore((state) => state.data);
  const pane =
    data?.workspaces.find((candidate) => candidate.workspace_id === workspaceId)?.panes.find(
      (candidate) => candidate.pane_id === paneId,
    ) ?? null;
  const entry = useSkillsStore((state) =>
    workspaceId === null
      ? EMPTY_SKILLS_ENTRY
      : state.byWorkspace[workspaceId] ?? EMPTY_SKILLS_ENTRY,
  );
  const dockRef = useRef<CommandLensDockHandle>(null);

  useEffect(() => {
    if (workspaceId !== null) {
      void useSkillsStore.getState().load(workspaceId);
    }
  }, [workspaceId]);

  const reload = (): void => {
    if (workspaceId !== null) {
      void useSkillsStore.getState().load(workspaceId);
    }
  };

  const insert = (skill: ProjectSkill, style: SkillInsertStyle): void => {
    dockRef.current?.insertSkill(skill, style);
    if (workspaceId !== null && paneId !== null) {
      usePaneViewStore.getState().setView(workspaceId, paneId, "terminal");
    }
  };

  const state = skillsBodyState(entry);
  const found = skillsFoundCount(entry.projectSkills, entry.userSkills);
  // iOS shows the count as soon as a successful response exists (even 0).
  const showCount = state === "content" || state === "empty";

  let body;
  if (state === "loading") {
    body = (
      <div className="hz-skills-loading">
        <div className="spinner" aria-hidden />
        <span>Indexing project and user skills…</span>
      </div>
    );
  } else if (state === "error") {
    body = <ToolErrorCard tool="Skills" message={entry.error ?? ""} onRetry={reload} />;
  } else {
    body = (
      <>
        {entry.error !== null ? (
          <ToolErrorCard tool="Skills" message={entry.error} onRetry={reload} />
        ) : null}
        {state === "empty" ? (
          <div className="hz-skills-empty">
            <Wand2 size={24} aria-hidden />
            <span className="hz-skills-empty-title">No skills found</span>
            <span className="hz-skills-empty-sub">
              Add project skills under .claude/skills or user skills under your configured skills
              directory.
            </span>
          </div>
        ) : (
          <>
            {entry.projectSkills.length > 0 ? (
              <SkillSection
                title="project skills"
                detail={entry.skillsDirectory}
                skills={entry.projectSkills}
                onInsert={insert}
              />
            ) : null}
            {entry.userSkills.length > 0 ? (
              <SkillSection
                title="user skills"
                detail={entry.userSkillsDirectory}
                skills={entry.userSkills}
                onInsert={insert}
              />
            ) : null}
          </>
        )}
        <div className="hz-skills-insert-card">
          <span className="hz-skills-insert-title">Add to terminal</span>
          <span className="hz-skills-insert-copy">
            Choose a skill, then insert it as a Claude command, Codex invocation, or file
            reference.
          </span>
        </div>
      </>
    );
  }

  return (
    <main className="hz-detail-col hz-skills-col">
      <div className="hz-skills-scroll">
        <section className="hz-skills-header">
          <div className="hz-skills-header-row">
            <Wand2 size={15} className="hz-skills-wand" aria-hidden />
            <span className="hz-skills-title">workspace skills</span>
            {showCount ? <span className="hz-skills-count">{found} found</span> : null}
            <button
              type="button"
              className="hz-skills-refresh"
              title="Refresh skills"
              aria-label="Refresh skills"
              disabled={entry.loading}
              onClick={reload}
            >
              <RefreshCw size={14} aria-hidden />
            </button>
          </div>
          {entry.rootPath !== "" ? (
            <div className="hz-skills-root mono" title={entry.rootPath}>
              {entry.rootPath}
            </div>
          ) : null}
        </section>
        {body}
      </div>
      {pane !== null ? <CommandLensDock ref={dockRef} pane={pane} /> : null}
    </main>
  );
}

function SkillSection({
  title,
  detail,
  skills,
  onInsert,
}: {
  title: string;
  detail: string;
  skills: ProjectSkill[];
  onInsert: (skill: ProjectSkill, style: SkillInsertStyle) => void;
}) {
  return (
    <section className="hz-skills-section">
      <header className="hz-skills-section-header">
        <span className="hz-skills-section-title">{title}</span>
        {detail !== "" ? (
          <span className="hz-skills-section-detail mono" title={detail}>
            {detail}
          </span>
        ) : null}
        <span className="hz-skills-section-count">{skills.length}</span>
      </header>
      <div className="hz-skills-section-rows">
        {skills.map((skill) => (
          <SkillRow key={skillKey(skill)} skill={skill} onInsert={onInsert} />
        ))}
      </div>
    </section>
  );
}

/** iOS `ProjectSkill.id`: `\(scope ?? "project")|\(name)|\(skillFilePath)`. */
function skillKey(skill: ProjectSkill): string {
  return `${skill.scope ?? "project"}|${skill.name}|${skill.skill_file_path}`;
}

/** Row tap opens the insert-style menu (iOS SkillMenuRow Menu). */
function SkillRow({
  skill,
  onInsert,
}: {
  skill: ProjectSkill;
  onInsert: (skill: ProjectSkill, style: SkillInsertStyle) => void;
}) {
  const popover = usePopover();

  return (
    <>
      <button
        type="button"
        className="hz-skill-row"
        aria-haspopup="menu"
        aria-expanded={popover.open}
        aria-label={`Insert ${skill.name} skill`}
        onClick={(event) => popover.toggle(event.currentTarget)}
      >
        {skill.scope === "user" ? (
          <UserRound size={15} className="hz-skill-icon-user" aria-hidden />
        ) : (
          <Package size={15} className="hz-skill-icon-project" aria-hidden />
        )}
        <span className="hz-skill-row-main">
          <span className="hz-skill-name" title={skill.name}>
            {skill.name}
          </span>
          <span className="hz-skill-path mono" title={skill.skill_file_path}>
            {skill.skill_file_path}
          </span>
        </span>
      </button>
      {popover.open && popover.style !== null
        ? createPortal(
            <div
              ref={popover.panelRef}
              className="hz-popover hz-skill-popover"
              style={popover.style}
              role="menu"
            >
              {INSERT_STYLES.map(({ style, label }) => (
                <button
                  key={style}
                  type="button"
                  role="menuitem"
                  className="hz-skill-menu-item"
                  onClick={() => {
                    popover.close();
                    onInsert(skill, style);
                  }}
                >
                  <StyleIcon style={style} />
                  <span>{label}</span>
                </button>
              ))}
            </div>,
            document.body,
          )
        : null}
    </>
  );
}

function StyleIcon({ style }: { style: SkillInsertStyle }) {
  if (style === "claude") return <Terminal size={14} aria-hidden />;
  if (style === "codex") return <DollarSign size={14} aria-hidden />;
  return <FileText size={14} aria-hidden />;
}
