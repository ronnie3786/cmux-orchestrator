import { describe, expect, it } from "vitest";
import { RADAR_MAX_CELLS, radarPanes, radarStateForPane } from "./TopologyRadar";
import type { Pane, PiSemantic } from "../../types/herdr";

// Pane shapes mirror the live /api/v1/workspaces capture (P10-run-A):
// most panes are `idle` + pi_semantic, shells are `unknown` without it,
// wH carries a `done` pane, and wG has 10 panes for the overflow rule.

const PI_SEMANTIC: PiSemantic = {
  available: true,
  connected: true,
  protocol_version: 1,
  session_id: "s1",
  cursor: 0,
  oldest_cursor: 0,
  capabilities: {
    prompt: true,
    steer: true,
    followUp: true,
    abort: true,
    listModels: true,
    setModel: true,
    setThinkingLevel: true,
    interactionResponse: true,
  },
  generated_at: "2026-01-01T00:00:00Z",
};

function pane(paneId: string, over: Partial<Pane> = {}): Pane {
  return {
    pane_id: paneId,
    terminal_id: `term-${paneId}`,
    workspace_id: paneId.slice(0, 2),
    tab_id: "t1",
    focused: false,
    cwd: "/tmp",
    foreground_cwd: "/tmp",
    agent_status: "idle",
    scroll: { offset_from_bottom: 0, max_offset_from_bottom: 0, viewport_rows: 24 },
    revision: 1,
    pi_semantic: PI_SEMANTIC,
    ...over,
  };
}

describe("radarStateForPane", () => {
  it("idle agent → idle (muted cell)", () => {
    expect(radarStateForPane(pane("w1:p1"))).toBe("idle");
  });

  it("unknown agent (plain shell) → idle", () => {
    expect(radarStateForPane(pane("wB:p1", { agent_status: "unknown", pi_semantic: undefined }))).toBe(
      "idle",
    );
  });

  it("working agent → working (pulse)", () => {
    expect(radarStateForPane(pane("wC:p1", { agent_status: "working" }))).toBe("working");
  });

  it("blocked agent (Swift: 'Needs you', needsAttention) → blocked", () => {
    expect(radarStateForPane(pane("wD:p1", { agent_status: "blocked" }))).toBe("blocked");
  });

  it("done agent (Swift: 'Ready', needsAttention) → done", () => {
    expect(radarStateForPane(pane("wH:pM", { agent_status: "done" }))).toBe("done");
  });

  it("pi_semantic presence never changes the state", () => {
    for (const status of ["idle", "working", "blocked", "done"] as const) {
      expect(radarStateForPane(pane("p", { agent_status: status }))).toBe(
        radarStateForPane(pane("p", { agent_status: status, pi_semantic: PI_SEMANTIC })),
      );
    }
  });
});

describe("radarPanes (overflow rule)", () => {
  it("grid shows at most 4 cells", () => {
    expect(RADAR_MAX_CELLS).toBe(4);
  });

  it("zero panes → no cells", () => {
    expect(radarPanes([])).toEqual([]);
  });

  it("≤4 panes → all of them", () => {
    const panes = [pane("w4:p1"), pane("w4:p2"), pane("w4:p3")];
    expect(radarPanes(panes).map((p) => p.pane_id)).toEqual(["w4:p1", "w4:p2", "w4:p3"]);
  });

  it(">4 panes → first 4 in stable pane_id order (live wG: 10 panes)", () => {
    const panes = ["wG:p9", "wG:pA", "wG:p1", "wG:p5", "wG:p3", "wG:p4"].map((id) => pane(id));
    expect(radarPanes(panes).map((p) => p.pane_id)).toEqual(["wG:p1", "wG:p3", "wG:p4", "wG:p5"]);
  });

  it("does not mutate the input order", () => {
    const panes = [pane("wG:p9"), pane("wG:p1")];
    radarPanes(panes);
    expect(panes.map((p) => p.pane_id)).toEqual(["wG:p9", "wG:p1"]);
  });
});
