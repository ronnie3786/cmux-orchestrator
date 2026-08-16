import { Sparkles, X } from "lucide-react";
import type { ProjectSkill } from "../../api/types";

/**
 * Skill autocomplete panel (iOS SkillAutocompleteViews.swift `SkillAutocompletePanel`
 * parity). Thin display component: the keyboard handling (arrows / Enter / Esc)
 * lives in the InputBar's textarea, which owns focus; this panel receives the
 * highlighted row and the select/cancel callbacks.
 *
 * Placement matches iOS: the panel renders ABOVE the main input row inside the
 * input bar (iOS puts it at the top of the DetailInputBar VStack).
 */

interface SkillAutocompleteProps {
  suggestions: ProjectSkill[];
  invocationPrefix: "/" | "$";
  /** Index of the keyboard-highlighted suggestion. */
  highlight: number;
  onSelect: (skill: ProjectSkill) => void;
  onCancel: () => void;
}

export function SkillAutocomplete({
  suggestions,
  invocationPrefix,
  highlight,
  onSelect,
  onCancel,
}: SkillAutocompleteProps) {
  return (
    <div className="input-bar-autocomplete" role="listbox" aria-label="Skill suggestions">
      <div className="input-bar-autocomplete-header">
        <Sparkles size={12} aria-hidden="true" className="input-bar-autocomplete-icon" />
        <span>Skills</span>
        <button
          type="button"
          className="input-bar-autocomplete-cancel"
          onClick={onCancel}
        >
          <X size={10} aria-hidden="true" />
          Cancel
        </button>
      </div>
      {suggestions.map((skill, index) => (
        <button
          key={`${skill.scope ?? "skill"}:${skill.name}`}
          type="button"
          role="option"
          aria-selected={index === highlight}
          className={`input-bar-autocomplete-row${index === highlight ? " input-bar-autocomplete-row-active" : ""}`}
          onMouseDown={(event) => {
            // Click without stealing the textarea's focus first.
            event.preventDefault();
            onSelect(skill);
          }}
        >
          <span className="input-bar-autocomplete-name">
            {invocationPrefix}
            {skill.name}
          </span>
          <span className="input-bar-autocomplete-scope">
            {skill.scope === "user" ? "User" : "Project"}
          </span>
        </button>
      ))}
    </div>
  );
}
