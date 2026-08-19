/**
 * Formatted prompt blocks for the detail input row.
 *
 * EXACT TEXT PARITY (exact-text-critical): the strings produced here are sent
 * to coding agents verbatim, so they must match the iOS app's
 * `HarnessFeatureHelpers.formatDiffLineReviewPrompt` /
 * `formatPRCommentThreadPrompt` and `GitHubPRThread.promptReference` byte-for-byte
 * (see the iOS unit tests `appends the formatted PR review thread to the
 * existing detail draft` and `appends the formatted diff-line review comment
 * to the existing detail draft` for the authoritative expected strings).
 */
import type { GitHubPRCommentsResponse, GitHubPRThread } from "../api/types";
import type { DiffLineReviewComment } from "./unifiedDiff";

/**
 * Appends a formatted block to a draft (iOS `appendPromptBlock`).
 * Both sides are trimmed; an empty draft yields just the trimmed block.
 */
export function appendPromptBlock(block: string, draft: string): string {
  const trimmedBlock = block.trim();
  const trimmedDraft = draft.trim();
  if (trimmedDraft === "") {
    return trimmedBlock;
  }
  return `${trimmedDraft}\n\n${trimmedBlock}`;
}

/**
 * Exact port of `appendPromptToken(_ token: String, to draft: String)`
 * (HarnessFeatureHelpers.swift). Used by the file-search, skill, and Jira
 * inserts — the token (e.g. `` `path` ``, `/name`, `$name`) is appended
 * space-separated. Unlike `appendPromptBlock`, neither side is trimmed:
 * an empty draft yields the token as-is; a non-empty draft ending in
 * whitespace gets the token directly; otherwise a single space is inserted.
 */
export function appendPromptToken(token: string, draft: string): string {
  if (draft === "") {
    return token;
  }
  const last = draft.charAt(draft.length - 1);
  if (/\s/.test(last)) {
    return draft + token;
  }
  return draft + " " + token;
}

/** iOS `DiffLineCommentSide.promptLabel` — the raw values are the labels. */
function sidePromptLabel(side: DiffLineReviewComment["side"]): string {
  return side;
}

/**
 * Exact port of `formatDiffLineReviewPrompt` (HarnessFeatureHelpers.swift).
 * No trailing newline.
 */
export function formatDiffLineReviewPrompt(reviewComment: DiffLineReviewComment): string {
  const comment = reviewComment.comment.trim();
  const code = reviewComment.code === "" ? "(blank line)" : reviewComment.code;
  const line =
    reviewComment.lineNumber !== null && reviewComment.lineNumber !== undefined
      ? `${reviewComment.lineNumber} (${sidePromptLabel(reviewComment.side)})`
      : sidePromptLabel(reviewComment.side);

  return [
    "Please address this review comment:",
    "",
    `File: ${reviewComment.file}`,
    `Line: ${line}`,
    `Code: ${code}`,
    `Comment: ${comment}`,
  ].join("\n");
}

/** Exact port of `GitHubPRThread.lineLabel` (GitHubPRModels.swift). */
export function prThreadLineLabel(thread: GitHubPRThread): string {
  const start = thread.startLine ?? thread.originalStartLine;
  const end = thread.line ?? thread.originalLine;
  if (start !== null && start !== undefined && end !== null && end !== undefined && start !== end) {
    return `Lines ${start}-${end}`;
  }
  if (end !== null && end !== undefined) {
    return `Line ${end}`;
  }
  return "File";
}

/**
 * Exact port of `GitHubPRThread.promptReference(pullRequest:)`
 * (GitHubPRModels.swift), wrapped like `formatPRCommentThreadPrompt`
 * (HarnessFeatureHelpers.swift). Lines are joined with "\n"; no trailing
 * newline.
 */
export function formatPRCommentThreadPrompt(
  thread: GitHubPRThread,
  response: GitHubPRCommentsResponse | null | undefined,
): string {
  const pullRequest = response?.pullRequest ?? null;
  const lines: string[] = [
    "Please address this GitHub PR review thread:",
    "",
    `PR: ${pullRequest ? `#${pullRequest.number} ${pullRequest.title}` : ""}`.trim(),
  ];
  if (pullRequest && pullRequest.url !== "") {
    lines.push(`PR URL: ${pullRequest.url}`);
  }
  lines.push(`File: ${thread.path}`);
  lines.push(`Line: ${prThreadLineLabel(thread)}`);
  if (thread.url !== "") {
    lines.push(`Thread URL: ${thread.url}`);
  }
  const codeContext = thread.codeContext;
  if (codeContext && codeContext.lines.length > 0) {
    lines.push("");
    lines.push("Referenced code:");
    lines.push("```");
    for (const codeLine of codeContext.lines) {
      const marker = codeLine.isTarget ? ">" : " ";
      lines.push(`${marker} ${codeLine.number}: ${codeLine.text}`);
    }
    lines.push("```");
  }
  thread.comments.forEach((comment, index) => {
    lines.push("");
    const who = comment.author === "" ? "unknown" : comment.author;
    lines.push(`${index === 0 ? "Comment" : "Reply"} by ${who}:`);
    lines.push(comment.body);
  });
  return lines.join("\n");
}
