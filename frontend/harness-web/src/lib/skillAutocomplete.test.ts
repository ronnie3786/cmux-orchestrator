import { describe, expect, it } from "vitest";
import {
  computeSkillAutocompleteContext,
  filterSkillSuggestions,
  replaceSkillToken,
  type SkillAutocompleteContext,
} from "./skillAutocomplete";

/**
 * Parity tests for the skill autocomplete pure logic (iOS
 * SkillAutocompleteViews.swift `SkillAutocompleteContext`, the filter in
 * DetailInputBar, and `replaceSkillToken`).
 */

describe("computeSkillAutocompleteContext", () => {
  it("returns null for an empty draft", () => {
    expect(computeSkillAutocompleteContext("", 0)).toBeNull();
  });

  it("returns null when the caret is at the very start (iOS: cursor > startIndex)", () => {
    expect(computeSkillAutocompleteContext("/skill", 0)).toBeNull();
  });

  it("triggers on a bare `/` at the start of the draft (empty query)", () => {
    const context = computeSkillAutocompleteContext("/", 1);
    expect(context).not.toBeNull();
    expect(context).toMatchObject({
      tokenStart: 0,
      cursor: 1,
      query: "",
      invocationPrefix: "/",
      signature: "0:/",
    });
  });

  it("triggers on a `$` token (Codex CLI prefix)", () => {
    const context = computeSkillAutocompleteContext("$skill", 6);
    expect(context).toMatchObject({
      tokenStart: 0,
      query: "skill",
      invocationPrefix: "$",
      signature: "0:$skill",
    });
  });

  it("triggers at a token start after whitespace", () => {
    const context = computeSkillAutocompleteContext("run /ios-re", 11);
    expect(context).not.toBeNull();
    expect(context).toMatchObject({
      tokenStart: 4,
      cursor: 11,
      query: "ios-re",
      invocationPrefix: "/",
      signature: "4:/ios-re",
    });
  });

  it("uses the caret position, not the end of the draft", () => {
    const draft = "/abc /def";
    // Cursor 4 = right after "/abc" (before the space at index 4).
    const context = computeSkillAutocompleteContext(draft, 4);
    expect(context).toMatchObject({ tokenStart: 0, cursor: 4, query: "abc", signature: "0:/abc" });
  });

  it("returns null when the token does not start with a trigger (plain word)", () => {
    expect(computeSkillAutocompleteContext("skill", 5)).toBeNull();
  });

  it("returns null after a space ends the token (cursor right after the space)", () => {
    expect(computeSkillAutocompleteContext("/skill ", 7)).toBeNull();
  });

  it("returns null when the caret sits on a non-trigger character of the token", () => {
    // Token is "/abc" but caret is before the trigger → no token yet.
    expect(computeSkillAutocompleteContext("/abc", 0)).toBeNull();
  });

  it("does not trigger when the trigger is glued to a preceding word (token starts at 'f')", () => {
    // No whitespace before the "/" → the token is "foo/bar", first char "f" → null.
    expect(computeSkillAutocompleteContext("foo/bar", 7)).toBeNull();
  });

  it("triggers when the trigger starts a token after whitespace", () => {
    const context = computeSkillAutocompleteContext("foo /bar", 8);
    expect(context).toMatchObject({ tokenStart: 4, query: "bar", signature: "4:/bar" });
  });

  it("clamps stale cursors past the end of the draft", () => {
    const context = computeSkillAutocompleteContext("/abc", 99);
    expect(context).toMatchObject({ cursor: 4, query: "abc" });
  });

  it("keeps the signature stable per token so a cancel dismissal sticks", () => {
    const a = computeSkillAutocompleteContext("/ios-review", 11);
    const b = computeSkillAutocompleteContext("/ios-review", 11);
    expect(a?.signature).toBe(b?.signature);
    const c = computeSkillAutocompleteContext("/ios-review-x", 12);
    expect(c?.signature).not.toBe(a?.signature);
  });
});

describe("filterSkillSuggestions", () => {
  const skills = [
    { name: "ios-review", skillFilePath: "a" },
    { name: "PR-Tools", skillFilePath: "b" },
    { name: "review-remote", skillFilePath: "c" },
    { name: "swiftui-perf", skillFilePath: "d" },
    { name: "reviewer", skillFilePath: "e" },
  ];

  it("returns the first 3 skills for an empty query (iOS .prefix(3))", () => {
    expect(filterSkillSuggestions(skills, "").map((s) => s.name)).toEqual([
      "ios-review",
      "PR-Tools",
      "review-remote",
    ]);
  });

  it("filters case-insensitively as a substring (iOS localizedCaseInsensitiveContains)", () => {
    // "rev" matches ios-review, review-remote, reviewer — "PR-Tools" does NOT contain "rev".
    expect(filterSkillSuggestions(skills, "REV").map((s) => s.name)).toEqual([
      "ios-review",
      "review-remote",
      "reviewer",
    ]);
  });

  it("caps results at 3 even when more match", () => {
    expect(filterSkillSuggestions(skills, "e")).toHaveLength(3);
  });

  it("returns an empty array when nothing matches", () => {
    expect(filterSkillSuggestions(skills, "zzz")).toEqual([]);
  });
});

describe("replaceSkillToken", () => {
  function contextFor(draft: string, cursor: number): SkillAutocompleteContext {
    const context = computeSkillAutocompleteContext(draft, cursor);
    if (context === null) throw new Error("expected a context for test");
    return context;
  }

  it("replaces the token with prefix + name and no trailing space (iOS parity)", () => {
    const { draft, cursor } = replaceSkillToken(
      "/ios-r",
      contextFor("/ios-r", 6),
      "ios-review",
    );
    expect(draft).toBe("/ios-review");
    expect(cursor).toBe(11);
  });

  it("keeps the `$` invocation prefix", () => {
    const { draft } = replaceSkillToken("$rev", contextFor("$rev", 4), "review-remote");
    expect(draft).toBe("$review-remote");
  });

  it("replaces mid-draft and preserves the surrounding text", () => {
    const { draft, cursor } = replaceSkillToken(
      "run /ios- please",
      contextFor("run /ios- please", 9),
      "ios-review",
    );
    expect(draft).toBe("run /ios-review please");
    expect(cursor).toBe(4 + 11); // tokenStart(4) + replacement length(11)
  });

  it("places the caret right after the replacement (iOS cursorOffset)", () => {
    const context = contextFor("a /b c", 4);
    const { cursor } = replaceSkillToken("a /b c", context, "beta");
    expect(cursor).toBe(2 + "/beta".length);
  });

  it("leaves the rest of the draft after the token untouched", () => {
    const { draft } = replaceSkillToken("/ios-r and more", contextFor("/ios-r and more", 6), "ios-review");
    expect(draft).toBe("/ios-review and more");
  });
});
