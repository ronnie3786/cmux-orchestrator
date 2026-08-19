/**
 * Thinking-level chip (P8-run-B) — web port of
 * `herdr-harness-ios/Views/Pane/PiThinkingLevelChip.swift`: chip label =
 * current level display name (lowercase "thinking" fallback), popover
 * lists the 7 canonical levels (byte-exact: Off / Minimal / Low / Medium
 * / High / Extra High / Max), select → piStore.setThinkingLevel.
 *
 * On a failed selection (e.g. 501 → "Thinking control isn't supported by
 * this Pi session") the server error string (store `lastError`) is shown
 * as a muted line in the popover.
 */
import { useState } from "react";
import { PI_THINKING_LEVELS, piThinkingLevelDisplayName } from "../../pi/types";
import { piThinkingLevelChipText } from "../../pi/modelCatalog";
import { usePiStore } from "../../store/piStore";

export interface ThinkingChipProps {
  thinkingLevel: string | null;
  isSettingThinkingLevel: boolean;
  /** Swift `isEnabled` = configuration.canSelectThinkingLevel. */
  isEnabled: boolean;
}

export function ThinkingChip({
  thinkingLevel,
  isSettingThinkingLevel,
  isEnabled,
}: ThinkingChipProps) {
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selectLevel = async (level: (typeof PI_THINKING_LEVELS)[number]): Promise<void> => {
    setOpen(false);
    const succeeded = await usePiStore.getState().setThinkingLevel(level);
    if (!succeeded) {
      const lastError = usePiStore.getState().lastError;
      if (lastError !== null) setError(lastError);
    }
  };

  return (
    <span className="hz-pi-chip-wrap" data-pi-thinking-chip>
      <button
        type="button"
        className={`hz-pi-chip${isEnabled ? "" : " hz-pi-chip-disabled"}`}
        aria-expanded={open}
        aria-label={`Thinking level: ${piThinkingLevelChipText(thinkingLevel)}`}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="hz-pi-chip-icon" aria-hidden>
          {isSettingThinkingLevel ? "…" : "◐"}
        </span>
        <span className="hz-pi-chip-label">{piThinkingLevelChipText(thinkingLevel)}</span>
        <span className="hz-pi-chip-caret" aria-hidden>
          ▾
        </span>
      </button>
      {open && (
        <span className="hz-pi-chip-menu" role="menu">
          {PI_THINKING_LEVELS.map((level) => (
            <button
              key={level}
              type="button"
              role="menuitem"
              className={`hz-pi-chip-item${
                thinkingLevel === level ? " hz-pi-chip-item-current" : ""
              }`}
              onClick={() => void selectLevel(level)}
            >
              {piThinkingLevelDisplayName(level)}
            </button>
          ))}
          {error !== null && (
            <span className="hz-pi-chip-muted" role="alert">
              {error}
            </span>
          )}
        </span>
      )}
    </span>
  );
}
