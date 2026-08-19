import { describe, expect, it } from "vitest";
import type { CmuxNotification, Workspace } from "../api/types";
import {
  approvalAgeLabel,
  approvalBannerText,
  approvalClearPayload,
  isApprovalNotification,
  matchApprovalWorkspace,
  newestApprovalNotification,
} from "./approvalNotification";

const NOW = Date.parse("2026-08-16T23:00:00Z");

function notification(overrides: Partial<CmuxNotification> = {}): CmuxNotification {
  return {
    id: "notif-1",
    title: "Session done",
    body: "Session done",
    subtitle: "",
    created_at: "2026-08-16T22:58:00Z",
    is_read: false,
    workspace_id: "WS-UUID-1",
    surface_id: null,
    tab_title: "pane title",
    ...overrides,
  };
}

function workspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    hasClaude: true,
    index: 1,
    name: "cmux-harness",
    uuid: "WS-UUID-1",
    enabled: true,
    ...overrides,
  };
}

describe("isApprovalNotification", () => {
  it("matches the live cmux permission string", () => {
    expect(
      isApprovalNotification(
        notification({ body: "Permission needs input", title: "Resuming opencode session investigation" }),
      ),
    ).toBe(true);
  });

  it("matches approval-style wording in any field", () => {
    expect(isApprovalNotification(notification({ title: "Plan approval" }))).toBe(true);
    expect(isApprovalNotification(notification({ body: "Approve this change?" }))).toBe(true);
  });

  it("does not match routine notifications", () => {
    expect(isApprovalNotification(notification())).toBe(false);
    expect(isApprovalNotification(notification({ body: "Build finished" }))).toBe(false);
  });

  it("never matches read notifications", () => {
    expect(
      isApprovalNotification(notification({ body: "Permission needs input", is_read: true })),
    ).toBe(false);
  });
});

describe("newestApprovalNotification", () => {
  it("returns null when nothing qualifies", () => {
    expect(newestApprovalNotification([notification()])).toBe(null);
    expect(newestApprovalNotification([])).toBe(null);
  });

  it("returns the single approval notification", () => {
    const item = notification({ body: "Permission needs input" });
    expect(newestApprovalNotification([notification(), item])?.id).toBe(item.id);
  });

  it("prefers the most recent by created_at, not list order", () => {
    const older = notification({ id: "a", body: "Permission needs input", created_at: "2026-08-16T22:00:00Z" });
    const newer = notification({ id: "b", body: "Plan approval", created_at: "2026-08-16T22:59:00Z" });
    // Deliberately older-first list order.
    expect(newestApprovalNotification([older, newer])?.id).toBe("b");
  });

  it("keeps the first item when timestamps are missing or equal", () => {
    const a = notification({ id: "a", body: "Permission needs input", created_at: null });
    const b = notification({ id: "b", body: "Permission needs input", created_at: null });
    expect(newestApprovalNotification([a, b])?.id).toBe("a");
  });
});

describe("matchApprovalWorkspace", () => {
  it("matches by workspace uuid", () => {
    const match = matchApprovalWorkspace(notification(), [workspace({ uuid: "OTHER" }), workspace()]);
    expect(match?.rowID).toBe("WS-UUID-1");
    expect(match?.workspaceName).toBe("cmux-harness");
  });

  it("returns null for unknown workspaces or missing workspace_id", () => {
    expect(matchApprovalWorkspace(notification(), [workspace({ uuid: "OTHER" })])).toBe(null);
    expect(matchApprovalWorkspace(notification({ workspace_id: null }), [workspace()])).toBe(null);
  });

  it("prefers the pane whose surfaceUuid matches the notification surface_id", () => {
    const panes: Workspace[] = [
      workspace({ surfaceUuid: "SURFACE-A", surfaceId: "surface:1", surfaceLabel: "Main" }),
      workspace({ surfaceUuid: "SURFACE-B", surfaceId: "surface:2", surfaceLabel: "Aux" }),
    ];
    const match = matchApprovalWorkspace(
      notification({ surface_id: "SURFACE-B" }),
      panes,
    );
    expect(match?.rowID).toBe("WS-UUID-1|surface:2");
    expect(match?.surfaceID).toBe("surface:2");
  });

  it("falls back to the first candidate when the surface is unknown", () => {
    const panes: Workspace[] = [
      workspace({ surfaceUuid: "SURFACE-A", surfaceId: "surface:1", surfaceLabel: "Main" }),
      workspace({ surfaceUuid: "SURFACE-B", surfaceId: "surface:2", surfaceLabel: "Aux" }),
    ];
    const match = matchApprovalWorkspace(notification({ surface_id: "SURFACE-?" }), panes);
    expect(match?.rowID).toBe("WS-UUID-1|surface:1");
  });
});

describe("approvalClearPayload", () => {
  it("uses <uuid>|<surfaceId> when the surface is known", () => {
    const match = matchApprovalWorkspace(
      notification({ surface_id: "SURFACE-A" }),
      [workspace({ surfaceUuid: "SURFACE-A", surfaceId: "surface:1", surfaceLabel: "Main" })],
    )!;
    expect(approvalClearPayload(notification({ surface_id: "SURFACE-A" }), match)).toEqual({
      workspaceID: "WS-UUID-1|surface:1",
      workspaceUUID: "WS-UUID-1",
      surfaceID: "surface:1",
    });
  });

  it("falls back to the uuid alone when no workspace matches", () => {
    const payload = approvalClearPayload(notification(), null);
    expect(payload).toEqual({
      workspaceID: "WS-UUID-1",
      workspaceUUID: "WS-UUID-1",
      surfaceID: null,
    });
  });
});

describe("approvalBannerText", () => {
  it("shows the matched workspace name plus the notification body", () => {
    const match = matchApprovalWorkspace(notification({ body: "Permission needs input" }), [workspace()])!;
    expect(approvalBannerText(notification({ body: "Permission needs input" }), match)).toEqual({
      title: "cmux-harness",
      detail: "Permission needs input",
    });
  });

  it("falls back to tab_title, then the notification title, then a generic title, when unmatched", () => {
    expect(approvalBannerText(notification({ body: "Permission needs input" }), null).title).toBe(
      "pane title",
    );
    const noTab = notification({ body: "Permission needs input", tab_title: null });
    expect(approvalBannerText(noTab, null).title).toBe("Session done");
    const noTabNoTitle = notification({
      body: "Permission needs input",
      tab_title: null,
      title: null,
    });
    expect(approvalBannerText(noTabNoTitle, null).title).toBe("Approval needed");
  });

  it("drops the detail line when it duplicates the title", () => {
    const match = matchApprovalWorkspace(notification(), [workspace()])!;
    const text = approvalBannerText(
      notification({ body: "cmux-harness", title: "cmux-harness" }),
      match,
    );
    expect(text.detail).toBe(null);
  });
});

describe("approvalAgeLabel", () => {
  it("formats seconds, minutes, hours, days", () => {
    expect(approvalAgeLabel("2026-08-16T22:59:30Z", NOW)).toBe("30s ago");
    expect(approvalAgeLabel("2026-08-16T22:45:00Z", NOW)).toBe("15m ago");
    expect(approvalAgeLabel("2026-08-16T19:00:00Z", NOW)).toBe("4h ago");
    expect(approvalAgeLabel("2026-08-14T19:00:00Z", NOW)).toBe("2d ago");
  });

  it("treats naive ISO timestamps as UTC (earlier server builds)", () => {
    // Server builds before the Z suffix wrote naive UTC strings.
    expect(approvalAgeLabel("2026-08-16T22:58:00", NOW)).toBe("2m ago");
  });

  it("returns null for missing or unparseable timestamps", () => {
    expect(approvalAgeLabel(null, NOW)).toBe(null);
    expect(approvalAgeLabel("not-a-date", NOW)).toBe(null);
  });

  it("clamps negative ages to 0s", () => {
    expect(approvalAgeLabel("2026-08-16T23:59:59Z", NOW)).toBe("0s ago");
  });
});
