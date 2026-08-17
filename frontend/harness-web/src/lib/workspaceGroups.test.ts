import { describe, expect, it } from "vitest";
import type { CmuxNotification, FeedItem, Workspace } from "../api/types";
import {
  displayName,
  filterGroups,
  groupMatchesFilter,
  groupMatchesSearch,
  groupNeedsYou,
  groups,
  paneDisplayName,
  paneLabel,
  preferredWorkspaceID,
  sessionDisplayName,
  SESSION_FILTERS,
  unreadCountForGroup,
  workspaceAutoEnabled,
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

  describe("groupMatchesSearch (iOS Workspace/WorkspaceSessionGroup.matchesSearch)", () => {
    function singleGroup(overrides: Partial<Workspace>): ReturnType<typeof groups>[number] {
      return groups([workspace({ index: 1, uuid: "u1", ...overrides })])[0];
    }

    it("matches everything for an empty or whitespace-only query", () => {
      const group = singleGroup({ name: "anything" });
      expect(groupMatchesSearch(group, "")).toBe(true);
      expect(groupMatchesSearch(group, "   ")).toBe(true);
    });

    it("is case-insensitive and matches the group display name", () => {
      const group = singleGroup({ name: "My Session" });
      expect(groupMatchesSearch(group, "my session")).toBe(true);
      expect(groupMatchesSearch(group, "MY SESSION")).toBe(true);
      expect(groupMatchesSearch(group, "missing")).toBe(false);
    });

    it("matches each per-workspace field (name, customName, cwd, branch, surfaceLabel, surfaceTitle)", () => {
      expect(groupMatchesSearch(singleGroup({ name: "proj-alpha" }), "alpha")).toBe(true);
      expect(
        groupMatchesSearch(singleGroup({ name: "other", customName: "My custom name" }), "custom"),
      ).toBe(true);
      expect(
        groupMatchesSearch(
          singleGroup({ name: "other", cwd: "/Users/ronnie/projects/harness" }),
          "harness",
        ),
      ).toBe(true);
      expect(
        groupMatchesSearch(singleGroup({ name: "other", branch: "feat/thing" }), "FEAT"),
      ).toBe(true);
      expect(
        groupMatchesSearch(singleGroup({ name: "other", surfaceLabel: "Left Pane" }), "left pane"),
      ).toBe(true);
      expect(
        groupMatchesSearch(singleGroup({ name: "other", surfaceTitle: "Editor" }), "editor"),
      ).toBe(true);
      // Fields the web helper matched before the parity port still work.
      expect(groupMatchesSearch(singleGroup({ name: "other", surfaceLabel: "/x : Terminal 2" }), "terminal 2")).toBe(true);
    });

    it("matches a pane label even when no other field does", () => {
      // paneDisplayName falls back to surfaceTitle; nothing else contains "notes".
      const group = singleGroup({ name: "other", surfaceTitle: "Notes" });
      expect(groupMatchesSearch(group, "notes")).toBe(true);
    });
  });

  describe("groupMatchesFilter (iOS SessionFilter parity)", () => {
    const rowState = { notifications: [] as CmuxNotification[], feedItems: [] as FeedItem[] };

    function groupOf(overrides: Partial<Workspace>): ReturnType<typeof groups>[number] {
      return groups([workspace({ index: 1, uuid: "u1", ...overrides })])[0];
    }

    it("SESSION_FILTERS carries the iOS labels in order", () => {
      expect(SESSION_FILTERS.map((option) => option.label)).toEqual(["All", "Needs You", "Auto"]);
    });

    it('"all" always matches', () => {
      const group = groupOf({ enabled: false });
      expect(groupMatchesFilter(group, "all", rowState)).toBe(true);
    });

    it('"needsYou" reuses the badge predicate (unread notifications or pending feed items)', () => {
      const target = workspace({ index: 1, uuid: "w1", surfaceUuid: "su1" });
      const group = groups([target])[0];
      const unread = { id: "1", is_read: false, workspace_id: "w1" };
      const unreadSurface = { id: "2", is_read: false, surface_id: "su1" };
      const read = { id: "3", is_read: true, workspace_id: "w1" };
      const feedByWorkspace: FeedItem = { requestID: "r1", kind: "approval", workspaceID: "w1" };
      const feedBySurface: FeedItem = { requestID: "r2", kind: "question", surfaceID: "su1" };
      const feedElsewhere: FeedItem = { requestID: "r3", kind: "approval", workspaceID: "wX" };

      expect(groupMatchesFilter(group, "needsYou", { notifications: [unread], feedItems: [] })).toBe(true);
      expect(groupMatchesFilter(group, "needsYou", { notifications: [unreadSurface], feedItems: [] })).toBe(true);
      expect(groupMatchesFilter(group, "needsYou", { notifications: [read], feedItems: [] })).toBe(false);
      expect(groupMatchesFilter(group, "needsYou", { notifications: [], feedItems: [feedByWorkspace] })).toBe(true);
      expect(groupMatchesFilter(group, "needsYou", { notifications: [], feedItems: [feedBySurface] })).toBe(true);
      expect(groupMatchesFilter(group, "needsYou", { notifications: [], feedItems: [feedElsewhere] })).toBe(false);
      expect(groupMatchesFilter(group, "needsYou", rowState)).toBe(false);
    });

    it('"needsYou" on a multi-pane group: one pane needing attention flags the group', () => {
      const group = groups([
        workspace({ index: 1, uuid: "w1" }),
        workspace({ index: 2, uuid: "w1", surfaceLabel: "Two", surfaceId: "s2", surfaceUuid: "su2" }),
      ])[0];
      const unreadOnSecondPane = { id: "1", is_read: false, surface_id: "su2" };
      expect(
        groupMatchesFilter(group, "needsYou", { notifications: [unreadOnSecondPane], feedItems: [] }),
      ).toBe(true);
    });

    it('"auto" mirrors resolvedAutoMode.isEnabled (autoMode ?? (enabled ? auto : off), enabled when != off)', () => {
      // Explicit modes win over `enabled`.
      expect(
        groupMatchesFilter(groupOf({ enabled: false, autoMode: "super" }), "auto", rowState),
      ).toBe(true);
      expect(
        groupMatchesFilter(groupOf({ enabled: false, autoMode: "auto" }), "auto", rowState),
      ).toBe(true);
      expect(
        groupMatchesFilter(groupOf({ enabled: true, autoMode: "off" }), "auto", rowState),
      ).toBe(false);
      // No explicit mode: resolve from `enabled`.
      expect(groupMatchesFilter(groupOf({ enabled: true, autoMode: null }), "auto", rowState)).toBe(true);
      expect(groupMatchesFilter(groupOf({ enabled: false, autoMode: null }), "auto", rowState)).toBe(false);
      // Multi-pane: any pane auto-enabled flags the group (iOS `contains`).
      const group = groups([
        workspace({ index: 1, uuid: "w1", enabled: false, autoMode: null }),
        workspace({
          index: 2,
          uuid: "w1",
          surfaceLabel: "Two",
          surfaceId: "s2",
          enabled: true,
          autoMode: "super",
        }),
      ])[0];
      expect(groupMatchesFilter(group, "auto", rowState)).toBe(true);
      // workspaceAutoEnabled agrees with the resolved mode.
      expect(workspaceAutoEnabled(workspace({ enabled: false, autoMode: "super" }))).toBe(true);
      expect(workspaceAutoEnabled(workspace({ enabled: true, autoMode: "off" }))).toBe(false);
    });

    it("needsYou filter and the badge predicate never disagree (property check)", () => {
      const group = groups([
        workspace({ index: 1, uuid: "w1", surfaceUuid: "su1" }),
        workspace({ index: 2, uuid: "w1", surfaceLabel: "Two", surfaceId: "s2", surfaceUuid: "su2" }),
        workspace({ index: 3, uuid: "w2", customName: "Second session" }),
      ]);
      const notificationCases: CmuxNotification[][] = [
        [],
        [{ id: "1", is_read: false, workspace_id: "w1" }],
        [{ id: "2", is_read: false, surface_id: "su2" }],
        [{ id: "3", is_read: true, workspace_id: "w1" }],
        [{ id: "4", is_read: false, workspace_id: "other" }],
      ];
      const feedCases: FeedItem[][] = [
        [],
        [{ requestID: "r1", kind: "approval", workspaceID: "w2" }],
        [{ requestID: "r2", kind: "question", surfaceID: "su1" }],
      ];
      for (const notifications of notificationCases) {
        for (const feedItems of feedCases) {
          for (const candidate of group) {
            expect(
              groupMatchesFilter(candidate, "needsYou", { notifications, feedItems }),
              `group ${candidate.id} / ${notifications.length} notifications / ${feedItems.length} feed items`,
            ).toBe(groupNeedsYou(candidate, notifications, feedItems));
          }
        }
      }
    });
  });

  describe("filterGroups (search AND filter)", () => {
    const rowState = { notifications: [] as CmuxNotification[], feedItems: [] as FeedItem[] };

    const alphaAuto = groups([workspace({ index: 1, uuid: "a", name: "alpha-app" })])[0];
    const betaNeedsYou = groups([workspace({ index: 2, uuid: "b", name: "beta-app" })])[0];
    const gamma = groups([workspace({ index: 3, uuid: "c", name: "gamma-app", enabled: false })])[0];
    const allGroups = [alphaAuto, betaNeedsYou, gamma];
    const unreadForBeta = { id: "1", is_read: false, workspace_id: "b" };
    const stateWithBetaUnread = { notifications: [unreadForBeta], feedItems: [] as FeedItem[] };

    it("returns every group with an empty search and the All filter", () => {
      expect(filterGroups(allGroups, "", "all", rowState)).toEqual(allGroups);
    });

    it("search only (All filter)", () => {
      expect(filterGroups(allGroups, "beta", "all", rowState).map((g) => g.id)).toEqual(["b"]);
      expect(filterGroups(allGroups, "zzz", "all", rowState)).toEqual([]);
    });

    it("filter only (empty search)", () => {
      expect(filterGroups(allGroups, "", "needsYou", stateWithBetaUnread).map((g) => g.id)).toEqual(["b"]);
      expect(filterGroups(allGroups, "", "auto", rowState).map((g) => g.id)).toEqual(["a", "b"]);
      expect(filterGroups(allGroups, "", "auto", stateWithBetaUnread).map((g) => g.id)).toEqual(["a", "b"]);
    });

    it("search AND filter: a group must satisfy both", () => {
      // beta matches the search, and the filter (needsYou with the unread)
      // matches beta too → beta survives.
      expect(
        filterGroups(allGroups, "beta", "needsYou", stateWithBetaUnread).map((g) => g.id),
      ).toEqual(["b"]);
      // alpha matches the filter but not the search → dropped; beta matches
      // both → kept.
      expect(filterGroups(allGroups, "beta", "auto", rowState).map((g) => g.id)).toEqual(["b"]);
      // gamma matches the search but neither filter → dropped.
      expect(filterGroups(allGroups, "gamma", "needsYou", stateWithBetaUnread)).toEqual([]);
      expect(filterGroups(allGroups, "gamma", "auto", rowState)).toEqual([]);
    });

    it("preserves input order", () => {
      expect(
        filterGroups([gamma, alphaAuto, betaNeedsYou], "", "all", rowState).map((g) => g.id),
      ).toEqual(["c", "a", "b"]);
    });
  });
});
