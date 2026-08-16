import { describe, expect, it } from "vitest";
import type { JiraTicket } from "../api/types";
import { appendPromptBlock } from "./reviewPrompt";
import { formatJiraTicketPrompt } from "./jiraPrompt";

/**
 * Exact-text-critical: the expected strings below are the authoritative
 * outputs from the iOS app's Swift Testing suite
 * (`cmux_harness_iosTests/Feature/cmux_harness_iosTests.swift`,
 * `jiraLookupResolvesAnyKeyAndInsertsCompactMetadata`), using the same ticket
 * fixture ported 1:1. Any change to these strings breaks the web/iOS prompt
 * parity contract.
 */

/** 1:1 port of the iOS test fixture ticket (`WEB-42`). */
function ticket(overrides: Partial<JiraTicket> = {}): JiraTicket {
  return {
    key: "WEB-42",
    projectKey: "WEB",
    title: "Support exact Jira lookup",
    status: "In Progress",
    priority: "High",
    issueType: "Story",
    url: "https://example.atlassian.net/browse/WEB-42",
    ...overrides,
  };
}

describe("formatJiraTicketPrompt", () => {
  it("formats the full ticket exactly like iOS", () => {
    expect(formatJiraTicketPrompt(ticket())).toBe(
      [
        "Jira: WEB-42",
        "Title: Support exact Jira lookup",
        "URL: https://example.atlassian.net/browse/WEB-42",
        "Status: In Progress",
        "Priority: High",
        "Type: Story",
        "",
        "Please use this ticket as context.",
      ].join("\n"),
    );
  });

  it("appends to an existing draft with a blank-line separator (iOS test parity)", () => {
    // iOS test: draft "Existing context." + appendJiraTicketReference(ticket)
    expect(appendPromptBlock(formatJiraTicketPrompt(ticket()), "Existing context.")).toBe(
      [
        "Existing context.",
        "",
        "Jira: WEB-42",
        "Title: Support exact Jira lookup",
        "URL: https://example.atlassian.net/browse/WEB-42",
        "Status: In Progress",
        "Priority: High",
        "Type: Story",
        "",
        "Please use this ticket as context.",
      ].join("\n"),
    );
  });

  it("uses (no title) for an empty title", () => {
    expect(formatJiraTicketPrompt(ticket({ title: "" }))).toBe(
      [
        "Jira: WEB-42",
        "Title: (no title)",
        "URL: https://example.atlassian.net/browse/WEB-42",
        "Status: In Progress",
        "Priority: High",
        "Type: Story",
        "",
        "Please use this ticket as context.",
      ].join("\n"),
    );
  });

  it("omits empty status/priority/type lines (Swift isEmpty, no trim)", () => {
    expect(
      formatJiraTicketPrompt(
        ticket({
          status: "",
          priority: "",
          issueType: "",
          key: "WEB-1",
          title: "Bare",
          url: "https://example.atlassian.net/browse/WEB-1",
        }),
      ),
    ).toBe(
      [
        "Jira: WEB-1",
        "Title: Bare",
        "URL: https://example.atlassian.net/browse/WEB-1",
        "",
        "Please use this ticket as context.",
      ].join("\n"),
    );
  });
});
