import { describe, expect, it } from "vitest";
import { appendPromptBlock, appendPromptToken, formatJiraTicketInsert } from "./promptInsert";

describe("appendPromptToken", () => {
  it("appends the token as-is to an empty draft", () => {
    expect(appendPromptToken("`src/main.swift`", "")).toBe("`src/main.swift`");
  });

  it("appends directly to a draft ending in whitespace", () => {
    expect(appendPromptToken("token", "draft ")).toBe("draft token");
    expect(appendPromptToken("token", "draft\n")).toBe("draft\ntoken");
  });

  it("inserts a single space otherwise", () => {
    expect(appendPromptToken("token", "draft")).toBe("draft token");
  });
});

describe("appendPromptBlock", () => {
  it("yields the trimmed block for an empty draft", () => {
    expect(appendPromptBlock("  line\nline2  ", "")).toBe("line\nline2");
    expect(appendPromptBlock("  line  ", "   \n  ")).toBe("line");
  });

  it("joins a non-empty draft with a blank line", () => {
    expect(appendPromptBlock("Jira: A-1 · t", "Existing context.")).toBe(
      "Existing context.\n\nJira: A-1 · t",
    );
  });
});

describe("formatJiraTicketInsert (doc 01 §6 byte-exact)", () => {
  const ticket = {
    key: "IOSDOX-1",
    title: "Fix the thing",
    status: "In Progress",
    priority: "High",
    url: "https://doximity.atlassian.net/browse/IOSDOX-1",
  };

  it("renders all three lines with the U+00B7 middle dot", () => {
    expect(formatJiraTicketInsert(ticket)).toBe(
      "Jira: IOSDOX-1 · Fix the thing\nStatus: In Progress · Priority: High\nhttps://doximity.atlassian.net/browse/IOSDOX-1",
    );
  });

  it("omits the status line when both fields are empty", () => {
    expect(
      formatJiraTicketInsert({ ...ticket, status: "", priority: "" }),
    ).toBe("Jira: IOSDOX-1 · Fix the thing\nhttps://doximity.atlassian.net/browse/IOSDOX-1");
  });

  it("keeps a present field with its own label", () => {
    expect(formatJiraTicketInsert({ ...ticket, status: "", priority: "High" })).toBe(
      "Jira: IOSDOX-1 · Fix the thing\nPriority: High\nhttps://doximity.atlassian.net/browse/IOSDOX-1",
    );
  });
});
