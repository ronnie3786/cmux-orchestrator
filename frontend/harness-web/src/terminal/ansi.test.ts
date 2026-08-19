import { describe, expect, it } from "vitest";
import { plainText, renderANSI, renderANSIBlock, type Run } from "./ansi";

const ESC = "\x1b";

function text(runs: Run[]): string {
  return runs.map((r) => r.text).join("");
}

describe("renderANSI", () => {
  it("passes plain text through with no styling", () => {
    const runs = renderANSI("hello world");
    expect(runs).toHaveLength(1);
    expect(runs[0].text).toBe("hello world");
    expect(runs[0].fg).toBeUndefined();
    expect(runs[0].bg).toBeUndefined();
    expect(runs[0].bold).toBeUndefined();
    expect(runs[0].italic).toBeUndefined();
    expect(runs[0].underline).toBeUndefined();
  });

  it("renders the 16 named foreground colors with the iOS dark palette", () => {
    const expectations: Array<[number, string]> = [
      [30, "rgb(84, 97, 120)"], // black
      [31, "rgb(248, 113, 113)"], // red
      [32, "rgb(52, 211, 153)"], // green
      [33, "rgb(251, 191, 36)"], // yellow
      [34, "rgb(96, 165, 250)"], // blue
      [35, "rgb(192, 132, 252)"], // magenta
      [36, "rgb(34, 211, 238)"], // cyan
      [37, "rgb(226, 232, 240)"], // white
      [90, "rgb(122, 139, 164)"], // brightBlack
      [91, "rgb(252, 165, 165)"], // brightRed
      [92, "rgb(110, 231, 183)"], // brightGreen
      [93, "rgb(253, 230, 138)"], // brightYellow
      [94, "rgb(147, 197, 253)"], // brightBlue
      [95, "rgb(216, 180, 254)"], // brightMagenta
      [96, "rgb(103, 232, 249)"], // brightCyan
      [97, "rgb(248, 250, 252)"], // brightWhite
    ];
    for (const [code, fg] of expectations) {
      const runs = renderANSI(`${ESC}[${code}mx${ESC}[0m`);
      expect(text(runs)).toBe("x");
      expect(runs[0].fg).toBe(fg);
    }
  });

  it("renders named background colors from the iOS dark palette", () => {
    // Solid slates for black/brightBlack…
    expect(renderANSI(`${ESC}[40mx`)[0].bg).toBe("#1E293B");
    expect(renderANSI(`${ESC}[100mx`)[0].bg).toBe("#334155");
    // …and 0.25-opacity tints for the rest.
    expect(renderANSI(`${ESC}[41mx`)[0].bg).toBe("rgba(248, 113, 113, 0.25)");
    expect(renderANSI(`${ESC}[42mx`)[0].bg).toBe("rgba(52, 211, 153, 0.25)");
    expect(renderANSI(`${ESC}[104mx`)[0].bg).toBe("rgba(96, 165, 250, 0.25)");
    // 39/49 clear fg/bg again.
    const runs = renderANSI(`${ESC}[31;41mab${ESC}[39;49mcd`);
    expect(runs).toHaveLength(2);
    expect(runs[1].fg).toBeUndefined();
    expect(runs[1].bg).toBeUndefined();
  });

  it("renders the 256-color table (VGA base 16, cube, grayscale)", () => {
    // 0-15 are the fixed VGA base colors, not the app palette.
    expect(renderANSI(`${ESC}[38;5;0mx`)[0].fg).toBe("rgb(0, 0, 0)");
    expect(renderANSI(`${ESC}[38;5;1mx`)[0].fg).toBe("rgb(128, 0, 0)");
    expect(renderANSI(`${ESC}[38;5;8mx`)[0].fg).toBe("rgb(128, 128, 128)");
    expect(renderANSI(`${ESC}[38;5;15mx`)[0].fg).toBe("rgb(255, 255, 255)");
    // 16-231 are the 6x6x6 cube.
    expect(renderANSI(`${ESC}[38;5;16mx`)[0].fg).toBe("rgb(0, 0, 0)");
    expect(renderANSI(`${ESC}[38;5;196mx`)[0].fg).toBe("rgb(255, 0, 0)");
    expect(renderANSI(`${ESC}[38;5;21mx`)[0].fg).toBe("rgb(0, 0, 255)");
    expect(renderANSI(`${ESC}[38;5;231mx`)[0].fg).toBe("rgb(255, 255, 255)");
    // 232-255 are the grayscale ramp.
    expect(renderANSI(`${ESC}[38;5;232mx`)[0].fg).toBe("rgb(8, 8, 8)");
    expect(renderANSI(`${ESC}[38;5;244mx`)[0].fg).toBe("rgb(128, 128, 128)");
    expect(renderANSI(`${ESC}[38;5;255mx`)[0].fg).toBe("rgb(238, 238, 238)");
    // 48;5 works for backgrounds too (0.35 opacity in the dark scheme).
    expect(renderANSI(`${ESC}[48;5;196mx`)[0].bg).toBe("rgba(255, 0, 0, 0.35)");
  });

  it("renders truecolor (38;2 / 48;2)", () => {
    const runs = renderANSI(`${ESC}[38;2;10;200;30mx${ESC}[0m`);
    expect(runs[0].fg).toBe("rgb(10, 200, 30)");
    const bgRuns = renderANSI(`${ESC}[48;2;1;2;3mx`);
    expect(bgRuns[0].bg).toBe("rgba(1, 2, 3, 0.35)");
    // Out-of-range truecolor components are clamped like the iOS palette.
    expect(renderANSI(`${ESC}[38;2;300;-5;256mx`)[0].fg).toBe("rgb(255, 0, 255)");
  });

  it("combines styles in a single run", () => {
    const runs = renderANSI(`${ESC}[1;3;4;32mx${ESC}[0m`);
    expect(runs).toHaveLength(1);
    expect(runs[0].text).toBe("x");
    expect(runs[0].bold).toBe(true);
    expect(runs[0].italic).toBe(true);
    expect(runs[0].underline).toBe(true);
    expect(runs[0].fg).toBe("rgb(52, 211, 153)");
  });

  it("handles reset mid-line and sequential style changes", () => {
    const runs = renderANSI(`${ESC}[1mbold${ESC}[0mplain${ESC}[31mred${ESC}[0m`);
    expect(runs.map((r) => r.text)).toEqual(["bold", "plain", "red"]);
    expect(runs[0].bold).toBe(true);
    expect(runs[1].bold).toBeUndefined();
    expect(runs[1].fg).toBeUndefined();
    expect(runs[2].fg).toBe("rgb(248, 113, 113)");
  });

  it("coalesces adjacent runs with the same resolved style", () => {
    // No-op SGR boundaries that leave the style unchanged are merged,
    // matching the iOS parser's coalesce pass.
    const runs = renderANSI(`${ESC}[31mab${ESC}[31mcd${ESC}[0mef`);
    expect(runs.map((r) => r.text)).toEqual(["abcd", "ef"]);
    expect(runs[0].fg).toBe("rgb(248, 113, 113)");
  });

  it("dims the resolved foreground (SGR 2) and clears it (SGR 22)", () => {
    const runs = renderANSI(`${ESC}[2;31mdim${ESC}[22mbright`);
    expect(runs[0].fg).toBe("rgba(248, 113, 113, 0.6)");
    expect(runs[1].fg).toBe("rgb(248, 113, 113)");
    expect(runs[1].bold).toBeUndefined();
    // Dim without a foreground dims the default color (0xD8DDE8).
    const dimmed = renderANSI(`${ESC}[2mdim${ESC}[22mbright`);
    expect(dimmed[0].fg).toBe("rgba(216, 221, 232, 0.6)");
    expect(dimmed[1].fg).toBeUndefined();
  });

  it("treats an empty SGR parameter list as a reset", () => {
    const runs = renderANSI(`${ESC}[1mb${ESC}[mc`);
    expect(runs).toHaveLength(2);
    expect(runs[0].bold).toBe(true);
    expect(runs[1].bold).toBeUndefined();
  });

  it("ignores unknown SGR codes without corrupting state", () => {
    const runs = renderANSI(`${ESC}[999;31mx${ESC}[0m`);
    expect(text(runs)).toBe("x");
    expect(runs[0].fg).toBe("rgb(248, 113, 113)");
  });

  it("skips consumed extended-color parameters (38;5;0 is not a reset)", () => {
    // The trailing 0 is the color index, not an SGR reset code.
    const runs = renderANSI(`${ESC}[38;5;0mx`);
    expect(runs[0].fg).toBe("rgb(0, 0, 0)");
    expect(runs[0].bold).toBeUndefined();
  });

  it("does not crash on malformed sequences", () => {
    // Lone ESC is dropped (iOS behavior), never emitted as text.
    expect(text(renderANSI("abc\x1b"))).toBe("abc");
    // ESC + "[" with nothing else: ESC dropped, "[" stays.
    expect(text(renderANSI("abc\x1b["))).toBe("abc[");
    // CSI with no final byte: ESC dropped, the parameters stay as text.
    expect(text(renderANSI("abc\x1b[1;31"))).toBe("abc[1;31");
    // 38 with missing parameters leaves the current foreground untouched…
    expect(renderANSI(`${ESC}[32m${ESC}[38mgreen`)[0].fg).toBe("rgb(52, 211, 153)");
    expect(renderANSI(`${ESC}[32m${ESC}[38;5mgreen`)[0].fg).toBe("rgb(52, 211, 153)");
    // …but an incomplete 38;2 falls through and SGR 2 (dim) still applies.
    expect(renderANSI(`${ESC}[32m${ESC}[38;2;1;2mgreen`)[0].fg).toBe("rgba(52, 211, 153, 0.6)");
    // Semicolon-only parameters become [0, 0] (reset).
    expect(text(renderANSI(`${ESC}[;mx`))).toBe("x");
    // Non-SGR CSI sequences (incl. private markers) are consumed as no-ops.
    expect(text(renderANSI(`a${ESC}[15;2Hb${ESC}[?25lc`))).toBe("abc");
    expect(text(renderANSI(`a${ESC}[Ab`))).toBe("ab");
    // OSC sequences are fully consumed (BEL or ST terminated)…
    expect(text(renderANSI(`a${ESC}]0;title\u0007b`))).toBe("ab");
    expect(text(renderANSI(`a${ESC}]0;title${ESC}\\b`))).toBe("ab");
    // …and an unterminated OSC swallows the rest of the line.
    expect(text(renderANSI(`a${ESC}]0;title`))).toBe("a");
  });

  it("renders multi-line input with style carried across lines", () => {
    const block = `${ESC}[1;33mfirst\nsecond${ESC}[0mplain\n\nend`;
    const lines = renderANSIBlock(block);
    expect(lines).toHaveLength(4);
    expect(lines[0].map((r) => r.text).join("")).toBe("first");
    expect(lines[0][0].bold).toBe(true);
    expect(lines[0][0].fg).toBe("rgb(251, 191, 36)");
    // The bold+yellow style persists onto the next line until reset.
    expect(lines[1].map((r) => r.text).join("")).toBe("secondplain");
    expect(lines[1][0].bold).toBe(true);
    expect(lines[1][0].fg).toBe("rgb(251, 191, 36)");
    expect(lines[1][1].bold).toBeUndefined();
    expect(lines[2]).toHaveLength(0);
    expect(lines[3].map((r) => r.text).join("")).toBe("end");
  });
});

describe("plainText", () => {
  it("returns plain text unchanged", () => {
    expect(plainText("hello world\nline two")).toBe("hello world\nline two");
  });

  it("strips SGR sequences", () => {
    expect(plainText(`${ESC}[1;31mred${ESC}[0m plain`)).toBe("red plain");
  });

  it("strips cursor sequences and OSC payloads", () => {
    expect(plainText(`a${ESC}[15;2Hb${ESC}]0;title${ESC}\\c`)).toBe("abc");
    expect(plainText(`a${ESC}]0;title\u0007b`)).toBe("ab");
  });

  it("drops unparseable escape bytes (same tolerance as the iOS parser)", () => {
    expect(plainText("abc\x1b")).toBe("abc");
    expect(plainText("abc\x1b[")).toBe("abc[");
  });
});
