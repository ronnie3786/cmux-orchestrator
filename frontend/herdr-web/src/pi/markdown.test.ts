/**
 * 1:1 port of `herdr-harness-iosTests/PiMarkdownParserTests.swift`
 * (10 @Test cases, same inputs and expectations).
 */
import { describe, expect, it } from "vitest";
import { parsePiMarkdown } from "./markdown";
import type { PiMarkdownListItem, PiMarkdownTable } from "./types";

const bullet: PiMarkdownListItem["marker"] = { kind: "bullet" };
const number = (value: string): PiMarkdownListItem["marker"] => ({ kind: "number", value });
const task = (isCompleted: boolean): PiMarkdownListItem["marker"] => ({ kind: "task", isCompleted });

describe("Pi Markdown blocks", () => {
  it("Parses coding-agent block structure without a dependency", () => {
    const blocks = parsePiMarkdown(
      `Intro with **emphasis** and [a link](https://example.com).

- one
2. two
> note

\`\`\`swift
let value = 42
print(value)
\`\`\``,
    );

    expect(blocks).toHaveLength(4);
    expect(blocks[0]).toEqual({
      kind: "paragraph",
      id: 0,
      text: "Intro with **emphasis** and [a link](https://example.com).",
    });
    expect(blocks[1]).toEqual({
      kind: "list",
      id: 1,
      items: [
        { marker: bullet, text: "one", depth: 0 },
        { marker: number("2"), text: "two", depth: 0 },
      ],
    });
    expect(blocks[2]).toEqual({ kind: "quote", id: 2, text: "note" });
    expect(blocks[3]).toEqual({
      kind: "code",
      id: 3,
      language: "swift",
      code: "let value = 42\nprint(value)",
    });
  });

  it("Parses GitHub-style tables with alignment and inline pipes", () => {
    const blocks = parsePiMarkdown(`| Command | State | Cost |
| :--- | :---: | ---: |
| \`build|test\` | **ready** | $4 |
| escaped \\| pipe | waiting | 9 |`);

    const table: PiMarkdownTable = {
      headers: ["Command", "State", "Cost"],
      alignments: ["leading", "center", "trailing"],
      rows: [
        ["`build|test`", "**ready**", "$4"],
        ["escaped \\| pipe", "waiting", "9"],
      ],
    };
    expect(blocks).toEqual([{ kind: "table", id: 0, table }]);
  });

  it("Normalizes short and long table rows", () => {
    const blocks = parsePiMarkdown(`A | B
--- | ---
one
one | two | ignored`);

    // A row must contain a pipe, so the first line after the delimiter ends the table.
    const table: PiMarkdownTable = {
      headers: ["A", "B"],
      alignments: ["leading", "leading"],
      rows: [],
    };
    expect(blocks).toEqual([
      { kind: "table", id: 0, table },
      { kind: "paragraph", id: 1, text: "one\none | two | ignored" },
    ]);
  });

  it("Parses ATX and setext headings plus thematic breaks", () => {
    const blocks = parsePiMarkdown(`# Summary **today** ##

Results
===

---

###### Detail`);

    expect(blocks).toEqual([
      { kind: "heading", id: 0, level: 1, text: "Summary **today**" },
      { kind: "heading", id: 1, level: 1, text: "Results" },
      { kind: "thematicBreak", id: 2 },
      { kind: "heading", id: 3, level: 6, text: "Detail" },
    ]);
  });

  it("Does not treat a hash without whitespace as a heading", () => {
    const blocks = parsePiMarkdown("#include <stdio.h>");
    expect(blocks).toEqual([{ kind: "paragraph", id: 0, text: "#include <stdio.h>" }]);
  });

  it("Groups quote lines and preserves quote paragraph spacing", () => {
    const blocks = parsePiMarkdown(`> First **point**
>
> Second point`);
    expect(blocks).toEqual([{ kind: "quote", id: 0, text: "First **point**\n\nSecond point" }]);
  });

  it("Parses tasks, nesting, ordered markers, and continuation text", () => {
    const blocks = parsePiMarkdown(`- [x] shipped
- [ ] pending
    - nested **child**
        - deep child
1) first
   continued explanation`);

    expect(blocks).toEqual([
      {
        kind: "list",
        id: 0,
        items: [
          { marker: task(true), text: "shipped", depth: 0 },
          { marker: task(false), text: "pending", depth: 0 },
          { marker: bullet, text: "nested **child**", depth: 1 },
          { marker: bullet, text: "deep child", depth: 2 },
          {
            marker: number("1"),
            text: "first\ncontinued explanation",
            depth: 0,
          },
        ],
      },
    ]);
  });

  it("Supports tilde fences and uses the first info token as the language", () => {
    const blocks = parsePiMarkdown(`~~~~typescript title=sample
const value = \`ok\`;
~~~~~`);

    expect(blocks).toEqual([
      { kind: "code", id: 0, language: "typescript", code: "const value = `ok`;" },
    ]);
  });

  it("An unfinished fence remains readable while streaming", () => {
    const blocks = parsePiMarkdown("```sh\necho ready");
    expect(blocks).toEqual([{ kind: "code", id: 0, language: "sh", code: "echo ready" }]);
  });

  it("Empty and whitespace-only messages have no blocks", () => {
    expect(parsePiMarkdown("")).toEqual([]);
    expect(parsePiMarkdown(" \n\t")).toEqual([]);
  });
});
