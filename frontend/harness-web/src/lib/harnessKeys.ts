import type { HarnessKey } from "../api/types";

/**
 * iOS `HarnessKey.inputRows` (Models/HarnessUIEnums.swift) — every key here is
 * in the server's /api/send whitelist (`_HARNESS_ALLOWED_KEYS` in
 * cmux_harness/server.py), verified against the running server.
 *
 * - Row 0 is always visible in the input bar (iOS DetailInputBar).
 * - Row 1 is visible only when the action row is expanded (iOS DetailInputBar)
 *   and in the easy-mode keyboard (iOS EasyModeKeyboard renders both rows).
 */
export const HARNESS_KEY_ROWS: HarnessKey[][] = [
  ["up", "down", "tab", "enter"],
  ["left", "right", "escape", "backspace"],
];

/** iOS `HarnessKey.label` display names (verbatim). */
export const HARNESS_KEY_LABELS: Record<HarnessKey, string> = {
  up: "Up",
  down: "Down",
  tab: "Tab",
  enter: "Enter",
  left: "Left",
  right: "Right",
  escape: "Esc",
  backspace: "Bkspc",
};
