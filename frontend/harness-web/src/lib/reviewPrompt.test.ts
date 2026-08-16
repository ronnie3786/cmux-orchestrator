import { describe, expect, it } from "vitest";
import type { GitHubPRCommentsResponse, GitHubPRThread } from "../api/types";
import {
  appendPromptBlock,
  formatDiffLineReviewPrompt,
  formatPRCommentThreadPrompt,
  prThreadLineLabel,
} from "./reviewPrompt";

/**
 * Exact-text-critical: the expected strings below are the authoritative
 * outputs from the iOS app's Swift Testing suite
 * (`cmux_harness_iosTests/Feature/cmux_harness_iosTests.swift`,
 * `appendingDiffLineReviewCommentInsertsPromptAndClosesDiff` and
 * `prCommentsSegmentLoadsThreadsAndAppendsPromptReference`), using the same
 * `Self.prThread()` / `Self.prCommentsResponse(thread:)` fixtures ported 1:1.
 * Any change to these strings breaks the web/iOS prompt parity contract.
 */

/** 1:1 port of the iOS test fixture `Self.prThread()`. */
function prThread(overrides: Partial<GitHubPRThread> = {}): GitHubPRThread {
  return {
    id: "thread-1",
    path: "Sources/App.swift",
    line: 18,
    originalLine: 18,
    startLine: null,
    originalStartLine: null,
    diffSide: "RIGHT",
    startDiffSide: "",
    subjectType: "LINE",
    isResolved: false,
    isOutdated: false,
    url: "https://github.com/example-org/cmux-harness/pull/42#discussion_r18",
    codeContext: {
      path: "Sources/App.swift",
      source: "workspace",
      startLine: 18,
      endLine: 18,
      lines: [
        { number: 17, text: "let oldValue = value", isTarget: false },
        { number: 18, text: "let value = helper()", isTarget: true },
        { number: 19, text: "return value", isTarget: false },
      ],
    },
    comments: [
      {
        id: "comment-1",
        author: "reviewer",
        body: "Use the new helper.",
        bodyText: "Use the new helper.",
        createdAt: "2026-04-29T12:00:00Z",
        updatedAt: "2026-04-29T12:00:00Z",
        url: "https://github.com/example-org/cmux-harness/pull/42#discussion_r18",
        diffHunk: "@@ -1 +1 @@",
        path: "Sources/App.swift",
        line: 18,
        originalLine: 18,
      },
    ],
    ...overrides,
  };
}

/** 1:1 port of the iOS test fixture `Self.prCommentsResponse(thread:)`. */
function prCommentsResponse(thread: GitHubPRThread): GitHubPRCommentsResponse {
  return {
    ok: true,
    cwd: "/Users/ronnie/Code/cmux",
    repository: {
      owner: "example-org",
      name: "cmux-harness",
      url: "https://github.com/example-org/cmux-harness",
    },
    pullRequest: {
      number: 42,
      title: "Ship comments",
      url: "https://github.com/example-org/cmux-harness/pull/42",
      headRefName: "feature/pr-comments",
      baseRefName: "main",
      state: "OPEN",
      author: "reviewer",
    },
    includeResolved: false,
    threads: [thread],
    files: [{ path: "Sources/App.swift", threadCount: 1, threads: [thread] }],
    totalThreadCount: 1,
    returnedThreadCount: 1,
    resolvedThreadCount: 0,
    hiddenResolvedCount: 0,
    error: null,
  };
}

const expectedPRPrompt = `Please address this GitHub PR review thread:

PR: #42 Ship comments
PR URL: https://github.com/example-org/cmux-harness/pull/42
File: Sources/App.swift
Line: Line 18
Thread URL: https://github.com/example-org/cmux-harness/pull/42#discussion_r18

Referenced code:
\`\`\`
  17: let oldValue = value
> 18: let value = helper()
  19: return value
\`\`\`

Comment by reviewer:
Use the new helper.`;

describe("formatPRCommentThreadPrompt (iOS GitHubPRThread.promptReference parity)", () => {
  it("produces the exact iOS unit-test string for the standard thread", () => {
    const thread = prThread();
    expect(formatPRCommentThreadPrompt(thread, prCommentsResponse(thread))).toBe(expectedPRPrompt);
  });

  it("omits the PR URL line when the PR has no URL", () => {
    const thread = prThread();
    const response = prCommentsResponse(thread);
    response.pullRequest = { ...response.pullRequest!, url: "" };
    const prompt = formatPRCommentThreadPrompt(thread, response);
    expect(prompt).not.toContain("PR URL:");
    expect(prompt).toContain("PR: #42 Ship comments");
  });

  it("renders an empty PR line when no PR is present (404 envelope)", () => {
    const thread = prThread();
    const noPR: GitHubPRCommentsResponse = {
      ...prCommentsResponse(thread),
      ok: false,
      pullRequest: null,
      error: "No GitHub pull request found for the current branch",
    };
    const prompt = formatPRCommentThreadPrompt(thread, noPR);
    expect(prompt.startsWith("Please address this GitHub PR review thread:\n\nPR:\nFile: ")).toBe(
      true,
    );
  });

  it("omits the Thread URL line when the thread has no URL", () => {
    const thread = prThread({ url: "" });
    const prompt = formatPRCommentThreadPrompt(thread, prCommentsResponse(thread));
    expect(prompt).not.toContain("Thread URL:");
  });

  it("omits the Referenced code block when the code context is empty", () => {
    const thread = prThread({
      codeContext: { path: "Sources/App.swift", source: "workspace", startLine: 18, endLine: 18, lines: [] },
    });
    const prompt = formatPRCommentThreadPrompt(thread, prCommentsResponse(thread));
    expect(prompt).not.toContain("Referenced code:");
  });

  it("labels replies and empty authors like iOS", () => {
    const thread = prThread({
      comments: [
        { id: "c1", author: "", body: "First.", bodyText: "First.", createdAt: "", updatedAt: "", url: "", diffHunk: "", path: "", line: null, originalLine: null },
        { id: "c2", author: "second", body: "Second.", bodyText: "Second.", createdAt: "", updatedAt: "", url: "", diffHunk: "", path: "", line: null, originalLine: null },
      ],
    });
    const prompt = formatPRCommentThreadPrompt(thread, prCommentsResponse(thread));
    expect(prompt).toContain("Comment by unknown:\nFirst.\n\nReply by second:\nSecond.");
  });
});

describe("prThreadLineLabel (iOS GitHubPRThread.lineLabel parity)", () => {
  it("uses Line n for a single line", () => {
    expect(prThreadLineLabel(prThread())).toBe("Line 18");
  });

  it("falls back to originalLine", () => {
    expect(prThreadLineLabel(prThread({ line: null, originalLine: 7 }))).toBe("Line 7");
  });

  it("uses Lines a-b when start differs from end", () => {
    expect(prThreadLineLabel(prThread({ startLine: 5, line: 9 }))).toBe("Lines 5-9");
    expect(prThreadLineLabel(prThread({ line: null, originalLine: 9, originalStartLine: 5 }))).toBe(
      "Lines 5-9",
    );
  });

  it("uses Line end when start equals end", () => {
    expect(prThreadLineLabel(prThread({ startLine: 9, line: 9 }))).toBe("Line 9");
  });

  it("falls back to File when no lines are present", () => {
    expect(prThreadLineLabel(prThread({ line: null, originalLine: null }))).toBe("File");
  });
});

describe("formatDiffLineReviewPrompt (iOS formatDiffLineReviewPrompt parity)", () => {
  it("produces the exact iOS unit-test string", () => {
    const prompt = formatDiffLineReviewPrompt({
      file: "Sources/App.swift",
      lineNumber: 11,
      side: "new",
      code: "let new = value",
      comment: "Use the validated value here.",
    });
    expect(prompt).toBe(
      "Please address this review comment:\n\nFile: Sources/App.swift\nLine: 11 (new)\nCode: let new = value\nComment: Use the validated value here.",
    );
  });

  it("renders only the side when there is no line number", () => {
    const prompt = formatDiffLineReviewPrompt({
      file: "a/b.c",
      lineNumber: null,
      side: "old",
      code: "x",
      comment: "c",
    });
    expect(prompt).toBe("Please address this review comment:\n\nFile: a/b.c\nLine: old\nCode: x\nComment: c");
  });

  it("renders (blank line) for empty code and trims the comment", () => {
    const prompt = formatDiffLineReviewPrompt({
      file: "a/b.c",
      lineNumber: 3,
      side: "context",
      code: "",
      comment: "  spaced comment  ",
    });
    expect(prompt).toBe(
      "Please address this review comment:\n\nFile: a/b.c\nLine: 3 (context)\nCode: (blank line)\nComment: spaced comment",
    );
  });
});

describe("appendPromptBlock (iOS appendPromptBlock parity)", () => {
  it("appends to an existing draft (diff-line case from the iOS suite)", () => {
    const block = formatDiffLineReviewPrompt({
      file: "Sources/App.swift",
      lineNumber: 11,
      side: "new",
      code: "let new = value",
      comment: "Use the validated value here.",
    });
    expect(appendPromptBlock(block, "Existing note.")).toBe(
      `Existing note.

Please address this review comment:

File: Sources/App.swift
Line: 11 (new)
Code: let new = value
Comment: Use the validated value here.`,
    );
  });

  it("appends to an existing draft (PR-thread case from the iOS suite)", () => {
    const thread = prThread();
    const block = formatPRCommentThreadPrompt(thread, prCommentsResponse(thread));
    expect(appendPromptBlock(block, "Also add coverage.")).toBe(
      `Also add coverage.

${expectedPRPrompt}`,
    );
  });

  it("returns the trimmed block for an empty or whitespace draft", () => {
    const block = "  block text\n";
    expect(appendPromptBlock(block, "")).toBe("block text");
    expect(appendPromptBlock(block, "   \n  ")).toBe("block text");
  });
});
