/**
 * Composer insert helpers (P9-run-B) — port of the Phase-1 appendPromptToken
 * / appendPromptBlock join semantics (space-separated tokens, blank-line
 * separated blocks).
 */

import type { JiraTicket } from "../api/tools";

/**
 * Token insert (file/skill refs): no trimming — an empty draft yields the
 * token as-is; a non-empty draft ending in whitespace gets the token
 * directly; otherwise a single space is inserted.
 */
export function appendPromptToken(token: string, draft: string): string {
  if (draft === "") {
    return token;
  }
  const last = draft.charAt(draft.length - 1);
  if (/\s/.test(last)) {
    return draft + token;
  }
  return draft + " " + token;
}

/** Block insert (Jira refs): both sides trimmed; an empty draft yields the block. */
export function appendPromptBlock(block: string, draft: string): string {
  const trimmedBlock = block.trim();
  const trimmedDraft = draft.trim();
  if (trimmedDraft === "") {
    return trimmedBlock;
  }
  return `${trimmedDraft}\n\n${trimmedBlock}`;
}

/**
 * Jira insert block (doc 01 §6, byte-exact):
 *   `Jira: <key> · <title>` / `Status: <s> · Priority: <p>` / `<url>`
 * The status line is omitted when both fields are empty; a present field
 * keeps its own label. Middle dot is U+00B7.
 */
export function formatJiraTicketInsert(
  ticket: Pick<JiraTicket, "key" | "title" | "status" | "priority" | "url">,
): string {
  const meta = [
    ticket.status !== "" ? `Status: ${ticket.status}` : null,
    ticket.priority !== "" ? `Priority: ${ticket.priority}` : null,
  ].filter((part): part is string => part !== null);
  return [`Jira: ${ticket.key} · ${ticket.title}`, ...(meta.length > 0 ? [meta.join(" · ")] : []), ticket.url].join("\n");
}
