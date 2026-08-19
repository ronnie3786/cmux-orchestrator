/**
 * Terminal color palette — faithful port of `TerminalGrid.indexedColor(for:)`
 * (herdr-harness-ios/.../Models/TerminalGrid.swift).
 *
 * The 16 base colors are copied VERBATIM from the Swift file (they are the
 * app's custom palette, NOT the classic VGA base and NOT harness-web's
 * phase-1 ANSI palette). The 216-color cube and 24-step gray ramp mirror the
 * Swift integer math 1:1.
 */

export interface RGB {
  r: number;
  g: number;
  b: number;
}

/** 16 base colors — copied verbatim from `TerminalGrid.indexedColor(for:)`. */
export const BASE_COLORS: RGB[] = [
  { r: 0, g: 0, b: 0 },
  { r: 205, g: 49, b: 49 },
  { r: 13, g: 188, b: 121 },
  { r: 229, g: 229, b: 16 },
  { r: 36, g: 114, b: 200 },
  { r: 188, g: 63, b: 188 },
  { r: 17, g: 168, b: 205 },
  { r: 229, g: 229, b: 229 },
  { r: 102, g: 102, b: 102 },
  { r: 241, g: 76, b: 76 },
  { r: 35, g: 209, b: 139 },
  { r: 245, g: 245, b: 67 },
  { r: 59, g: 142, b: 234 },
  { r: 214, g: 112, b: 214 },
  { r: 41, g: 184, b: 219 },
  { r: 255, g: 255, b: 255 },
];

/** Port of `indexedColor(_ index: Int)`: clamps to 0...255, then base/cube/ramp. */
export function indexedColor(index: number): RGB {
  const clampedIndex = Math.min(Math.max(index, 0), 255);
  if (clampedIndex < 16) {
    return BASE_COLORS[clampedIndex];
  }
  if (clampedIndex < 232) {
    const value = clampedIndex - 16;
    const levels = [0, 95, 135, 175, 215, 255];
    // Swift integer division: levels[value / 36], levels[(value / 6) % 6].
    return {
      r: levels[Math.floor(value / 36)],
      g: levels[Math.floor(value / 6) % 6],
      b: levels[value % 6],
    };
  }
  const gray = 8 + (clampedIndex - 232) * 10;
  return { r: gray, g: gray, b: gray };
}

/** RGB → CSS color string (the web substitute for SwiftUI `Color(red:green:blue:)`). */
export function rgbToCss(color: RGB): string {
  return `rgb(${color.r}, ${color.g}, ${color.b})`;
}
