import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, configureClient } from "../api/client";
import { isUpstreamError } from "../components/Shared/ToolErrorCard";
import { useToastStore } from "../lib/toast";
import { useGitStore } from "./gitStore";

const BASE_URL = "http://127.0.0.1:9092/api/v1";
const PANE_ID = "w1:p1";
const PANE_PATH = "w1%3Ap1";
const GIT_URL = `${BASE_URL}/panes/${PANE_PATH}/git`;
const STAGE_URL = `${GIT_URL}/stage`;
const UNSTAGE_URL = `${GIT_URL}/unstage`;

const GIT_RESPONSE = {
  ok: true,
  pane_id: PANE_ID,
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
    return response.clone();
  });
}

async function primeGitSnapshot(response = GIT_RESPONSE): Promise<void> {
  mockFetch({ [GIT_URL]: jsonResponse(response) });
  await useGitStore.getState().load(PANE_ID);
  fetchMock.mockClear();
}

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
  configureClient({ baseUrl: BASE_URL, onUnauthorized: undefined });
  useGitStore.setState({ byPane: {}, diffSheet: null });
  useToastStore.getState().dismiss();
});

afterEach(() => {
  useToastStore.getState().dismiss();
  vi.unstubAllGlobals();
});

describe("gitStore.load", () => {
  it("caches the Git snapshot by pane", async () => {
    mockFetch({ [GIT_URL]: jsonResponse(GIT_RESPONSE) });

    await useGitStore.getState().load(PANE_ID);

    expect(fetchMock.mock.calls[0]?.[0]).toBe(GIT_URL);
    expect(useGitStore.getState().byPane[PANE_ID]).toMatchObject({
      loading: false,
      error: null,
      noRepo: false,
      snapshot: {
        branch: "main",
        rootPath: "/Users/ronnierocha/repo",
        detached: false,
        staged: [{ status: "M", file: "src/a.py" }],
        unstaged: [{ status: "M", file: "src/b.py" }],
        untracked: ["src/c.py"],
        commits: [{ hash: "c10e3c23", message: "Initial commit" }],
      },
    });
  });

  it("recognizes HEAD as detached", async () => {
    mockFetch({ [GIT_URL]: jsonResponse({ ...GIT_RESPONSE, branch: "HEAD" }) });

    await useGitStore.getState().load(PANE_ID);

    expect(useGitStore.getState().byPane[PANE_ID]?.snapshot?.detached).toBe(true);
  });

  it("turns the repository-not-found response into the no-repo state", async () => {
    mockFetch({
      [GIT_URL]: jsonResponse(
        {
          ok: false,
          error: { code: "git_repository_not_found", message: "No Git repository" },
        },
        404,
      ),
    });

    await useGitStore.getState().load(PANE_ID);

    expect(useGitStore.getState().byPane[PANE_ID]).toMatchObject({
      noRepo: true,
      error: null,
      snapshot: null,
    });
  });

  it("preserves the upstream error for the retry card", async () => {
    mockFetch({
      [GIT_URL]: jsonResponse(
        { ok: false, error: { code: "upstream", message: "cmux tool failed" } },
        502,
      ),
    });

    await useGitStore.getState().load(PANE_ID);

    expect(useGitStore.getState().byPane[PANE_ID]?.error).toBe("cmux tool failed");
    expect(isUpstreamError(new ApiError("upstream", "cmux tool failed", 502))).toBe(true);
    expect(isUpstreamError(new ApiError("error", "bad request", 400))).toBe(false);
  });
});

describe("gitStore.stage / unstage", () => {
  it("stages a file, reports success, and reloads the same pane", async () => {
    await primeGitSnapshot();
    mockFetch({
      [STAGE_URL]: jsonResponse({ ok: true, file: "src/b.py" }),
      [GIT_URL]: jsonResponse(GIT_RESPONSE),
    });

    await useGitStore.getState().stage(PANE_ID, "src/b.py");

    const [stageUrl, stageInit] = fetchMock.mock.calls[0]!;
    expect(stageUrl).toBe(STAGE_URL);
    expect(stageInit?.method).toBe("POST");
    expect(stageInit?.body).toBe(
      JSON.stringify({ file: "src/b.py", expected_root: "/Users/ronnierocha/repo" }),
    );
    expect(fetchMock.mock.calls[1]?.[0]).toBe(GIT_URL);
    expect(useToastStore.getState().message).toBe("Staged src/b.py");
  });

  it("unstages a file and reloads the same pane", async () => {
    await primeGitSnapshot();
    mockFetch({
      [UNSTAGE_URL]: jsonResponse({ ok: true, file: "src/a.py" }),
      [GIT_URL]: jsonResponse(GIT_RESPONSE),
    });

    await useGitStore.getState().unstage(PANE_ID, "src/a.py");

    expect(fetchMock.mock.calls[0]?.[0]).toBe(UNSTAGE_URL);
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(
      JSON.stringify({ file: "src/a.py", expected_root: "/Users/ronnierocha/repo" }),
    );
    expect(fetchMock.mock.calls[1]?.[0]).toBe(GIT_URL);
    expect(useToastStore.getState().message).toBe("Unstaged src/a.py");
  });

  it("reports a mutation failure without reloading", async () => {
    await primeGitSnapshot();
    mockFetch({
      [STAGE_URL]: jsonResponse(
        { ok: false, error: { code: "upstream", message: "stage failed" } },
        502,
      ),
    });

    await useGitStore.getState().stage(PANE_ID, "src/b.py");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(useToastStore.getState().message).toBe("stage failed");
  });

  it("does not mutate without a displayed repository root and refreshes status", async () => {
    await primeGitSnapshot({ ...GIT_RESPONSE, root_path: "" });
    mockFetch({ [GIT_URL]: jsonResponse(GIT_RESPONSE) });

    await useGitStore.getState().stage(PANE_ID, "src/b.py");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe(GIT_URL);
    expect(useToastStore.getState().message).toBe(
      "Refreshing Git status before staging files",
    );
  });

  it("reports a changed repository and force-refreshes the pane snapshot", async () => {
    await primeGitSnapshot();
    mockFetch({
      [STAGE_URL]: jsonResponse(
        {
          ok: false,
          error: {
            code: "git_repository_changed",
            message: "This pane moved to a different Git repository",
          },
        },
        409,
      ),
      [GIT_URL]: jsonResponse({
        ...GIT_RESPONSE,
        root_path: "/Users/ronnierocha/other-repo",
      }),
    });

    await useGitStore.getState().stage(PANE_ID, "src/b.py");

    expect(fetchMock.mock.calls.map((call) => call[0])).toEqual([STAGE_URL, GIT_URL]);
    expect(useToastStore.getState().message).toBe(
      "This pane moved to a different Git repository",
    );
    expect(useGitStore.getState().byPane[PANE_ID]?.snapshot?.rootPath).toBe(
      "/Users/ronnierocha/other-repo",
    );
  });
});

describe("gitStore.diff", () => {
  it("loads a working-tree diff, including untracked files", async () => {
    await primeGitSnapshot();
    const diffUrl = `${GIT_URL}/diff?file=src%2Fc.py&section=untracked&expected_root=%2FUsers%2Fronnierocha%2Frepo`;
    mockFetch({
      [diffUrl]: jsonResponse({
        ok: true,
        pane_id: PANE_ID,
        file: "src/c.py",
        section: "untracked",
        diff: "@@ -0,0 +1 @@\n+new\n",
        truncated: true,
      }),
    });

    useGitStore.getState().diff(PANE_ID, "src/c.py", "untracked");
    expect(useGitStore.getState().diffSheet).toMatchObject({
      paneId: PANE_ID,
      file: "src/c.py",
      section: "untracked",
      isLoading: true,
    });

    await vi.waitFor(() => expect(useGitStore.getState().diffSheet?.isLoading).toBe(false));
    expect(useGitStore.getState().diffSheet).toMatchObject({
      diff: "@@ -0,0 +1 @@\n+new\n",
      truncated: true,
      error: null,
    });
  });

  it("keeps the server message when a diff fails", async () => {
    await primeGitSnapshot();
    const diffUrl = `${GIT_URL}/diff?file=src%2Fa.py&section=staged&expected_root=%2FUsers%2Fronnierocha%2Frepo`;
    mockFetch({
      [diffUrl]: jsonResponse(
        { ok: false, error: { code: "upstream", message: "diff failed" } },
        502,
      ),
    });

    useGitStore.getState().diff(PANE_ID, "src/a.py", "staged");
    await vi.waitFor(() => expect(useGitStore.getState().diffSheet?.isLoading).toBe(false));
    expect(useGitStore.getState().diffSheet?.error).toBe("diff failed");
  });

  it("closes a stale diff and refreshes status when the repository changes", async () => {
    await primeGitSnapshot();
    const diffUrl = `${GIT_URL}/diff?file=src%2Fa.py&section=staged&expected_root=%2FUsers%2Fronnierocha%2Frepo`;
    mockFetch({
      [diffUrl]: jsonResponse(
        {
          ok: false,
          error: {
            code: "git_repository_changed",
            message: "The pane is now in another repository",
          },
        },
        409,
      ),
      [GIT_URL]: jsonResponse({
        ...GIT_RESPONSE,
        root_path: "/Users/ronnierocha/other-repo",
      }),
    });

    useGitStore.getState().diff(PANE_ID, "src/a.py", "staged");
    await vi.waitFor(() =>
      expect(useGitStore.getState().byPane[PANE_ID]?.snapshot?.rootPath).toBe(
        "/Users/ronnierocha/other-repo",
      ),
    );

    expect(useGitStore.getState().diffSheet).toBe(null);
    expect(useToastStore.getState().message).toBe("The pane is now in another repository");
    expect(fetchMock.mock.calls.map((call) => call[0])).toEqual([diffUrl, GIT_URL]);
  });
});

describe("gitStore commit history", () => {
  it("expands a commit and loads its changed files", async () => {
    await primeGitSnapshot();
    const filesUrl = `${GIT_URL}/commit-files?hash=c10e3c23&expected_root=%2FUsers%2Fronnierocha%2Frepo`;
    mockFetch({
      [filesUrl]: jsonResponse({
        ok: true,
        hash: "c10e3c23",
        files: [{ status: "M", file: "src/old.py" }],
      }),
    });

    useGitStore.getState().toggleCommit(PANE_ID, "c10e3c23");
    expect(useGitStore.getState().byPane[PANE_ID]?.expandedCommitHash).toBe("c10e3c23");
    await vi.waitFor(() =>
      expect(useGitStore.getState().byPane[PANE_ID]?.commitFiles.c10e3c23?.loading).toBe(false),
    );
    expect(useGitStore.getState().byPane[PANE_ID]?.commitFiles.c10e3c23?.files).toEqual([
      { status: "M", file: "src/old.py" },
    ]);
  });

  it("loads a historical file diff into the shared inspector", async () => {
    await primeGitSnapshot();
    const diffUrl = `${GIT_URL}/commit-diff?hash=c10e3c23&file=src%2Fold.py&expected_root=%2FUsers%2Fronnierocha%2Frepo`;
    mockFetch({
      [diffUrl]: jsonResponse({
        ok: true,
        hash: "c10e3c23",
        file: "src/old.py",
        diff: "@@ -1 +1 @@\n-old\n+new\n",
        truncated: true,
      }),
    });

    useGitStore.getState().commitDiff(PANE_ID, "c10e3c23", "src/old.py");
    await vi.waitFor(() => expect(useGitStore.getState().diffSheet?.isLoading).toBe(false));
    expect(useGitStore.getState().diffSheet).toMatchObject({
      paneId: PANE_ID,
      file: "src/old.py",
      section: "commit",
      commitHash: "c10e3c23",
      diff: "@@ -1 +1 @@\n-old\n+new\n",
      truncated: true,
    });
  });

  it("blocks history reads without a displayed root and refreshes status", async () => {
    await primeGitSnapshot({ ...GIT_RESPONSE, root_path: "" });
    mockFetch({ [GIT_URL]: jsonResponse(GIT_RESPONSE) });

    useGitStore.getState().toggleCommit(PANE_ID, "c10e3c23");
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));

    expect(fetchMock.mock.calls[0]?.[0]).toBe(GIT_URL);
    expect(useGitStore.getState().byPane[PANE_ID]?.expandedCommitHash).toBe(null);
    expect(useToastStore.getState().message).toBe(
      "Refreshing Git status before loading commit history",
    );
  });

  it("collapses stale history when a commit request detects a new repository", async () => {
    await primeGitSnapshot();
    const filesUrl = `${GIT_URL}/commit-files?hash=c10e3c23&expected_root=%2FUsers%2Fronnierocha%2Frepo`;
    mockFetch({
      [filesUrl]: jsonResponse(
        {
          ok: false,
          error: {
            code: "git_repository_changed",
            message: "The pane changed repositories",
          },
        },
        409,
      ),
      [GIT_URL]: jsonResponse({
        ...GIT_RESPONSE,
        root_path: "/Users/ronnierocha/other-repo",
      }),
    });

    useGitStore.getState().toggleCommit(PANE_ID, "c10e3c23");
    await vi.waitFor(() =>
      expect(useGitStore.getState().byPane[PANE_ID]?.snapshot?.rootPath).toBe(
        "/Users/ronnierocha/other-repo",
      ),
    );

    expect(useGitStore.getState().byPane[PANE_ID]?.expandedCommitHash).toBe(null);
    expect(useGitStore.getState().byPane[PANE_ID]?.commitFiles).toEqual({});
    expect(useToastStore.getState().message).toBe("The pane changed repositories");
    expect(fetchMock.mock.calls.map((call) => call[0])).toEqual([filesUrl, GIT_URL]);
  });
});
