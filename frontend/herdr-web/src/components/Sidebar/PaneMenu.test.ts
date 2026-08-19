import { describe, expect, it } from "vitest";
import { AGENT_PICKER, menuItemsFor, type PaneMenuItem } from "./PaneMenu";
import type { AgentStatus, Pane } from "../../types/herdr";

function makePane(overrides: Partial<Pane> = {}): Pane {
  return {
    pane_id: "w1:p1",
    terminal_id: "term-1",
    workspace_id: "w1",
    tab_id: "w1:t1",
    focused: false,
    cwd: "/tmp",
    foreground_cwd: "/tmp",
    agent_status: "unknown",
    scroll: { offset_from_bottom: 0, max_offset_from_bottom: 0, viewport_rows: 24 },
    revision: 1,
    ...overrides,
  };
}

function ids(items: PaneMenuItem[]): string[] {
  return items.map((item) => item.id);
}

const piSemantic = {
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
    listModels: false,
    setModel: false,
    setThinkingLevel: false,
    interactionResponse: false,
  },
  generated_at: "2026-01-01T00:00:00.000Z",
};

describe("menuItemsFor", () => {
  it("Pi pane: mode toggle present, start agent absent", () => {
    const pane = makePane({ agent: "pi", agent_status: "idle", pi_semantic: piSemantic });
    const items = menuItemsFor(pane, { demo: false });
    const idList = ids(items);
    expect(idList).toContain("viewChat");
    expect(idList).toContain("viewTerminal");
    expect(idList).not.toContain("startAgent");
    // Auto default is chat until the user overrides.
    expect(items.find((item) => item.id === "viewChat")?.checked).toBe(true);
    expect(items.find((item) => item.id === "viewTerminal")?.checked).toBe(false);
  });

  it("Pi pane honors a stored terminal override in the toggle", () => {
    const pane = makePane({ agent: "pi", agent_status: "idle", pi_semantic: piSemantic });
    const items = menuItemsFor(pane, { demo: false, mode: "terminal" });
    expect(items.find((item) => item.id === "viewChat")?.checked).toBe(false);
    expect(items.find((item) => item.id === "viewTerminal")?.checked).toBe(true);
  });

  it("non-Pi pane: no mode toggle, View section present (Terminal/Git/Skills)", () => {
    const pane = makePane({ agent: "codex", agent_status: "working" });
    const items = menuItemsFor(pane, { demo: false });
    const idList = ids(items);
    expect(idList).not.toContain("viewChat");
    expect(idList).not.toContain("viewTerminal");
    expect(idList).toContain("viewSection");
    expect(idList).toContain("viewPaneTerminal");
    expect(idList).toContain("viewPaneGit");
    expect(idList).toContain("viewPaneSkills");
    // Default view is terminal.
    expect(items.find((item) => item.id === "viewPaneTerminal")?.checked).toBe(true);
    expect(items.find((item) => item.id === "viewPaneGit")?.checked).toBe(false);
  });

  it("non-Pi pane honors a stored git override in the View section", () => {
    const pane = makePane({ agent: "codex", agent_status: "working" });
    const items = menuItemsFor(pane, { demo: false, view: "git" });
    expect(items.find((item) => item.id === "viewPaneGit")?.checked).toBe(true);
    expect(items.find((item) => item.id === "viewPaneTerminal")?.checked).toBe(false);
  });

  it("working agent pane: interrupt present, start agent absent", () => {
    const pane = makePane({ agent: "codex", agent_status: "working" });
    const idList = ids(menuItemsFor(pane, { demo: false }));
    expect(idList).toContain("interrupt");
    expect(idList).not.toContain("startAgent");
  });

  it("shell pane: start agent present, interrupt absent", () => {
    const pane = makePane({ agent_status: "unknown" });
    const idList = ids(menuItemsFor(pane, { demo: false }));
    expect(idList).toContain("startAgent");
    expect(idList).not.toContain("interrupt");
  });

  it("rename + close are always present", () => {
    for (const status of ["blocked", "done", "working", "idle", "unknown"] as AgentStatus[]) {
      const idList = ids(menuItemsFor(makePane({ agent_status: status }), { demo: false }));
      expect(idList).toContain("rename");
      expect(idList).toContain("close");
    }
  });

  it("demo mode: every mutating item disabled, view toggles still enabled (local state)", () => {
    const shell = menuItemsFor(makePane({ agent_status: "unknown" }), { demo: true });
    const localView = new Set(["viewSection", "viewPaneTerminal", "viewPaneGit", "viewPaneSkills"]);
    for (const item of shell) {
      if (item.id === "viewSection") continue;
      expect(item.enabled).toBe(localView.has(item.id));
    }

    const pi = makePane({ agent: "pi", agent_status: "idle", pi_semantic: piSemantic });
    const piItems = menuItemsFor(pi, { demo: true });
    expect(piItems.find((item) => item.id === "viewChat")?.enabled).toBe(true);
    expect(piItems.find((item) => item.id === "viewTerminal")?.enabled).toBe(true);
    expect(
      piItems.filter((item) => item.id !== "viewChat" && item.id !== "viewTerminal").every(
        (item) => item.id === "viewSection" || !item.enabled,
      ),
    ).toBe(true);
  });

  it("labels are byte-exact per doc 01 §6", () => {
    const items = menuItemsFor(makePane({ agent: "codex", agent_status: "unknown" }), { demo: false });
    const labelOf = (id: string) => items.find((item) => item.id === id)?.label;
    expect(labelOf("startAgent")).toBe("Start agent");
    expect(labelOf("rename")).toBe("Rename pane");
    expect(labelOf("close")).toBe("Close pane");
    expect(labelOf("viewSection")).toBe("View");
    expect(labelOf("viewPaneTerminal")).toBe("Terminal");
    expect(labelOf("viewPaneGit")).toBe("Git");
    expect(labelOf("viewPaneSkills")).toBe("Skills");
    const working = menuItemsFor(makePane({ agent: "codex", agent_status: "working" }), {
      demo: false,
    });
    expect(working.find((item) => item.id === "interrupt")?.label).toBe("Interrupt");
  });
});

describe("AGENT_PICKER", () => {
  it("matches the iOS start-agent menu byte-exact (doc 01 §3/§6)", () => {
    expect(AGENT_PICKER.map((option) => option.label)).toEqual(["Codex", "Claude", "OpenCode"]);
    expect(AGENT_PICKER.map((option) => option.agent)).toEqual([
      "codex",
      "claude",
      "opencode",
    ]);
  });
});
