/**
 * Tests for the TerminalGrid port.
 *
 * Tests 1–5 are 1:1 ports (same inputs, same expectations) of the Swift
 * Testing cases in herdr-harness-ios/.../TerminalGridHardeningTests.swift:
 *   1. fullFrameWithCursorPositioning
 *   2. deltaPreservesPriorCells
 *   3. gridDimensions
 *   4. invalidBase64IsNonDestructive
 *   5. terminalSSEActivityParsing
 *
 * The remaining tests are extra edge cases mirroring Swift parser behavior
 * noticed while porting (auto-wrap, scroll-at-bottom, cursor visibility,
 * truecolor, stale delta, OSC consumption, erases, resize overlap copy).
 */

import { describe, expect, it } from "vitest";

import { makeTerminalFrame, type TerminalFrame } from "./frame";
import { TerminalGrid } from "./grid";
import { TerminalSSEParser } from "./sseParser";

const ESC = "\u001B";

describe("TerminalGridHardeningTests (1:1 port)", () => {
  it("Full base64 ANSI frame clears and positions the cursor", () => {
    const grid = new TerminalGrid(8, 3);
    const frame = makeTerminalFrame(
      `${ESC}[2J${ESC}[HABC${ESC}[2;3HZ`,
      true,
      1,
      8,
      3,
    );

    const applied = grid.apply(frame);
    expect(applied).toBe(true);
    expect(grid.columns).toBe(8);
    expect(grid.rows).toBe(3);
    expect(grid.plainText).toBe("ABC\n  Z");
  });

  it("Delta frame updates cells without erasing the previous frame", () => {
    const grid = new TerminalGrid(5, 2);

    const fullApplied = grid.apply(
      makeTerminalFrame("hello\r\nworld", true, 10, 5, 2),
    );
    expect(fullApplied).toBe(true);
    const deltaApplied = grid.apply(
      makeTerminalFrame(`${ESC}[1;2HX`, false, 11, 5, 2),
    );
    expect(deltaApplied).toBe(true);

    expect(grid.plainText).toBe("hXllo\nworld");
  });

  it("Grid exposes its configured dimensions", () => {
    const grid = new TerminalGrid(132, 41);

    expect(grid.columns).toBe(132);
    expect(grid.rows).toBe(41);
    expect(grid.plainText).toBe("");
  });

  it("Invalid base64 is rejected without mutating visible cells", () => {
    const grid = new TerminalGrid(4, 1);
    const seedApplied = grid.apply(
      makeTerminalFrame("safe", true, 20, 4, 1),
    );
    expect(seedApplied).toBe(true);
    const previousText = grid.plainText;

    const invalidFrame: TerminalFrame = {
      type: "terminal.frame",
      bytes: "%%% definitely-not-base64 %%%",
      encoding: "base64",
      full: false,
      height: 1,
      seq: 21,
      width: 4,
    };

    const invalidApplied = grid.apply(invalidFrame);
    expect(invalidApplied).toBe(false);
    expect(grid.plainText).toBe(previousText);
    expect(grid.columns).toBe(4);
    expect(grid.rows).toBe(1);
  });

  it("Terminal SSE parser exposes ready, heartbeats, and frames", () => {
    const parser = new TerminalSSEParser();

    expect(parser.consume("event: ready")).toBeNull();
    expect(parser.consume('data: {"paneId":"w1:p1"}')).toEqual({ kind: "ready" });
    expect(parser.consume("")).toBeNull();
    expect(parser.consume(": terminal heartbeat now")).toEqual({ kind: "activity" });
    expect(parser.consume("")).toBeNull();

    expect(parser.consume("event: terminal.frame")).toBeNull();
    expect(
      parser.consume(
        'data: {"bytes":"aGk=","encoding":"base64","full":true,"height":1,"seq":7,"type":"terminal.frame","width":2}',
      ),
    ).toEqual({
      kind: "frame",
      frame: makeTerminalFrame("hi", true, 7, 2, 1),
    });
    expect(parser.consume("")).toBeNull();
  });
});

describe("TerminalGrid edge behavior (mirrors Swift parser semantics)", () => {
  it("auto-wraps at the last column, deferring the wrap to the next character", () => {
    const grid = new TerminalGrid(4, 2);
    expect(grid.apply(makeTerminalFrame("abcde", true, 1, 4, 2))).toBe(true);
    // "abcd" fills row 0 (wrap pending after d); "e" wraps onto row 1.
    expect(grid.plainText).toBe("abcd\ne");
  });

  it("scrolls at the bottom row when the cursor wraps around", () => {
    const grid = new TerminalGrid(2, 2);
    // NOTE: "\r\n" is ONE grapheme cluster (UAX#29 GB98), so both Swift and
    // this port skip it entirely (it matches neither the \r nor the \n case
    // and is all-control). The line advance here comes from auto-wrap +
    // scroll — the same reason the Swift hardening test works. See the
    // CRLF test below.
    expect(grid.apply(makeTerminalFrame("ab\r\ncd\r\ne", true, 1, 2, 2))).toBe(true);
    expect(grid.plainText).toBe("cd\ne");
  });

  it("a lone LF moves to the next row, preserving the column (Swift semantics)", () => {
    // Only "\r" resets the column; "\n" alone just line-feeds — and "\r\n"
    // is a single (skipped) grapheme, so the column survives LF.
    const grid = new TerminalGrid(4, 2);
    expect(grid.apply(makeTerminalFrame("ab\ncd", true, 1, 4, 2))).toBe(true);
    expect(grid.plainText).toBe("ab\n  cd");

    // Second lone LF on the bottom row scrolls the grid up: the "c" that
    // was on the bottom row ends up on row 0 after the scroll.
    const bottom = new TerminalGrid(2, 2);
    expect(
      bottom.apply(makeTerminalFrame("ab\nc\n", true, 1, 2, 2)),
    ).toBe(true);
    expect(bottom.plainText).toBe(" c");
  });

  it("a CRLF pair is one grapheme and is skipped (Swift Character semantics)", () => {
    // Swift `Array("ab\\r\\ncdef")` == ["a","b","\r\n","c","d","e","f"]: the
    // ";\r\n" cluster matches neither `case \"\\r\"` nor `case \"\\n\"` and is
    // all-control, so it is dropped. Faithful port — do not "fix" this.
    const grid = new TerminalGrid(6, 2);
    expect(grid.apply(makeTerminalFrame("ab\r\ncdef", true, 1, 6, 2))).toBe(true);
    expect(grid.plainText).toBe("abcdef");
  });

  it("applies tab stops at 8-column boundaries", () => {
    const grid = new TerminalGrid(16, 1);
    expect(grid.apply(makeTerminalFrame("a\tb", true, 1, 16, 1))).toBe(true);
    // tab from column 1 to column 8, then "b" at column 8.
    expect(grid.plainText).toBe("a       b");
  });

  it("?25l hides the cursor, ?25h shows it again", () => {
    const hidden = new TerminalGrid(4, 3);
    expect(
      hidden.apply(
        makeTerminalFrame(`${ESC}[?25lA${ESC}[3;1H`, true, 1, 4, 3),
      ),
    ).toBe(true);
    // Cursor on row 2 (0-based) must NOT extend visibility while hidden.
    expect(hidden.plainText).toBe("A");
    expect(hidden.visibleRows(true).length).toBe(1);

    const shown = new TerminalGrid(4, 3);
    expect(
      shown.apply(makeTerminalFrame(`A${ESC}[3;1H`, true, 1, 4, 3)),
    ).toBe(true);
    const rows = shown.visibleRows(true);
    expect(rows.length).toBe(3);
    const cursorRun = rows[2][0];
    expect(cursorRun.cursor).toBe(true);
    expect(cursorRun.inverse).toBe(true);
    // Inverse with no explicit colors: fg becomes ink, bg becomes the text color.
    expect(cursorRun.foreground).toBe("#181825");
    expect(cursorRun.background).toBe("#CDD6F4");

    const restored = new TerminalGrid(4, 3);
    expect(
      restored.apply(
        makeTerminalFrame(`${ESC}[?25l${ESC}[?25hA${ESC}[3;1H`, true, 1, 4, 3),
      ),
    ).toBe(true);
    expect(restored.visibleRows(true).length).toBe(3);
  });

  it("38;2 truecolor resolves foreground and background", () => {
    const grid = new TerminalGrid(4, 1);
    expect(
      grid.apply(
        makeTerminalFrame(`${ESC}[38;2;255;128;0m${ESC}[48;2;1;2;3mX`, true, 1, 4, 1),
      ),
    ).toBe(true);
    const run = grid.visibleRows(true)[0][0];
    expect(run.text).toBe("X");
    expect(run.foreground).toBe("rgb(255, 128, 0)");
    expect(run.background).toBe("rgb(1, 2, 3)");
  });

  it("38;5 256-indexed colors use the Swift palette (base, cube, ramp)", () => {
    const grid = new TerminalGrid(16, 1);
    expect(
      grid.apply(
        makeTerminalFrame(
          `${ESC}[38;5;2mX${ESC}[38;5;196mX${ESC}[38;5;250mX`,
          true,
          1,
          16,
          1,
        ),
      ),
    ).toBe(true);
    // One run per character: green base, cube corner, gray ramp
    // (8 + (250-232)*10), then the cursor cell (inverse → ink fg).
    expect(grid.visibleRows(true)[0].map((run) => run.foreground)).toEqual([
      "rgb(13, 188, 121)",
      "rgb(255, 0, 0)",
      "rgb(188, 188, 188)",
      "#181825",
    ]);
  });

  it("stale delta (seq <= lastSequence) is rejected without mutating the grid", () => {
    const grid = new TerminalGrid(5, 2);
    expect(grid.apply(makeTerminalFrame("hello\r\nworld", true, 10, 5, 2))).toBe(true);

    // Equal seq — stale. NOTE: the Swift source returns true here
    // (`guard frame.sequence > lastSequence else { return true }`); this port
    // follows the P4 brief and returns false so the store's frameSequence
    // (fN counter) does NOT advance on a stale delta. The grid is untouched.
    expect(grid.apply(makeTerminalFrame(`${ESC}[1;1HZ`, false, 10, 5, 2))).toBe(false);
    expect(grid.plainText).toBe("hello\nworld");
    expect(grid.lastSequence).toBe(10);
    expect(grid.columns).toBe(5);
    expect(grid.rows).toBe(2);

    // Older seq — also stale.
    expect(grid.apply(makeTerminalFrame(`${ESC}[1;1MZ`, false, 9, 5, 2))).toBe(false);
    expect(grid.plainText).toBe("hello\nworld");
    expect(grid.lastSequence).toBe(10);
  });

  it("non-positive frame dimensions are rejected", () => {
    const grid = new TerminalGrid(4, 1);
    expect(grid.apply(makeTerminalFrame("safe", true, 1, 4, 1))).toBe(true);
    expect(
      grid.apply({ ...makeTerminalFrame("x", true, 2, 0, 1) }),
    ).toBe(false);
    expect(grid.plainText).toBe("safe");
  });

  it("OSC sequences are consumed and ignored (BEL and ESC\\ terminators)", () => {
    const bel = new TerminalGrid(8, 1);
    expect(
      bel.apply(makeTerminalFrame(`${ESC}]0;title\u0007AB`, true, 1, 8, 1)),
    ).toBe(true);
    expect(bel.plainText).toBe("AB");

    const st = new TerminalGrid(8, 1);
    expect(st.apply(makeTerminalFrame(`${ESC}]0;title${ESC}\\AB`, true, 1, 8, 1))).toBe(true);
    expect(st.plainText).toBe("AB");
  });

  it("unrecognized escape consumes ESC + one character", () => {
    const grid = new TerminalGrid(8, 1);
    expect(grid.apply(makeTerminalFrame(`${ESC}MX`, true, 1, 8, 1))).toBe(true);
    expect(grid.plainText).toBe("X");
  });

  it("0K erases from the cursor to end of line; 2J clears the screen", () => {
    const grid = new TerminalGrid(6, 2);
    expect(
      grid.apply(
        makeTerminalFrame(`${ESC}[2;1Hcdef`, true, 1, 6, 2),
      ),
    ).toBe(true);
    // "ESC[2;1H" starts row 1 at column 0; row 0 stays blank (visibleRows
    // keeps it, so plainText has a leading newline for the empty row).
    expect(grid.plainText).toBe("\ncdef");
    expect(
      grid.apply(
        makeTerminalFrame(`${ESC}[2;3H${ESC}[0K`, false, 2, 6, 2),
      ),
    ).toBe(true);
    // Cursor at row 2, column 3 (1-based); erase-to-EOL blanks row 1 cols 2..5.
    // Row 0 remains blank → leading newline in plainText.
    expect(grid.plainText).toBe("\ncd");

    // 2J then reposition + write: only the new text survives.
    expect(
      grid.apply(
        makeTerminalFrame(`${ESC}[2J${ESC}[Hqq`, false, 3, 6, 2),
      ),
    ).toBe(true);
    expect(grid.plainText).toBe("qq");
  });

  it("delta resize copies the overlap and clamps the cursor", () => {
    const grid = new TerminalGrid(5, 2);
    expect(grid.apply(makeTerminalFrame("hello\r\nworld", true, 1, 5, 2))).toBe(true);
    // Grow to 7x2 via delta (cursor currently at row 1 col 5).
    expect(grid.apply(makeTerminalFrame("XY", false, 2, 7, 2))).toBe(true);
    expect(grid.columns).toBe(7);
    expect(grid.rows).toBe(2);
    // "hello" preserved in the overlap; cursor was at row 1 col 4 (wrap
    // pending after "world"), so X overwrites "d" and Y lands at col 5.
    expect(grid.plainText).toBe("hello\nworlXY");
  });

  it("SGR reset and attribute toggles carry across cells", () => {
    const grid = new TerminalGrid(8, 1);
    expect(
      grid.apply(
        makeTerminalFrame(`${ESC}[1;4;7mAB${ESC}[0mC`, true, 1, 8, 1),
      ),
    ).toBe(true);
    const runs = grid.visibleRows(true)[0];
    expect(runs.map((run) => run.text)).toEqual(["AB", "C", " "]);
    expect(runs[0].bold).toBe(true);
    expect(runs[0].underline).toBe(true);
    expect(runs[0].inverse).toBe(true);
    expect(runs[0].background).toBe("#CDD6F4");
    expect(runs[1].bold).toBe(false);
    expect(runs[1].underline).toBe(false);
    expect(runs[1].inverse).toBe(false);
  });
});
