import { useEffect, useRef, useState } from "react";
import {
  CheckCircle2,
  ChevronDown,
  Circle,
  CircleMinus,
  CirclePlus,
  Search,
  RefreshCw,
} from "lucide-react";
import type { GitFile, GitStatus, Workspace } from "../../api/types";
import { useGitStore } from "../../store/gitStore";
import { DiffSheet } from "./DiffSheet";
import { PRComments } from "./PRComments";

interface GitStatusViewProps {
  workspace: Workspace;
  /** Switch the detail view to the Terminal tab (iOS `detailTab = .terminal`). */
  onJumpToTerminal: () => void;
}

type FileSectionKind = "staged" | "unstaged" | "untracked";

/**
 * iOS `GitStatusView`: the Status / PR Comments segmented control with the
 * Repository section, Staged / Unstaged (untracked merged in, iOS parity) /
 * Recent Commits sections, and per-file Diff / Stage / Unstage actions.
 */
export function GitStatusView({ workspace, onJumpToTerminal }: GitStatusViewProps) {
  const gitSegment = useGitStore((state) => state.gitSegment);
  const setSegment = useGitStore((state) => state.setSegment);

  return (
    <div className="git-tab-panel">
      <div className="git-segments" role="tablist" aria-label="Git sections">
        <button
          type="button"
          role="tab"
          aria-selected={gitSegment === "status"}
          className={gitSegment === "status" ? "git-segment git-segment-active" : "git-segment"}
          onClick={() => setSegment("status")}
        >
          Status
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={gitSegment === "prComments"}
          className={gitSegment === "prComments" ? "git-segment git-segment-active" : "git-segment"}
          onClick={() => setSegment("prComments")}
        >
          PR Comments
        </button>
      </div>

      {gitSegment === "status" ? (
        <GitStatusSections workspace={workspace} />
      ) : (
        <PRComments workspace={workspace} onJumpToTerminal={onJumpToTerminal} />
      )}

      <DiffSheet workspace={workspace} onJumpToTerminal={onJumpToTerminal} />
    </div>
  );
}

function GitStatusSections({ workspace }: { workspace: Workspace }) {
  const gitStatus = useGitStore((state) => state.gitStatus);
  const gitError = useGitStore((state) => state.gitError);
  const isLoadingGit = useGitStore((state) => state.isLoadingGit);
  const pollNow = useGitStore((state) => state.pollNow);

  return (
    <div className="git-status">
      {isLoadingGit && gitStatus === null ? (
        <div className="git-loading">
          <div className="spinner" aria-label="Loading git status" />
        </div>
      ) : gitError !== null ? (
        <div className="git-error">
          <span className="git-error-text">{gitError}</span>
          <button type="button" className="git-error-retry" onClick={() => void pollNow()}>
            <RefreshCw size={13} />
            Retry
          </button>
        </div>
      ) : gitStatus !== null ? (
        <GitStatusBody status={gitStatus} workspace={workspace} />
      ) : (
        <div className="git-empty git-empty-block">
          <span className="git-empty-icon">
            <Circle size={28} />
          </span>
          <span className="git-empty-title">No Git Data</span>
        </div>
      )}
    </div>
  );
}

/** iOS `gitStatusSections` body: Repository + conditional file sections. */
function GitStatusBody({ status, workspace }: { status: GitStatus; workspace: Workspace }) {
  const isClean =
    status.staged.length === 0 && status.unstaged.length === 0 && status.untracked.length === 0;

  return (
    <>
      <section className="git-section">
        <h3 className="git-section-title">Repository</h3>
        <div className="git-labeled-row">
          <span className="git-labeled-key">Branch</span>
          <span className="git-labeled-value mono" title={status.branch ?? undefined}>
            {status.branch != null && status.branch !== "" ? status.branch : "Unknown"}
          </span>
        </div>
        <div className="git-labeled-row">
          <span className="git-labeled-key">Path</span>
          <span className="git-labeled-value mono" title={status.cwd ?? undefined}>
            {status.cwd != null && status.cwd !== "" ? status.cwd : "No git repo"}
          </span>
        </div>
      </section>

      {isClean ? (
        <div className="git-empty git-empty-block">
          <span className="git-empty-icon">
            <CheckCircle2 size={28} />
          </span>
          <span className="git-empty-title">Clean</span>
        </div>
      ) : null}

      {status.staged.length > 0 ? (
        <GitStatusFileListSection
          title="Staged"
          entries={status.staged}
          kindOf={() => "staged"}
          workspace={workspace}
        />
      ) : null}

      {status.unstaged.length > 0 || status.untracked.length > 0 ? (
        <GitStatusFileListSection
          title="Unstaged"
          entries={[
            ...status.unstaged,
            // iOS merges untracked rows into the Unstaged section with "?" status.
            ...status.untracked.map((file): GitFile => ({ file, status: "?" })),
          ]}
          kindOf={(entry) => (entry.status === "?" && status.untracked.includes(entry.file) ? "untracked" : "unstaged")}
          workspace={workspace}
        />
      ) : null}

      {status.commits.length > 0 ? (
        <section className="git-section">
          <h3 className="git-section-title">Recent Commits</h3>
          <div className="git-commit-list">
            {status.commits.map((commit) => (
              <div className="git-commit-row" key={commit.hash}>
                <span className="git-commit-message" title={commit.message}>
                  {commit.message}
                </span>
                <span className="git-commit-hash" title={commit.hash}>
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

function GitStatusFileListSection({
  title,
  entries,
  kindOf,
  workspace,
}: {
  title: string;
  entries: GitFile[];
  /** Per-row section kind (untracked rows live in the Unstaged section, iOS parity). */
  kindOf: (entry: GitFile) => FileSectionKind;
  workspace: Workspace;
}) {
  return (
    <section className="git-section">
      <h3 className="git-section-title">
        {title} <span className="git-section-count">{entries.length}</span>
      </h3>
      <div className="git-file-list">
        {entries.map((entry) => (
          <GitStatusFileRow
            key={`${kindOf(entry)}-${entry.file}`}
            entry={entry}
            kind={kindOf(entry)}
            workspace={workspace}
          />
        ))}
      </div>
    </section>
  );
}

/**
 * iOS `GitFileRow`: status badge (green for staged, orange otherwise), file
 * name, inline Diff button, and the context menu (View Diff / Stage File /
 * Unstage File).
 */
function GitStatusFileRow({
  entry,
  kind,
  workspace,
}: {
  entry: GitFile;
  kind: FileSectionKind;
  workspace: Workspace;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const requestDiff = useGitStore((state) => state.requestDiff);
  const stageFile = useGitStore((state) => state.stageFile);
  const unstageFile = useGitStore((state) => state.unstageFile);

  useEffect(() => {
    if (!menuOpen) return;
    const close = (event: PointerEvent) => {
      if (menuRef.current !== null && !menuRef.current.contains(event.target as Node)) {
        setMenuOpen(false);
      }
    };
    window.addEventListener("pointerdown", close);
    return () => window.removeEventListener("pointerdown", close);
  }, [menuOpen]);

  const openDiff = () => requestDiff(workspace.index, entry.file, kind);
  const stage = () => void stageFile(workspace.index, entry.file);
  const unstage = () => void unstageFile(workspace.index, entry.file);

  return (
    <div className="git-file-row">
      <span
        className={`git-file-status${kind === "staged" ? " git-file-status-green" : " git-file-status-orange"}`}
      >
        {entry.status}
      </span>
      <span className="git-file-name" title={entry.file}>
        {entry.file}
      </span>
      <button
        type="button"
        className="git-file-diff-button"
        title="View Diff"
        aria-label={`View diff for ${entry.file}`}
        onClick={openDiff}
      >
        <Search size={15} />
      </button>
      <button
        type="button"
        className="git-file-menu-button"
        aria-label={`Actions for ${entry.file}`}
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        onClick={() => setMenuOpen((open) => !open)}
      >
        <ChevronDown size={15} />
      </button>
      {menuOpen ? (
        <div className="git-file-menu" ref={menuRef} role="menu">
          <button
            type="button"
            role="menuitem"
            className="git-file-menu-item"
            onClick={() => {
              setMenuOpen(false);
              openDiff();
            }}
          >
            <Search size={14} />
            View Diff
          </button>
          {kind === "staged" ? (
            <button
              type="button"
              role="menuitem"
              className="git-file-menu-item"
              onClick={() => {
                setMenuOpen(false);
                unstage();
              }}
            >
              <CircleMinus size={14} />
              Unstage File
            </button>
          ) : (
            <button
              type="button"
              role="menuitem"
              className="git-file-menu-item"
              onClick={() => {
                setMenuOpen(false);
                stage();
              }}
            >
              <CirclePlus size={14} />
              Stage File
            </button>
          )}
        </div>
      ) : null}
    </div>
  );
}
