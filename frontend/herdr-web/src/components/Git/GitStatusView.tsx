/**
 * Git pane view (P11-run-A) — doc 01 §4 WorkspaceGitView parity: repository
 * header (branch + "N changed"/"clean" + path), staged/unstaged/untracked
 * sections with per-file Stage/Unstage + diff tap, recent commits rows, and
 * the diff sheet. Strings byte-exact per doc 01 §6.
 *
 * The Command Lens dock stays mounted in every pane view so skill/file/Jira
 * inserts have a composer target (doc 01 §4.3).
 */

import { useEffect } from "react";
import { useWorkspacesStore } from "../../store/workspacesStore";
import { useGitStore, EMPTY_GIT_ENTRY, type GitSnapshot } from "../../store/gitStore";
import { ToolErrorCard } from "../Shared/ToolErrorCard";
import { CommandLensDock } from "../Pane/CommandLensDock";
import { DiffSheet } from "./DiffSheet";
import "./git.css";

export function GitStatusView() {
  const workspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const paneId = useWorkspacesStore((state) => state.selectedPaneId);
  const data = useWorkspacesStore((state) => state.data);
  const pane =
    data?.workspaces.find((candidate) => candidate.workspace_id === workspaceId)?.panes.find(
      (candidate) => candidate.pane_id === paneId,
    ) ?? null;
  const entry = useGitStore((state) =>
    workspaceId === null ? EMPTY_GIT_ENTRY : state.byWorkspace[workspaceId] ?? EMPTY_GIT_ENTRY,
  );

  useEffect(() => {
    if (workspaceId !== null) {
      void useGitStore.getState().load(workspaceId);
    }
  }, [workspaceId]);

  let body;
  if (entry.error !== null) {
    body = (
      <ToolErrorCard
        tool="Git"
        message={entry.error}
        onRetry={() => workspaceId !== null && void useGitStore.getState().load(workspaceId)}
      />
    );
  } else if (entry.loading && entry.snapshot === null) {
    body = <p className="hz-git-state-title">Reading workspace Git state…</p>;
  } else if (entry.noRepo || entry.snapshot === null) {
    body = (
      <div className="hz-git-state">
        <span className="hz-git-state-title">No Git data</span>
        <span className="hz-git-state-sub">This workspace does not have a Git repository yet.</span>
      </div>
    );
  } else {
    body = <GitBody snapshot={entry.snapshot} />;
  }

  return (
    <main className="hz-detail-col hz-git-col">
      <div className="hz-git-scroll">{body}</div>
      {pane !== null ? <CommandLensDock pane={pane} /> : null}
      <DiffSheet />
    </main>
  );
}

function GitBody({ snapshot }: { snapshot: GitSnapshot }) {
  const workspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const changedCount = snapshot.staged.length + snapshot.unstaged.length + snapshot.untracked.length;
  const isClean = changedCount === 0;

  return (
    <>
      <section className="hz-git-header">
        <div className="hz-git-header-row">
          <span className="hz-git-branch mono" title={snapshot.branch}>
            {snapshot.branch}
          </span>
          {snapshot.detached ? <span className="hz-git-detached">detached</span> : null}
          <button
            type="button"
            className="hz-git-refresh"
            onClick={() => workspaceId !== null && void useGitStore.getState().load(workspaceId)}
          >
            Refresh Git
          </button>
        </div>
        <div className="hz-git-header-row">
          <span className="hz-git-changed">{isClean ? "clean" : `${changedCount} changed`}</span>
          <span className="hz-git-path mono" title={snapshot.rootPath}>
            {snapshot.rootPath}
          </span>
        </div>
      </section>

      {isClean ? (
        <div className="hz-git-state">
          <span className="hz-git-state-title">Working tree clean</span>
          <span className="hz-git-state-sub">Everything in this workspace is committed.</span>
        </div>
      ) : null}

      {snapshot.staged.length > 0 ? (
        <section className="hz-git-section">
          <h3 className="hz-git-section-title">staged</h3>
          {snapshot.staged.map((file) => (
            <GitFileRow key={`staged-${file.file}`} path={file.file} status={file.status} section="staged" />
          ))}
        </section>
      ) : null}

      {snapshot.unstaged.length > 0 ? (
        <section className="hz-git-section">
          <h3 className="hz-git-section-title">unstaged</h3>
          {snapshot.unstaged.map((file) => (
            <GitFileRow key={`unstaged-${file.file}`} path={file.file} status={file.status} section="unstaged" />
          ))}
        </section>
      ) : null}

      {snapshot.untracked.length > 0 ? (
        <section className="hz-git-section">
          <h3 className="hz-git-section-title">untracked</h3>
          {snapshot.untracked.map((file) => (
            <GitFileRow key={`untracked-${file}`} path={file} status="?" section={null} />
          ))}
        </section>
      ) : null}

      {snapshot.commits.length > 0 ? (
        <section className="hz-git-section">
          <h3 className="hz-git-section-title">recent commits</h3>
          <div className="hz-git-commits">
            {snapshot.commits.map((commit) => (
              <div className="hz-git-commit-row" key={commit.hash}>
                <span className="hz-git-commit-message" title={commit.message}>
                  {commit.message}
                </span>
                <span className="hz-git-commit-hash mono" title={commit.hash}>
                  {commit.hash}
                </span>
              </div>
            ))}
          </div>
        </section>
      ) : null}
    </>
  );
}

/**
 * Per-file row: status badge + path, tap → diff sheet (staged/unstaged only —
 * the 9092 diff route has no section for untracked files), Stage for
 * unstaged/untracked, Unstage for staged.
 */
function GitFileRow({
  path,
  status,
  section,
}: {
  path: string;
  status: string;
  /** null = untracked row (no diff available). */
  section: "staged" | "unstaged" | null;
}) {
  const badgeClass =
    section === "staged"
      ? "hz-git-badge-green"
      : section === "unstaged"
        ? "hz-git-badge-orange"
        : "hz-git-badge-muted";

  return (
    <div
      className={`hz-git-row${section === null ? "" : " hz-git-row-diffable"}`}
      onClick={section === null ? undefined : () => useGitStore.getState().diff(path, section)}
      role={section === null ? undefined : "button"}
      tabIndex={section === null ? undefined : 0}
      onKeyDown={
        section === null
          ? undefined
          : (event) => {
              if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                useGitStore.getState().diff(path, section);
              }
            }
      }
    >
      <span className={`hz-git-badge mono ${badgeClass}`} aria-hidden>
        {status}
      </span>
      <span className="hz-git-file mono" title={path}>
        {path}
      </span>
      <button
        type="button"
        className="hz-git-row-action"
        onClick={(event) => {
          event.stopPropagation();
          if (section === "staged") {
            void useGitStore.getState().unstage(path);
          } else {
            void useGitStore.getState().stage(path);
          }
        }}
      >
        {section === "staged" ? "Unstage" : "Stage"}
      </button>
    </div>
  );
}
