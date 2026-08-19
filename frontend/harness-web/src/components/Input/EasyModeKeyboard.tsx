import {
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  CornerDownLeft,
  CornerDownRight,
  Delete,
  XSquare,
} from "lucide-react";
import type { HarnessKey } from "../../api/types";
import { HARNESS_KEY_LABELS, HARNESS_KEY_ROWS } from "../../lib/harnessKeys";

/**
 * Easy-mode keyboard (iOS EasyModeKeyboard.swift parity): a 2×4 grid of big
 * keys — both iOS `HarnessKey.inputRows` (row 1: up/down/tab/enter, row 2:
 * left/right/escape/backspace), every key in the server's /api/send whitelist.
 *
 * Shown instead of the InputBar while easy mode is on for the selected
 * workspace (iOS DetailTerminalLayout: `if isEasyModeEnabled { EasyModeKeyboard }
 * else { DetailInputBar }`, only when no active interaction card is showing).
 */

const KEY_ICONS: Record<HarnessKey, typeof ArrowUp> = {
  up: ArrowUp,
  down: ArrowDown,
  // SF Symbols arrow.right.to.line / return (↵)
  tab: CornerDownRight,
  enter: CornerDownLeft,
  left: ArrowLeft,
  right: ArrowRight,
  // SF Symbols x.square / delete.left
  escape: XSquare,
  backspace: Delete,
};

interface EasyModeKeyboardProps {
  onSendKey: (key: HarnessKey) => void;
  disabled?: boolean;
}

export function EasyModeKeyboard({ onSendKey, disabled = false }: EasyModeKeyboardProps) {
  return (
    <div className="easy-keyboard" role="group" aria-label="Easy mode keyboard">
      {HARNESS_KEY_ROWS.map((row, rowIndex) => (
        <div className="easy-keyboard-row" key={rowIndex}>
          {row.map((key) => {
            const Icon = KEY_ICONS[key];
            return (
              <button
                key={key}
                type="button"
                className="easy-key"
                title={`Send ${HARNESS_KEY_LABELS[key]} key`}
                aria-label={`Send ${HARNESS_KEY_LABELS[key]} key`}
                disabled={disabled}
                onClick={() => onSendKey(key)}
              >
                <Icon size={20} aria-hidden="true" />
                <span>{HARNESS_KEY_LABELS[key]}</span>
              </button>
            );
          })}
        </div>
      ))}
    </div>
  );
}
