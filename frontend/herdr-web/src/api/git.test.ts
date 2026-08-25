import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { configureClient } from "./client";
import { paneGitCommitDiff, paneGitCommitFiles, paneGitDiff } from "./git";

const BASE_URL = "http://127.0.0.1:9092/api/v1";

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(
    new Response(JSON.stringify({ ok: true, files: [], diff: "" }), {
      headers: { "content-type": "application/json" },
    }),
  );
  vi.stubGlobal("fetch", fetchMock);
  configureClient({ baseUrl: BASE_URL, onUnauthorized: undefined });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("pane Git read preconditions", () => {
  it("includes the expected repository root in working-tree diff queries", async () => {
    await paneGitDiff("w1:p1", "src/a b.ts", "untracked", "/repo with spaces");

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      `${BASE_URL}/panes/w1%3Ap1/git/diff?file=src%2Fa+b.ts&section=untracked&expected_root=%2Frepo+with+spaces`,
    );
  });

  it("includes the expected repository root in commit-file queries", async () => {
    await paneGitCommitFiles("w1:p1", "a1b2c3d", "/repo");

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      `${BASE_URL}/panes/w1%3Ap1/git/commit-files?hash=a1b2c3d&expected_root=%2Frepo`,
    );
  });

  it("includes the expected repository root in historical diff queries", async () => {
    await paneGitCommitDiff("w1:p1", "a1b2c3d", "src/a.ts", "/repo");

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      `${BASE_URL}/panes/w1%3Ap1/git/commit-diff?hash=a1b2c3d&file=src%2Fa.ts&expected_root=%2Frepo`,
    );
  });
});
