/**
 * Composer aux bar (P9-run-A) — the chip row of the iOS
 * `ComposerAuxiliaryBar` (doc 01 §6): "attach" "voice" "@ file" "jira".
 *
 * This run ships the chips only (their modals land in run-B): "voice" is
 * disabled with no action (v1 decision); the other chips report their name
 * through `onAction` so run-B can attach the modals.
 */

export const AUX_CHIPS = ["attach", "voice", "@ file", "jira"] as const;

export type AuxChip = (typeof AUX_CHIPS)[number];
export type AuxActionName = Exclude<AuxChip, "voice">;

export interface ComposerAuxBarProps {
  onAction: (name: AuxActionName) => void;
}

export function ComposerAuxBar({ onAction }: ComposerAuxBarProps) {
  return (
    <div className="hz-pane-aux">
      {AUX_CHIPS.map((chip) => (
        <button
          key={chip}
          type="button"
          className="hz-pane-aux-chip"
          disabled={chip === "voice"}
          onClick={chip === "voice" ? undefined : () => onAction(chip)}
        >
          {chip}
        </button>
      ))}
    </div>
  );
}
