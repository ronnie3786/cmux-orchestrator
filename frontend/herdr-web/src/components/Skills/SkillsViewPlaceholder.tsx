/**
 * Skills view placeholder (P11-run-A). The ⋯ menu already lists "Skills";
 * the real view (skill sections + Claude/Codex/file inserts) arrives with
 * the tools port (P11-run-B) and replaces this component. The Command Lens
 * dock stays mounted so inserts have a composer target.
 */

import { useWorkspacesStore } from "../../store/workspacesStore";
import { CommandLensDock } from "../Pane/CommandLensDock";
import "./skills.css";

export function SkillsViewPlaceholder() {
  const workspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const paneId = useWorkspacesStore((state) => state.selectedPaneId);
  const data = useWorkspacesStore((state) => state.data);
  const pane =
    data?.workspaces.find((candidate) => candidate.workspace_id === workspaceId)?.panes.find(
      (candidate) => candidate.pane_id === paneId,
    ) ?? null;

  return (
    <main className="hz-detail-col hz-skills-col">
      <div className="hz-skills-placeholder">
        <h2 className="hz-skills-placeholder-title">Skills</h2>
        <p className="hz-skills-placeholder-copy">
          Choose a skill, then insert it as a Claude command, Codex invocation, or file reference.
        </p>
      </div>
      {pane !== null ? <CommandLensDock pane={pane} /> : null}
    </main>
  );
}
