/**
 * Pure logic for the skill autocomplete panel (iOS SkillAutocompleteViews.swift
 * parity — `SkillAutocompleteContext`, the filter in DetailInputBar, and
 * `replaceSkillToken`).
 *
 * Trigger rules (port of `SkillAutocompleteContext.init?(draft:selection:)`):
 * - the token is the run of characters from the start of the draft or the last
 *   whitespace before the cursor, up to the cursor;
 * - the token must be non-empty and its FIRST character must be `/` (Claude
 *   Code) or `$` (Codex CLI);
 * - the query is the token minus the trigger character (empty right after the
 *   trigger → unfiltered list);
 * - `signature` (`"<tokenStart>:<token>"`, iOS parity) identifies the current
 *   token so a cancel dismissal survives re-renders but clears on any edit.
 */

export interface SkillAutocompleteContext {
  /** Offset of the trigger character in the draft. */
  tokenStart: number;
  /** Cursor offset (one past the last typed token character). */
  cursor: number;
  /** Token text after the trigger character. */
  query: string;
  /** The trigger character. */
  invocationPrefix: "/" | "$";
  /** Stable identity for the current token (iOS `signature`). */
  signature: string;
}

/**
 * Compute the autocomplete context for the current draft + cursor.
 *
 * @param draft Full draft text.
 * @param cursor Caret offset (textarea `selectionStart`; the iOS default when
 *   no selection is known is the end of the draft).
 */
export function computeSkillAutocompleteContext(
  draft: string,
  cursor: number,
): SkillAutocompleteContext | null {
  // iOS: guard !draft.isEmpty
  if (draft.length === 0) return null;

  const clamped = Math.max(0, Math.min(cursor, draft.length));
  // iOS: guard cursor > draft.startIndex
  if (clamped <= 0) return null;

  const prefix = draft.slice(0, clamped);
  let tokenStart = 0;
  for (let i = clamped - 1; i >= 0; i -= 1) {
    if (/\s/.test(prefix[i])) {
      tokenStart = i + 1;
      break;
    }
  }
  // iOS: guard tokenStart < cursor
  if (tokenStart >= clamped) return null;

  const trigger = draft[tokenStart];
  // iOS: guard trigger == "/" || trigger == "$"
  if (trigger !== "/" && trigger !== "$") return null;

  const token = draft.slice(tokenStart, clamped);
  // iOS: guard !token.contains(where: \.isWhitespace)
  // (redundant given tokenStart sits after the last whitespace, kept for parity)
  if (/\s/.test(token)) return null;

  return {
    tokenStart,
    cursor: clamped,
    query: token.slice(1),
    invocationPrefix: trigger,
    signature: `${tokenStart}:${token}`,
  };
}

/**
 * iOS `filteredSkillSuggestions(for:)` — case-insensitive substring match on
 * the skill name (empty query = unfiltered), capped at 3 (iOS `.prefix(3)`).
 */
export function filterSkillSuggestions<T extends { name: string }>(
  skills: ReadonlyArray<T>,
  query: string,
): T[] {
  const q = query.toLowerCase();
  const filtered = q.length === 0 ? skills : skills.filter((skill) => skill.name.toLowerCase().includes(q));
  return filtered.slice(0, 3);
}

export interface SkillTokenReplacement {
  draft: string;
  cursor: number;
}

/**
 * iOS `replaceSkillToken(_:with:)` — replace the token range with
 * `<invocationPrefix><skill name>` (NO trailing space — iOS parity) and place
 * the caret right after the replacement.
 */
export function replaceSkillToken(
  draft: string,
  context: SkillAutocompleteContext,
  skillName: string,
): SkillTokenReplacement {
  const replacement = `${context.invocationPrefix}${skillName}`;
  const nextDraft = draft.slice(0, context.tokenStart) + replacement + draft.slice(context.cursor);
  // iOS: cursorOffset = distance(start, range.lowerBound) + replacement.count
  return { draft: nextDraft, cursor: context.tokenStart + replacement.length };
}
