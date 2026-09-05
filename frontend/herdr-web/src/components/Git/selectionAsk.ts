/**
 * Text-selection → inline AI plumbing for the Git diff inspector.
 *
 * Pierre renders each diff inside an open shadow root, so line discovery
 * walks `container.shadowRoot` when present. Everything downstream of the
 * DOM access is pure and unit-tested.
 */

export interface SelectedDiffLine {
  /** File line number from the diff gutter (new-file for additions, old-file for deletions). */
  lineNumber: number | null;
  lineType: string | null;
}

export interface SelectionAskContext {
  code: string;
  startLine: number | null;
  endLine: number | null;
}

/** The diff container: Pierre's custom element carries an open shadow root. */
export type DiffLineContainer = ParentNode & { shadowRoot?: ShadowRoot | null };

const MAX_PROMPT_CODE_CHARS = 6000;

/** Elements the current selection touches, in document order. */
export function selectedLineElements(container: DiffLineContainer, range: Range): Element[] {
  const root = container.shadowRoot ?? container;
  const candidates = Array.from(root.querySelectorAll("[data-line]"));
  const hits: Element[] = [];
  for (const element of candidates) {
    if (range.intersectsNode(element)) {
      hits.push(element);
    }
  }
  return hits;
}

/**
 * The selected text within one diff line. Pierre renders each line as its
 * own element with no newline between them, so a multi-line selection has
 * to be sliced per line and rejoined — otherwise the lines run together.
 */
export function selectedTextWithinElement(element: Element, range: Range): string {
  try {
    const slice = range.cloneRange();
    slice.selectNodeContents(element);
    if (range.compareBoundaryPoints(Range.START_TO_START, slice) > 0) {
      slice.setStart(range.startContainer, range.startOffset);
    }
    if (range.compareBoundaryPoints(Range.END_TO_END, slice) < 0) {
      slice.setEnd(range.endContainer, range.endOffset);
    }
    return slice.toString();
  } catch {
    return "";
  }
}

function lineNumberFor(element: Element): number | null {
  const raw = element.getAttribute("data-line");
  if (raw === null) return null;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

/** Normalizes one or more DOM text chunks into compact selected code. */
export function normalizeSelectedCode(text: string): string {
  return text.replace(/\r\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}

/** Collects the code + line range the user highlighted inside the diff. */
export function selectionAskContext(
  container: DiffLineContainer,
  selectionText: string,
  range: Range,
): SelectionAskContext {
  const elements = selectedLineElements(container, range);
  const perLine = elements.map((el) => selectedTextWithinElement(el, range)).filter((s) => s.trim().length > 0);
  const lines: SelectedDiffLine[] = elements.map((element) => ({
    lineNumber: lineNumberFor(element),
    lineType: element.getAttribute("data-line-type"),
  }));
  const numbers = lines
    .map((line) => line.lineNumber)
    .filter((value): value is number => value !== null);
  const code = perLine.length > 0 ? normalizeSelectedCode(perLine.join("\n")) : normalizeSelectedCode(selectionText);
  return {
    code,
    startLine: numbers.length > 0 ? Math.min(...numbers) : null,
    endLine: numbers.length > 0 ? Math.max(...numbers) : null,
  };
}

export function formatLineRange(startLine: number | null, endLine: number | null): string | null {
  if (startLine === null || endLine === null) return null;
  if (startLine === endLine) return `line ${startLine}`;
  return `lines ${startLine}–${endLine}`;
}

export function fenceForFile(file: string): string {
  if (!file.includes(".")) return "";
  const extension = file.split(".").pop() ?? "";
  const language = extension.toLowerCase().replace(/[^a-z0-9+_-]/g, "");
  return language.length > 0 && language.length <= 12 ? language : "";
}

export function truncateCodeForPrompt(code: string): string {
  if (code.length <= MAX_PROMPT_CODE_CHARS) return code;
  return `${code.slice(0, MAX_PROMPT_CODE_CHARS)}\n… (selection truncated)`;
}

export interface BuildAskPromptInput {
  file: string;
  startLine: number | null;
  endLine: number | null;
  code: string;
  question: string;
}

/**
 * Builds the full prompt sent to a pane-scoped "ask" agent run. The run's
 * working directory is the pane's directory, so the agent can open the file
 * itself for wider context; the excerpt keeps the question grounded in
 * exactly what the user highlighted.
 */
export function buildAskPrompt(input: BuildAskPromptInput): string {
  const range = formatLineRange(input.startLine, input.endLine);
  const location = range !== null ? ` (${range})` : "";
  const code = truncateCodeForPrompt(normalizeSelectedCode(input.code));
  return [
    `The user highlighted part of a Git diff in Herdr and is asking about it.`,
    ``,
    `File: ${input.file}${location}`,
    `Working directory: the pane's repository (you are already running in it).`,
    ``,
    `Highlighted code:`,
    "```" + fenceForFile(input.file),
    code,
    "```",
    ``,
    `Question: ${input.question.trim()}`,
    ``,
    `Answer the question about the highlighted code. You may read surrounding`,
    `code in the repository when it helps, but do not modify anything.`,
  ].join("\n");
}

export interface AnchorPosition {
  left: number;
  top: number;
}

/** Clamps a fixed-position panel so it stays inside the viewport. */
export function clampAnchor(
  x: number,
  y: number,
  width: number,
  height: number,
  viewportWidth: number,
  viewportHeight: number,
  margin = 10,
): AnchorPosition {
  const left = Math.min(Math.max(x, margin), Math.max(margin, viewportWidth - width - margin));
  const top = Math.min(Math.max(y, margin), Math.max(margin, viewportHeight - height - margin));
  return { left, top };
}

/** One-line preview of the highlighted code for the panel's context strip. */
export function summarizeCode(code: string, maxChars = 96): string {
  const single = normalizeSelectedCode(code).split("\n")[0] ?? "";
  if (single.length <= maxChars) return single;
  return `${single.slice(0, maxChars - 1)}…`;
}
