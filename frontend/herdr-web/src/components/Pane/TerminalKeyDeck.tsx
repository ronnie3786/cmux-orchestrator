/**
 * Terminal key deck (P9-run-A) — the 8-key row of the iOS `TerminalKeyDeck`
 * (doc 01 §4.3/§6). Labels are byte-exact; each key's label doubles as the
 * send-keys token (the cmux layer lowercases/aliases key names server-side).
 * No Interrupt button here — that is a menu action (P10).
 */

export const KEY_DECK = ["Up", "Down", "Tab", "Enter", "Left", "Right", "Esc", "Bkspc"] as const;

export type PaneKey = (typeof KEY_DECK)[number];

export interface TerminalKeyDeckProps {
  /** False (visually + functionally) when the connection is not Live/Demo. */
  enabled: boolean;
  onKey: (key: PaneKey) => void;
}

export function TerminalKeyDeck({ enabled, onKey }: TerminalKeyDeckProps) {
  return (
    <div className="hz-pane-keydeck" role="group" aria-label="Terminal keys">
      {KEY_DECK.map((key) => (
        <button
          key={key}
          type="button"
          className="hz-pane-key"
          aria-label={`${key} key`}
          disabled={!enabled}
          onClick={() => onKey(key)}
        >
          {key}
        </button>
      ))}
    </div>
  );
}
