import { describe, expect, it } from "vitest";
import { formatRelativeTime } from "./AlertCardView";
import { rankQueueAlerts, recentAlerts } from "./AttentionView";
import type { Alert, Pane } from "../../types/herdr";

function alert(overrides: Partial<Alert> & Pick<Alert, "id" | "createdAt">): Alert {
  return {
    kind: "agent_done",
    status: "done",
    previousStatus: "working",
    severity: "success",
    title: "agent finished",
    message: "Work completed.",
    workspaceId: "w1",
    workspaceLabel: "w1",
    tabId: "w1:t1",
    tabLabel: "t1",
    paneId: "w1:p1",
    paneTitle: "pane",
    agentName: "pi",
    isRead: false,
    readAt: null,
    action: { type: "open_pane", paneId: "w1:p1" },
    ...overrides,
  };
}

function pane(overrides: Partial<Pane> & Pick<Pane, "pane_id" | "agent_status">): Pane {
  return {
    terminal_id: "t",
    workspace_id: "w1",
    tab_id: "w1:t1",
    focused: false,
    cwd: "/",
    foreground_cwd: "/",
    revision: 1,
    scroll: { offset_from_bottom: 0, max_offset_from_bottom: 0, viewport_rows: 1 },
    ...overrides,
  };
}

describe("rankQueueAlerts", () => {
  it("keeps only unread alerts", () => {
    const panes = new Map([["p1", pane({ pane_id: "p1", agent_status: "blocked" })]]);
    const out = rankQueueAlerts(
      [alert({ id: "a1", createdAt: "2026-01-01T00:00:00Z" }), alert({ id: "a2", createdAt: "2026-01-02T00:00:00Z", isRead: true })],
      panes,
    );
    expect(out.map((a) => a.id)).toEqual(["a1"]);
  });

  it("ranks blocked → done → working → idle → unknown via the pane's agent_status", () => {
    const panes = new Map([
      ["p-done", pane({ pane_id: "p-done", agent_status: "done" })],
      ["p-working", pane({ pane_id: "p-working", agent_status: "working" })],
      ["p-blocked", pane({ pane_id: "p-blocked", agent_status: "blocked" })],
      ["p-idle", pane({ pane_id: "p-idle", agent_status: "idle" })],
    ]);
    const out = rankQueueAlerts(
      [
        alert({ id: "a-idle", createdAt: "2026-01-05T00:00:00Z", paneId: "p-idle" }),
        alert({ id: "a-working", createdAt: "2026-01-04T00:00:00Z", paneId: "p-working" }),
        alert({ id: "a-blocked", createdAt: "2026-01-01T00:00:00Z", paneId: "p-blocked" }),
        alert({ id: "a-done", createdAt: "2026-01-02T00:00:00Z", paneId: "p-done" }),
      ],
      panes,
    );
    expect(out.map((a) => a.id)).toEqual(["a-blocked", "a-done", "a-working", "a-idle"]);
  });

  it("ranks alerts whose pane is gone as unknown (last), ties by createdAt desc", () => {
    const panes = new Map([
      ["p1", pane({ pane_id: "p1", agent_status: "idle" })],
      ["p2", pane({ pane_id: "p2", agent_status: "idle" })],
    ]);
    const out = rankQueueAlerts(
      [
        alert({ id: "a-gone-old", createdAt: "2026-01-01T00:00:00Z", paneId: "p-gone" }),
        alert({ id: "a-idle-new", createdAt: "2026-01-04T00:00:00Z", paneId: "p1" }),
        alert({ id: "a-gone-new", createdAt: "2026-01-05T00:00:00Z", paneId: "p-gone" }),
        alert({ id: "a-idle-old", createdAt: "2026-01-02T00:00:00Z", paneId: "p2" }),
      ],
      panes,
    );
    expect(out.map((a) => a.id)).toEqual(["a-idle-new", "a-idle-old", "a-gone-new", "a-gone-old"]);
  });
});

describe("recentAlerts", () => {
  it("sorts newest first and caps at the limit", () => {
    const out = recentAlerts(
      [
        alert({ id: "a-old", createdAt: "2026-01-01T00:00:00Z" }),
        alert({ id: "a-new", createdAt: "2026-01-05T00:00:00Z" }),
        alert({ id: "a-mid", createdAt: "2026-01-03T00:00:00Z" }),
      ],
      2,
    );
    expect(out.map((a) => a.id)).toEqual(["a-new", "a-mid"]);
  });
});

describe("formatRelativeTime", () => {
  const NOW = Date.parse("2026-01-10T00:00:00Z");
  it("clamps to now / minutes / hours / days", () => {
    expect(formatRelativeTime("2026-01-10T00:00:10Z", NOW)).toBe("now");
    expect(formatRelativeTime("2026-01-09T23:58:00Z", NOW)).toBe("2m ago");
    expect(formatRelativeTime("2026-01-09T21:00:00Z", NOW)).toBe("3h ago");
    expect(formatRelativeTime("2026-01-05T00:00:00Z", NOW)).toBe("5d ago");
  });

  it("clamps future timestamps to now and rejects garbage", () => {
    expect(formatRelativeTime("2026-01-11T00:00:00Z", NOW)).toBe("now");
    expect(formatRelativeTime("not-a-date", NOW)).toBe("");
  });
});
