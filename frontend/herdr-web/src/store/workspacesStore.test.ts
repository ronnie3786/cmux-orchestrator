import { beforeEach, describe, expect, it } from "vitest";
import workspacesFixture from "../__fixtures__/workspaces.json";
import {
  attentionPanes,
  canControl,
  useWorkspacesStore,
  unreadAlertCount,
  visibleWorkspaces,
} from "./workspacesStore";
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

beforeEach(() => {
  useWorkspacesStore.setState({
    data: null,
    lastUpdated: null,
    refreshing: false,
    selectedWorkspaceId: null,
    selectedPaneId: null,
  });
});

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

describe("selectors over the live fixture", () => {
  beforeEach(() => {
    useWorkspacesStore.setState({ data: fixture });
  });

  it("visibleWorkspaces returns the full snapshot list", () => {
    expect(visibleWorkspaces(useWorkspacesStore.getState())).toHaveLength(fixture.workspaces.length);
  });

  it("unreadAlertCount counts !isRead alerts in the snapshot", () => {
    const expected = fixture.alerts.filter((alert) => !alert.isRead).length;
    expect(unreadAlertCount(useWorkspacesStore.getState())).toBe(expected);
  });

  it("canControl flips with snapshot presence", () => {
    expect(canControl(useWorkspacesStore.getState())).toBe(true);
    useWorkspacesStore.setState({ data: null });
    expect(canControl(useWorkspacesStore.getState())).toBe(false);
  });
});
