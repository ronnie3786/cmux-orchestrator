import { useMemo } from "react";
import { ChevronDown, ChevronRight, GitBranch, X } from "lucide-react";
import type { GitFile, GitSection } from "../../api/git";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import {
  EMPTY_GIT_ENTRY,
  useGitStore,
  type DiffSheetState,
  type GitEntry,
} from "../../store/gitStore";
import {
  lineCode,
  lineMarker,
  parseUnifiedDiffLines,
  type ParsedDiffLine,
} from "../../lib/unifiedDiff";
import "./git.css";

export function DiffSheet() {
  const sheet = useGitStore((state) => state.diffSheet);
  const entry = useGitStore((state) =>
    sheet === null ? EMPTY_GIT_ENTRY : state.byPane[sheet.paneId] ?? EMPTY_GIT_ENTRY,
  );
  const closeDiff = useGitStore((state) => state.closeDiff);
  const lines = useMemo(() => parseUnifiedDiffLines(sheet?.diff ?? ""), [sheet?.diff]);

  useEscapeLayer(closeDiff, sheet !== null);
  useScrollLock(sheet !== null);

  if (sheet === null) return null;

  const retry = () => {
    if (sheet.section === "commit" && sheet.commitHash !== null) {
      useGitStore.getState().commitDiff(sheet.paneId, sheet.commitHash, sheet.file);
    } else if (sheet.section !== "commit") {
      useGitStore.getState().diff(sheet.paneId, sheet.file, sheet.section);
    }
  };
  const revisionLabel =
    sheet.section === "commit" && sheet.commitHash !== null
      ? `commit ${sheet.commitHash.slice(0, 8)}`
      : sheet.section;

  return (
    <div className="hz-diff-backdrop" onMouseDown={(event) => event.target === event.currentTarget && closeDiff()}>
      <div className="hz-diff-sheet" role="dialog" aria-modal="true" aria-label={`Diff for ${sheet.file}`}>
        <div className="hz-diff-header">
          <div className="hz-diff-heading">
            <span className="hz-diff-eyebrow">{revisionLabel}</span>
            <span className="hz-diff-title mono" title={sheet.file}>
              {sheet.file}
            </span>
          </div>
          <button type="button" className="hz-diff-done" onClick={closeDiff}>
            <X size={14} aria-hidden />
            <span>Done</span>
          </button>
        </div>
        <div className="hz-diff-layout">
          <DiffSidebar entry={entry} sheet={sheet} />
          <div className="hz-diff-body">
            {sheet.isLoading ? (
              <p className="hz-diff-state" role="status">Loading diff…</p>
            ) : sheet.error !== null ? (
              <div className="hz-diff-state hz-diff-error">
                <span>Diff unavailable</span>
                <small>{sheet.error}</small>
                <button type="button" onClick={retry}>
                  Try again
                </button>
              </div>
            ) : sheet.diff === "" ? (
              <p className="hz-diff-state hz-diff-empty">(empty diff)</p>
            ) : (
              lines.map((line) => <DiffLineRow key={line.id} line={line} />)
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function DiffSidebar({ entry, sheet }: { entry: GitEntry; sheet: DiffSheetState }) {
  const snapshot = entry.snapshot;
  if (snapshot === null) return null;
  return (
    <aside className="hz-diff-sidebar" aria-label="Repository changes">
      <div className="hz-diff-sidebar-header">
        <GitBranch size={14} aria-hidden />
        <div>
          <span>{snapshot.branch || "HEAD"}</span>
          <small className="mono" title={snapshot.rootPath}>{snapshot.rootPath}</small>
        </div>
      </div>
      <div className="hz-diff-sidebar-scroll">
        <DiffSidebarSection
          title="Staged"
          paneId={sheet.paneId}
          section="staged"
          files={snapshot.staged}
          active={sheet}
        />
        <DiffSidebarSection
          title="Unstaged"
          paneId={sheet.paneId}
          section="unstaged"
          files={snapshot.unstaged}
          active={sheet}
        />
        <DiffSidebarSection
          title="Untracked"
          paneId={sheet.paneId}
          section="untracked"
          files={snapshot.untracked.map((file) => ({ status: "?", file }))}
          active={sheet}
        />
        {snapshot.commits.length > 0 ? (
          <section className="hz-diff-sidebar-section">
            <h3>Recent commits</h3>
            {snapshot.commits.map((commit) => {
              const expanded = entry.expandedCommitHash === commit.hash;
              const files = entry.commitFiles[commit.hash];
              return (
                <div className="hz-diff-sidebar-commit" key={commit.hash}>
                  <button
                    type="button"
                    aria-expanded={expanded}
                    title={commit.message}
                    onClick={() => useGitStore.getState().toggleCommit(sheet.paneId, commit.hash)}
                  >
                    {expanded ? (
                      <ChevronDown size={12} aria-hidden />
                    ) : (
                      <ChevronRight size={12} aria-hidden />
                    )}
                    <span className="mono">{commit.hash.slice(0, 8)}</span>
                    <span>{commit.message}</span>
                  </button>
                  {expanded ? (
                    <div className="hz-diff-sidebar-commit-files">
                      {files === undefined || files.loading ? (
                        <small>Loading…</small>
                      ) : files.error !== null ? (
                        <button
                          type="button"
                          className="hz-diff-sidebar-retry"
                          onClick={() =>
                            useGitStore
                              .getState()
                              .toggleCommit(sheet.paneId, commit.hash, { force: true })
                          }
                        >
                          Try again
                        </button>
                      ) : files.files.length === 0 ? (
                        <small>No files</small>
                      ) : (
                        files.files.map((file) => {
                          const active =
                            sheet.section === "commit" &&
                            sheet.commitHash === commit.hash &&
                            sheet.file === file.file;
                          return (
                            <button
                              type="button"
                              className={active ? "hz-diff-sidebar-file-active" : ""}
                              key={`${commit.hash}-${file.file}`}
                              title={file.file}
                              onClick={() =>
                                useGitStore
                                  .getState()
                                  .commitDiff(sheet.paneId, commit.hash, file.file)
                              }
                            >
                              <span className="mono">{file.status}</span>
                              <span className="mono">{file.file}</span>
                            </button>
                          );
                        })
                      )}
                    </div>
                  ) : null}
                </div>
              );
            })}
          </section>
        ) : null}
      </div>
    </aside>
  );
}

function DiffSidebarSection({
  title,
  paneId,
  section,
  files,
  active,
}: {
  title: string;
  paneId: string;
  section: GitSection;
  files: GitFile[];
  active: DiffSheetState;
}) {
  if (files.length === 0) return null;
  return (
    <section className="hz-diff-sidebar-section">
      <h3>{title}</h3>
      {files.map((file) => {
        const isActive =
          active.section === section && active.commitHash === null && active.file === file.file;
        return (
          <button
            type="button"
            className={isActive ? "hz-diff-sidebar-file-active" : ""}
            key={`${section}-${file.file}`}
            title={file.file}
            onClick={() => useGitStore.getState().diff(paneId, file.file, section)}
          >
            <span className="mono">{file.status}</span>
            <span className="mono">{file.file}</span>
          </button>
        );
      })}
    </section>
  );
}

function DiffLineRow({ line }: { line: ParsedDiffLine }) {
  return (
    <div className={`hz-diff-row hz-diff-row-${line.kind}`}>
      <span className="hz-diff-gutter">{line.oldLineNumber ?? ""}</span>
      <span className="hz-diff-gutter">{line.newLineNumber ?? ""}</span>
      <span className="hz-diff-marker">{lineMarker(line)}</span>
      <span className="hz-diff-text">{lineCode(line)}</span>
    </div>
  );
}
