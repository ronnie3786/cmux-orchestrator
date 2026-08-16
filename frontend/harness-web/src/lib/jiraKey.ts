/**
 * Port of the iOS `jiraKey(from:)` helper (HarnessFeatureHelpers.swift):
 * the first `[A-Z]+-\d+` match, searched case-insensitively and returned
 * uppercased. Returns `null` when the text has no ticket key.
 */
const JIRA_KEY_PATTERN = /[A-Z]+-\d+/i;

export function jiraKey(text: string): string | null {
  const match = text.match(JIRA_KEY_PATTERN);
  return match ? match[0].toUpperCase() : null;
}
