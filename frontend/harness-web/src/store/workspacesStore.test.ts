import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useWorkspacesStore } from "./workspacesStore";
import { useConnectionStore } from "./connectionStore";
import { useNewSessionStore } from "./newSessionStore";
import type { CmuxNotification, FeedItem, HarnessStatus, Workspace } from "../api/types";

function installLocalStorage() {
  const store = new Map<string, string>();
  (globalThis as { localStorage?: unknown }).localStorage = {
    getItem: (key: string) => (store.has(key) ? store.get(key) : null),
    setItem: (key: string, value: string) => {
      store.set(key, String(value));
    },
    removeItem: (key: string) => {
      store.delete(key);
    },
    clear: () => store.clear(),
  };
}

function workspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    hasClaude: true,
    index: 1,
    name: "cmux-harness",
    uuid: "uuid-1",
    enabled: true,
    ...overrides,
  };
}

function status(workspaces: Workspace[]): HarnessStatus {
  return { enabled: true, workspaces, pollInterval: 2, socketFound: true, connected: true };
}

const INITIAL = {
  workspaces: [] as Workspace[],
  notifications: [] as CmuxNotification[],
  feedItems: [] as FeedItem[],
  lastUpdated: null,
  hasReceivedStatus: false,
  selectedGroupID: null,
  selectedWorkspaceID: null,
};

describe("workspacesStore", () => {
  beforeEach(() => {
    installLocalStorage();
    useWorkspacesStore.setState(INITIAL);
    useConnectionStore.setState({ errorMessage: null });
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
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("applies status and clears a stale selection", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, _init?: RequestInit) => new Response(JSON.stringify({ ok: true }), { status: 200 })),
    );
    const target = workspace({});
    useWorkspacesStore.getState().applyStatus(status([target]));
    useWorkspacesStore.getState().selectWorkspace("uuid-1");
    expect(useWorkspacesStore.getState().selectedWorkspaceID).toBe("uuid-1");
    expect(useWorkspacesStore.getState().selectedGroupID).toBe("uuid-1");

    // The workspace disappears from a later poll.
    useWorkspacesStore.getState().applyStatus(status([]));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(useWorkspacesStore.getState().selectedWorkspaceID).toBeNull();
    expect(useWorkspacesStore.getState().selectedGroupID).toBeNull();
    expect(useWorkspacesStore.getState().hasReceivedStatus).toBe(true);
  });

  it("selecting a pane fires push/clear and marks its notifications read optimistically", async () => {
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) =>
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const target = workspace({ uuid: "w9", surfaceUuid: "su9", surfaceId: "s9", surfaceLabel: "Terminal" });
    useWorkspacesStore.getState().applyStatus(status([target]));
    useWorkspacesStore.getState().applyNotifications({
      ok: true,
      notifications: [
        { id: "1", is_read: false, workspace_id: "w9" },
        { id: "2", is_read: false, workspace_id: "someone-else" },
      ],
    });

    useWorkspacesStore.getState().selectWorkspace("w9|s9");
    // Let the fire-and-forget promises settle.
    await new Promise((resolve) => setTimeout(resolve, 0));

    const urls = fetchMock.mock.calls.map(([url]) => String(url));
    expect(urls).toContain("/api/push/clear");
    expect(urls).toContain("/api/notifications/read");

    const clearBody = fetchMock.mock.calls.find(([url]) => String(url) === "/api/push/clear")?.[1]?.body as string;
    expect(JSON.parse(clearBody)).toEqual({ workspaceID: "w9|s9", workspaceUUID: "w9", surfaceID: "s9" });

    // Optimistic mark-read: only the selected session's notification flipped.
    const notifications = useWorkspacesStore.getState().notifications;
    expect(notifications.find((n) => n.id === "1")?.is_read).toBe(true);
    expect(notifications.find((n) => n.id === "2")?.is_read).toBe(false);
  });

  it("selectGroup picks the primary pane, and keeps the selected one", () => {
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) =>
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    useWorkspacesStore.getState().applyStatus(status([
      workspace({ uuid: "g1", index: 2, surfaceLabel: "Two", surfaceId: "s2" }),
      workspace({ uuid: "g1", index: 1, surfaceLabel: "One", surfaceId: "s1" }),
    ]));

    useWorkspacesStore.getState().selectGroup("g1");
    expect(useWorkspacesStore.getState().selectedWorkspaceID).toBe("g1|s1");

    // Re-selecting the group keeps the already-selected pane.
    useWorkspacesStore.getState().selectWorkspace("g1|s2");
    useWorkspacesStore.getState().selectGroup("g1");
    expect(useWorkspacesStore.getState().selectedWorkspaceID).toBe("g1|s2");
  });

  it("toggles stars optimistically and reports failures", async () => {
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) => {
      if (String(_url) === "/api/workspace-star") {
        return new Response(JSON.stringify({ ok: false, error: "nope" }), { status: 500 });
      }
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });
    vi.stubGlobal("fetch", fetchMock);

    useWorkspacesStore.getState().applyStatus(status([workspace({ index: 3, starred: false })]));

    useWorkspacesStore.getState().toggleStar(3, true);
    expect(useWorkspacesStore.getState().workspaces[0]?.starred).toBe(true);

    await new Promise((resolve) => setTimeout(resolve, 0));
    // Reverted after the server error; the shared error banner shows it.
    expect(useWorkspacesStore.getState().workspaces[0]?.starred).toBe(false);
    expect(useConnectionStore.getState().errorMessage).toBe("nope");
  });

  it("auto-selects the created session once it appears in status (iOS refreshSucceeded parity)", async () => {
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) =>
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    // A new session was just created; the poll hasn't seen it yet.
    useNewSessionStore.setState({ phase: "switching", pendingSelection: { uuid: "uuid-9", index: 9 } });
    useWorkspacesStore.getState().applyStatus(status([workspace({})]));
    expect(useWorkspacesStore.getState().selectedWorkspaceID).toBeNull();

    // The next poll lists it — it gets selected and the overlay state clears.
    useWorkspacesStore.getState().applyStatus(status([
      workspace({}),
      workspace({ uuid: "uuid-9", index: 9, name: "IOSDOX-123" }),
    ]));

    expect(useWorkspacesStore.getState().selectedWorkspaceID).toBe("uuid-9");
    const newSession = useNewSessionStore.getState();
    expect(newSession.pendingSelection).toBeNull();
    expect(newSession.phase).toBe("idle");

    // Let the fire-and-forget selection calls settle.
    await new Promise((resolve) => setTimeout(resolve, 0));
    const urls = fetchMock.mock.calls.map(([url]) => String(url));
    expect(urls).toContain("/api/push/clear");
  });
});
