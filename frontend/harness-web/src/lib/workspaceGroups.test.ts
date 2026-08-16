import { describe, expect, it } from "vitest";
import type { CmuxNotification, Workspace } from "../api/types";
import {
  displayName,
  groupNeedsYou,
  groups,
  paneDisplayName,
  paneLabel,
  preferredWorkspaceID,
  sessionDisplayName,
  unreadCountForGroup,
  workspaceID,
  workspaceNeedsYou,
} from "./workspaceGroups";

function workspace(overrides: Partial<Workspace>): Workspace {
  return {
    hasClaude: true,
    index: 1,
    name: "cmux-harness",
    uuid: "uuid-1",
    enabled: true,
    ...overrides,
  };
}

describe("workspaceGroups", () => {
  it("computes stable row ids (uuid, or uuid|surfaceId with a surface label)", () => {
    expect(workspaceID(workspace({}))).toBe("uuid-1");
    expect(
      workspaceID(
        workspace({ uuid: "", index: 7, surfaceLabel: "Terminal", surfaceId: "s1" }),
      ),
    ).toBe("index-7|s1");
    // Label without a surface id falls back to the stable id.
    expect(workspaceID(workspace({ surfaceLabel: "Terminal" }))).toBe("uuid-1");
  });

  it("groups by uuid and sorts panes by index", () => {
    const result = groups([
      workspace({ index: 5, uuid: "b", surfaceLabel: "Pane B", surfaceId: "s2" }),
      workspace({ index: 1, uuid: "a" }),
      workspace({ index: 2, uuid: "b", surfaceLabel: "Pane A", surfaceId: "s1" }),
    ]);
    expect(result.map((group) => group.id)).toEqual(["a", "b"]);
    const groupB = result.find((group) => group.id === "b");
    expect(groupB?.paneCount).toBe(2);
    expect(groupB?.hasMultiplePanes).toBe(true);
    expect(groupB?.workspaces.map((entry) => entry.index)).toEqual([2, 5]);
  });

  it("sorts groups starred-first, then by name", () => {
    const result = groups([
      workspace({ index: 1, uuid: "a", name: "zebra" }),
      workspace({ index: 2, uuid: "b", name: "apple", starred: true }),
    ]);
    expect(result.map((group) => group.displayName)).toEqual(["apple", "zebra"]);
  });

  it("shortens non-custom names to a path basename", () => {
    expect(sessionDisplayName(workspace({ name: "/Users/ronnie/proj/app" }))).toBe("app");
    expect(
      sessionDisplayName(workspace({ name: "/Users/ronnie/proj/app : feature-x" })),
    ).toBe("app : feature-x");
    // Custom names pass through untouched (sessionDisplayName uses customName).
    expect(
      sessionDisplayName(workspace({ name: "/Users/ronnie/proj/app", customName: "My session" })),
    ).toBe("My session");
    // displayName prefers surfaceLabel; a custom name only suppresses shortening
    // (iOS Workspace.displayName behavior).
    expect(
      displayName(
        workspace({ name: "/Users/ronnie/proj/app", customName: "My session", surfaceLabel: "Other" }),
      ),
    ).toBe("Other");
  });

  it("falls back to Pane N labels", () => {
    const group = groups([workspace({ surfaceTitle: undefined })])[0];
    expect(paneDisplayName(group.primaryWorkspace)).toBe("Pane");
    expect(paneLabel(group, group.primaryWorkspace, 0)).toBe("Pane 1");
  });

  it("extracts the trailing part of 'path : label' surface labels", () => {
    expect(paneDisplayName(workspace({ surfaceLabel: "/tmp/dir : Terminal 2" }))).toBe(
      "Terminal 2",
    );
  });

  it("keeps the selected pane when the group is re-selected", () => {
    const group = groups([
      workspace({ index: 1, uuid: "a", surfaceLabel: "One", surfaceId: "s1" }),
      workspace({ index: 2, uuid: "a", surfaceLabel: "Two", surfaceId: "s2" }),
    ])[0];
    const selected = "a|s2";
    expect(preferredWorkspaceID(group, selected)).toBe(selected);
    expect(preferredWorkspaceID(group, null)).toBe("a|s1");
  });

  it("counts unread notifications by workspace uuid and surface id", () => {
    const target = workspace({ uuid: "w1", surfaceUuid: "su1" });
    const notifications: CmuxNotification[] = [
      { id: "1", is_read: false, workspace_id: "w1" },
      { id: "2", is_read: true, workspace_id: "w1" },
      { id: "3", is_read: false, surface_id: "su1" },
      { id: "4", is_read: false, workspace_id: "other" },
    ];
    const group = groups([target])[0];
    expect(unreadCountForGroup(group, notifications)).toBe(2);
  });

  it("derives Needs You from unread notifications or matching feed items", () => {
    const target = workspace({ uuid: "w1", surfaceUuid: "su1" });
    const group = groups([target])[0];
    const notification: CmuxNotification = { id: "1", is_read: false, workspace_id: "w1" };
    const feedItem = { requestID: "r1", kind: "approval", workspaceID: "w1" };

    expect(workspaceNeedsYou(target, [notification], [])).toBe(true);
    expect(workspaceNeedsYou(target, [], [feedItem])).toBe(true);
    expect(workspaceNeedsYou(target, [], [{ requestID: "r2", kind: "approval" }])).toBe(false);
    expect(groupNeedsYou(group, [notification], [])).toBe(true);
    // Read notifications do not count.
    expect(
      workspaceNeedsYou(target, [{ id: "1", is_read: true, workspace_id: "w1" }], []),
    ).toBe(false);
  });
});
