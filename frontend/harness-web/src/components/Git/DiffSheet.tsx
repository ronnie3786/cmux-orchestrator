import { useEffect, useRef, useState } from "react";
import { MessageSquare, MessageSquareDashed, RefreshCw, X } from "lucide-react";
import type { Workspace } from "../../api/types";
import {
  isCommentable,
  lineCode,
  lineMarker,
  parseUnifiedDiffLines,
  reviewCommentForLine,
  reviewLineNumber,
  reviewSide,
  type ParsedDiffLine,
} from "../../lib/unifiedDiff";
import { formatDiffLineReviewPrompt } from "../../lib/reviewPrompt";
import { useDraftStore } from "../../store/draftStore";
import { useGitStore } from "../../store/gitStore";

interface DiffSheetProps {
  workspace: Workspace;
  /** Switch the detail view to the Terminal tab (iOS `detailTab = .terminal`). */
  onJumpToTerminal: () => void;
}

/**
 * iOS `DiffSheetView`: the unified diff with commentable line rows. Tapping a
 * line opens the review-comment sheet; submitting appends the formatted
 * prompt block to the input draft, jumps to the terminal tab, and focuses
 * the input row (iOS `appendDiffLineReviewComment`).
 */
export function DiffSheet({ workspace, onJumpToTerminal }: DiffSheetProps) {
  const diffSheet = useGitStore((state) => state.diffSheet);
  const closeDiff = useGitStore((state) => state.closeDiff);
  const requestDiff = useGitStore((state) => state.requestDiff);

  const [selectedLine, setSelectedLine] = useState<ParsedDiffLine | null>(null);

  // Close on Escape (the Done button is the primary affordance).
  useEffect(() => {
    if (diffSheet === null) return;
    const handler = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      if (selectedLine !== null) {
        setSelectedLine(null);
      } else {
        closeDiff();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [diffSheet, selectedLine, closeDiff]);

  if (diffSheet === null) return null;

  const lines = parseUnifiedDiffLines(diffSheet.diff);

  return (
    <div className="diff-sheet-backdrop" onPointerDown={(e) => e.stopPropagation()}>
      <div className="diff-sheet" role="dialog" aria-label={`Diff for ${diffSheet.file}`}>
        <div className="diff-sheet-header">
          <span className="diff-sheet-title" title={diffSheet.file}>
            {diffSheet.file}
          </span>
          <button type="button" className="diff-sheet-done" onClick={() => closeDiff()}>
            Done
          </button>
        </div>

        <div className="diff-sheet-body">
          {diffSheet.isLoading ? (
            <div className="git-loading">
              <div className="spinner" aria-label="Loading diff" />
            </div>
          ) : diffSheet.error !== null ? (
            <div className="git-error">
              <span className="git-error-text">{diffSheet.error}</span>
              <button
                type="button"
                className="git-error-retry"
                onClick={() => requestDiff(workspace.index, diffSheet.file, diffSheet.section)}
              >
                <RefreshCw size={13} />
                Retry
              </button>
            </div>
          ) : (
            <>
              <div className="diff-instruction">
                <MessageSquareDashed size={14} />
                <span>Tap a line of code to add a comment or instruction to send.</span>
              </div>
              {lines.map((line) => (
                <DiffLineRow
                  key={line.id}
                  line={line}
                  onComment={isCommentable(line) ? () => setSelectedLine(line) : undefined}
                />
              ))}
            </>
          )}
        </div>

        {selectedLine !== null ? (
          <DiffLineCommentSheet
            file={diffSheet.file}
            line={selectedLine}
            onCancel={() => setSelectedLine(null)}
            onSubmit={(comment) => {
              const line = selectedLine;
              setSelectedLine(null);
              // iOS `.appendDiffLineReviewComment`
              useDraftStore
                .getState()
                .appendBlock(formatDiffLineReviewPrompt(reviewCommentForLine(line, diffSheet.file, comment)));
              onJumpToTerminal();
              useDraftStore.getState().requestFocus();
            }}
          />
        ) : null}
      </div>
    </div>
  );
}

function DiffLineRow({
  line,
  onComment,
}: {
  line: ParsedDiffLine;
  onComment?: () => void;
}) {
  const className = `diff-row diff-row-${line.kind}${line.kind === "hunk" ? " diff-row-tall" : ""}`;
  const content = (
    <>
      <span className="diff-gutter diff-gutter-old">
        {line.oldLineNumber === null ? "" : line.oldLineNumber}
      </span>
      <span className="diff-gutter diff-gutter-new">
        {line.newLineNumber === null ? "" : line.newLineNumber}
      </span>
      <span className="diff-marker">{lineMarker(line)}</span>
      <span className="diff-text">{lineCode(line)}</span>
    </>
  );

  if (onComment === undefined) {
    return <div className={className}>{content}</div>;
  }
  return (
    <button
      type="button"
      className={className + " diff-row-commentable"}
      onClick={onComment}
      aria-label={`Add review comment on line ${
        reviewLineNumber(line) === null ? "unknown" : reviewLineNumber(line)
      }`}
    >
      {content}
    </button>
  );
}

function DiffLineCommentSheet({
  file,
  line,
  onCancel,
  onSubmit,
}: {
  file: string;
  line: ParsedDiffLine;
  onCancel: () => void;
  onSubmit: (comment: string) => void;
}) {
  const [comment, setComment] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    textareaRef.current?.focus();
  }, []);

  const trimmedComment = comment.trim();
  const previewCode = lineCode(line).trim();
  const lineNumber = reviewLineNumber(line);
  const side = reviewSide(line);
  // iOS `DiffLineCommentSheet.lineLabel`
  const lineLabel = lineNumber === null ? side : `${lineNumber} ${side}`;
  const marker = lineMarker(line);

  return (
    <div className="diff-comment-dialog-backdrop" onClick={onCancel}>
      <div
        className="diff-comment-dialog"
        role="dialog"
        aria-label="Review comment"
        onPointerDown={(e) => e.stopPropagation()}
      >
        <div className="diff-comment-header">
          <span className="diff-comment-title">Review Comment</span>
          <button type="button" className="diff-comment-cancel" onClick={onCancel} aria-label="Cancel">
            <X size={15} />
          </button>
        </div>

        <div className="diff-comment-preview">
          <div className="diff-comment-preview-meta">
            <span className="diff-comment-file">
              <MessageSquare size={12} />
              {file}
            </span>
            <span className="diff-comment-lineno">{lineLabel}</span>
          </div>
          <div className={`diff-comment-code diff-comment-code-${line.kind}`}>
            <span className="diff-comment-code-marker">{marker === "" ? " " : marker}</span>
            <span className="diff-comment-code-text">
              {previewCode === "" ? "(blank line)" : previewCode}
            </span>
          </div>
        </div>

        <textarea
          ref={textareaRef}
          className="diff-comment-input"
          placeholder="Comment"
          value={comment}
          onChange={(e) => setComment(e.target.value)}
          aria-label="Comment"
        />

        <button
          type="button"
          className="diff-comment-submit"
          disabled={trimmedComment.length === 0}
          onClick={() => onSubmit(trimmedComment)}
        >
          <MessageSquare size={14} />
          Insert Comment
        </button>
      </div>
    </div>
  );
}
