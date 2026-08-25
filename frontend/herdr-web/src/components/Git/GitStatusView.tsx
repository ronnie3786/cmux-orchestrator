import {
  useCallback,
  useEffect,
  useState,
  type KeyboardEvent,
  type MouseEvent,
} from "react";
import {
  ChevronDown,
  ChevronRight,
  FileClock,
  GitBranch,
  History,
  RefreshCw,
} from "lucide-react";
import type { GitSection } from "../../api/git";
import { useWorkspacesStore } from "../../store/workspacesStore";
import {
  EMPTY_GIT_ENTRY,
  useGitStore,
  type CommitFilesEntry,
  type GitEntry,
  type GitSnapshot,
} from "../../store/gitStore";
import { ToolErrorCard } from "../Shared/ToolErrorCard";
import { CommandLensDock } from "../Pane/CommandLensDock";
import { DiffSheet } from "./DiffSheet";
import { GitContextMenu, type GitContextTarget } from "./GitContextMenu";
import "./git.css";

const POLL_INTERVAL_MS = 10_000;

interface GitStatusViewProps {
  paneId: string;
  embedded?: boolean;
}

export function GitStatusView({ paneId, embedded = false }: GitStatusViewProps) {
  const data = useWorkspacesStore((state) => state.data);
  const pane = embedded
    ? null
    : (data?.workspaces
        .flatMap((workspace) => workspace.panes)
        .find((candidate) => candidate.pane_id === paneId) ?? null);
  const entry = useGitStore((state) => state.byPane[paneId] ?? EMPTY_GIT_ENTRY);

  useEffect(() => {
    const store = useGitStore.getState();
    if (store.diffSheet !== null && store.diffSheet.paneId !== paneId) {
      store.closeDiff();
    }

    let pollTimer: ReturnType<typeof setInterval> | null = null;
    const refresh = () => void useGitStore.getState().load(paneId);
    const stopPolling = () => {
      if (pollTimer !== null) {
        clearInterval(pollTimer);
        pollTimer = null;
      }
    };
    const syncPolling = () => {
      stopPolling();
      if (document.visibilityState === "visible") {
        refresh();
        pollTimer = setInterval(refresh, POLL_INTERVAL_MS);
      }
    };

    syncPolling();
    document.addEventListener("visibilitychange", syncPolling);
    return () => {
      stopPolling();
      document.removeEventListener("visibilitychange", syncPolling);
      const latest = useGitStore.getState();
      if (latest.diffSheet?.paneId === paneId) {
        latest.closeDiff();
      }
    };
  }, [paneId]);

  let body;
  if (entry.error !== null && entry.snapshot === null) {
    body = (
      <ToolErrorCard
        tool="Git"
        message={entry.error}
        onRetry={() => void useGitStore.getState().load(paneId, { force: true })}
      />
    );
  } else if (entry.loading && entry.snapshot === null) {
    body = (
      <div className="hz-git-state" role="status">
        <RefreshCw className="hz-git-state-spinner" size={18} aria-hidden />
        <span className="hz-git-state-title">Reading working tree…</span>
        <span className="hz-git-state-sub">Resolving the repository for this pane.</span>
      </div>
    );
  } else if (entry.noRepo || entry.snapshot === null) {
    body = (
      <div className="hz-git-state">
        <GitBranch size={20} aria-hidden />
        <span className="hz-git-state-title">No Git repository</span>
        <span className="hz-git-state-sub">This pane's working directory is outside a repository.</span>
      </div>
    );
  } else {
    body = <GitBody paneId={paneId} entry={entry} snapshot={entry.snapshot} />;
  }

  return (
    <main
      className={`hz-detail-col hz-git-col${embedded ? " hz-git-col-embedded" : ""}`}
      aria-busy={entry.loading}
    >
      <div className="hz-git-scroll">{body}</div>
      {pane !== null ? <CommandLensDock pane={pane} /> : null}
      <DiffSheet />
    </main>
  );
}

function GitBody({
  paneId,
  entry,
  snapshot,
}: {
  paneId: string;
  entry: GitEntry;
  snapshot: GitSnapshot;
}) {
  const [contextTarget, setContextTarget] = useState<GitContextTarget | null>(null);
  const closeContextMenu = useCallback(() => setContextTarget(null), []);
  const changedCount = snapshot.staged.length + snapshot.unstaged.length + snapshot.untracked.length;
  const isClean = changedCount === 0;
  const branch = snapshot.branch || "HEAD";
  const repositoryPathParts = snapshot.rootPath.split(/[\\/]/).filter(Boolean);
  const repositoryName = repositoryPathParts[repositoryPathParts.length - 1] ?? "repository";

  return (
    <div className="hz-git-workbench">
      <section className="hz-git-header" aria-label="Repository status">
        <div className="hz-git-header-main">
          <div className="hz-git-repo-mark" aria-hidden>
            <GitBranch size={17} />
          </div>
          <div className="hz-git-repo-copy">
            <span className="hz-git-eyebrow">Working tree</span>
            <div className="hz-git-identity">
              <span className="hz-git-repo-name" title={snapshot.rootPath}>
                {repositoryName}
              </span>
              <span className="hz-git-branch mono" title={branch}>
                {branch}
              </span>
              {snapshot.detached ? <span className="hz-git-detached">detached</span> : null}
            </div>
          </div>
          <button
            type="button"
            className="hz-git-refresh"
            onClick={() => void useGitStore.getState().load(paneId, { force: true })}
            aria-label="Refresh Git status"
          >
            <RefreshCw className={entry.loading ? "hz-git-refresh-spinning" : ""} size={14} aria-hidden />
            <span>Refresh</span>
          </button>
        </div>
        <div className="hz-git-header-meta">
          <span className={`hz-git-changed${isClean ? " hz-git-changed-clean" : ""}`}>
            {isClean ? "Clean" : `${changedCount} changed`}
          </span>
          <span className="hz-git-path mono" title={snapshot.rootPath}>
            {snapshot.rootPath}
          </span>
        </div>
      </section>

      {entry.error !== null ? (
        <div className="hz-git-refresh-warning" role="status">
          <span>Couldn't refresh: {entry.error}</span>
          <button
            type="button"
            onClick={() => void useGitStore.getState().load(paneId, { force: true })}
          >
            Try again
          </button>
        </div>
      ) : null}

      {isClean ? (
        <div className="hz-git-clean-state">
          <span className="hz-git-clean-pulse" aria-hidden />
          <div>
            <span className="hz-git-state-title">Working tree clean</span>
            <span className="hz-git-state-sub">Everything in this repository is committed.</span>
          </div>
        </div>
      ) : (
        <div className="hz-git-change-stack">
          <GitFileSection
            paneId={paneId}
            title="Staged"
            section="staged"
            files={snapshot.staged}
            onContextMenu={setContextTarget}
          />
          <GitFileSection
            paneId={paneId}
            title="Unstaged"
            section="unstaged"
            files={snapshot.unstaged}
            onContextMenu={setContextTarget}
          />
          <GitFileSection
            paneId={paneId}
            title="Untracked"
            section="untracked"
            files={snapshot.untracked.map((file) => ({ status: "?", file }))}
            onContextMenu={setContextTarget}
          />
        </div>
      )}

      {snapshot.commits.length > 0 ? (
        <CommitHistory paneId={paneId} snapshot={snapshot} entry={entry} />
      ) : null}

      {contextTarget !== null ? (
        <GitContextMenu paneId={paneId} target={contextTarget} onClose={closeContextMenu} />
      ) : null}
    </div>
  );
}

interface GitFileSectionProps {
  paneId: string;
  title: string;
  section: GitSection;
  files: Array<{ status: string; file: string }>;
  onContextMenu: (target: GitContextTarget) => void;
}

function GitFileSection({ paneId, title, section, files, onContextMenu }: GitFileSectionProps) {
  if (files.length === 0) return null;
  return (
    <section className={`hz-git-section hz-git-section-${section}`}>
      <div className="hz-git-section-heading">
        <h2>{title}</h2>
        <span>{files.length}</span>
      </div>
      <div className="hz-git-file-list">
        {files.map((file) => (
          <GitFileRow
            key={`${section}-${file.file}`}
            paneId={paneId}
            path={file.file}
            status={file.status}
            section={section}
            onContextMenu={onContextMenu}
          />
        ))}
      </div>
    </section>
  );
}

interface GitFileRowProps {
  paneId: string;
  path: string;
  status: string;
  section: GitSection;
  onContextMenu: (target: GitContextTarget) => void;
}

function GitFileRow({ paneId, path, status, section, onContextMenu }: GitFileRowProps) {
  const showContextMenu = (x: number, y: number) => onContextMenu({ x, y, path, section });
  const contextPoint = (event: MouseEvent<HTMLDivElement>) => {
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    showContextMenu(event.clientX || rect.left + 28, event.clientY || rect.top + rect.height / 2);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (event.shiftKey && event.key === "F10") {
      event.preventDefault();
      const rect = event.currentTarget.getBoundingClientRect();
      showContextMenu(rect.left + 28, rect.top + rect.height / 2);
    }
  };
  const actionLabel = section === "staged" ? "Unstage" : "Stage";

  return (
    <div
      className="hz-git-row hz-git-row-diffable"
      onContextMenu={contextPoint}
    >
      <button
        type="button"
        className="hz-git-row-open"
        aria-label={`View ${section} diff for ${path}`}
        onClick={() => useGitStore.getState().diff(paneId, path, section)}
        onKeyDown={onKeyDown}
      >
        <span className="hz-git-change-rail" aria-hidden />
        <span className="hz-git-badge mono" aria-hidden>
          {status}
        </span>
        <span className="hz-git-file mono" title={path}>
          {path}
        </span>
      </button>
      <button
        type="button"
        className="hz-git-row-action"
        aria-label={`${actionLabel} ${path}`}
        onClick={() => {
          if (section === "staged") {
            void useGitStore.getState().unstage(paneId, path);
          } else {
            void useGitStore.getState().stage(paneId, path);
          }
        }}
      >
        {actionLabel}
      </button>
    </div>
  );
}

function CommitHistory({
  paneId,
  snapshot,
  entry,
}: {
  paneId: string;
  snapshot: GitSnapshot;
  entry: GitEntry;
}) {
  return (
    <section className="hz-git-history">
      <div className="hz-git-history-heading">
        <div>
          <History size={14} aria-hidden />
          <h2>Recent commits</h2>
        </div>
        <span>Browse an earlier snapshot</span>
      </div>
      <div className="hz-git-commits">
        {snapshot.commits.map((commit) => {
          const expanded = entry.expandedCommitHash === commit.hash;
          const files = entry.commitFiles[commit.hash];
          return (
            <div className={`hz-git-commit${expanded ? " hz-git-commit-expanded" : ""}`} key={commit.hash}>
              <button
                type="button"
                className="hz-git-commit-row"
                aria-expanded={expanded}
                onClick={() => useGitStore.getState().toggleCommit(paneId, commit.hash)}
              >
                {expanded ? (
                  <ChevronDown size={14} aria-hidden />
                ) : (
                  <ChevronRight size={14} aria-hidden />
                )}
                <span className="hz-git-commit-hash mono" title={commit.hash}>
                  {commit.hash.slice(0, 8)}
                </span>
                <span className="hz-git-commit-message" title={commit.message}>
                  {commit.message}
                </span>
              </button>
              {expanded ? (
                <CommitFiles paneId={paneId} hash={commit.hash} state={files} />
              ) : null}
            </div>
          );
        })}
      </div>
    </section>
  );
}

function CommitFiles({
  paneId,
  hash,
  state,
}: {
  paneId: string;
  hash: string;
  state: CommitFilesEntry | undefined;
}) {
  if (state === undefined || state.loading) {
    return <p className="hz-git-commit-state">Loading changed files…</p>;
  }
  if (state.error !== null) {
    return (
      <div className="hz-git-commit-state hz-git-commit-error">
        <span>{state.error}</span>
        <button
          type="button"
          onClick={() => useGitStore.getState().toggleCommit(paneId, hash, { force: true })}
        >
          Try again
        </button>
      </div>
    );
  }
  if (state.files.length === 0) {
    return <p className="hz-git-commit-state">No files changed in this commit.</p>;
  }
  return (
    <div className="hz-git-commit-files">
      {state.files.map((file) => (
        <button
          type="button"
          className="hz-git-commit-file"
          key={`${hash}-${file.file}`}
          onClick={() => useGitStore.getState().commitDiff(paneId, hash, file.file)}
        >
          <span className="hz-git-commit-file-status mono">{file.status}</span>
          <span className="mono" title={file.file}>
            {file.file}
          </span>
          <FileClock size={13} aria-hidden />
        </button>
      ))}
    </div>
  );
}
