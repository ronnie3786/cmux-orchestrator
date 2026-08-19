/**
 * `TerminalGrid` — deterministic 1:1 port of
 * herdr-harness-ios/.../Models/TerminalGrid.swift (419 lines).
 *
 * The Swift file is the source of truth: Cell/Style internals, the
 * run-building logic (Swift `attributedText.appendRun`), `apply`, `reset`,
 * `resize`, `parse`, `consumeEscape`, `applyCSI`, `applySGR`, `eraseDisplay`,
 * `eraseLine`, `put`, `lineFeed`, `visibleRows(includeCursor:)`,
 * `resolvedColors(for:)`, `indexedColor(for:)`, and `clamped(_:upperBound:)`
 * are all translated verbatim in semantics. Where Swift uses SwiftUI
 * `Color`, this port emits CSS color strings instead.
 *
 * Public surface:
 *  - `TerminalFrame` type + `decodeFrameBytes`      (./frame.ts)
 *  - `TerminalGrid` (this file)
 *  - `TerminalSSEParser` (./sseParser.ts)
 *  - `indexedColor` / `rgbToCss` / `BASE_COLORS`   (./palette.ts)
 */

import { decodeFrameBytes, type TerminalFrame } from "./frame";
import { indexedColor, rgbToCss, type RGB } from "./palette";

// MARK: - Defaults (Swift `resolvedColors(for:)` uses HerdrTheme.text / .ink)

/** Swift `HerdrTheme.text` = Color(red: 0.804, green: 0.839, blue: 0.957). */
export const DEFAULT_TEXT_COLOR = "#CDD6F4";
/** Swift `HerdrTheme.ink` = Color(red: 0.094, green: 0.094, blue: 0.145). */
export const INK_COLOR = "#181825";

// MARK: - Public types

/**
 * One styled run of cells in a rendered row — the web shape of Swift
 * `attributedText`'s `appendRun` output. Colors are resolved exactly like
 * `resolvedColors(for:)` (default foreground applied, inverse swapped):
 * `foreground` is always a CSS string; `background` is null when the
 * resolved background is absent (i.e. non-inverse runs with no bg).
 * `cursor` marks the run containing the terminal cursor cell (which has its
 * `inverse` flag toggled, as Swift does for `includeCursor` rows).
 */
export interface TerminalRun {
  text: string;
  foreground: string;
  background: string | null;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  inverse: boolean;
  cursor: boolean;
}

/** A trimmed visible row as an array of styled runs. */
export type Row = TerminalRun[];

// MARK: - Internal types (Swift Cell / Style / TerminalColor)

interface Style {
  foreground: RGB | null;
  background: RGB | null;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  inverse: boolean;
}

interface Cell {
  character: string;
  style: Style;
}

function freshStyle(): Style {
  return {
    foreground: null,
    background: null,
    bold: false,
    italic: false,
    underline: false,
    inverse: false,
  };
}

function freshCell(): Cell {
  return { character: " ", style: freshStyle() };
}

function sameStyle(a: Style, b: Style): boolean {
  return (
    a.bold === b.bold &&
    a.italic === b.italic &&
    a.underline === b.underline &&
    a.inverse === b.inverse &&
    sameColor(a.foreground, b.foreground) &&
    sameColor(a.background, b.background)
  );
}

function sameColor(a: RGB | null, b: RGB | null): boolean {
  if (a === null && b === null) return true;
  if (a === null || b === null) return false;
  return a.r === b.r && a.g === b.g && a.b === b.b;
}

/** Port of `clamped(_:upperBound:)`. */
function clamped(value: number, upperBound: number): number {
  return Math.min(Math.max(0, value), Math.max(0, upperBound - 1));
}

/** Port of `UInt8(clamping:)` for SGR 38;2;r;g;b channels. */
function clamp8(value: number): number {
  return Math.min(255, Math.max(0, value));
}

/**
 * Swift `Int(String) ?? 0`: only an optional leading "-" followed by digits
 * parses; everything else (empty, "5x", "+5", …) yields 0.
 */
function parseParameter(part: string): number {
  const match = /^-?\d+$/.exec(part);
  return match === null ? 0 : Number.parseInt(match[0], 10);
}

// MARK: - Grapheme iteration (Swift `Array(payload)` is grapheme-based)

/**
 * Swift iterates `Array(payload)` by user-perceived grapheme clusters (one
 * Character per `put` cell). Use UAX#29 grapheme boundaries where the
 * runtime provides them; fall back to code points (same result for every
 * single-code-point sequence, which covers all tested behavior).
 */
function splitGraphemes(payload: string): string[] {
  const segmenter = (Intl as unknown as {
    Segmenter?: new (locale?: string, options?: object) => {
      segment(input: string): Iterable<{ segment: string }>;
    };
  }).Segmenter;
  if (segmenter !== undefined) {
    const graphemes: string[] = [];
    for (const unit of new segmenter("en", { granularity: "grapheme" }).segment(payload)) {
      graphemes.push(unit.segment);
    }
    return graphemes;
  }
  return Array.from(payload);
}

/** First Unicode scalar of a grapheme (Swift `unicodeScalars.first`). */
function firstCodePoint(grapheme: string): number | null {
  const codePoint = grapheme.codePointAt(0);
  return codePoint === undefined ? null : codePoint;
}

/** Swift `CharacterSet.controlCharacters`: C0 (0x00-0x1F), DEL (0x7F), C1 (0x80-0x9F). */
function isControlCharacter(codePoint: number): boolean {
  return codePoint <= 0x1f || codePoint === 0x7f || (codePoint >= 0x80 && codePoint <= 0x9f);
}

/** Swift `character.unicodeScalars.allSatisfy { controlCharacters.contains($0) }`. */
function isAllControl(grapheme: string): boolean {
  if (grapheme.length === 0) return false;
  let offset = 0;
  for (;;) {
    const codePoint = grapheme.codePointAt(offset);
    if (codePoint === undefined) return true;
    if (!isControlCharacter(codePoint)) return false;
    offset += codePoint > 0xffff ? 2 : 1;
    if (offset >= grapheme.length) return true;
  }
}

// MARK: - TerminalGrid

export class TerminalGrid {
  #columns: number;
  #rows: number;
  private cells: Cell[];
  private cursorRow = 0;
  private cursorColumn = 0;
  private cursorVisible = true;
  private wrapPending = false;
  private style: Style = freshStyle();
  #lastSequence = 0;

  constructor(columns = 100, rows = 32) {
    this.#columns = Math.max(1, columns);
    this.#rows = Math.max(1, rows);
    this.cells = Array.from({ length: this.#columns * this.#rows }, freshCell);
  }

  get columns(): number {
    return this.#columns;
  }

  get rows(): number {
    return this.#rows;
  }

  get lastSequence(): number {
    return this.#lastSequence;
  }

  /**
   * Port of `plainText`: visible rows (no cursor), each row's characters
   * joined with trailing spaces trimmed, rows joined by "\n", then trailing
   * newlines trimmed (Swift `trimmingTrailingSpaces` / `trimmingTrailingNewlines`).
   */
  get plainText(): string {
    const lines = this.visibleRows(false).map((row) =>
      row
        .map((run) => run.text)
        .join("")
        .replace(/ +$/, ""),
    );
    return lines.join("\n").replace(/\n+$/, "");
  }

  /**
   * Port of `apply(_ frame: TerminalFrame) -> Bool`.
   *
   * NOTE (deviation flagged): Swift returns `true` on a stale delta
   * (`frame.seq <= lastSequence`) (`guard frame.sequence > lastSequence
   * else { return true }`) without parsing or updating `lastSequence`.
   * This port intentionally returns `false` instead (P4 brief). The
   * difference is load-bearing for the caller: terminalStore advances its
   * frameSequence (the fN counter) ONLY when apply returns true — a stale
   * delta must not advance the fN counter, so the `false` is required.
   * The grid itself is left untouched in both variants.
   */
  apply(frame: TerminalFrame): boolean {
    if (frame.type !== "terminal.frame" || frame.width <= 0 || frame.height <= 0) {
      return false;
    }
    const payload = decodeFrameBytes(frame);
    if (payload === null) {
      return false;
    }

    if (frame.full) {
      this.#columns = frame.width;
      this.#rows = frame.height;
      this.reset();
    } else {
      if (frame.seq <= this.#lastSequence) {
        return false;
      }
      this.resize(frame.width, frame.height);
    }
    this.#lastSequence = frame.seq;
    this.parse(payload);
    return true;
  }

  // MARK: - reset / resize

  /** Port of `reset()`. */
  private reset(): void {
    this.cells = Array.from({ length: this.#columns * this.#rows }, freshCell);
    this.cursorRow = 0;
    this.cursorColumn = 0;
    this.cursorVisible = true;
    this.wrapPending = false;
    this.style = freshStyle();
  }

  /** Port of `resize(columns:rows:)` — copy overlap, clamp cursor. */
  private resize(newColumns: number, newRows: number): void {
    const targetColumns = Math.max(1, newColumns);
    const targetRows = Math.max(1, newRows);
    if (targetColumns === this.#columns && targetRows === this.#rows) return;
    const resized: Cell[] = Array.from(
      { length: targetColumns * targetRows },
      freshCell,
    );
    for (let row = 0; row < Math.min(this.#rows, targetRows); row += 1) {
      for (let column = 0; column < Math.min(this.#columns, targetColumns); column += 1) {
        resized[row * targetColumns + column] = this.cells[row * this.#columns + column];
      }
    }
    this.#columns = targetColumns;
    this.#rows = targetRows;
    this.cells = resized;
    this.cursorRow = Math.min(this.cursorRow, this.#rows - 1);
    this.cursorColumn = Math.min(this.cursorColumn, this.#columns - 1);
    this.wrapPending = false;
  }

  // MARK: - parse

  /** Port of `parse(_ payload: String)`. */
  private parse(payload: string): void {
    const characters = splitGraphemes(payload);
    let index = 0;
    while (index < characters.length) {
      const character = characters[index];
      if (character === "\u001B") {
        index = this.consumeEscape(characters, index);
        continue;
      }
      switch (character) {
        case "\r":
          this.cursorColumn = 0;
          this.wrapPending = false;
          break;
        case "\n":
          this.lineFeed();
          this.wrapPending = false;
          break;
        case "\u0008":
          this.cursorColumn = Math.max(0, this.cursorColumn - 1);
          this.wrapPending = false;
          break;
        case "\t":
          // Swift integer division: ((cursorColumn / 8) + 1) * 8.
          this.cursorColumn = Math.min(
            this.#columns - 1,
            (Math.floor(this.cursorColumn / 8) + 1) * 8,
          );
          this.wrapPending = false;
          break;
        default:
          if (!isAllControl(character)) {
            this.put(character);
          }
      }
      index += 1;
    }
  }

  /** Port of `consumeEscape(in:from:)`. */
  private consumeEscape(characters: string[], start: number): number {
    if (start + 1 >= characters.length) return start + 1;
    const introducer = characters[start + 1];

    if (introducer === "[") {
      let end = start + 2;
      while (end < characters.length) {
        const scalar = firstCodePoint(characters[end]);
        if (scalar !== null && scalar >= 0x40 && scalar <= 0x7e) {
          const parameters = characters.slice(start + 2, end).join("");
          this.applyCSI(characters[end], parameters);
          return end + 1;
        }
        end += 1;
      }
      return characters.length;
    }

    if (introducer === "]") {
      let end = start + 2;
      while (end < characters.length) {
        if (characters[end] === "\u0007") return end + 1;
        if (characters[end] === "\u001B" && end + 1 < characters.length && characters[end + 1] === "\\") {
          return end + 2;
        }
        end += 1;
      }
      return characters.length;
    }

    return Math.min(start + 2, characters.length);
  }

  // MARK: - CSI / SGR

  /** Port of `applyCSI(final:parameters:)`. */
  private applyCSI(final: string, rawParameters: string): void {
    const isPrivate = rawParameters.startsWith("?");
    // Swift `trimmingCharacters(in: CharacterSet(charactersIn: "?>!"))`:
    // strips leading/trailing runs of ? > !.
    const cleaned = rawParameters.replace(/^[?!>]+|[?!>]+$/g, "");
    // Swift `split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }`
    // — JS `split` keeps empty subsequences, matching the Swift call.
    const values = cleaned.split(";").map(parseParameter);
    const first = values.length > 0 ? values[0] : 0;
    this.wrapPending = false;

    if (isPrivate && (final === "h" || final === "l")) {
      if (values.includes(25)) {
        this.cursorVisible = final === "h";
      }
      return;
    }

    switch (final) {
      case "H":
      case "f":
        // Swift: `(values[safe: 0] ?? 1) - 1` — a missing value means 1.
        this.cursorRow = clamped((values.length > 0 ? values[0] : 1) - 1, this.#rows);
        this.cursorColumn = clamped((values.length > 1 ? values[1] : 1) - 1, this.#columns);
        break;
      case "A":
        this.cursorRow = Math.max(0, this.cursorRow - Math.max(1, first));
        break;
      case "B":
        this.cursorRow = Math.min(this.#rows - 1, this.cursorRow + Math.max(1, first));
        break;
      case "C":
        this.cursorColumn = Math.min(this.#columns - 1, this.cursorColumn + Math.max(1, first));
        break;
      case "D":
        this.cursorColumn = Math.max(0, this.cursorColumn - Math.max(1, first));
        break;
      case "G":
        this.cursorColumn = clamped(Math.max(1, first) - 1, this.#columns);
        break;
      case "d":
        this.cursorRow = clamped(Math.max(1, first) - 1, this.#rows);
        break;
      case "J":
        this.eraseDisplay(first);
        break;
      case "K":
        this.eraseLine(first);
        break;
      case "m":
        this.applySGR(values.length === 0 ? [0] : values);
        break;
      default:
        break;
    }
  }

  /** Port of `applySGR(_ values: [Int])`. */
  private applySGR(values: number[]): void {
    let index = 0;
    while (index < values.length) {
      const code = values[index];
      switch (code) {
        case 0:
          this.style = freshStyle();
          break;
        case 1:
          this.style.bold = true;
          break;
        case 2:
          break;
        case 3:
          this.style.italic = true;
          break;
        case 4:
          this.style.underline = true;
          break;
        case 7:
          this.style.inverse = true;
          break;
        case 22:
          this.style.bold = false;
          break;
        case 23:
          this.style.italic = false;
          break;
        case 24:
          this.style.underline = false;
          break;
        case 27:
          this.style.inverse = false;
          break;
        case 39:
          this.style.foreground = null;
          break;
        case 49:
          this.style.background = null;
          break;
        case 38:
        case 48: {
          const isForeground = code === 38;
          const setColor = (color: RGB): void => {
            if (isForeground) {
              this.style.foreground = color;
            } else {
              this.style.background = color;
            }
          };
          // `values[safe: n]` == undefined past the end in this port.
          if (
            values[index + 1] === 2 &&
            values[index + 2] !== undefined &&
            values[index + 3] !== undefined &&
            values[index + 4] !== undefined
          ) {
            setColor({
              r: clamp8(values[index + 2]),
              g: clamp8(values[index + 3]),
              b: clamp8(values[index + 4]),
            });
            index += 4;
          } else if (values[index + 1] === 5 && values[index + 2] !== undefined) {
            setColor(indexedColor(values[index + 2]));
            index += 2;
          }
          break;
        }
        default:
          if (code >= 30 && code <= 37) {
            this.style.foreground = indexedColor(code - 30);
          } else if (code >= 40 && code <= 47) {
            this.style.background = indexedColor(code - 40);
          } else if (code >= 90 && code <= 97) {
            this.style.foreground = indexedColor(code - 90 + 8);
          } else if (code >= 100 && code <= 107) {
            this.style.background = indexedColor(code - 100 + 8);
          }
          break;
      }
      index += 1;
    }
  }

  // MARK: - erases

  /** Port of `eraseDisplay(mode:)`. */
  private eraseDisplay(mode: number): void {
    switch (mode) {
      case 2:
      case 3:
        this.cells = Array.from({ length: this.#columns * this.#rows }, freshCell);
        break;
      case 1: {
        const end = this.cursorRow * this.#columns + this.cursorColumn;
        if (end >= 0) {
          for (let i = 0; i <= Math.min(end, this.cells.length - 1); i += 1) {
            this.cells[i] = freshCell();
          }
        }
        break;
      }
      default: {
        const start = this.cursorRow * this.#columns + this.cursorColumn;
        if (start < this.cells.length) {
          for (let i = start; i < this.cells.length; i += 1) {
            this.cells[i] = freshCell();
          }
        }
        break;
      }
    }
  }

  /** Port of `eraseLine(mode:)`. */
  private eraseLine(mode: number): void {
    const rowStart = this.cursorRow * this.#columns;
    switch (mode) {
      case 1:
        for (let column = 0; column <= this.cursorColumn; column += 1) {
          this.cells[rowStart + column] = freshCell();
        }
        break;
      case 2:
        for (let column = 0; column < this.#columns; column += 1) {
          this.cells[rowStart + column] = freshCell();
        }
        break;
      default:
        for (let column = this.cursorColumn; column < this.#columns; column += 1) {
          this.cells[rowStart + column] = freshCell();
        }
        break;
    }
  }

  // MARK: - cursor movement

  /** Port of `put(_ character:)` — Swift `Character`; one grapheme per cell. */
  private put(character: string): void {
    if (this.wrapPending) {
      this.cursorColumn = 0;
      this.lineFeed();
      this.wrapPending = false;
    }
    // Cell stores a copy of the pen style (Swift struct copy semantics).
    this.cells[this.cursorRow * this.#columns + this.cursorColumn] = {
      character,
      style: { ...this.style },
    };
    if (this.cursorColumn === this.#columns - 1) {
      this.wrapPending = true;
    } else {
      this.cursorColumn += 1;
    }
  }

  /** Port of `lineFeed()` — scrolls when the cursor is on the bottom row. */
  private lineFeed(): void {
    if (this.cursorRow === this.#rows - 1) {
      this.cells.splice(0, this.#columns);
      this.cells.push(
        ...Array.from({ length: this.#columns }, freshCell),
      );
    } else {
      this.cursorRow += 1;
    }
  }

  // MARK: - visible rows + run building (Swift `visibleRows` + `attributedText`)

  /**
   * Port of `visibleRows(includeCursor:)` + the `attributedText` run loop:
   * trailing all-blank rows are trimmed (the visible cursor extends
   * visibility), rows are trimmed at their last non-blank column (or the
   * cursor column), and cells are coalesced into runs of identical style.
   * The cursor cell's `inverse` flag is toggled exactly as Swift does.
   */
  visibleRows(includeCursor = false): Row[] {
    if (this.cells.length === 0) return [];

    let lastRow = -1;
    for (let row = 0; row < this.#rows; row += 1) {
      const start = row * this.#columns;
      const range = this.cells.slice(start, start + this.#columns);
      if (range.some((cell) => cell.character !== " ")) {
        lastRow = row;
      }
    }
    if (includeCursor && this.cursorVisible) {
      lastRow = Math.max(lastRow, this.cursorRow);
    }
    if (lastRow < 0) return [];

    const result: Row[] = [];
    for (let row = 0; row <= lastRow; row += 1) {
      const start = row * this.#columns;
      const values = this.cells.slice(start, start + this.#columns);
      let lastColumn = -1;
      for (let i = values.length - 1; i >= 0; i -= 1) {
        if (values[i].character !== " ") {
          lastColumn = i;
          break;
        }
      }
      if (includeCursor && this.cursorVisible && row === this.cursorRow) {
        lastColumn = Math.max(lastColumn, this.cursorColumn);
      }
      if (lastColumn < 0) {
        result.push([]);
        continue;
      }
      result.push(this.buildRow(values.slice(0, lastColumn + 1), row, includeCursor));
    }
    return result;
  }

  /**
   * The `attributedText` inner loop: walk the row's cells, toggle the
   * cursor cell's inverse, and flush a run whenever the style changes
   * (Swift `appendRun`). The cursor cell always flushes before and after so
   * its run is exactly that one cell (rendering detail — the run text and
   * resolved styles are identical to Swift's output).
   */
  private buildRow(cells: Cell[], rowIndex: number, includeCursor: boolean): Row {
    const runs: Row = [];
    let run = "";
    let runCursor = false;
    let runStyle: Style | null = null;

    const appendRun = (): void => {
      if (run === "" || runStyle === null) return;
      runs.push(this.materializeRun(run, runStyle, runCursor));
      run = "";
      runCursor = false;
    };

    for (let columnIndex = 0; columnIndex < cells.length; columnIndex += 1) {
      const cell: Cell = { ...cells[columnIndex], style: { ...cells[columnIndex].style } };
      const isCursor =
        includeCursor &&
        this.cursorVisible &&
        rowIndex === this.cursorRow &&
        columnIndex === this.cursorColumn;
      if (isCursor) {
        cell.style.inverse = !cell.style.inverse;
      }
      if (runStyle !== null && (isCursor || !sameStyle(runStyle, cell.style))) {
        appendRun();
        run = "";
      }
      runStyle = cell.style;
      runCursor = isCursor;
      run += cell.character;
      if (isCursor) {
        appendRun();
        runStyle = null;
      }
    }
    appendRun();
    return runs;
  }

  /** Port of `resolvedColors(for:)`, emitting CSS strings. */
  private materializeRun(
    text: string,
    style: Style,
    cursor: boolean,
  ): TerminalRun {
    const foreground = style.foreground !== null ? rgbToCss(style.foreground) : DEFAULT_TEXT_COLOR;
    const background = style.background !== null ? rgbToCss(style.background) : null;
    if (style.inverse) {
      return {
        text,
        foreground: background ?? INK_COLOR,
        background: foreground,
        bold: style.bold,
        italic: style.italic,
        underline: style.underline,
        inverse: style.inverse,
        cursor,
      };
    }
    return {
      text,
      foreground,
      background,
      bold: style.bold,
      italic: style.italic,
      underline: style.underline,
      inverse: style.inverse,
      cursor,
    };
  }
}
