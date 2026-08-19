/**
 * OpenCode terminal interaction detector (fallback path).
 *
 * Line-by-line port of
 * cmux-harness-ios/Views/Shared/OpenCodeTerminalInteractionDetector.swift.
 *
 * Detects an *active* OpenCode prompt (permission / question / questionReview)
 * in a raw terminal screen (ANSI included — stripped via plainText, same as
 * the iOS TerminalTextStyler). Detection is anchored to the most recent
 * "OpenCode x.y" status line: the prompt must live in the frame above it and
 * the lines below the action footer must be empty or anchor lines only
 * (current-tail check), which keeps transcript prose from re-triggering cards.
 *
 * The server-side plugin (cmux-feed.js) emits structured feed items for
 * OpenCode 1.5.10+. This detector only runs when no native feed item matches
 * the selected session (older OpenCode versions / plugin not installed).
 */

import { plainText } from "./ansi";

export type OpenCodeTerminalKind = "permission" | "question" | "questionReview";
export type OpenCodeNavigationAxis = "horizontal" | "vertical";

export interface OpenCodeReviewItem {
  label: string;
  value: string;
}

export interface OpenCodeTerminalInteraction {
  kind: OpenCodeTerminalKind;
  title: string;
  detail: string;
  options: string[];
  navigationAxis: OpenCodeNavigationAxis;
  reviewItems: OpenCodeReviewItem[];
}

/** Mirrors OpenCodeTerminalInteraction.promptID (reset key for UI state). */
export function interactionPromptID(interaction: OpenCodeTerminalInteraction): string {
  const reviewItems = interaction.reviewItems.map((item) => `${item.label}=${item.value}`);
  return [interaction.kind, interaction.detail, interaction.options.join(","), reviewItems.join("|")].join(
    "\u{0}",
  );
}

/** Mirrors OpenCodeTerminalInteractionDetector.detect(in:). */
export function detect(rawText: string): OpenCodeTerminalInteraction | null {
  const text = plainText(rawText)
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n");
  const lines = text.split("\n").slice(-48);
  return (
    permissionInteraction(lines) ?? questionReviewInteraction(lines) ?? questionInteraction(lines)
  );
}

// --- Shared helpers (line-by-line port) --------------------------------------

const borderCharacters = new Set(["│", "┃", "|", "△", "←", "›", "❯", "•"]);

/** Mirror of normalized(line): trims leading border glyphs and whitespace. */
function normalized(line: string): string {
  let value = line.trim();
  while (value.length > 0) {
    const first = value[0];
    if (borderCharacters.has(first) || /\s/.test(first)) {
      value = value.slice(1);
    } else {
      break;
    }
  }
  return value.trim();
}

/**
 * Mirror of primaryColumn(in:): the text before the first run of 3+
 * whitespace characters. Terminal right-hand prompt columns (shell path,
 * cwd) are separated by wide gaps, so this drops them.
 */
function primaryColumn(line: string): string {
  const value = normalized(line);
  const match = /\s{3,}/.exec(value);
  if (!match) return value;
  return value.slice(0, match.index).trim();
}

/** Mirror of isOpenCodeAnchor(_:): the "OpenCode x.y[.z]" status line. */
function isOpenCodeAnchor(line: string): boolean {
  return /^opencode\s+\d+\.\d+(?:\.\d+)?$/i.test(normalized(line));
}

/**
 * Mirror of containsControlToken(_:in:): split on non-alphanumerics
 * (Unicode letters/digits, same class as CharacterSet.alphanumerics.inverted)
 * and look for the exact lowercase token among the fragments.
 */
function containsControlToken(token: string, value: string): boolean {
  const fragments = value.split(/[^\p{L}\p{Nd}]/u).map((fragment) => fragment.toLowerCase());
  return fragments.includes(token.toLowerCase());
}

/** Mirror of containsOpenCodeControlHint(_:). */
function containsOpenCodeControlHint(footer: string): boolean {
  return ["⇆", "↑", "↓", "ctrl+", "⌃", "↵", "⏎"].some((hint) => footer.includes(hint));
}

/** Mirror of isCurrentPromptTail(_:): only empty or anchor lines remain. */
function isCurrentPromptTail(lines: string[]): boolean {
  return lines.every((line) => {
    const value = normalized(line);
    return value.length === 0 || isOpenCodeAnchor(line);
  });
}

/**
 * Mirror of activeOpenCodeAnchorIndex(_:).
 *
 * Swift finds the LAST MEANINGFUL line and requires THAT line to be the
 * anchor (the "OpenCode x.y" status line must be the bottom of the frame).
 * An anchor with any non-empty transcript after it is stale -> nil.
 * Do NOT scan back for the last anchor anywhere; that re-triggers old prompts.
 */
function activeOpenCodeAnchorIndex(lines: string[]): number {
  let lastMeaningful = -1;
  for (let index = lines.length - 1; index >= 0; index--) {
    if (normalized(lines[index]).length > 0) {
      lastMeaningful = index;
      break;
    }
  }
  if (lastMeaningful < 0 || !isOpenCodeAnchor(lines[lastMeaningful])) {
    return -1;
  }
  return lastMeaningful;
}

/** Mirror of activePromptWindowStart(_:anchorIndex:): frame after the previous anchor. */
function activePromptWindowStart(lines: string[], anchorIndex: number): number {
  if (anchorIndex <= 0) return 0;
  let previousAnchorIndex = -1;
  for (let index = anchorIndex - 1; index >= 0; index--) {
    if (isOpenCodeAnchor(lines[index])) {
      previousAnchorIndex = index;
      break;
    }
  }
  if (previousAnchorIndex < 0) return 0;
  return previousAnchorIndex + 1;
}

/** Mirror of interactionFooterIndex(_:requiredTokens:): last matching footer line. */
function interactionFooterIndex(lines: string[], requiredTokens: string[]): number {
  for (let index = lines.length - 1; index >= 0; index--) {
    const current = normalized(lines[index]).toLowerCase();
    if (!requiredTokens.some((token) => containsControlToken(token, current))) continue;
    const previous = index > 0 ? normalized(lines[index - 1]).toLowerCase() : "";
    const footer = requiredTokens.includes(current) ? `${previous} ${current}` : current;
    const matchesAll = requiredTokens.every((token) => containsControlToken(token, footer));
    if (matchesAll && containsOpenCodeControlHint(footer)) {
      return index;
    }
  }
  return -1;
}

// --- Kind detection (line-by-line port) ---------------------------------------

/** Mirror of permissionInteraction(in:). */
function permissionInteraction(lines: string[]): OpenCodeTerminalInteraction | null {
  const anchorIndex = activeOpenCodeAnchorIndex(lines);
  if (anchorIndex < 0) return null;

  const windowStart = activePromptWindowStart(lines, anchorIndex);
  const promptWindow = lines.slice(windowStart, anchorIndex);
  let headerIndex = -1;
  for (let index = promptWindow.length - 1; index >= 0; index--) {
    if (normalized(promptWindow[index]).toLowerCase().includes("permission required")) {
      headerIndex = index;
      break;
    }
  }
  if (headerIndex < 0) return null;

  const block = lines.slice(windowStart + headerIndex, anchorIndex);
  const flattened = block
    .map((line) => normalized(line).toLowerCase())
    .join(" ");
  const optionLabels = ["allow once", "allow always", "reject"];
  if (!optionLabels.every((label) => flattened.includes(label))) return null;
  if (!flattened.includes("enter") || !flattened.includes("confirm")) return null;

  const footerIndex = interactionFooterIndex(block, ["select", "enter", "confirm"]);
  if (footerIndex < 0) return null;
  if (!isCurrentPromptTail(block.slice(footerIndex + 1))) return null;

  // prefix { stops at the first line that looks like action/footer text }
  const detailRange: string[] = [];
  for (let offset = 1; offset < block.length; offset++) {
    const value = normalized(block[offset]).toLowerCase();
    if (
      value.includes("allow once") ||
      value.includes("allow always") ||
      value.includes("reject") ||
      value.includes("select") ||
      value.includes("confirm")
    ) {
      break;
    }
    detailRange.push(block[offset]);
  }
  const detailLines = detailRange
    .map(primaryColumn)
    .filter((value) => value.length > 0 && value.toLowerCase() !== "patterns");

  return {
    kind: "permission",
    title: "Permission required",
    detail: detailLines.join("\n"),
    options: ["Allow once", "Allow always", "Reject"],
    navigationAxis: "horizontal",
    reviewItems: [],
  };
}

/** Mirror of reviewItem(from:): "Label: value" rows inside the review list. */
function reviewItem(line: string): OpenCodeReviewItem | null {
  const trimmedLine = line.trim();
  if (trimmedLine.length === 0) return null;
  if (!["│", "┃", "|"].includes(trimmedLine[0])) return null;

  const value = primaryColumn(line);
  const separatorIndex = value.indexOf(":");
  if (separatorIndex <= 0) return null;
  const label = value.slice(0, separatorIndex).trim();
  const answer = value.slice(separatorIndex + 1).trim();
  if (label.length === 0 || answer.length === 0) return null;

  return { label, value: answer };
}

/** Mirror of questionReviewInteraction(in:). */
function questionReviewInteraction(lines: string[]): OpenCodeTerminalInteraction | null {
  const anchorIndex = activeOpenCodeAnchorIndex(lines);
  if (anchorIndex < 0) return null;

  const windowStart = Math.max(activePromptWindowStart(lines, anchorIndex), Math.max(0, anchorIndex - 32));
  const activeLines = lines.slice(windowStart, anchorIndex);
  const flattened = activeLines
    .map((line) => normalized(line).toLowerCase())
    .join(" ");
  if (!flattened.includes("review") || !flattened.includes("submit") || !flattened.includes("dismiss")) {
    return null;
  }

  const footerIndex = interactionFooterIndex(activeLines, ["tab", "enter", "submit", "dismiss"]);
  if (footerIndex < 0) return null;
  if (!isCurrentPromptTail(activeLines.slice(footerIndex + 1))) return null;

  const contentLines = activeLines.slice(0, footerIndex);
  let reviewIndex = -1;
  for (let index = contentLines.length - 1; index >= 0; index--) {
    if (primaryColumn(contentLines[index]).toLowerCase() === "review") {
      reviewIndex = index;
      break;
    }
  }
  if (reviewIndex < 0) return null;

  const reviewItems = contentLines
    .slice(reviewIndex + 1)
    .map(reviewItem)
    .filter((item): item is OpenCodeReviewItem => item !== null);
  if (reviewItems.length === 0) return null;

  return {
    kind: "questionReview",
    title: "Review answers",
    detail: "Confirm these choices before OpenCode continues.",
    options: [],
    navigationAxis: "horizontal",
    reviewItems,
  };
}

/** Mirror of numberedOption(from:): "1. Label" rows (label only). */
function numberedOption(line: string): string | null {
  const value = primaryColumn(line);
  if (value.length === 0) return null;
  if (!/\d/.test(value[0])) return null;
  if (value.toLowerCase().includes("opencode")) return null;

  let digitEnd = 0;
  while (digitEnd < value.length && /\d/.test(value[digitEnd])) {
    digitEnd += 1;
  }
  if (digitEnd === value.length) return null;

  const separator = value[digitEnd];
  if (separator !== "." && separator !== ")") return null;

  const content = value.slice(digitEnd + 1).replace(/^\s+/, "");
  if (content.length === 0) return null;
  return content.trim();
}

/** Mirror of questionInteraction(in:). */
function questionInteraction(lines: string[]): OpenCodeTerminalInteraction | null {
  const anchorIndex = activeOpenCodeAnchorIndex(lines);
  if (anchorIndex < 0) return null;

  const windowStart = Math.max(activePromptWindowStart(lines, anchorIndex), Math.max(0, anchorIndex - 24));
  const activeLines = lines.slice(windowStart, anchorIndex);
  const flattened = activeLines
    .map((line) => normalized(line).toLowerCase())
    .join(" ");
  if (!flattened.includes("select") || !flattened.includes("enter") || !flattened.includes("dismiss")) {
    return null;
  }

  const footerIndex = interactionFooterIndex(activeLines, ["select", "enter", "dismiss"]);
  if (footerIndex < 0) return null;
  if (!isCurrentPromptTail(activeLines.slice(footerIndex + 1))) return null;

  const optionLines = activeLines.slice(0, footerIndex);
  const options = optionLines
    .map(numberedOption)
    .filter((option): option is string => option !== null);
  if (options.length < 2) return null;

  const firstOptionIndexRaw = optionLines.findIndex((line) => numberedOption(line) !== null);
  const firstOptionIndex = firstOptionIndexRaw < 0 ? 0 : firstOptionIndexRaw;

  let question = "";
  for (let index = firstOptionIndex - 1; index >= 0; index--) {
    const value = primaryColumn(optionLines[index]);
    if (
      value.length > 0 &&
      !value.toLowerCase().includes("opencode ") &&
      !value.toLowerCase().includes("select")
    ) {
      question = value;
      break;
    }
  }
  if (question.length === 0) question = "OpenCode needs your answer";

  return {
    kind: "question",
    title: "OpenCode question",
    detail: question,
    options,
    navigationAxis: "vertical",
    reviewItems: [],
  };
}
