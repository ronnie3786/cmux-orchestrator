import { describe, expect, it } from "vitest";
import { jiraKey } from "./jiraKey";

describe("jiraKey (iOS HarnessFeatureHelpers parity)", () => {
  it("extracts the key from a Jira browse URL", () => {
    expect(jiraKey("https://doximity.atlassian.net/browse/IOSDOX-123")).toBe("IOSDOX-123");
  });

  it("is case-insensitive and uppercases the match", () => {
    expect(jiraKey("fix iosdox-1234 please")).toBe("IOSDOX-1234");
  });

  it("returns the first match", () => {
    expect(jiraKey("AB-9 and IOSDOX-123")).toBe("AB-9");
  });

  it("stops digits at the first non-digit character", () => {
    expect(jiraKey("IOSDOX-12abc")).toBe("IOSDOX-12");
  });

  it("matches single-letter prefixes (case-insensitive A-Z+)", () => {
    expect(jiraKey("a-1")).toBe("A-1");
  });

  it("returns null without digits", () => {
    expect(jiraKey("IOSDOX-")).toBeNull();
    expect(jiraKey("IOSDOX")).toBeNull();
  });

  it("returns null for empty text", () => {
    expect(jiraKey("")).toBeNull();
  });
});
