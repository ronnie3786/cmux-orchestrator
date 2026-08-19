/**
 * Unified diff parsing + diff-line review plumbing.
 *
 * Exact port of the web-free logic in the iOS app's
 * `cmux-harness-ios/Feature/Views/Git/DiffViews.swift` (`parseUnifiedDiffLines`,
 * `parseHunkStart`, `parseHunkLineStart`, `ParsedDiffLine.code`) and
 * `cmux-harness-ios/Feature/Reducers/HarnessFeatureGitReducer.swift`
 * (`reviewLineNumber`/`reviewSide`, `DiffLineReviewComment`).
 *
 * `parseUnifiedDiffLines` does NOT handle multi-section git output (the same
 * file can appear in both staged + unstaged sections); it is fed the
 * single-section diff returned by `POST /api/git-diff` — same as the iOS
 * app, which passes `diffBody` (the first non-empty section) to the sheet.
 */

export type DiffLineKind = "metadata" | "hunk" | "context" | "addition" | "deletion";

/** Which side of the diff a review line belongs to (iOS `reviewSide`). */
export type DiffLineCommentSide = "old" | "new" | "context";

/** One parsed unified-diff line (iOS `ParsedDiffLine`). */
export interface ParsedDiffLine {
  /** Stable identity for React keys: original offset in the raw diff. */
  id: number;
  raw: string;
  kind: DiffLineKind;
  /** 1-based old-file line number (deletions/context), else null. */
  oldLineNumber: number | null;
  /** 1-based new-file line number (additions/context), else null. */
  newLineNumber: number | null;
}

/** Payload appended to the detail draft (iOS `DiffLineReviewComment`). */
export interface DiffLineReviewComment {
  file: string;
  /** Old line number for deletions, new line number for additions/context. */
  lineNumber: number | null;
  side: DiffLineCommentSide;
  /** Line content without the diff marker; empty string for blank lines. */
  code: string;
  /** Free-form instruction typed by the user. */
  comment: string;
}

/** Context/addition/deletion lines can receive review comments (iOS `isCommentable`). */
export function isCommentable(line: ParsedDiffLine): boolean {
  return line.kind === "addition" || line.kind === "deletion" || line.kind === "context";
}

/** The rendered marker character for the line's gutter (iOS `marker`). */
export function lineMarker(line: ParsedDiffLine): string {
  switch (line.kind) {
    case "addition":
      return "+";
    case "deletion":
      return "-";
    case "context":
      return " ";
    default:
      return "";
  }
}

/** Line content without the diff marker; unparseable lines keep their raw text (iOS `code`). */
export function lineCode(line: ParsedDiffLine): string {
  if (!isCommentable(line) || line.raw === "") {
    return line.raw;
  }
  return line.raw.slice(1);
}

/** Review line number: old number for deletions, new number for additions/context (iOS `reviewLineNumber`). */
export function reviewLineNumber(line: ParsedDiffLine): number | null {
  switch (line.kind) {
    case "deletion":
      return line.oldLineNumber;
    case "addition":
    case "context":
      return line.newLineNumber ?? line.oldLineNumber;
    default:
      return null;
  }
}

/** Review side: old for deletions, new for additions, context otherwise (iOS `reviewSide`). */
export function reviewSide(line: ParsedDiffLine): DiffLineCommentSide {
  switch (line.kind) {
    case "deletion":
      return "old";
    case "addition":
      return "new";
    default:
      return "context";
  }
}

/** Builds the review-comment payload for a clickable diff line (iOS `.appendDiffLineReviewComment` logic). */
export function reviewCommentForLine(
  line: ParsedDiffLine,
  file: string,
  comment: string,
): DiffLineReviewComment {
  return {
    file,
    lineNumber: reviewLineNumber(line),
    side: reviewSide(line),
    code: lineCode(line),
    comment,
  };
}

/** Exact port of `parseHunkLineStart` (DiffViews.swift). */
function parseHunkLineStart(part: string): number | null {
  const value = part.slice(1);
  const lineStart = value.split(",")[0] ?? value;
  if (!/^[+-]?\d+$/.test(lineStart)) {
    return null;
  }
  return Number(lineStart);
}

/** Exact port of `parseHunkStart` (DiffViews.swift). */
function parseHunkStart(line: string): { old: number; new: number } | null {
  if (!line.startsWith("@@")) {
    return null;
  }
  const parts = line.split(" ").filter((part) => part.length > 0);
  const oldPart = parts.find((part) => part.startsWith("-"));
  const newPart = parts.find((part) => part.startsWith("+"));
  if (oldPart === undefined || newPart === undefined) {
    return null;
  }
  const oldStart = parseHunkLineStart(oldPart);
  const newStart = parseHunkLineStart(newPart);
  if (oldStart === null || newStart === null) {
    return null;
  }
  return { old: oldStart, new: newStart };
}

/**
 * Parses a single-section unified diff into per-line records (iOS
 * `parseUnifiedDiffLines`). `id` is the line's offset so it is stable across
 * repeated polls.
 */
export function parseUnifiedDiffLines(diff: string): ParsedDiffLine[] {
  let oldLineNumber: number | null = null;
  let newLineNumber: number | null = null;

  return diff.split("\n").map((raw, offset) => {
    const hunkStart = parseHunkStart(raw);
    if (hunkStart !== null) {
      oldLineNumber = hunkStart.old;
      newLineNumber = hunkStart.new;
      return { id: offset, raw, kind: "hunk" as const, oldLineNumber: null, newLineNumber: null };
    }

    if (raw.startsWith("+") && !raw.startsWith("+++")) {
      const line: ParsedDiffLine = {
        id: offset,
        raw,
        kind: "addition",
        oldLineNumber: null,
        newLineNumber,
      };
      if (newLineNumber !== null) {
        newLineNumber += 1;
      }
      return line;
    }

    if (raw.startsWith("-") && !raw.startsWith("---")) {
      const line: ParsedDiffLine = {
        id: offset,
        raw,
        kind: "deletion",
        oldLineNumber,
        newLineNumber: null,
      };
      if (oldLineNumber !== null) {
        oldLineNumber += 1;
      }
      return line;
    }

    if (raw.startsWith(" ")) {
      const line: ParsedDiffLine = {
        id: offset,
        raw,
        kind: "context",
        oldLineNumber,
        newLineNumber,
      };
      if (oldLineNumber !== null) {
        oldLineNumber += 1;
      }
      if (newLineNumber !== null) {
        newLineNumber += 1;
      }
      return line;
    }

    return { id: offset, raw, kind: "metadata" as const, oldLineNumber: null, newLineNumber: null };
  });
}
