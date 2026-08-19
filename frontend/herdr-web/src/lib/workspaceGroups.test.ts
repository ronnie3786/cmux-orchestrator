import { describe, expect, it } from "vitest";
import {
  branchLabel,
  chatDisplayName,
  compactStatus,
  filterGroups,
  groups,
  groupMatchesSearch,
  needsAttention,
  STATUS_COMPACT,
  STATUS_TITLE,
  statusTitle,
  type ChatRow,
} from "./workspaceGroups";
import type { AgentStatus, Pane, Tab, Workspace } from "../types/herdr";

function pane(over: Partial<Pane> & { pane_id: string; tab_id: string }): Pane {
  return {
    terminal_id: `term-${over.pane_id}`,
    workspace_id: "w1",
    focused: false,
    cwd: "/tmp",
    foreground_cwd: "/tmp",
    agent_status: "idle",
    scroll: { offset_from_bottom: 0, max_offset_from_bottom: 0, viewport_rows: 24 },
    revision: 1,
    ...over,
  };
}

function tab(over: Partial<Tab> & { tab_id: string }): Tab {
  return {
    workspace_id: "w1",
    number: 1,
    label: "Tab 1",
    focused: false,
    pane_count: 0,
    agent_status: "idle",
    ...over,
  };
}

function workspace(over: Partial<Workspace> & { workspace_id: string }): Workspace {
  return {
    number: 1,
    label: "Synthetic",
    focused: false,
    pane_count: 0,
    tab_count: 0,
    active_tab_id: "",
    agent_status: "idle",
    tabs: [],
    panes: [],
    agents: [],
    layouts: [],
    ...over,
  };
}

describe("status vocabulary (byte-exact, doc 01 §6)", () => {
  it("workspace-level titles", () => {
    expect(STATUS_TITLE).toEqual({
      blocked: "Needs you",
      done: "Ready",
      working: "Working",
      idle: "Idle",
      unknown: "Shell",
    });
    expect(statusTitle("blocked")).toBe("Needs you");
  });

  it("compact pane-level titles", () => {
    expect(STATUS_COMPACT).toEqual({
      blocked: "Blocked",
      done: "Done",
      working: "Working",
      idle: "Idle",
      unknown: "Unknown",
    });
  });

  it("compactStatus renders lowercased", () => {
    expect(compactStatus("blocked")).toBe("blocked");
    expect(compactStatus("done")).toBe("done");
    expect(compactStatus("working")).toBe("working");
    expect(compactStatus("idle")).toBe("idle");
    expect(compactStatus("unknown")).toBe("unknown");
  });

  it("needsAttention = blocked || done (iOS parity)", () => {
    expect(needsAttention("blocked")).toBe(true);
    expect(needsAttention("done")).toBe(true);
    for (const status of ["working", "idle", "unknown"] as AgentStatus[]) {
      expect(needsAttention(status)).toBe(false);
    }
  });
});

describe("display helpers", () => {
  it("branchLabel falls back to 'shell' without a worktree", () => {
    expect(branchLabel(workspace({ workspace_id: "w" }))).toBe("shell");
  });

  it("branchLabel uses repo_name for a main checkout", () => {
    expect(
      branchLabel(
        workspace({
          workspace_id: "w",
          worktree: {
            repo_key: "/r/iOS-Doximity/.git",
            repo_name: "iOS-Doximity",
            repo_root: "/r/iOS-Doximity",
            checkout_path: "/r/iOS-Doximity",
            is_linked_worktree: false,
          },
        }),
      ),
    ).toBe("iOS-Doximity");
  });

  it("branchLabel uses the checkout basename for a linked worktree", () => {
    expect(
      branchLabel(
        workspace({
          workspace_id: "w",
          worktree: {
            repo_key: "/r/iOS-Doximity/.git",
            repo_name: "iOS-Doximity",
            repo_root: "/r/iOS-Doximity",
            checkout_path: "/r/iOS-Doximity/worktrees/iOS-Doximity-IOSDOX-27253-x",
            is_linked_worktree: true,
          },
        }),
      ),
    ).toBe("iOS-Doximity-IOSDOX-27253-x");
  });

  it("chatDisplayName: label → stripped title → title → pane id", () => {
    const base = pane({ pane_id: "p", tab_id: "t" });
    expect(chatDisplayName({ ...base, label: "  My Label  " })).toBe("My Label");
    expect(chatDisplayName({ ...base, label: undefined, terminal_title: "π - raw", terminal_title_stripped: "π - clean" })).toBe(
      "π - clean",
    );
    expect(chatDisplayName({ ...base, label: undefined, terminal_title: "π - raw" })).toBe("π - raw");
    expect(chatDisplayName(base)).toBe("p");
  });
});

describe("groups", () => {
  it("sorts by number and groups panes under tabs", () => {
    const w1 = workspace({
      workspace_id: "w1",
      number: 2,
      tabs: [tab({ tab_id: "w1:t2", number: 2, label: "second" }), tab({ tab_id: "w1:t1", number: 1, label: "first" })],
      panes: [
        pane({ pane_id: "w1:p1", tab_id: "w1:t1", revision: 3, agent_status: "working" }),
        pane({ pane_id: "w1:p2", tab_id: "w1:t2", revision: 5, agent_status: "done" }),
        pane({ pane_id: "w1:p3", tab_id: "w1:gone", revision: 1 }),
      ],
    });
    const w2 = workspace({ workspace_id: "w2", number: 1 });

    const result = groups([w1, w2]);
    expect(result.map((group) => group.workspaceId)).toEqual(["w2", "w1"]);

    const group = result[1];
    expect(group).toBeDefined();
    expect(group?.tabSections.map((section) => section.tab.label)).toEqual(["first", "second"]);
    expect(group?.tabSections[0]?.chats.map((chat) => chat.paneId)).toEqual(["w1:p1"]);
    expect(group?.looseChats.map((chat) => chat.paneId)).toEqual(["w1:p3"]);
    expect(group?.revision).toBe(5);
    expect(group?.needsYou).toBe(true);
    expect(group?.active).toBe(true);
    expect(group?.attentionCount).toBe(1);
  });

  it("no panes → null revision, no attention", () => {
    const [group] = groups([workspace({ workspace_id: "w" })]);
    expect(group).toBeDefined();
    expect(group?.revision).toBe(null);
    expect(group?.needsYou).toBe(false);
    expect(group?.active).toBe(false);
    expect(group?.attentionCount).toBe(0);
  });

  it("chat rows carry workspace id and status", () => {
    const [group] = groups([
      workspace({
        workspace_id: "w1",
        tabs: [tab({ tab_id: "t1" })],
        panes: [pane({ pane_id: "p1", tab_id: "t1", agent_status: "blocked", label: "B" })],
      }),
    ]);
    const row: ChatRow | undefined = group?.tabSections[0]?.chats[0];
    expect(row).toEqual({ paneId: "p1", workspaceId: "w1", title: "B", status: "blocked" });
  });
});

describe("filter + search", () => {
  const mk = (
    over: { workspace_id: string; panes: Array<Partial<Pane> & { pane_id: string }> } & Omit<Partial<Workspace>, "panes">,
  ): Workspace => {
    const { panes, ...rest } = over;
    return workspace({
      tabs: [tab({ tab_id: `${over.workspace_id}:t1`, label: "tab" })],
      panes: panes.map((p) => pane({ ...p, tab_id: `${over.workspace_id}:t1` })),
      ...rest,
    });
  };

  const blockedWs = mk({
    workspace_id: "a",
    number: 1,
    label: "Alpha",
    panes: [{ pane_id: "a1", agent_status: "blocked" }],
  });
  const workingWs = mk({
    workspace_id: "b",
    number: 2,
    label: "Beta audit",
    panes: [{ pane_id: "b1", agent_status: "working" }],
  });
  const quietWs = mk({
    workspace_id: "c",
    number: 3,
    label: "Gamma",
    panes: [{ pane_id: "c1", agent_status: "idle" }],
  });

  it("needsYou filter keeps only blocked/done workspaces", () => {
    expect(filterGroups(groups([blockedWs, workingWs, quietWs]), "", "needsYou").map((g) => g.workspaceId)).toEqual(["a"]);
  });

  it("active filter keeps only working workspaces", () => {
    expect(filterGroups(groups([blockedWs, workingWs, quietWs]), "", "active").map((g) => g.workspaceId)).toEqual(["b"]);
  });

  it("all filter + empty search keeps everything", () => {
    expect(filterGroups(groups([blockedWs, workingWs, quietWs]), "", "all")).toHaveLength(3);
  });

  it("search matches workspace label, tab label, and chat title (case-insensitive)", () => {
    expect(groupMatchesSearch(groups([blockedWs])[0]!, "alpha")).toBe(true);
    expect(groupMatchesSearch(groups([workingWs])[0]!, "AUDIT")).toBe(true);
    const tabbed = groups([
      mk({
        workspace_id: "d",
        number: 4,
        label: "Delta",
        panes: [{ pane_id: "d1", label: "Deep Dive" }],
      }),
    ])[0]!;
    expect(groupMatchesSearch(tabbed, "deep dive")).toBe(true);
    expect(groupMatchesSearch(tabbed, "zzz")).toBe(false);
  });
});
