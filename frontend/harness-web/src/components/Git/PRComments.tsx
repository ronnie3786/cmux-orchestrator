import {
  CheckCircle2,
  Clock3,
  Copy,
  Link,
  ListOrdered,
  PlusCircle,
  Send,
  RefreshCw,
} from "lucide-react";
import { sendTextOrKey } from "../../api/endpoints";
import type {
  GitHubPRCommentsResponse,
  GitHubPRThread,
  Workspace,
} from "../../api/types";
import { formatPRCommentThreadPrompt, prThreadLineLabel } from "../../lib/reviewPrompt";
import { useConnectionStore } from "../../store/connectionStore";
import { useDraftStore } from "../../store/draftStore";
import { useGitStore } from "../../store/gitStore";
import { useSessionStore } from "../../store/sessionStore";

interface PRCommentsProps {
  workspace: Workspace;
  /** Switch the detail view to the Terminal tab (iOS `detailTab = .terminal`). */
  onJumpToTerminal: () => void;
}

/**
 * iOS `GitPRCommentsSections`: show-resolved toggle, PR header, per-file
 * thread rows with code context, and the four thread actions (insert to
 * prompt, copy, open, request fix).
 */
export function PRComments({ workspace, onJumpToTerminal }: PRCommentsProps) {
  const prComments = useGitStore((state) => state.prComments);
  const prCommentsError = useGitStore((state) => state.prCommentsError);
  const isLoadingPRComments = useGitStore((state) => state.isLoadingPRComments);
  const includeResolved = useGitStore((state) => state.includeResolved);
  const setIncludeResolved = useGitStore((state) => state.setIncludeResolved);
  const loadPRComments = useGitStore((state) => state.loadPRComments);

  /** iOS `.appendPRCommentThread`: append prompt block, jump to terminal, focus input. */
  const insertThread = (thread: GitHubPRThread) => {
    useDraftStore
      .getState()
      .appendBlock(formatPRCommentThreadPrompt(thread, prComments));
    onJumpToTerminal();
    useDraftStore.getState().requestFocus();
  };

  const copyThread = (thread: GitHubPRThread) => {
    void navigator.clipboard
      .writeText(formatPRCommentThreadPrompt(thread, prComments))
      .catch(() => {
        useConnectionStore.setState({ errorMessage: "Couldn't copy to clipboard" });
      });
  };

  /**
   * iOS `.requestFixForPRCommentThread`: send the formatted prompt directly to
   * the terminal (sendTextEffect appends the trailing newline), switch to the
   * terminal tab, and clear the shared error.
   */
  const requestFix = async (thread: GitHubPRThread) => {
    const message = formatPRCommentThreadPrompt(thread, prComments) + "\n";
    onJumpToTerminal();
    useConnectionStore.getState().clearError();
    try {
      await sendTextOrKey({
        index: workspace.index,
        text: message,
        surfaceId: workspace.surfaceId ?? null,
      });
      // iOS: .requestFinished + .screenTick
      void useSessionStore.getState().pollNow();
    } catch (err) {
      useConnectionStore.setState({
        errorMessage: err instanceof Error ? err.message : "Couldn't send fix request",
      });
    }
  };

  return (
    <div className="git-pr">
      <div className="git-pr-toggle-row">
        <label className="git-pr-toggle">
          <input
            type="checkbox"
            checked={includeResolved}
            onChange={(e) => setIncludeResolved(e.target.checked)}
          />
          Show resolved
        </label>
      </div>
      {prComments && prComments.hiddenResolvedCount > 0 ? (
        <div className="git-pr-hidden-note">
          {prComments.hiddenResolvedCount} resolved thread
          {prComments.hiddenResolvedCount === 1 ? "" : "s"} hidden
        </div>
      ) : null}

      {isLoadingPRComments && prComments === null ? (
        <div className="git-loading">
          <div className="spinner" aria-label="Loading PR comments" />
        </div>
      ) : prCommentsError !== null ? (
        <div className="git-error">
          <span className="git-error-text">{prCommentsError}</span>
          <button
            type="button"
            className="git-error-retry"
            onClick={() => loadPRComments(workspace.index)}
          >
            <RefreshCw size={13} />
            Retry
          </button>
        </div>
      ) : prComments !== null ? (
        <PRCommentsBody
          response={prComments}
          onInsert={insertThread}
          onCopy={copyThread}
          onRequestFix={requestFix}
        />
      ) : (
        <div className="git-empty">
          <span className="git-empty-icon">
            <ListOrdered size={28} />
          </span>
          <span className="git-empty-title">No PR Data</span>
        </div>
      )}
    </div>
  );
}

function PRCommentsBody({
  response,
  onInsert,
  onCopy,
  onRequestFix,
}: {
  response: GitHubPRCommentsResponse;
  onInsert: (thread: GitHubPRThread) => void;
  onCopy: (thread: GitHubPRThread) => void;
  onRequestFix: (thread: GitHubPRThread) => void;
}) {
  const pullRequest = response.pullRequest;
  return (
    <>
      {pullRequest != null ? (
        <section className="git-section git-pr-header-section">
          <h3 className="git-section-title">Pull Request</h3>
          <div className="git-pr-header">
            <div className="git-pr-title">#{pullRequest.number} {pullRequest.title}</div>
            {response.repository != null ? (
              <div className="git-pr-repo">
                {response.repository.owner}/{response.repository.name}
              </div>
            ) : null}
            {pullRequest.url != null && pullRequest.url !== "" ? (
              <a
                className="git-pr-open"
                href={pullRequest.url}
                target="_blank"
                rel="noreferrer"
              >
                <Link size={13} />
                Open PR
              </a>
            ) : null}
          </div>
        </section>
      ) : null}

      {response.files.length === 0 ? (
        <section className="git-section">
          <div className="git-empty">
            <span className="git-empty-icon">
              <ListOrdered size={28} />
            </span>
            <span className="git-empty-title">
              {response.hiddenResolvedCount > 0 ? "Only Resolved Threads" : "No PR Comments"}
            </span>
            <span className="git-empty-description">
              {response.hiddenResolvedCount > 0
                ? "Enable Show resolved to view resolved review threads."
                : "No code review threads were found for this branch."}
            </span>
          </div>
        </section>
      ) : (
        response.files.map((fileGroup) => (
          <section className="git-section" key={fileGroup.path}>
            <h3 className="git-section-title git-file-section-title">{fileGroup.path}</h3>
            {fileGroup.threads.map((thread) => (
              <PRThreadRow
                key={thread.id}
                thread={thread}
                onInsert={() => onInsert(thread)}
                onCopy={() => onCopy(thread)}
                onRequestFix={() => void onRequestFix(thread)}
              />
            ))}
          </section>
        ))
      )}
    </>
  );
}

function PRThreadRow({
  thread,
  onInsert,
  onCopy,
  onRequestFix,
}: {
  thread: GitHubPRThread;
  onInsert: () => void;
  onCopy: () => void;
  onRequestFix: () => void;
}) {
  const codeContext = thread.codeContext;

  return (
    <div className="pr-thread">
      <div className="pr-thread-top">
        <span className="pr-line-pill">
          <ListOrdered size={11} />
          {prThreadLineLabel(thread)}
        </span>
        {thread.isResolved ? (
          <span className="pr-pill">
            <CheckCircle2 size={11} />
            Resolved
          </span>
        ) : null}
        {thread.isOutdated ? (
          <span className="pr-pill">
            <Clock3 size={11} />
            Outdated
          </span>
        ) : null}
        <span className="pr-thread-actions">
          <button
            type="button"
            className="pr-action pr-action-insert"
            title="Insert to prompt"
            aria-label="Insert PR comment thread"
            onClick={onInsert}
          >
            <PlusCircle size={18} />
          </button>
          <button
            type="button"
            className="pr-action"
            title="Copy"
            aria-label="Copy PR comment thread"
            onClick={onCopy}
          >
            <Copy size={15} />
          </button>
          {thread.url != null && thread.url !== "" ? (
            <a
              className="pr-action pr-action-link"
              href={thread.url}
              target="_blank"
              rel="noreferrer"
              title="Open"
              aria-label="Open PR comment thread"
            >
              <Link size={15} />
            </a>
          ) : null}
        </span>
      </div>

      {codeContext != null && codeContext.lines.length > 0 ? (
        <div className="pr-code-context">
          {codeContext.lines.map((line) => (
            <div
              key={`${line.number}-${line.isTarget}`}
              className={line.isTarget ? "pr-code-line pr-code-line-target" : "pr-code-line"}
            >
              <span className="pr-code-line-number">{line.number}</span>
              <span className="pr-code-line-text">{line.text === "" ? " " : line.text}</span>
            </div>
          ))}
        </div>
      ) : null}

      {thread.comments.map((comment) => (
        <div className="pr-comment-bubble" key={comment.id}>
          <div className="pr-comment-meta">
            <span className="pr-comment-author">
              {comment.author === "" ? "unknown" : comment.author}
            </span>
            {comment.createdAt !== "" ? (
              <span className="pr-comment-date">{comment.createdAt}</span>
            ) : null}
          </div>
          <div className="pr-comment-body">{comment.body}</div>
        </div>
      ))}

      <button
        type="button"
        className="pr-request-fix"
        aria-label="Request fix for PR comment thread"
        onClick={onRequestFix}
      >
        <Send size={13} />
        Request fix
      </button>
    </div>
  );
}
