import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useConnectionStore } from "./connectionStore";
import { useNewSessionStore } from "./newSessionStore";

function reset() {
  useNewSessionStore.setState({
    isOpen: false,
    mode: "claude",
    projectPath: "~/Documents/Development/sample-app",
    branchName: "",
    jiraUrl: "",
    prompt: "",
    sessionName: "Shell",
    error: null,
    phase: "idle",
    pendingSelection: null,
    overlayDirectory: null,
  });
  useConnectionStore.setState({ tickRequestCount: 0 });
}

function okResponse(body: unknown) {
  return new Response(JSON.stringify(body), { status: 200 });
}

function lastRequestBody(fetchMock: ReturnType<typeof vi.fn>): Record<string, unknown> {
  const call = fetchMock.mock.calls[fetchMock.mock.calls.length - 1];
  return JSON.parse(String(call[1].body)) as Record<string, unknown>;
}

describe("newSessionStore", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    reset();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("open() resets the form to the iOS defaults", () => {
    const store = useNewSessionStore.getState();
    store.setMode("shell");
    store.setProjectPath("~/Other");
    store.setJiraUrl("https://x/browse/AB-1");
    store.open();

    const state = useNewSessionStore.getState();
    expect(state.isOpen).toBe(true);
    expect(state.mode).toBe("claude");
    expect(state.projectPath).toBe("~/Documents/Development/sample-app");
    expect(state.branchName).toBe("");
    expect(state.jiraUrl).toBe("");
    expect(state.prompt).toBe("");
    expect(state.sessionName).toBe("Shell");
    expect(state.error).toBeNull();
    expect(state.phase).toBe("idle");
  });

  it("auto-fills the branch from the JIRA URL only while the branch is empty (iOS parity)", () => {
    const store = useNewSessionStore.getState();
    store.setJiraUrl("https://doximity.atlassian.net/browse/IOSDOX-123");
    expect(useNewSessionStore.getState().branchName).toBe("IOSDOX-123");

    // User edits the branch — later URL changes must not overwrite it.
    useNewSessionStore.getState().setBranchName("custom-branch");
    useNewSessionStore.getState().setJiraUrl("https://doximity.atlassian.net/browse/AB-9");
    expect(useNewSessionStore.getState().branchName).toBe("custom-branch");

    // Clearing the branch re-enables auto-fill.
    useNewSessionStore.getState().setBranchName("");
    useNewSessionStore.getState().setJiraUrl("https://doximity.atlassian.net/browse/AB-9");
    expect(useNewSessionStore.getState().branchName).toBe("AB-9");
  });

  it("requires a non-empty project path (iOS error string)", async () => {
    const fetchMock = vi.fn(async () => okResponse({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    useNewSessionStore.getState().setProjectPath("   ");
    await useNewSessionStore.getState().submit();

    expect(useNewSessionStore.getState().error).toBe("Project path is required.");
    expect(useNewSessionStore.getState().phase).toBe("idle");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("sends the iOS claude payload and enters switching on success", async () => {
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) =>
      okResponse({
        ok: true,
        workspace: { index: 4, uuid: "uuid-4" },
        worktreePath: "/tmp/wt",
        branchName: "IOSDOX-123",
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const store = useNewSessionStore.getState();
    store.open();
    store.setJiraUrl("https://doximity.atlassian.net/browse/IOSDOX-123");
    store.setPrompt("Do the thing");
    await useNewSessionStore.getState().submit();

    expect(fetchMock.mock.calls[0][0]).toBe("/api/new-session");
    expect(lastRequestBody(fetchMock)).toEqual({
      projectPath: "~/Documents/Development/sample-app",
      branchName: "IOSDOX-123",
      jiraUrl: "https://doximity.atlassian.net/browse/IOSDOX-123",
      prompt: "Do the thing",
      command: "claude",
      sessionName: "",
    });

    const state = useNewSessionStore.getState();
    expect(state.isOpen).toBe(false);
    expect(state.phase).toBe("switching");
    expect(state.pendingSelection).toEqual({ uuid: "uuid-4", index: 4 });
    expect(state.overlayDirectory).toBe("~/Documents/Development/sample-app");

    // iOS parity: catch-up refresh 750 ms after success.
    expect(useConnectionStore.getState().tickRequestCount).toBe(0);
    vi.advanceTimersByTime(749);
    expect(useConnectionStore.getState().tickRequestCount).toBe(0);
    vi.advanceTimersByTime(1);
    expect(useConnectionStore.getState().tickRequestCount).toBe(1);
  });

  it("sends the iOS shell payload (command zsh, name defaulted to Shell)", async () => {
    const fetchMock = vi.fn(async () => okResponse({ ok: true, workspace: { index: 7 } }));
    vi.stubGlobal("fetch", fetchMock);

    const store = useNewSessionStore.getState();
    store.open();
    store.setMode("shell");
    store.setJiraUrl("https://x/browse/AB-1");
    store.setPrompt("ignored for shell");
    store.setSessionName("   ");
    await useNewSessionStore.getState().submit();

    expect(lastRequestBody(fetchMock)).toEqual({
      projectPath: "~/Documents/Development/sample-app",
      branchName: "",
      jiraUrl: "",
      prompt: "",
      command: "zsh",
      sessionName: "Shell",
    });
    expect(useNewSessionStore.getState().phase).toBe("switching");
    // Index-only pending selection when the server returns no uuid.
    expect(useNewSessionStore.getState().pendingSelection).toEqual({ uuid: null, index: 7 });
  });

  it("keeps the modal open with the server error string on failure", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ok: false, error: "Workspace already exists" }), { status: 409 }));
    vi.stubGlobal("fetch", fetchMock);

    useNewSessionStore.getState().open();
    await useNewSessionStore.getState().submit();

    const state = useNewSessionStore.getState();
    expect(state.isOpen).toBe(true);
    expect(state.phase).toBe("idle");
    expect(state.error).toBe("Workspace already exists");
    expect(state.pendingSelection).toBeNull();
  });

  it("resolves the pending selection by uuid first, then index (iOS matchingWorkspaceID)", () => {
    const workspaces = [
      { hasClaude: false, index: 1, name: "a", uuid: "uuid-1", enabled: true },
      { hasClaude: false, index: 9, name: "new", uuid: "uuid-9", enabled: true },
    ];
    useNewSessionStore.setState({ pendingSelection: { uuid: "uuid-9", index: 1 } });
    // uuid wins even when the stale index matches an older workspace.
    expect(useNewSessionStore.getState().resolvePendingSelection(workspaces)).toBe("uuid-9");

    useNewSessionStore.setState({ pendingSelection: { uuid: "missing", index: 9 } });
    expect(useNewSessionStore.getState().resolvePendingSelection(workspaces)).toBe("uuid-9");

    useNewSessionStore.setState({ pendingSelection: { uuid: null, index: 5 } });
    expect(useNewSessionStore.getState().resolvePendingSelection(workspaces)).toBeNull();

    useNewSessionStore.getState().finishSelection();
    const state = useNewSessionStore.getState();
    expect(state.phase).toBe("idle");
    expect(state.pendingSelection).toBeNull();
    expect(state.overlayDirectory).toBeNull();
  });
});
