import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, configureClient } from "../api/client";
import { isUpstreamError } from "../components/Shared/ToolErrorCard";
import { useToastStore } from "../lib/toast";
import { useGitStore } from "./gitStore";

const BASE_URL = "http://127.0.0.1:9092/api/v1";

const GIT_URL = `${BASE_URL}/workspaces/w1/git`;
const STAGE_URL = `${BASE_URL}/workspaces/w1/git/stage`;
const UNSTAGE_URL = `${BASE_URL}/workspaces/w1/git/unstage`;

const GIT_RESPONSE = {
  ok: true,
  workspace_id: "w1",
  root_path: "/Users/ronnierocha/repo",
  branch: "main",
  staged: [{ status: "M", file: "src/a.py" }],
  unstaged: [{ status: "M", file: "src/b.py" }],
  untracked: ["src/c.py"],
  commits: [{ hash: "c10e3c23", message: "Initial commit" }],
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

let fetchMock: ReturnType<typeof vi.fn>;

function mockFetch(routes: Record<string, Response>): void {
  fetchMock.mockImplementation(async (url: string) => {
    const response = routes[url];
    if (response === undefined) throw new Error(`unmocked URL: ${url}`);
    return response;
  });
}

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
  configureClient({ baseUrl: BASE_URL, onUnauthorized: undefined });
  useGitStore.setState({ byWorkspace: {}, diffSheet: null });
  useToastStore.getState().dismiss();
});

afterEach(() => {
  useToastStore.getState().dismiss();
  vi.unstubAllGlobals();
});

describe("gitStore.load", () => {
  it("caches the /git snapshot per workspace (branch, path, sections, commits)", async () => {
    mockFetch({ [GIT_URL]: jsonResponse(GIT_RESPONSE) });

    await useGitStore.getState().load("w1");

    const entry = useGitStore.getState().byWorkspace["w1"];
    expect(entry?.loading).toBe(false);
    expect(entry?.error).toBe(null);
    expect(entry?.noRepo).toBe(false);
    expect(entry?.snapshot).toMatchObject({
      branch: "main",
      rootPath: "/Users/ronnierocha/repo",
      detached: false,
      staged: [{ status: "M", file: "src/a.py" }],
      unstaged: [{ status: "M", file: "src/b.py" }],
      untracked: ["src/c.py"],
      commits: [{ hash: "c10e3c23", message: "Initial commit" }],
    });
  });

  it("treats a missing repo root + branch as a workspace without Git", async () => {
    mockFetch({
      [GIT_URL]: jsonResponse({
        ok: true,
        workspace_id: "w1",
        root_path: null,
        branch: null,
        staged: [],
        unstaged: [],
        untracked: [],
        commits: [],
      }),
    });

    await useGitStore.getState().load("w1");

    const entry = useGitStore.getState().byWorkspace["w1"];
    expect(entry?.noRepo).toBe(true);
    expect(entry?.error).toBe(null);
  });

  it("502: error carries the server message (upstream → ToolErrorCard path)", async () => {
    mockFetch({
      [GIT_URL]: jsonResponse({ ok: false, error: { code: "upstream", message: "cmux tool failed" } }, 502),
    });

    await useGitStore.getState().load("w1");

    const entry = useGitStore.getState().byWorkspace["w1"];
    expect(entry?.error).toBe("cmux tool failed");
    expect(entry?.snapshot).toBe(null);

    // The classification that routes 502/503/timeout into the upstream card
    // (vs a plain failure).
    expect(isUpstreamError(new ApiError("upstream", "cmux tool failed", 502))).toBe(true);
    expect(isUpstreamError(new ApiError("upstream", "cmux tool failed", 503))).toBe(true);
    expect(isUpstreamError(new ApiError("error", "bad request", 400))).toBe(false);
    expect(isUpstreamError(new Error("Request timed out"))).toBe(true);
    expect(isUpstreamError(new Error("cmux tool failed"))).toBe(false);
  });
});

describe("gitStore.stage / unstage", () => {
  it("stage: POSTs {file}, toasts `Staged <file>`, reloads status", async () => {
    mockFetch({
      [STAGE_URL]: jsonResponse({ ok: true }),
      [GIT_URL]: jsonResponse(GIT_RESPONSE),
    });
    await useGitStore.getState().load("w1");
    fetchMock.mockClear();

    await useGitStore.getState().stage("src/b.py");

    const [stageUrl, stageInit] = fetchMock.mock.calls[0]!;
    expect(stageUrl).toBe(STAGE_URL);
    expect(stageInit?.method).toBe("POST");
    expect(stageInit?.body).toBe(JSON.stringify({ file: "src/b.py" }));
    expect(fetchMock.mock.calls[1]?.[0]).toBe(GIT_URL); // reload after success
    expect(useToastStore.getState().message).toBe("Staged src/b.py");
  });

  it("unstage: POSTs {file}, toasts `Unstaged <file>`, reloads status", async () => {
    mockFetch({
      [UNSTAGE_URL]: jsonResponse({ ok: true }),
      [GIT_URL]: jsonResponse(GIT_RESPONSE),
    });
    await useGitStore.getState().load("w1");
    fetchMock.mockClear();

    await useGitStore.getState().unstage("src/a.py");

    const [unstageUrl] = fetchMock.mock.calls[0]!;
    expect(unstageUrl).toBe(UNSTAGE_URL);
    expect(fetchMock.mock.calls[1]?.[0]).toBe(GIT_URL);
    expect(useToastStore.getState().message).toBe("Unstaged src/a.py");
  });

  it("stage failure: toasts the server message, no reload", async () => {
    mockFetch({
      [STAGE_URL]: jsonResponse({ ok: false, error: { code: "upstream", message: "stage failed" } }, 502),
    });
    await useGitStore.getState().load("w1");
    fetchMock.mockClear();

    await useGitStore.getState().stage("src/b.py");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(useToastStore.getState().message).toBe("stage failed");
  });
});

describe("gitStore.diff", () => {
  it("opens the sheet and stores the fetched diff text", async () => {
    mockFetch({
      [`${BASE_URL}/workspaces/w1/git/diff?file=src%2Fa.py&section=staged`]: jsonResponse({
        ok: true,
        workspace_id: "w1",
        file: "src/a.py",
        section: "staged",
        diff: "@@ -1 +1 @@\n-old\n+new\n",
        truncated: false,
      }),
    });
    await useGitStore.getState().load("w1");

    useGitStore.getState().diff("src/a.py", "staged");
    expect(useGitStore.getState().diffSheet).toMatchObject({
      file: "src/a.py",
      section: "staged",
      isLoading: true,
    });

    await vi.waitFor(() => {
      expect(useGitStore.getState().diffSheet?.isLoading).toBe(false);
    });
    expect(useGitStore.getState().diffSheet).toMatchObject({
      diff: "@@ -1 +1 @@\n-old\n+new\n",
      error: null,
    });
  });

  it("stores an empty string for an empty diff (view renders `(empty diff)`)", async () => {
    mockFetch({
      [`${BASE_URL}/workspaces/w1/git/diff?file=src%2Fa.py&section=unstaged`]: jsonResponse({
        ok: true,
        workspace_id: "w1",
        file: "src/a.py",
        section: "unstaged",
        diff: "",
        truncated: false,
      }),
    });
    await useGitStore.getState().load("w1");

    useGitStore.getState().diff("src/a.py", "unstaged");
    await vi.waitFor(() => {
      expect(useGitStore.getState().diffSheet?.isLoading).toBe(false);
    });
    expect(useGitStore.getState().diffSheet?.diff).toBe("");
  });

  it("diff failure: sheet carries the `Diff unavailable` error message", async () => {
    mockFetch({
      [`${BASE_URL}/workspaces/w1/git/diff?file=src%2Fa.py&section=staged`]: jsonResponse(
        { ok: false, error: { code: "upstream", message: "diff failed" } },
        502,
      ),
    });
    await useGitStore.getState().load("w1");

    useGitStore.getState().diff("src/a.py", "staged");
    await vi.waitFor(() => {
      expect(useGitStore.getState().diffSheet?.isLoading).toBe(false);
    });
    expect(useGitStore.getState().diffSheet?.error).toBe("diff failed");
  });
});
