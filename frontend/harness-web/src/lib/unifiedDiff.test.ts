import { describe, expect, it } from "vitest";
import {
  isCommentable,
  lineCode,
  lineMarker,
  parseUnifiedDiffLines,
  reviewCommentForLine,
  reviewLineNumber,
  reviewSide,
} from "./unifiedDiff";

/**
 * Fixture: a real `git diff` from this repo — commit 4eb89ea (phase 2b) for
 * `frontend/harness-web/src/App.tsx` (`git show 4eb89ea -- frontend/harness-web/src/App.tsx`).
 * The iOS repo has no DiffViews unit tests to port, so this real diff is the
 * fixture of record. It exercises metadata, hunk headers (with and without
 * trailing function text), context (including a blank context line),
 * deletions, and additions across five hunks.
 */
const REAL_DIFF = `diff --git a/frontend/harness-web/src/App.tsx b/frontend/harness-web/src/App.tsx
index f84d440..be0091c 100644
--- a/frontend/harness-web/src/App.tsx
+++ b/frontend/harness-web/src/App.tsx
@@ -1,7 +1,7 @@
 import { useEffect, useState } from "react";
 import { KeyRound } from "lucide-react";
 import { getToken, setToken } from "./api/client";
-import { getFeed, getNotifications, getStatus } from "./api/endpoints";
+import { getFeed, getLog, getNotifications, getOpenCodeIntegration, getStatus } from "./api/endpoints";
 import { ConnectionBar } from "./components/ConnectionBar";
 import { Sidebar } from "./components/Sidebar";
 import { WorkspaceDetailView } from "./components/Workspace/WorkspaceDetailView";
@@ -32,9 +32,11 @@ export default function App() {
   }, []);
__BLANK_CONTEXT__
   // Polling lifecycle: 2 s tick for /api/status + /api/notifications +
-  // /api/feed (iOS global refresh parity). Skipped while a tick is in flight
-  // (overlap guard) and while the tab is hidden; an immediate tick fires when
-  // the tab becomes visible again. Runs only while a token is stored.
+  // /api/feed + /api/log + /api/integrations/opencode (iOS global refresh
+  // parity — HarnessFeatureConnectionReducer.refresh fetches all five in
+  // parallel). Skipped while a tick is in flight (overlap guard) and while
+  // the tab is hidden; an immediate tick fires when the tab becomes visible
+  // again. Runs only while a token is stored.
   useEffect(() => {
     if (!token) {
       return;
@@ -51,11 +53,14 @@ export default function App() {
       }
       inFlight = true;
       try {
-        const [statusResult, notificationsResult, feedResult] = await Promise.allSettled([
-          getStatus(),
-          getNotifications(),
-          getFeed(),
-        ]);
+        const [statusResult, notificationsResult, feedResult, logResult, integrationResult] =
+          await Promise.allSettled([
+            getStatus(),
+            getNotifications(),
+            getFeed(),
+            getLog(),
+            getOpenCodeIntegration(),
+          ]);
         if (disposed) {
           return;
         }
@@ -73,6 +78,12 @@ export default function App() {
         if (feedResult.status === "fulfilled") {
           workspaces.applyFeed(feedResult.value);
         }
+        if (logResult.status === "fulfilled") {
+          workspaces.applyLog(logResult.value);
+        }
+        if (integrationResult.status === "fulfilled") {
+          workspaces.applyOpenCodeIntegration(integrationResult.value);
+        }
       } finally {
         inFlight = false;
       }
@@ -123,6 +134,8 @@ export default function App() {
       workspaces: [],
       notifications: [],
       feedItems: [],
+      logEntries: [],
+      openCodeIntegration: null,
       lastUpdated: null,
       hasReceivedStatus: false,
       selectedGroupID: null,`;

// The real diff's blank context line is a single space; the template literal
// above cannot preserve a whitespace-only line, so it is substituted here.
const DIFF = REAL_DIFF.replace("__BLANK_CONTEXT__", " ");

describe("parseUnifiedDiffLines (iOS parseUnifiedDiffLines parity)", () => {
  const lines = parseUnifiedDiffLines(DIFF);

  it("keeps one record per raw line with stable offsets", () => {
    expect(lines).toHaveLength(70);
    lines.forEach((line, index) => {
      expect(line.id).toBe(index);
      expect(line.raw).toBe(DIFF.split("\n")[index]);
    });
  });

  it("classifies the file header as metadata, including ---/+++ file lines", () => {
    expect(lines.slice(0, 4).map((line) => line.kind)).toEqual([
      "metadata",
      "metadata",
      "metadata",
      "metadata",
    ]);
  });

  it("parses hunk 1 line numbers (context/deletion/addition/context)", () => {
    expect(lines[4].kind).toBe("hunk");
    // @@ -1,7 +1,7 @@
    expect(lines[5]).toMatchObject({ kind: "context", oldLineNumber: 1, newLineNumber: 1 });
    expect(lines[7]).toMatchObject({ kind: "context", oldLineNumber: 3, newLineNumber: 3 });
    expect(lines[8]).toMatchObject({ kind: "deletion", oldLineNumber: 4, newLineNumber: null });
    expect(lines[9]).toMatchObject({ kind: "addition", oldLineNumber: null, newLineNumber: 4 });
    expect(lines[10]).toMatchObject({ kind: "context", oldLineNumber: 5, newLineNumber: 5 });
    expect(lines[12]).toMatchObject({ kind: "context", oldLineNumber: 7, newLineNumber: 7 });
  });

  it("resets counters at hunk 2 (@@ -32,9 +32,11 @@ with trailing function text)", () => {
    expect(lines[13].kind).toBe("hunk");
    expect(lines[14]).toMatchObject({ kind: "context", oldLineNumber: 32, newLineNumber: 32 });
    // Blank context line is " " (single space), still counts as context.
    expect(lines[15]).toMatchObject({ kind: "context", oldLineNumber: 33, newLineNumber: 33, raw: " " });
    expect(lines[16]).toMatchObject({ kind: "context", oldLineNumber: 34, newLineNumber: 34 });
    expect(lines[17]).toMatchObject({ kind: "deletion", oldLineNumber: 35 });
    expect(lines[18]).toMatchObject({ kind: "deletion", oldLineNumber: 36 });
    expect(lines[19]).toMatchObject({ kind: "deletion", oldLineNumber: 37 });
    expect(lines[20]).toMatchObject({ kind: "addition", newLineNumber: 35 });
    expect(lines[24]).toMatchObject({ kind: "addition", newLineNumber: 39 });
    expect(lines[25]).toMatchObject({ kind: "context", oldLineNumber: 38, newLineNumber: 40 });
    expect(lines[27]).toMatchObject({ kind: "context", oldLineNumber: 40, newLineNumber: 42 });
  });

  it("parses hunk 3 where old and new numbers diverge (@@ -51,11 +53,14 @@)", () => {
    expect(lines[28].kind).toBe("hunk");
    expect(lines[29]).toMatchObject({ kind: "context", oldLineNumber: 51, newLineNumber: 53 });
    expect(lines[31]).toMatchObject({ kind: "context", oldLineNumber: 53, newLineNumber: 55 });
    expect(lines[32]).toMatchObject({ kind: "deletion", oldLineNumber: 54 });
    expect(lines[33]).toMatchObject({ kind: "deletion", oldLineNumber: 55 });
    expect(lines[34]).toMatchObject({ kind: "deletion", oldLineNumber: 56 });
    expect(lines[35]).toMatchObject({ kind: "deletion", oldLineNumber: 57 });
    expect(lines[36]).toMatchObject({ kind: "deletion", oldLineNumber: 58 });
    expect(lines[37]).toMatchObject({ kind: "addition", newLineNumber: 56 });
    expect(lines[43]).toMatchObject({ kind: "addition", newLineNumber: 62 });
    expect(lines[44]).toMatchObject({ kind: "addition", newLineNumber: 63 });
    expect(lines[45]).toMatchObject({ kind: "context", oldLineNumber: 59, newLineNumber: 64 });
    expect(lines[47]).toMatchObject({ kind: "context", oldLineNumber: 61, newLineNumber: 66 });
  });

  it("parses hunk 4 (addition-only) and hunk 5", () => {
    expect(lines[48].kind).toBe("hunk");
    expect(lines[49]).toMatchObject({ kind: "context", oldLineNumber: 73, newLineNumber: 78 });
    expect(lines[51]).toMatchObject({ kind: "context", oldLineNumber: 75, newLineNumber: 80 });
    expect(lines[52]).toMatchObject({ kind: "addition", newLineNumber: 81 });
    expect(lines[53]).toMatchObject({ kind: "addition", newLineNumber: 82 });
    expect(lines[54]).toMatchObject({ kind: "addition", newLineNumber: 83 });
    expect(lines[55]).toMatchObject({ kind: "addition", newLineNumber: 84 });
    expect(lines[56]).toMatchObject({ kind: "addition", newLineNumber: 85 });
    expect(lines[57]).toMatchObject({ kind: "addition", newLineNumber: 86 });
    expect(lines[58]).toMatchObject({ kind: "context", oldLineNumber: 76, newLineNumber: 87 });

    expect(lines[61].kind).toBe("hunk");
    expect(lines[62]).toMatchObject({ kind: "context", oldLineNumber: 123, newLineNumber: 134 });
    expect(lines[64]).toMatchObject({ kind: "context", oldLineNumber: 125, newLineNumber: 136 });
    expect(lines[65]).toMatchObject({ kind: "addition", newLineNumber: 137 });
    expect(lines[66]).toMatchObject({ kind: "addition", newLineNumber: 138 });
    expect(lines[67]).toMatchObject({ kind: "context", oldLineNumber: 126, newLineNumber: 139 });
    expect(lines[69]).toMatchObject({ kind: "context", oldLineNumber: 128, newLineNumber: 141 });
  });

  it("leaves line numbers null for changes before any hunk header", () => {
    const noHunk = parseUnifiedDiffLines("-deleted before hunk\n+added before hunk\n");
    expect(noHunk[0]).toMatchObject({ kind: "deletion", oldLineNumber: null });
    expect(noHunk[1]).toMatchObject({ kind: "addition", newLineNumber: null });
  });

  it("treats a truly empty line as metadata without touching counters", () => {
    const parsed = parseUnifiedDiffLines("@@ -1,3 +1,3 @@\n ctx\n\n+add\n");
    expect(parsed[2]).toMatchObject({ kind: "metadata", oldLineNumber: null, newLineNumber: null });
    expect(parsed[3]).toMatchObject({ kind: "addition", newLineNumber: 2 });
  });

  it("ignores a malformed hunk (no + part) as metadata", () => {
    const parsed = parseUnifiedDiffLines("@@ -1,3 @@\n ctx\n");
    expect(parsed[0].kind).toBe("metadata");
    expect(parsed[1].kind).toBe("context");
  });
});

describe("diff line helpers (iOS ParsedDiffLine/review parity)", () => {
  const lines = parseUnifiedDiffLines(DIFF);
  const deletion = lines[8]; // -import { getFeed, getNotifications, getStatus } ...
  const addition = lines[9]; // +import { getFeed, getLog, ... } ...
  const context = lines[10]; // import { ConnectionBar } ...
  const blankContext = lines[15]; // " "
  const hunk = lines[13];

  it("isCommentable covers context/addition/deletion only", () => {
    expect(isCommentable(context)).toBe(true);
    expect(isCommentable(addition)).toBe(true);
    expect(isCommentable(deletion)).toBe(true);
    expect(isCommentable(hunk)).toBe(false);
    expect(isCommentable(lines[0])).toBe(false);
  });

  it("markers are +, -, and space", () => {
    expect(lineMarker(addition)).toBe("+");
    expect(lineMarker(deletion)).toBe("-");
    expect(lineMarker(context)).toBe(" ");
    expect(lineMarker(hunk)).toBe("");
  });

  it("code drops the marker and keeps blank lines empty", () => {
    expect(lineCode(addition)).toBe(
      "import { getFeed, getLog, getNotifications, getOpenCodeIntegration, getStatus } from \"./api/endpoints\";",
    );
    expect(lineCode(deletion)).toBe("import { getFeed, getNotifications, getStatus } from \"./api/endpoints\";");
    expect(lineCode(context)).toBe("import { ConnectionBar } from \"./components/ConnectionBar\";");
    expect(lineCode(blankContext)).toBe("");
    expect(lineCode(hunk)).toBe(hunk.raw); // unparseable lines keep raw text
  });

  it("reviewLineNumber/reviewSide pick old for deletions, new for additions", () => {
    expect(reviewLineNumber(deletion)).toBe(4);
    expect(reviewSide(deletion)).toBe("old");
    expect(reviewLineNumber(addition)).toBe(4);
    expect(reviewSide(addition)).toBe("new");
    expect(reviewLineNumber(context)).toBe(5);
    expect(reviewSide(context)).toBe("context");
    expect(reviewLineNumber(hunk)).toBe(null);
  });

  it("builds the review-comment payload used by the prompt formatter", () => {
    const payload = reviewCommentForLine(addition, "frontend/harness-web/src/App.tsx", "Use X");
    expect(payload).toEqual({
      file: "frontend/harness-web/src/App.tsx",
      lineNumber: 4,
      side: "new",
      code: "import { getFeed, getLog, getNotifications, getOpenCodeIntegration, getStatus } from \"./api/endpoints\";",
      comment: "Use X",
    });
  });
});
