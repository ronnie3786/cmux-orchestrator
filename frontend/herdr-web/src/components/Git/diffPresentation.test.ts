import { describe, expect, it, vi } from "vitest";
import { parseDiffPresentation } from "./diffPresentation";

const TEXT_PATCH = `diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1 +1 @@
-const value = 1;
+const value = 2;
`;

describe("parseDiffPresentation", () => {
  it("returns a Pierre model for a line-based patch with a content-specific cache key", () => {
    const parsed = parseDiffPresentation("src/app.ts", TEXT_PATCH);

    expect(parsed.fallbackReason).toBe(null);
    expect(parsed.fileDiff?.hunks).toHaveLength(1);
    expect(parsed.fileDiff?.cacheKey).toMatch(/^src\/app\.ts#[0-9a-f]{8}$/);
  });

  it.each([
    [
      "binary change",
      `diff --git a/icon.png b/icon.png
index 1111111..2222222 100644
Binary files a/icon.png and b/icon.png differ
`,
    ],
    [
      "pure rename",
      `diff --git a/old.txt b/new.txt
similarity index 100%
rename from old.txt
rename to new.txt
`,
    ],
    [
      "mode-only change",
      `diff --git a/tool.sh b/tool.sh
old mode 100644
new mode 100755
`,
    ],
  ])("routes a %s through the useful raw metadata fallback", (_label, patch) => {
    const parsed = parseDiffPresentation("file", patch);

    expect(parsed.fileDiff).toBe(null);
    expect(parsed.fallbackReason).toBe("metadata-only");
  });

  it("routes a malformed hunk through the raw parse fallback", () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const parsed = parseDiffPresentation(
      "src/app.ts",
      "diff --git a/src/app.ts b/src/app.ts\n@@ malformed\nraw\n",
    );
    consoleError.mockRestore();

    expect(parsed.fileDiff).toBe(null);
    expect(parsed.fallbackReason).toBe("parse-unavailable");
  });
});
