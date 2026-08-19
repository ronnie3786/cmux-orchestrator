/**
 * Detector tests — line-by-line port of the OpenCode detector cases in
 * cmux-harness-iosTests/Feature/cmux_harness_iosTests.swift
 * (OpenCodeTerminalInteractionDetectorTests + localDemoFallbackScreenDetects).
 *
 * Plus negative fixtures from real terminal screens captured live from the
 * cmux harness server (detector-fixtures.ts).
 */

import { describe, expect, it } from "vitest";

import { detect, interactionPromptID } from "./detector";
import { realScreenTail0, realScreenTail3 } from "./detector-fixtures";

// --- fixtures (verbatim from the Swift tests / local demo) --------------------

const permissionPromptScreen = `│  △ Permission required
│  ← Access external directory /tmp
│
│  Patterns
│
│  - /tmp/*
│
│     Allow once    Allow always    Reject
ctrl+f fullscreen   ⇆ select   enter
confirm
│
• OpenCode 1.18.3
`;

const questionPromptScreen = `│  Select
│
│  1. First option
│     First option description
│  2. Second option
│     Second option description
│  3. Type your own answer
│  4. Submit
│  5. Dismiss
│
│     ⇆ tab   ↑↓ select   enter confirm   esc dismiss
│
• OpenCode 1.18.3
`;

const questionReviewScreen = `│  Review
│  Build method: Build from current branch
│  Export method: Publish via tailnet
│
│     ⇆ tab   ↑↓ edit   enter submit   esc dismiss
│
• OpenCode 1.18.3
`;

const questionWithShellRightPromptScreen = `│  Select
│
│  1. First option   ronnierocha@mbp
│  2. Second option   ~/dev
│
│     ⇆ tab   ↑↓ select   enter confirm   esc dismiss
│
• OpenCode 1.18.3
`;

const permissionTranscriptScreen = `The tool asked:

│  △ Permission required
│  ← Access external directory /tmp
│     Allow once    Allow always    Reject

I chose to reject it and then continued editing.

• OpenCode 1.18.3
`;

const promptLeftFrameScreen = `│  △ Permission required
│     Allow once    Allow always    Reject
ctrl+f fullscreen   ⇆ select   enter
confirm
• OpenCode 1.18.3

✓ Done in 0.8s
$ pwd
/tmp

• OpenCode 1.18.3
`;

const adjacentPermissionProseScreen = `I ran git status and saw:
permission required to update the index.
Use select, enter, and confirm when ready.
The output was clean.

• OpenCode 1.18.3
`;

const adjacentQuestionProseScreen = `I asked the user to select an option and press enter to dismiss the panel.
The transcript shows the answer was recorded.

• OpenCode 1.18.3
`;

const permissionConfirmedScreen = `│  △ Permission required
│     Allow once    Allow always    Reject
ctrl+f fullscreen   ⇆ select   enter
confirm
• OpenCode 1.18.3

✓ Done in 0.8s
$ pwd
/tmp

• OpenCode 1.18.3
`;

const questionDismissedScreen = `│  Select
│  1. First option
│  2. Second option
│     ⇆ tab   ↑↓ select   enter confirm   esc dismiss
• OpenCode 1.18.3

✓ Done in 0.8s
$ pwd
/tmp

• OpenCode 1.18.3
`;

const previousPermissionFooterScreen = `│  △ Permission required
│     Allow once    Allow always    Reject
ctrl+f fullscreen   ⇆ select   enter
confirm
• OpenCode 1.18.3

Now the model said:
permission required for network access
Allow once    Allow always    Reject
select   enter   confirm

• OpenCode 1.18.3
`;

const previousQuestionFooterScreen = `│  Select
│  1. First option
│  2. Second option
│     ⇆ tab   ↑↓ select   enter confirm   esc dismiss
• OpenCode 1.18.3

The model then wrote:
Select the deployment option
1. First option
2. Second option
select   enter   dismiss

• OpenCode 1.18.3
`;

const opencodeVersionProseScreen = `OpenCode 1.18.3 introduced a new prompt layout.
permission required
Allow once    Allow always    Reject
select   enter   confirm

• OpenCode 1.18.3
`;

/**
 * A complete permission frame whose anchor line is NOT the last meaningful
 * line: transcript output followed it. The active-anchor rule (last
 * meaningful line must be the anchor) must reject this — a stale prompt.
 */
const stalePermissionAnchorScreen = `│  △ Permission required
│     Allow once    Allow always    Reject
ctrl+f fullscreen   ⇆ select   enter   confirm
• OpenCode 1.18.3
✓ Done in 0.8s
`;

/** HarnessClient.seedScreen(for: 2) — the local demo fallback screen. */
const localDemoScreen2 = `│  △ Permission required
│  ← Access external directory /tmp
│
│  Patterns
│
│  - /tmp/*
│
│     Allow once    Allow always    Reject
ctrl+f fullscreen   ⇆ select   enter
confirm
│
• OpenCode 1.18.3
`;

describe("OpenCodeTerminalInteractionDetector (web port)", () => {
  it("detectsScreenshotStyleOpenCodePermissionPrompt", () => {
    const interaction = detect(permissionPromptScreen);
    expect(interaction).not.toBeNull();
    expect(interaction!.kind).toBe("permission");
    expect(interaction!.title).toBe("Permission required");
    expect(interaction!.detail).toBe("Access external directory /tmp\n- /tmp/*");
    expect(interaction!.options).toEqual(["Allow once", "Allow always", "Reject"]);
    expect(interaction!.navigationAxis).toBe("horizontal");
    expect(interaction!.reviewItems).toEqual([]);
    expect(interactionPromptID(interaction!)).toContain("permission");
  });

  it("detectsOpenCodeQuestionPromptOptions", () => {
    const interaction = detect(questionPromptScreen);
    expect(interaction).not.toBeNull();
    expect(interaction!.kind).toBe("question");
    expect(interaction!.title).toBe("OpenCode question");
    expect(interaction!.detail).toBe("OpenCode needs your answer");
    expect(interaction!.options).toEqual([
      "First option",
      "Second option",
      "Type your own answer",
      "Submit",
      "Dismiss",
    ]);
    expect(interaction!.navigationAxis).toBe("vertical");
    expect(interaction!.reviewItems).toEqual([]);
    expect(interactionPromptID(interaction!)).toContain("question");
  });

  it("detectsOpenCodeQuestionReviewPromptAndAnswers", () => {
    const interaction = detect(questionReviewScreen);
    expect(interaction).not.toBeNull();
    expect(interaction!.kind).toBe("questionReview");
    expect(interaction!.title).toBe("Review answers");
    expect(interaction!.detail).toBe("Confirm these choices before OpenCode continues.");
    expect(interaction!.options).toEqual([]);
    expect(interaction!.navigationAxis).toBe("horizontal");
    expect(interaction!.reviewItems).toEqual([
      { label: "Build method", value: "Build from current branch" },
      { label: "Export method", value: "Publish via tailnet" },
    ]);
    expect(interactionPromptID(interaction!)).toContain("questionReview");
  });

  it("stripsShellRightPromptColumnsFromOpenCodeQuestionOptions", () => {
    const interaction = detect(questionWithShellRightPromptScreen);
    expect(interaction).not.toBeNull();
    expect(interaction!.kind).toBe("question");
    expect(interaction!.options).toEqual(["First option", "Second option"]);
  });

  it("doesNotTreatTranscriptPermissionWordsAsAnActivePrompt", () => {
    expect(detect(permissionTranscriptScreen)).toBeNull();
  });

  it("doesNotKeepTerminalActionsAfterPromptLeavesCurrentFrame", () => {
    expect(detect(promptLeftFrameScreen)).toBeNull();
  });

  it("doesNotMistakeAdjacentPermissionProseForAnOpenCodeFooter", () => {
    expect(detect(adjacentPermissionProseScreen)).toBeNull();
  });

  it("doesNotMistakeAdjacentQuestionProseForAnOpenCodeFooter", () => {
    expect(detect(adjacentQuestionProseScreen)).toBeNull();
  });

  it("doesNotKeepPermissionActionsAfterConfirmationOutput", () => {
    expect(detect(permissionConfirmedScreen)).toBeNull();
  });

  it("doesNotKeepQuestionActionsAfterDismissalOutput", () => {
    expect(detect(questionDismissedScreen)).toBeNull();
  });

  it("doesNotJoinPermissionProseToAPreviousFooter", () => {
    expect(detect(previousPermissionFooterScreen)).toBeNull();
  });

  it("doesNotJoinQuestionProseToAPreviousFooter", () => {
    expect(detect(previousQuestionFooterScreen)).toBeNull();
  });

  it("doesNotTreatOpenCodeVersionProseAsAStatusAnchor", () => {
    expect(detect(opencodeVersionProseScreen)).toBeNull();
  });

  it("doesNotTreatAStaleAnchorAsCurrentWhenTranscriptFollowsIt", () => {
    expect(detect(stalePermissionAnchorScreen)).toBeNull();
  });

  it("localDemoFallbackScreenDetectsPermission (HarnessClient seedScreen index 2)", () => {
    const interaction = detect(localDemoScreen2);
    expect(interaction).not.toBeNull();
    expect(interaction!.kind).toBe("permission");
  });
});

describe("OpenCodeTerminalInteractionDetector (real server screens)", () => {
  it("returns null for a real pi/claude terminal screen (sidebar + transcript)", () => {
    expect(detect(realScreenTail0)).toBeNull();
  });

  it("returns null for a real pi terminal at a shell prompt (markdown tables in history)", () => {
    expect(detect(realScreenTail3)).toBeNull();
  });

  it("strips ANSI styling before detecting (styled permission prompt)", () => {
    const styled = permissionPromptScreen
      .replace("Allow once", "\x1b[32;1mAllow once\x1b[0m")
      .replace("• OpenCode 1.18.3", "\x1b[90m• OpenCode 1.18.3\x1b[0m");
    const interaction = detect(styled);
    expect(interaction).not.toBeNull();
    expect(interaction!.kind).toBe("permission");
    expect(interaction!.detail).toBe("Access external directory /tmp\n- /tmp/*");
  });
});
