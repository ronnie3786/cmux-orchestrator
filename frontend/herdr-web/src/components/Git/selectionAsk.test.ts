import { describe, expect, it } from "vitest";
import {
  buildAskPrompt,
  clampAnchor,
  fenceForFile,
  formatLineRange,
  normalizeSelectedCode,
  selectionAskContext,
  summarizeCode,
  truncateCodeForPrompt,
  type DiffLineContainer,
} from "./selectionAsk";

function fakeLine(line: number, type: string): Element {
  return {
    getAttribute: (name: string) => (name === "data-line" ? String(line) : type),
  } as unknown as Element;
}

function fakeContainer(lines: Element[]): DiffLineContainer {
  return {
    shadowRoot: null,
    querySelectorAll: () => lines,
  } as unknown as DiffLineContainer;
}

function fakeRange(hitLines: Element[]): Range {
  return {
    intersectsNode: (node: Node) => hitLines.includes(node as Element),
  } as unknown as Range;
}

describe("selectionAskContext", () => {
  it("collects the line range the selection touches", () => {
    const lines = [fakeLine(120, "context"), fakeLine(121, "change-addition"), fakeLine(122, "change-deletion")];
    const context = selectionAskContext(
      fakeContainer(lines),
      "let x = 1\nlet y = 2\n-let z = 3",
      fakeRange(lines.slice(1)),
    );

    expect(context.code).toBe("let x = 1\nlet y = 2\n-let z = 3");
    expect(context.startLine).toBe(121);
    expect(context.endLine).toBe(122);
  });

  it("survives selections without line metadata (raw fallback)", () => {
    const context = selectionAskContext(fakeContainer([]), "+only text", fakeRange([]));
    expect(context.code).toBe("+only text");
    expect(context.startLine).toBeNull();
    expect(context.endLine).toBeNull();
  });

  it("collapses excess blank lines in selected code", () => {
    const context = selectionAskContext(
      fakeContainer([]),
      "one\n\n\n\ntwo",
      fakeRange([]),
    );
    expect(context.code).toBe("one\n\ntwo");
  });
});

describe("formatLineRange", () => {
  it("formats single lines and ranges", () => {
    expect(formatLineRange(41, 41)).toBe("line 41");
    expect(formatLineRange(40, 42)).toBe("lines 40–42");
  });

  it("returns null when line numbers are unknown", () => {
    expect(formatLineRange(null, 12)).toBeNull();
    expect(formatLineRange(12, null)).toBeNull();
  });
});

describe("fenceForFile", () => {
  it("derives a language fence from the extension", () => {
    expect(fenceForFile("Sources/Pane.swift")).toBe("swift");
    expect(fenceForFile("script.py")).toBe("py");
  });

  it("falls back to an empty fence for odd names", () => {
    expect(fenceForFile("Makefile")).toBe("");
    expect(fenceForFile("a.verylongextensionthatneverexists")).toBe("");
  });
});

describe("buildAskPrompt", () => {
  it("grounds the agent in the file, lines, and highlighted code", () => {
    const prompt = buildAskPrompt({
      file: "Sources/Pane.swift",
      startLine: 120,
      endLine: 121,
      code: "let x = 1\nlet y = 2",
      question: "Why is this here?",
    });

    expect(prompt).toContain("File: Sources/Pane.swift (lines 120–121)");
    expect(prompt).toContain("```swift\nlet x = 1\nlet y = 2\n```");
    expect(prompt).toContain("Question: Why is this here?");
    expect(prompt).toContain("do not modify anything");
  });

  it("omits the range when line numbers are unavailable", () => {
    const prompt = buildAskPrompt({
      file: "notes.txt",
      startLine: null,
      endLine: null,
      code: "hello",
      question: "what?",
    });
    expect(prompt).toContain("File: notes.txt\n");
    expect(prompt).not.toContain("(lines");
  });

  it("truncates enormous selections", () => {
    const huge = "a".repeat(50_000);
    const prompt = buildAskPrompt({
      file: "big.txt",
      startLine: null,
      endLine: null,
      code: huge,
      question: "q",
    });
    expect(prompt.length).toBeLessThan(10_000);
    expect(prompt).toContain("(selection truncated)");
  });
});

describe("clampAnchor", () => {
  it("keeps the launcher and panel inside the viewport", () => {
    expect(clampAnchor(-40, -10, 108, 30, 1200, 800)).toEqual({ left: 10, top: 10 });
    expect(clampAnchor(1300, 900, 108, 30, 1200, 800)).toEqual({ left: 1082, top: 760 });
    expect(clampAnchor(600, 400, 380, 420, 1200, 800)).toEqual({ left: 600, top: 370 });
  });
});

describe("summarizeCode", () => {
  it("previews the first selected line", () => {
    expect(summarizeCode("first line\nsecond line")).toBe("first line");
  });

  it("ellipsizes long previews", () => {
    const summary = summarizeCode("x".repeat(200), 96);
    expect(summary.length).toBe(96);
    expect(summary.endsWith("…")).toBe(true);
  });
});

describe("normalizeSelectedCode", () => {
  it("normalizes line endings", () => {
    expect(normalizeSelectedCode("a\r\nb\r\n")).toBe("a\nb");
  });
});

describe("truncateCodeForPrompt", () => {
  it("keeps short selections intact", () => {
    expect(truncateCodeForPrompt("short")).toBe("short");
  });
});