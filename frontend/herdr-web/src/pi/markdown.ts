/**
 * 1:1 port of `herdr-harness-ios/Models/PiMarkdownParser.swift` (source of
 * truth). Pure markdown → `PiMarkdownBlock[]`; no dependencies.
 *
 * Swift `Character` (grapheme cluster) semantics are approximated by code
 * units — byte-identical for ASCII, which is what the ported test suite
 * exercises. Whitespace classes mirror Swift: `.whitespaces` = space + tab;
 * `isWhitespace` ≈ JS `\s`.
 */
import type {
  PiMarkdownBlock,
  PiMarkdownColumnAlignment,
  PiMarkdownListItem,
  PiMarkdownListItemMarker,
  PiMarkdownTable,
} from "./types";

export function parsePiMarkdown(source: string): PiMarkdownBlock[] {
  const lines = source.split("\n");
  const blocks: PiMarkdownBlock[] = [];

  const append = (block: () => PiMarkdownBlock): void => {
    blocks.push(block());
  };

  let index = 0;
  while (index < lines.length) {
    if (isBlank(lines[index])) {
      index += 1;
      continue;
    }

    const fence = fenceOpening(lines[index]);
    if (fence !== null) {
      const parsed = parseFence(lines, index, fence);
      append(() => ({ kind: "code", id: blocks.length, language: parsed.language, code: parsed.code }));
      index = parsed.nextIndex;
      continue;
    }

    const heading = atxHeading(lines[index]);
    if (heading !== null) {
      append(() => ({ kind: "heading", id: blocks.length, level: heading.level, text: heading.text }));
      index += 1;
      continue;
    }

    const table = parseTable(lines, index);
    if (table !== null) {
      append(() => ({ kind: "table", id: blocks.length, table: table.table }));
      index = table.nextIndex;
      continue;
    }

    if (
      index + 1 < lines.length &&
      !isBlank(lines[index])
    ) {
      const level = setextHeadingLevel(lines[index + 1]);
      if (level !== null) {
        const text = lines[index].replace(/^[ \t]+|[ \t]+$/g, "");
        append(() => ({ kind: "heading", id: blocks.length, level, text }));
        index += 2;
        continue;
      }
    }

    if (isThematicBreak(lines[index])) {
      append(() => ({ kind: "thematicBreak", id: blocks.length }));
      index += 1;
      continue;
    }

    if (quoteText(lines[index]) !== null) {
      const quoteLines: string[] = [];
      while (index < lines.length) {
        const quote = quoteText(lines[index]);
        if (quote === null) break;
        quoteLines.push(quote);
        index += 1;
      }
      append(() => ({ kind: "quote", id: blocks.length, text: quoteLines.join("\n") }));
      continue;
    }

    if (listItem(lines[index]) !== null) {
      const parsed = parseList(lines, index);
      append(() => ({ kind: "list", id: blocks.length, items: parsed.items }));
      index = parsed.nextIndex;
      continue;
    }

    const paragraphLines: string[] = [];
    while (index < lines.length && !isBlank(lines[index])) {
      if (paragraphLines.length > 0 && startsBlock(lines, index)) break;
      paragraphLines.push(lines[index]);
      index += 1;
    }
    const text = paragraphLines.join("\n").replace(/^[ \t\n\r]+|[ \t\n\r]+$/g, "");
    if (text !== "") {
      append(() => ({ kind: "paragraph", id: blocks.length, text }));
    }
  }

  return blocks;
}

// ---------------------------------------------------------------------------
// Fences
// ---------------------------------------------------------------------------

interface Fence {
  marker: string;
  count: number;
  info: string;
}

function parseFence(
  lines: string[],
  openingIndex: number,
  fence: Fence,
): { language: string | null; code: string; nextIndex: number } {
  const codeLines: string[] = [];
  let index = openingIndex + 1;
  while (index < lines.length) {
    if (isFenceClosing(lines[index], fence)) {
      index += 1;
      break;
    }
    codeLines.push(lines[index]);
    index += 1;
  }
  const info = fence.info.trim();
  const language = info === "" ? null : info.split(/\s+/)[0];
  return { language, code: codeLines.join("\n"), nextIndex: index };
}

function fenceOpening(line: string): Fence | null {
  const content = dropUpToThreeLeadingSpaces(line);
  const marker = content[0];
  if (marker !== "`" && marker !== "~") return null;
  let count = 0;
  while (count < content.length && content[count] === marker) count += 1;
  if (count < 3) return null;
  const info = content.slice(count).replace(/^[ \t]+|[ \t]+$/g, "");
  if (marker === "`" && info.includes("`")) return null;
  return { marker, count, info };
}

function isFenceClosing(line: string, fence: Fence): boolean {
  const content = dropUpToThreeLeadingSpaces(line);
  let count = 0;
  while (count < content.length && content[count] === fence.marker) count += 1;
  if (count < fence.count) return false;
  return charsEvery(content.slice(count), isSpace);
}

// ---------------------------------------------------------------------------
// Headings / thematic breaks / quotes
// ---------------------------------------------------------------------------

function atxHeading(line: string): { level: number; text: string } | null {
  const content = dropUpToThreeLeadingSpaces(line);
  let level = 0;
  while (level < content.length && content[level] === "#") level += 1;
  if (level < 1 || level > 6) return null;
  const remainder = content.slice(level);
  if (remainder.length > 0 && !isSpace(remainder[0])) return null;

  let text = remainder.replace(/^[ \t]+|[ \t]+$/g, "");
  let lastNonHash = -1;
  for (let i = text.length - 1; i >= 0; i -= 1) {
    if (text[i] !== "#") {
      lastNonHash = i;
      break;
    }
  }
  if (lastNonHash >= 0) {
    const trailing = text.slice(lastNonHash + 1);
    if (trailing.length > 0 && isSpace(text[lastNonHash])) {
      text = text.slice(0, lastNonHash).replace(/^[ \t]+|[ \t]+$/g, "");
    }
  } else if (text.length > 0 && charsEvery(text, (c) => c === "#")) {
    text = "";
  }
  return { level, text };
}

function setextHeadingLevel(line: string): number | null {
  const content = line.replace(/^[ \t]+|[ \t]+$/g, "");
  if (content.length < 1) return null;
  if (charsEvery(content, (c) => c === "=")) return 1;
  if (charsEvery(content, (c) => c === "-")) return 2;
  return null;
}

function isThematicBreak(line: string): boolean {
  const content = line.replace(/\s/g, "");
  if (content.length < 3) return false;
  const marker = content[0];
  if (marker !== "*" && marker !== "-" && marker !== "_") return false;
  return charsEvery(content, (c) => c === marker);
}

function quoteText(line: string): string | null {
  const content = dropUpToThreeLeadingSpaces(line);
  if (content[0] !== ">") return null;
  let quote = content.slice(1);
  if (quote[0] === " ") quote = quote.slice(1);
  return quote;
}

// ---------------------------------------------------------------------------
// Lists
// ---------------------------------------------------------------------------

interface ParsedListItem {
  marker: PiMarkdownListItemMarker;
  text: string;
  indentation: number;
}

function listItem(line: string): ParsedListItem | null {
  const indentation = indentationWidth(line);
  let content = line;
  while (content.length > 0 && isSpace(content[0])) content = content.slice(1);
  if (content.length === 0) return null;

  const first = content[0];
  if (first === "-" || first === "+" || first === "*") {
    const remainder = content.slice(1);
    if (remainder.length === 0 || !isSpace(remainder[0])) return null;
    return taskOrListItem(ltrimSpace(remainder), { kind: "bullet" }, indentation);
  }

  let digits = "";
  while (digits.length < content.length && content[digits.length] >= "0" && content[digits.length] <= "9") {
    digits += content[digits.length];
  }
  if (digits.length === 0 || digits.length > 9) return null;
  const suffix = content.slice(digits.length);
  if (suffix.length === 0 || (suffix[0] !== "." && suffix[0] !== ")")) return null;
  const remainder = suffix.slice(1);
  if (remainder.length === 0 || !isSpace(remainder[0])) return null;
  return taskOrListItem(ltrimSpace(remainder), { kind: "number", value: digits }, indentation);
}

function taskOrListItem(
  text: string,
  defaultMarker: PiMarkdownListItemMarker,
  indentation: number,
): ParsedListItem {
  let marker = defaultMarker;
  let itemText = text;
  if (
    text.length >= 3 &&
    text[0] === "[" &&
    text[2] === "]" &&
    (text[1] === " " || text[1] === "x" || text[1] === "X")
  ) {
    marker = { kind: "task", isCompleted: text[1] === "x" || text[1] === "X" };
    itemText = text.slice(3).replace(/^[ \t]+|[ \t]+$/g, "");
  }
  return { marker, text: itemText, indentation };
}

function ltrimSpace(value: string): string {
  let i = 0;
  while (i < value.length && isSpace(value[i])) i += 1;
  return value.slice(i);
}

function parseList(
  lines: string[],
  startIndex: number,
): { items: PiMarkdownListItem[]; nextIndex: number } {
  const items: PiMarkdownListItem[] = [];
  const itemIndentations: number[] = [];
  const indentationLevels: number[] = [];
  let index = startIndex;

  while (index < lines.length) {
    const parsed = listItem(lines[index]);
    if (parsed !== null) {
      while (indentationLevels.length > 0 && indentationLevels[indentationLevels.length - 1] > parsed.indentation) {
        indentationLevels.pop();
      }
      if (indentationLevels[indentationLevels.length - 1] !== parsed.indentation) {
        indentationLevels.push(parsed.indentation);
      }
      const depth = Math.max(0, indentationLevels.length - 1);
      items.push({ marker: parsed.marker, text: parsed.text, depth });
      itemIndentations.push(parsed.indentation);
      index += 1;
      continue;
    }

    const lastIndentation = itemIndentations[itemIndentations.length - 1] ?? 0;
    if (items.length === 0 || isBlank(lines[index]) || indentationWidth(lines[index]) <= lastIndentation) {
      break;
    }
    const continuation = lines[index].replace(/^[ \t]+|[ \t]+$/g, "");
    const previous = items.pop() as PiMarkdownListItem;
    items.push({
      marker: previous.marker,
      text: `${previous.text}\n${continuation}`,
      depth: previous.depth,
    });
    index += 1;
  }

  return { items, nextIndex: index };
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

function parseTable(
  lines: string[],
  headerIndex: number,
): { table: PiMarkdownTable; nextIndex: number } | null {
  if (headerIndex + 1 >= lines.length || !containsUnescapedPipe(lines[headerIndex])) return null;

  const headers = splitTableRow(lines[headerIndex]);
  const delimiters = splitTableRow(lines[headerIndex + 1]);
  if (headers.length === 0 || headers.length !== delimiters.length) return null;

  const alignments: PiMarkdownColumnAlignment[] = [];
  for (const delimiter of delimiters) {
    const alignment = tableAlignment(delimiter);
    if (alignment === null) return null;
    alignments.push(alignment);
  }

  const rows: string[][] = [];
  let index = headerIndex + 2;
  while (index < lines.length && !isBlank(lines[index]) && containsUnescapedPipe(lines[index])) {
    let cells = splitTableRow(lines[index]);
    if (cells.length < headers.length) {
      while (cells.length < headers.length) cells.push("");
    } else if (cells.length > headers.length) {
      cells = cells.slice(0, headers.length);
    }
    rows.push(cells);
    index += 1;
  }

  return { table: { headers, alignments, rows }, nextIndex: index };
}

function tableAlignment(source: string): PiMarkdownColumnAlignment | null {
  const content = source.replace(/^[ \t]+|[ \t]+$/g, "");
  if (content.length === 0) return null;
  const leadingColon = content[0] === ":";
  const trailingColon = content[content.length - 1] === ":";
  let dashes = content.replace(/^:+/, "");
  if (trailingColon) dashes = dashes.slice(0, -1);
  if (dashes.length < 3 || !charsEvery(dashes, (c) => c === "-")) return null;
  if (leadingColon && trailingColon) return "center";
  if (trailingColon) return "trailing";
  return "leading";
}

function splitTableRow(line: string): string[] {
  let content = line.replace(/^[ \t]+|[ \t]+$/g, "");
  if (content[0] === "|") content = content.slice(1);
  if (
    content.length > 0 &&
    content[content.length - 1] === "|" &&
    !isEscapedPipe(content.length - 1, content)
  ) {
    content = content.slice(0, -1);
  }

  const cells: string[] = [];
  let cell = "";
  let isEscaped = false;
  let inCodeSpan = false;
  for (const character of content) {
    if (isEscaped) {
      cell += character;
      isEscaped = false;
    } else if (character === "\\") {
      cell += character;
      isEscaped = true;
    } else if (character === "`") {
      cell += character;
      inCodeSpan = !inCodeSpan;
    } else if (character === "|" && !inCodeSpan) {
      cells.push(cell.replace(/^[ \t]+|[ \t]+$/g, ""));
      cell = "";
    } else {
      cell += character;
    }
  }
  cells.push(cell.replace(/^[ \t]+|[ \t]+$/g, ""));
  return cells;
}

function containsUnescapedPipe(line: string): boolean {
  let isEscaped = false;
  let inCodeSpan = false;
  for (const character of line) {
    if (isEscaped) {
      isEscaped = false;
    } else if (character === "\\") {
      isEscaped = true;
    } else if (character === "`") {
      inCodeSpan = !inCodeSpan;
    } else if (character === "|" && !inCodeSpan) {
      return true;
    }
  }
  return false;
}

function isEscapedPipe(index: number, source: string): boolean {
  let slashes = 0;
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === "\\"; cursor -= 1) {
    slashes += 1;
  }
  return slashes % 2 !== 0;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

function startsBlock(lines: string[], index: number): boolean {
  return (
    fenceOpening(lines[index]) !== null ||
    parseTable(lines, index) !== null ||
    atxHeading(lines[index]) !== null ||
    isThematicBreak(lines[index]) ||
    quoteText(lines[index]) !== null ||
    listItem(lines[index]) !== null
  );
}

function indentationWidth(line: string): number {
  let width = 0;
  for (const character of line) {
    if (!isSpace(character)) break;
    width += character === "\t" ? 4 : 1;
  }
  return width;
}

function dropUpToThreeLeadingSpaces(line: string): string {
  let dropped = 0;
  while (dropped < 3 && line[dropped] === " ") dropped += 1;
  return line.slice(dropped);
}

function isSpace(character: string): boolean {
  return /\s/.test(character);
}

function charsEvery(value: string, predicate: (character: string) => boolean): boolean {
  for (let i = 0; i < value.length; i += 1) {
    if (!predicate(value[i])) return false;
  }
  return true;
}

function isBlank(line: string): boolean {
  return line.length === 0 || charsEvery(line, isSpace);
}
