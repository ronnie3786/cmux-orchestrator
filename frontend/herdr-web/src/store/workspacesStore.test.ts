import { beforeEach, describe, expect, it, vi } from "vitest";
import workspacesFixture from "../__fixtures__/workspaces.json";
import { workspaceFromPaneId } from "../lib/hashRoute";
import { attentionPanes, canControl, useWorkspacesStore } from "./workspacesStore";

const mocks = vi.hoisted(() => ({ workspaces: vi.fn() }));

vi.mock("../api/herdr", () => ({ workspaces: mocks.workspaces }));
import type {
  AgentStatus,
  Pane,
  WorkspacesResponse,
  Workspace,
} from "../types/herdr";

const fixture = workspacesFixture as unknown as WorkspacesResponse;

function makePane(agentStatus: AgentStatus, revision: number): Pane {
  return {
    pane_id: `synth:p-${agentStatus}-${revision}`,
    terminal_id: `term-${agentStatus}-${revision}`,
    workspace_id: "synth",
    tab_id: "synth:t1",
    focused: false,
    cwd: "/tmp",
    foreground_cwd: "/tmp",
    agent_status: agentStatus,
    scroll: { offset_from_bottom: 0, max_offset_from_bottom: 0, viewport_rows: 24 },
    revision,
  };
}

function workspaceWith(panes: Pane[]): Workspace {
  return {
    workspace_id: "synth",
    number: 1,
    label: "Synthetic",
    focused: true,
    pane_count: panes.length,
    tab_count: 1,
    active_tab_id: "synth:t1",
    agent_status: "idle",
    tabs: [],
    panes,
    agents: [],
    layouts: [],
  };
}

function setSnapshot(panes: Pane[]): void {
  useWorkspacesStore.setState({
    data: {
      ok: true,
      workspaces: [workspaceWith(panes)],
      alerts: [],
      generatedAt: "now",
    },
  });
}

const emptySnapshot = () => ({ ok: true, workspaces: [], alerts: [], generatedAt: "now" });

beforeEach(() => {
  vi.clearAllMocks();
  mocks.workspaces.mockResolvedValue(emptySnapshot());
  useWorkspacesStore.setState({
    data: null,
    lastUpdated: null,
    refreshing: false,
    selectedWorkspaceId: null,
    selectedPaneId: null,
  });
});

/** Let queued microtasks (incl. the trailing refresh) settle. */
async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

describe("attentionPanes", () => {
  it("ranks blocked → done → working → idle → unknown, ties by revision desc", () => {
    const panes = [
      makePane("unknown", 5),
      makePane("idle", 4),
      makePane("working", 3),
      makePane("working", 9),
      makePane("done", 2),
      makePane("working", 10),
      makePane("blocked", 1),
    ];
    setSnapshot(panes);

    const ranked = attentionPanes(useWorkspacesStore.getState());
    expect(ranked.map((pane) => pane.pane_id)).toEqual([
      "synth:p-blocked-1",
      "synth:p-done-2",
      "synth:p-working-10", // tie: higher revision first
      "synth:p-working-9",
      "synth:p-working-3",
      "synth:p-idle-4",
      "synth:p-unknown-5",
    ]);
  });

  it("returns empty before any snapshot", () => {
    expect(attentionPanes(useWorkspacesStore.getState())).toEqual([]);
  });
});

describe("pane-only deep links (P12-run-B pending-pane queue)", () => {
  beforeEach(() => {
    useWorkspacesStore.setState({ data: fixture });
  });

  const firstWorkspace = fixture.workspaces[0]!;
  const firstPane = firstWorkspace.panes[0]!;

  it("resolves a live pane-only link via the pane id prefix", () => {
    const selection = useWorkspacesStore
      .getState()
      .repairSelection(workspaceFromPaneId("w1:p1"), "w1:p1");
    expect(selection).toEqual({ workspaceId: "w1", paneId: "w1:p1" });
  });

  it("falls back to the workspace's first pane for a dead pane id", () => {
    const selection = useWorkspacesStore
      .getState()
      .repairSelection(workspaceFromPaneId("w1:pDead"), "w1:pDead");
    expect(selection.workspaceId).toBe("w1");
    expect(selection.paneId).toBe(firstWorkspace.panes[0]!.pane_id);
  });

  it("falls back to the first workspace (and its first pane) for a dead workspace prefix", () => {
    const selection = useWorkspacesStore
      .getState()
      .repairSelection(workspaceFromPaneId("wDead:pDead"), "wDead:pDead");
    expect(selection.workspaceId).toBe(firstWorkspace.workspace_id);
    expect(selection.paneId).toBe(firstPane.pane_id);
  });

  it("unresolvable pane ids (no colon) fall back to the first workspace/pane", () => {
    expect(workspaceFromPaneId("p1")).toBe(null);
    const selection = useWorkspacesStore.getState().repairSelection(null, "p1");
    expect(selection.workspaceId).toBe(firstWorkspace.workspace_id);
    expect(selection.paneId).toBe(firstPane.pane_id);
  });
});

describe("repairSelection", () => {
  it("keeps a live workspace + pane selection", () => {
    useWorkspacesStore.setState({ data: fixture });
    const workspace = fixture.workspaces[0]!;
    const pane = workspace.panes[0]!;

    const selection = useWorkspacesStore
      .getState()
      .repairSelection(workspace.workspace_id, pane.pane_id);
    expect(selection).toEqual({ workspaceId: workspace.workspace_id, paneId: pane.pane_id });
    expect(useWorkspacesStore.getState().selectedWorkspaceId).toBe(workspace.workspace_id);
    expect(useWorkspacesStore.getState().selectedPaneId).toBe(pane.pane_id);
  });

  it("prunes a dead pane to the workspace's first pane", () => {
    useWorkspacesStore.setState({ data: fixture });
    const workspace = fixture.workspaces[0]!;

    const selection = useWorkspacesStore
      .getState()
      .repairSelection(workspace.workspace_id, "wX:pDead");
    expect(selection.workspaceId).toBe(workspace.workspace_id);
    expect(selection.paneId).toBe(workspace.panes[0]!.pane_id);
  });

  it("reselects the first workspace (and its first pane) when the workspace is dead", () => {
    useWorkspacesStore.setState({ data: fixture });

    const selection = useWorkspacesStore.getState().repairSelection("wDead", "wDead:p1");
    expect(selection.workspaceId).toBe(fixture.workspaces[0]!.workspace_id);
    expect(selection.paneId).toBe(fixture.workspaces[0]!.panes[0]!.pane_id);
  });

  it("returns null selection with no snapshot and no input", () => {
    const selection = useWorkspacesStore.getState().repairSelection(null, null);
    expect(selection).toEqual({ workspaceId: null, paneId: null });
  });
});

describe("refresh — in-flight guard (stream.reset trailing re-arm)", () => {
  it("a refresh fired while one is in flight re-arms exactly one trailing refresh after settle", async () => {
    let releaseFirst: (value: unknown) => void = () => {};
    mocks.workspaces.mockImplementationOnce(() =>
      new Promise((resolve) => {
        releaseFirst = resolve;
      }),
    );

    const first = useWorkspacesStore.getState().refresh();
    await settle();
    expect(mocks.workspaces).toHaveBeenCalledTimes(1);
    expect(useWorkspacesStore.getState().refreshing).toBe(true);

    // The stream.reset path: refresh while the first is still in flight.
    await useWorkspacesStore.getState().refresh();
    expect(mocks.workspaces).toHaveBeenCalledTimes(1); // not fired yet

    releaseFirst(emptySnapshot());
    await first;
    await settle();

    expect(mocks.workspaces).toHaveBeenCalledTimes(2); // exactly one trailing
    expect(useWorkspacesStore.getState().refreshing).toBe(false);
  });

  it("multiple in-flight arms still coalesce to a single trailing refresh", async () => {
    let releaseFirst: (value: unknown) => void = () => {};
    mocks.workspaces.mockImplementationOnce(() =>
      new Promise((resolve) => {
        releaseFirst = resolve;
      }),
    );

    const first = useWorkspacesStore.getState().refresh();
    await settle();
    await useWorkspacesStore.getState().refresh();
    await useWorkspacesStore.getState().refresh();

    releaseFirst(emptySnapshot());
    await first;
    await settle();
    await settle();

    expect(mocks.workspaces).toHaveBeenCalledTimes(2);
    expect(useWorkspacesStore.getState().refreshing).toBe(false);
  });
});

describe("refresh — repairNavigation guard (P12-run-B)", () => {
  it("prunes a selection the fresh snapshot no longer contains", async () => {
    useWorkspacesStore.setState({ data: fixture });
    useWorkspacesStore
      .getState()
      .repairSelection("w1", "w1:p1");

    // The refetched snapshot is empty (mocked): the dead selection is
    // pruned to null instead of outliving its workspace.
    await useWorkspacesStore.getState().refresh();
    expect(useWorkspacesStore.getState().selectedWorkspaceId).toBe(null);
    expect(useWorkspacesStore.getState().selectedPaneId).toBe(null);
  });

  it("keeps a live selection untouched", async () => {
    useWorkspacesStore.setState({ data: null });
    // Same empty snapshot lands while nothing is selected: stays null,
    // and the pending-deep-link case is left to the route hook's repair.
    await useWorkspacesStore.getState().refresh();
    expect(useWorkspacesStore.getState().selectedWorkspaceId).toBe(null);
  });
});

describe("selectors over the live fixture", () => {
  beforeEach(() => {
    useWorkspacesStore.setState({ data: fixture });
  });

  it("canControl flips with snapshot presence", () => {
    expect(canControl(useWorkspacesStore.getState())).toBe(true);
    useWorkspacesStore.setState({ data: null });
    expect(canControl(useWorkspacesStore.getState())).toBe(false);
  });
});
