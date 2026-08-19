/**
 * ANSI escape-sequence parser + terminal palette.
 *
 * Faithful port of the iOS app's `ANSIParser` + `TerminalPalette`
 * (cmux-harness-ios/.../Views/Shared/TerminalTextStyler.swift). The web app is
 * dark-only, so the dark palette values are baked in. The iOS app additionally
 * runs a "semantic" highlighter over the styled runs (OpenCode-specific
 * decorations); that layer is intentionally out of scope for v1.
 */

export type NamedColor =
  | "black"
  | "red"
  | "green"
  | "yellow"
  | "blue"
  | "magenta"
  | "cyan"
  | "white"
  | "brightBlack"
  | "brightRed"
  | "brightGreen"
  | "brightYellow"
  | "brightBlue"
  | "brightMagenta"
  | "brightCyan"
  | "brightWhite";

export interface Run {
  text: string;
  /** CSS color for the foreground; undefined = terminal default foreground. */
  fg?: string;
  /** CSS color for the background. */
  bg?: string;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  /**
   * Reserved for API parity with the planned run shape. The iOS parser does
   * not handle SGR 9/29 (strikethrough), so this is never set today.
   */
  strikethrough?: boolean;
}

type ColorSpec =
  | { kind: "named"; name: NamedColor }
  | { kind: "rgb"; r: number; g: number; b: number };

interface TextStyle {
  foreground: ColorSpec | null;
  background: ColorSpec | null;
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
}

interface StyledRun {
  text: string;
  style: TextStyle;
}

const ESC = "\u001b";

// MARK: - Palette (dark scheme — ported from TerminalPalette)

const NAMED_FOREGROUNDS: Record<NamedColor, string> = {
  black: "#546178",
  red: "#F87171",
  green: "#34D399",
  yellow: "#FBBF24",
  blue: "#60A5FA",
  magenta: "#C084FC",
  cyan: "#22D3EE",
  white: "#E2E8F0",
  brightBlack: "#7A8BA4",
  brightRed: "#FCA5A5",
  brightGreen: "#6EE7B7",
  brightYellow: "#FDE68A",
  brightBlue: "#93C5FD",
  brightMagenta: "#D8B4FE",
  brightCyan: "#67E8F9",
  brightWhite: "#F8FAFC",
};

/**
 * Named background colors (dark scheme), ported from `backgroundColor(for:)`:
 * solid slates for black/brightBlack, 0.25-opacity tints of the foreground
 * colors for the rest.
 */
const NAMED_BACKGROUNDS: Record<NamedColor, string> = {
  black: "#1E293B",
  brightBlack: "#334155",
  red: "rgba(248, 113, 113, 0.25)",
  brightRed: "rgba(248, 113, 113, 0.25)",
  green: "rgba(52, 211, 153, 0.25)",
  brightGreen: "rgba(52, 211, 153, 0.25)",
  yellow: "rgba(251, 191, 36, 0.25)",
  brightYellow: "rgba(251, 191, 36, 0.25)",
  blue: "rgba(96, 165, 250, 0.25)",
  brightBlue: "rgba(96, 165, 250, 0.25)",
  magenta: "rgba(192, 132, 252, 0.25)",
  brightMagenta: "rgba(192, 132, 252, 0.25)",
  cyan: "rgba(34, 211, 238, 0.25)",
  brightCyan: "rgba(34, 211, 238, 0.25)",
  white: "rgba(226, 232, 240, 0.25)",
  brightWhite: "rgba(226, 232, 240, 0.25)",
};

/** Default foreground for the dark scheme (0xD8DDE8). */
const DEFAULT_FG: [number, number, number] = [0xd8, 0xdd, 0xe8];

/** Truecolor backgrounds render at 0.35 opacity (dark scheme). */
const RGB_BACKGROUND_ALPHA = 0.35;
/** Dim (SGR 2) runs render the foreground at 0.6 opacity. */
const DIM_ALPHA = 0.6;

const FG_CODES: Record<number, NamedColor> = {
  30: "black",
  31: "red",
  32: "green",
  33: "yellow",
  34: "blue",
  35: "magenta",
  36: "cyan",
  37: "white",
  90: "brightBlack",
  91: "brightRed",
  92: "brightGreen",
  93: "brightYellow",
  94: "brightBlue",
  95: "brightMagenta",
  96: "brightCyan",
  97: "brightWhite",
};

function clamp(value: number): number {
  return Math.min(255, Math.max(0, value));
}

function hexToRgb(hex: string): [number, number, number] {
  return [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16),
  ];
}

// MARK: - SGR application (ported from `TerminalTextStyle.applySGR`)

function freshStyle(): TextStyle {
  return {
    foreground: null,
    background: null,
    bold: false,
    dim: false,
    italic: false,
    underline: false,
  };
}

/**
 * Port of `rgbForANSI256`: 0-15 are the fixed VGA base colors (not the app
 * palette), 16-231 the 6x6x6 cube, 232-255 the grayscale ramp.
 */
function rgbForANSI256(value: number): [number, number, number] | null {
  if (value < 0 || value > 255) return null;
  const baseColors: [number, number, number][] = [
    [0, 0, 0],
    [128, 0, 0],
    [0, 128, 0],
    [128, 128, 0],
    [0, 0, 128],
    [128, 0, 128],
    [0, 128, 128],
    [192, 192, 192],
    [128, 128, 128],
    [255, 0, 0],
    [0, 255, 0],
    [255, 255, 0],
    [0, 0, 255],
    [255, 0, 255],
    [0, 255, 255],
    [255, 255, 255],
  ];
  if (value < baseColors.length) return baseColors[value];
  if (value >= 232) {
    const level = 8 + (value - 232) * 10;
    return [level, level, level];
  }
  const cubeIndex = value - 16;
  const levels = [0, 95, 135, 175, 215, 255];
  return [
    levels[Math.floor(cubeIndex / 36)],
    levels[Math.floor((cubeIndex % 36) / 6)],
    levels[cubeIndex % 6],
  ];
}

/**
 * Port of `ANSIParser.extendedColor`: reads `5;n` or `2;r;g;b` starting at the
 * index of the format code. Returns null when parameters are missing or the
 * value is out of range — the current color is left untouched and the caller
 * does not skip the consumed parameters, exactly like the iOS parser.
 */
function extendedColor(
  codes: number[],
  startingAt: number,
): { value: ColorSpec; nextIndex: number } | null {
  if (startingAt >= codes.length) return null;
  const format = codes[startingAt];
  if (format === 5) {
    if (startingAt + 1 >= codes.length) return null;
    const rgb = rgbForANSI256(codes[startingAt + 1]);
    if (!rgb) return null;
    return { value: { kind: "rgb", r: rgb[0], g: rgb[1], b: rgb[2] }, nextIndex: startingAt + 2 };
  }
  if (format === 2) {
    if (startingAt + 3 >= codes.length) return null;
    return {
      value: {
        kind: "rgb",
        r: codes[startingAt + 1],
        g: codes[startingAt + 2],
        b: codes[startingAt + 3],
      },
      nextIndex: startingAt + 4,
    };
  }
  return null;
}

function applySGR(style: TextStyle, codes: number[]): TextStyle {
  if (codes.length === 0) return freshStyle();
  let next: TextStyle = { ...style };
  let index = 0;
  while (index < codes.length) {
    const code = codes[index];
    switch (code) {
      case 0:
        next = freshStyle();
        break;
      case 1:
        next.bold = true;
        break;
      case 2:
        next.dim = true;
        break;
      case 3:
        next.italic = true;
        break;
      case 4:
        next.underline = true;
        break;
      case 22:
        next.bold = false;
        next.dim = false;
        break;
      case 23:
        next.italic = false;
        break;
      case 24:
        next.underline = false;
        break;
      case 39:
        next.foreground = null;
        break;
      case 49:
        next.background = null;
        break;
      case 38:
      case 48: {
        const color = extendedColor(codes, index + 1);
        if (color) {
          if (code === 38) next.foreground = color.value;
          else next.background = color.value;
          // Skip the parameters that were consumed by the extended color.
          index = color.nextIndex - 1;
        }
        break;
      }
      default: {
        if ((code >= 30 && code <= 37) || (code >= 90 && code <= 97)) {
          next.foreground = { kind: "named", name: FG_CODES[code] };
        } else if ((code >= 40 && code <= 47) || (code >= 100 && code <= 107)) {
          next.background = { kind: "named", name: FG_CODES[code - 10] };
        }
        // Unknown codes are ignored.
      }
    }
    index += 1;
  }
  return next;
}

// MARK: - Sequence scanning (ported from `controlSequence` / `operatingSystemCommandEnd`)

interface ControlSequence {
  params: string;
  final: string;
  /** Index just past the sequence. */
  end: number;
}

/** Port of `ANSIParser.controlSequence` — a CSI sequence (`ESC [` … final). */
function controlSequence(raw: string, escapeIndex: number): ControlSequence | null {
  const afterEscape = escapeIndex + 1;
  if (afterEscape >= raw.length || raw[afterEscape] !== "[") return null;
  let scan = afterEscape + 1;
  const parameterStart = scan;
  while (scan < raw.length) {
    const code = raw.charCodeAt(scan);
    if (code >= 0x40 && code <= 0x7e) {
      return { params: raw.slice(parameterStart, scan), final: raw[scan], end: scan + 1 };
    }
    scan += 1;
  }
  return null;
}

/**
 * Port of `ANSIParser.operatingSystemCommandEnd` — finds the end of an OSC
 * sequence (`ESC ]` … BEL or `ESC \`). An unterminated OSC consumes the rest
 * of the input. Returns null when the bytes are not an OSC sequence.
 */
function operatingSystemCommandEnd(raw: string, escapeIndex: number): number | null {
  const afterEscape = escapeIndex + 1;
  if (afterEscape >= raw.length || raw[afterEscape] !== "]") return null;
  let scan = afterEscape + 1;
  while (scan < raw.length) {
    if (raw[scan] === "\u0007") return scan + 1; // BEL
    if (raw[scan] === ESC) {
      const next = scan + 1;
      if (next < raw.length && raw[next] === "\\") return next + 1; // ST
    }
    scan += 1;
  }
  return raw.length;
}

// MARK: - Run building (ported from `ANSIParser.parse`)

function sgrCodes(params: string): number[] {
  if (params.length === 0) return [0];
  // JS String.split keeps trailing empty subsequences, matching
  // Swift's split(separator: ";", omittingEmptySubsequences: false).
  return params.split(";").map((part) => {
    const n = Number.parseInt(part, 10);
    return Number.isNaN(n) ? 0 : n;
  });
}

function sameStyle(a: TextStyle, b: TextStyle): boolean {
  return (
    a.bold === b.bold &&
    a.dim === b.dim &&
    a.italic === b.italic &&
    a.underline === b.underline &&
    sameColor(a.foreground, b.foreground) &&
    sameColor(a.background, b.background)
  );
}

function sameColor(a: ColorSpec | null, b: ColorSpec | null): boolean {
  if (!a && !b) return true;
  if (!a || !b) return false;
  if (a.kind !== b.kind) return false;
  if (a.kind === "named") {
    return b.kind === "named" && a.name === b.name;
  }
  return b.kind === "rgb" && a.r === b.r && a.g === b.g && a.b === b.b;
}

/** Port of `ANSIParser.coalesce` — merges adjacent runs with equal styles. */
function coalesce(runs: StyledRun[]): StyledRun[] {
  const result: StyledRun[] = [];
  for (const run of runs) {
    if (!run.text) continue;
    const last = result[result.length - 1];
    if (last && sameStyle(last.style, run.style)) {
      last.text += run.text;
    } else {
      result.push({ text: run.text, style: run.style });
    }
  }
  return result;
}

function parseRuns(raw: string, initialStyle: TextStyle): StyledRun[] {
  const runs: StyledRun[] = [];
  let style = initialStyle;
  let buffer = "";

  const flush = () => {
    if (!buffer) return;
    runs.push({ text: buffer, style });
    buffer = "";
  };

  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (ch !== ESC) {
      buffer += ch;
      continue;
    }
    const csi = controlSequence(raw, i);
    if (csi) {
      flush();
      if (csi.final === "m") {
        style = applySGR(style, sgrCodes(csi.params));
      }
      i = csi.end - 1;
      continue;
    }
    const osc = operatingSystemCommandEnd(raw, i);
    if (osc !== null) {
      flush();
      i = osc - 1;
      continue;
    }
    // Unrecognized escape: drop the ESC byte and continue (iOS behavior).
  }
  flush();
  return coalesce(runs);
}

// MARK: - Run materialization (ported from TerminalPalette rendering)

interface MaterializedStyle {
  fg?: string;
  bg?: string;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
}

function materialize(style: TextStyle): MaterializedStyle {
  const out: MaterializedStyle = {};
  if (style.bold) out.bold = true;
  if (style.italic) out.italic = true;
  if (style.underline) out.underline = true;

  // iOS dims the resolved foreground (including the default color) at 0.6.
  if (style.dim || style.foreground) {
    let rgb: [number, number, number];
    if (style.foreground) {
      if (style.foreground.kind === "named") {
        rgb = hexToRgb(NAMED_FOREGROUNDS[style.foreground.name]);
      } else {
        rgb = [
          clamp(style.foreground.r),
          clamp(style.foreground.g),
          clamp(style.foreground.b),
        ];
      }
    } else {
      rgb = DEFAULT_FG;
    }
    out.fg = style.dim
      ? `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, ${DIM_ALPHA})`
      : `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})`;
  }

  if (style.background) {
    if (style.background.kind === "named") {
      out.bg = NAMED_BACKGROUNDS[style.background.name];
    } else {
      out.bg = `rgba(${clamp(style.background.r)}, ${clamp(style.background.g)}, ${clamp(
        style.background.b,
      )}, ${RGB_BACKGROUND_ALPHA})`;
    }
  }
  return out;
}

function toRun(run: StyledRun): Run {
  return { text: run.text, ...materialize(run.style) };
}

// MARK: - Public API

/**
 * Renders a single line with a fresh SGR state. Use {@link renderANSIBlock}
 * for multi-line text so SGR state carries across lines the way a real
 * terminal does (the iOS app styles the entire screen in one pass).
 */
export function renderANSI(line: string): Run[] {
  return parseRuns(line, freshStyle()).map(toRun);
}

/**
 * Renders a full screen of text in a single pass (SGR state persists across
 * lines, matching the iOS app's attributed-string path) and splits the result
 * into per-line run arrays.
 */
export function renderANSIBlock(text: string): Run[][] {
  const runs = parseRuns(text, freshStyle()).map(toRun);
  const lines: Run[][] = [[]];
  let line = lines[0];
  for (const run of runs) {
    const segments = run.text.split("\n");
    for (let i = 0; i < segments.length; i++) {
      if (i > 0) {
        line = [];
        lines.push(line);
      }
      const segment = segments[i];
      if (segment.length > 0) {
        line.push({
          text: segment,
          fg: run.fg,
          bg: run.bg,
          bold: run.bold,
          italic: run.italic,
          underline: run.underline,
        });
      }
    }
  }
  return lines;
}

/** Strips every ANSI control sequence, keeping the plain text. */
export function plainText(text: string): string {
  return parseRuns(text, freshStyle())
    .map((run) => run.text)
    .join("");
}
