import { afterEach, describe, expect, it, vi } from "vitest";
import type { GitStatus } from "../api/types";

/**
 * gitStore behavior (iOS HarnessFeatureGitReducer parity) with a stubbed
 * fetch. Each test gets a fresh module instance so the module-level
 * interval/in-flight/poll-index state doesn't leak between cases.
 */

const GIT_STATUS: GitStatus = {
  branch: "feat/harness-web-app",
  cwd: "/Users/ronnierocha/Documents/Development/cmux-harness",
  staged: [{ file: "a.swift", status: "M" }],
  unstaged: [{ file: "b.swift", status: "M" }],
  untracked: ["c.swift"],
  commits: [{ hash: "abc1234", message: "A commit" }],
  ok: true,
};

const PR_COMMENTS = {
  ok: true,
  cwd: "/repo",
  repository: { owner: "org", name: "repo", url: "https://github.com/org/repo" },
  pullRequest: {
    number: 1,
    title: "PR",
    url: "https://github.com/org/repo/pull/1",
    headRefName: "feat",
    baseRefName: "main",
    state: "OPEN",
    author: "someone",
  },
  includeResolved: false,
  threads: [],
  files: [],
  totalThreadCount: 0,
  returnedThreadCount: 0,
  resolvedThreadCount: 0,
  hiddenResolvedCount: 0,
  error: null,
};

interface FetchCall {
  path: string;
  method: string;
  body?: string;
}

function createFetchStub(handler: (call: FetchCall) => { status?: number; body: unknown }) {
  const calls: FetchCall[] = [];
  const fn = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const path = String(input);
    const call: FetchCall = {
      path,
      method: init?.method ?? "GET",
      body: typeof init?.body === "string" ? init.body : undefined,
    };
    calls.push(call);
    const result = handler(call);
    return new Response(JSON.stringify(result.body), {
      status: result.status ?? 200,
      headers: { "Content-Type": "application/json" },
    });
  };
  return { fn: fn as unknown as typeof fetch, calls };
}

async function setup(handler: (call: FetchCall) => { status?: number; body: unknown }) {
  vi.stubGlobal("localStorage", {
    length: 0,
    getItem: () => null,
    setItem: () => undefined,
    removeItem: () => undefined,
    key: () => null,
    clear: () => undefined,
  });
  const stub = createFetchStub(handler);
  vi.stubGlobal("fetch", stub.fn);
  vi.resetModules();
  const [mod, connectionMod] = await Promise.all([
    import("./gitStore"),
    import("./connectionStore"),
  ]);
  return { store: mod.useGitStore, calls: stub.calls, connection: connectionMod.useConnectionStore };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("gitStore status polling (iOS gitPollingEffect/gitTick parity)", () => {
  it("polls immediately on start and stores the status", async () => {
    const { store, calls } = await setup((call) =>
      call.path.startsWith("/api/git-status") ? { body: GIT_STATUS } : { body: {} },
    );
    store.getState().startStatusPolling(8);
    await vi.waitFor(() => {
      expect(store.getState().gitStatus).toEqual(GIT_STATUS);
    });
    expect(store.getState().isLoadingGit).toBe(false);
    expect(store.getState().gitError).toBeNull();
    expect(calls.filter((c) => c.path.startsWith("/api/git-status"))).toHaveLength(1);
    expect(calls[0].path).toBe("/api/git-status?index=8");
    store.getState().stopStatusPolling();
  });

  it("records failures as gitError (iOS gitFailed) and recovers on the next tick", async () => {
    let fail = true;
    const { store, calls } = await setup((call) =>
      call.path.startsWith("/api/git-status")
        ? fail
          ? { status: 500, body: { error: "boom" } }
          : { body: GIT_STATUS }
        : { body: {} },
    );
    store.getState().startStatusPolling(8);
    await vi.waitFor(() => {
      expect(store.getState().gitError).toBe("boom");
    });
    expect(store.getState().isLoadingGit).toBe(false);

    fail = false;
    await store.getState().pollNow();
    expect(store.getState().gitError).toBeNull();
    expect(store.getState().gitStatus).toEqual(GIT_STATUS);
    expect(calls.filter((c) => c.path.startsWith("/api/git-status"))).toHaveLength(2);
    store.getState().stopStatusPolling();
  });
});

describe("gitStore stage/unstage (iOS stageFile/unstageFile parity)", () => {
  it("stages a file then refreshes the status", async () => {
    const { store, calls } = await setup((call) =>
      call.path.startsWith("/api/git-status") ? { body: GIT_STATUS } : { body: { ok: true } },
    );
    await store.getState().stageFile(8, "a.swift");
    const stageCall = calls.find((c) => c.path === "/api/git-stage");
    expect(stageCall?.method).toBe("POST");
    expect(JSON.parse(stageCall?.body ?? "{}")).toEqual({ index: 8, file: "a.swift" });
    // Immediate tick after the successful stage.
    expect(calls.filter((c) => c.path.startsWith("/api/git-status"))).toHaveLength(1);
  });

  it("unstage failure surfaces in the shared error banner (iOS requestFailed)", async () => {
    const { store, connection } = await setup(() => ({ status: 500, body: { error: "denied" } }));
    await store.getState().unstageFile(8, "a.swift");
    expect(connection.getState().errorMessage).toBe("denied");
  });
});

describe("gitStore diff sheet (iOS requestDiff/diffSucceeded parity)", () => {
  it("opens the sheet loading, then fills the diff", async () => {
    const { store } = await setup((call) =>
      call.path === "/api/git-diff" ? { body: { ok: true, diff: "@@ -1 +1 @@" } } : { body: {} },
    );
    store.getState().requestDiff(8, "a.swift", "unstaged");
    expect(store.getState().diffSheet).toEqual({
      file: "a.swift",
      section: "unstaged",
      diff: "",
      isLoading: true,
      error: null,
    });
    await vi.waitFor(() => {
      expect(store.getState().diffSheet?.diff).toBe("@@ -1 +1 @@");
    });
    expect(store.getState().diffSheet?.isLoading).toBe(false);
  });

  it("renders (empty diff) for a blank response and the message on failure", async () => {
    const { store } = await setup((call) =>
      call.path === "/api/git-diff"
        ? { status: 404, body: { error: "no diff" } }
        : { body: {} },
    );
    store.getState().requestDiff(8, "a.swift", "staged");
    await vi.waitFor(() => {
      expect(store.getState().diffSheet?.error).toBe("no diff");
    });
    expect(store.getState().diffSheet?.isLoading).toBe(false);

    store.getState().closeDiff();
    expect(store.getState().diffSheet).toBeNull();
  });
});

describe("gitStore PR comments (iOS loadPRComments parity)", () => {
  it("loads PR comments for the workspace on demand", async () => {
    const { store, calls } = await setup((call) =>
      call.path.startsWith("/api/github/pr-comments") ? { body: PR_COMMENTS } : { body: {} },
    );
    store.getState().loadPRComments(8);
    await vi.waitFor(() => {
      expect(store.getState().prComments).toEqual(PR_COMMENTS);
    });
    expect(calls[0].path).toBe("/api/github/pr-comments?index=8&includeResolved=false");
  });

  it("reloads when the include-resolved toggle changes, not when unchanged", async () => {
    const { store, calls } = await setup((call) =>
      call.path.startsWith("/api/github/pr-comments") ? { body: PR_COMMENTS } : { body: {} },
    );
    store.getState().loadPRComments(8);
    await vi.waitFor(() => {
      expect(store.getState().prComments).toEqual(PR_COMMENTS);
    });

    store.getState().setIncludeResolved(false); // unchanged → no reload
    expect(calls).toHaveLength(1);

    store.getState().setIncludeResolved(true);
    await vi.waitFor(() => {
      expect(calls).toHaveLength(2);
    });
    expect(calls[1].path).toBe("/api/github/pr-comments?index=8&includeResolved=true");
  });

  it("records load failures as prCommentsError (iOS prCommentsFailed)", async () => {
    const { store } = await setup(() => ({ status: 500, body: { error: "nope" } }));
    store.getState().loadPRComments(8);
    await vi.waitFor(() => {
      expect(store.getState().prCommentsError).toBe("nope");
    });
    expect(store.getState().isLoadingPRComments).toBe(false);
  });
});

describe("gitStore resets", () => {
  it("resetForSelection clears everything and returns to the status segment (iOS workspaceSelected)", async () => {
    const { store } = await setup(() => ({ body: {} }));
    store.getState().setSegment("prComments");
    store.getState().setIncludeResolved(true);
    store.setState({
      gitStatus: GIT_STATUS,
      prComments: PR_COMMENTS,
      diffSheet: { file: "a", section: "unstaged", diff: "", isLoading: false, error: null },
    });

    store.getState().resetForSelection();
    expect(store.getState()).toMatchObject({
      gitSegment: "status",
      gitStatus: null,
      includeResolved: false,
      prComments: null,
      diffSheet: null,
    });
  });

  it("resetPane keeps the segment and toggle but clears data (iOS selectWorkspacePane)", async () => {
    const { store } = await setup(() => ({ body: {} }));
    store.getState().setSegment("prComments");
    store.setState({ gitStatus: GIT_STATUS, prComments: PR_COMMENTS });

    store.getState().resetPane();
    expect(store.getState()).toMatchObject({
      gitSegment: "prComments",
      gitStatus: null,
      prComments: null,
    });
  });
});
