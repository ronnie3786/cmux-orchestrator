/**
 * Formatted Jira ticket context block for the detail input row.
 *
 * EXACT TEXT PARITY (exact-text-critical): the string produced here is sent
 * to coding agents verbatim, so it must match the iOS app's
 * `HarnessFeatureHelpers.formatJiraTicketPrompt` (HarnessFeatureHelpers.swift:103)
 * byte-for-byte. The authoritative expected string is the iOS test
 * `jiraLookupResolvesAnyKeyAndInsertsCompactMetadata`
 * (cmux_harness_iosTests/Feature/cmux_harness_iosTests.swift).
 */
import type { JiraTicket } from "../api/types";

/**
 * Exact port of `formatJiraTicketPrompt(_ ticket: JiraTicket) -> String`.
 *
 * Rules (mirror the Swift line by line):
 * - `Title:` falls back to `(no title)` only for an empty title (Swift uses
 *   `isEmpty`, not a trim).
 * - `Status:` / `Priority:` / `Type:` lines are omitted when the field is
 *   empty (also `isEmpty` — no trim).
 * - The metadata block is followed by a blank line and
 *   `Please use this ticket as context.` — joined with "\n", no trailing
 *   newline.
 */
export function formatJiraTicketPrompt(ticket: JiraTicket): string {
  const lines = [
    `Jira: ${ticket.key}`,
    `Title: ${ticket.title === "" ? "(no title)" : ticket.title}`,
    `URL: ${ticket.url}`,
  ];
  if (ticket.status !== "") {
    lines.push(`Status: ${ticket.status}`);
  }
  if (ticket.priority !== "") {
    lines.push(`Priority: ${ticket.priority}`);
  }
  if (ticket.issueType !== "") {
    lines.push(`Type: ${ticket.issueType}`);
  }
  lines.push("");
  lines.push("Please use this ticket as context.");
  return lines.join("\n");
}
