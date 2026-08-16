/**
 * Tests for the feed item helpers (port of FeedItem computed properties +
 * the WorkspaceDetailView.feedItem(_:matches:) predicate).
 */

import { describe, expect, it } from "vitest";

import type { FeedItem, Workspace } from "../api/types";
import {
  feedItemDisplayTitle,
  feedItemMatches,
  feedItemSummary,
  feedItemSupportsNativeReply,
  groupedQuestionFallbackNote,
} from "./feed";

const workspace: Workspace = {
  hasClaude: false,
  index: 2,
  name: "demo",
  uuid: "uuid-A",
  enabled: true,
  autoMode: null,
  starred: false,
  autoEnabledAt: null,
  autoExpiresAt: null,
  customName: null,
  lastCheck: null,
  screenTail: null,
  screenFull: null,
  cwd: null,
  branch: null,
  sessionStart: null,
  sessionCost: null,
  surfaceId: null,
  surfaceUuid: null,
  surfaceLabel: null,
  surfaceTitle: null,
  gitDirty: null,
  surfaceCreatedAt: null,
  surfaceAge: null,
};

const multiSurfaceWorkspace: Workspace = {
  ...workspace,
  uuid: "uuid-B",
  index: 3,
  surfaceId: "s-1",
  surfaceUuid: "surface-uuid-1",
  surfaceLabel: "Pane 1",
};

function baseItem(overrides: Partial<FeedItem>): FeedItem {
  return {
    requestID: "req-1",
    kind: "permission",
    title: null,
    message: null,
    command: null,
    workspaceID: "",
    surfaceID: "",
    agent: null,
    createdAt: null,
    options: null,
    permissionType: null,
    patterns: null,
    questions: null,
    raw: null,
    ...overrides,
  };
}

describe("feedItemMatches (iOS feedItem(_:matches:) port)", () => {
  it("matches by workspace uuid or row id when no surface attribution", () => {
    expect(feedItemMatches(baseItem({ workspaceID: "uuid-A" }), workspace)).toBe(true);
    // row id fallback: "index-N" when the workspace has no uuid
    const noUuid = { ...workspace, uuid: "" };
    expect(feedItemMatches(baseItem({ workspaceID: "index-2" }), noUuid)).toBe(true);
    expect(feedItemMatches(baseItem({ workspaceID: "uuid-B" }), workspace)).toBe(false);
  });

  it("surface attribution must match, and is decisive when workspaceID is absent", () => {
    // surface only -> matches via surfaceId
    expect(feedItemMatches(baseItem({ surfaceID: "s-1" }), multiSurfaceWorkspace)).toBe(true);
    // surface only, wrong surface -> no match
    expect(feedItemMatches(baseItem({ surfaceID: "surface-uuid-2" }), multiSurfaceWorkspace)).toBe(false);
    // surface matches but a different workspaceID is attached -> no match
    expect(
      feedItemMatches(baseItem({ workspaceID: "uuid-other", surfaceID: "s-1" }), multiSurfaceWorkspace),
    ).toBe(false);
    // surface matches + matching workspaceID -> match
    expect(
      feedItemMatches(baseItem({ workspaceID: "uuid-B", surfaceID: "s-1" }), multiSurfaceWorkspace),
    ).toBe(true);
  });

  it("matches a multi-surface row via its combined row id", () => {
    expect(feedItemMatches(baseItem({ workspaceID: "uuid-B|s-1" }), multiSurfaceWorkspace)).toBe(true);
  });

  it("unattributed items (both empty) match no workspace", () => {
    expect(feedItemMatches(baseItem({ workspaceID: "", surfaceID: "" }), workspace)).toBe(false);
    expect(feedItemMatches(baseItem({ workspaceID: " ", surfaceID: " " }), workspace)).toBe(false);
  });
});

describe("feedItemSupportsNativeReply (iOS: every kind except multiSelect questions)", () => {
  it("permission / plan / unknown kinds reply natively", () => {
    expect(feedItemSupportsNativeReply(baseItem({ kind: "permission" }))).toBe(true);
    expect(feedItemSupportsNativeReply(baseItem({ kind: "plan" }))).toBe(true);
    expect(feedItemSupportsNativeReply(baseItem({ kind: "tool" }))).toBe(true);
  });

  it("questions reply natively unless a question is multiSelect", () => {
    expect(
      feedItemSupportsNativeReply(
        baseItem({
          kind: "question",
          questions: [
            { id: "q1", header: null, question: "Q1", multiSelect: false, options: [] },
            { id: "q2", header: null, question: "Q2", multiSelect: true, options: [] },
          ],
        }),
      ),
    ).toBe(false);

    expect(
      feedItemSupportsNativeReply(
        baseItem({
          kind: "question",
          questions: [{ id: "q1", header: null, question: "Q1", multiSelect: false, options: [] }],
        }),
      ),
    ).toBe(true);

    // no questions at all -> supported
    expect(feedItemSupportsNativeReply(baseItem({ kind: "question" }))).toBe(true);
  });
});

describe("feedItemDisplayTitle (iOS displayTitle port)", () => {
  it("prefers a non-empty trimmed title", () => {
    expect(feedItemDisplayTitle(baseItem({ title: "Custom title", kind: "permission" }))).toBe(
      "Custom title",
    );
    expect(feedItemDisplayTitle(baseItem({ title: "  ", kind: "permission" }))).toBe(
      "Permission Request",
    );
  });

  it("falls back by kind", () => {
    expect(feedItemDisplayTitle(baseItem({ kind: "permission" }))).toBe("Permission Request");
    expect(feedItemDisplayTitle(baseItem({ kind: "plan" }))).toBe("Plan Approval");
    expect(feedItemDisplayTitle(baseItem({ kind: "question" }))).toBe("Question");
    expect(feedItemDisplayTitle(baseItem({ kind: "tool" }))).toBe("cmux Feed");
  });
});

describe("feedItemSummary (iOS summary port: message -> command -> displayTitle)", () => {
  it("prefers the trimmed message", () => {
    expect(feedItemSummary(baseItem({ message: "msg", command: "ls -la" }))).toBe("msg");
  });

  it("falls back to the trimmed command", () => {
    expect(feedItemSummary(baseItem({ message: "  ", command: "ls -la" }))).toBe("ls -la");
  });

  it("falls back to displayTitle", () => {
    expect(feedItemSummary(baseItem({ message: null, command: "  " }))).toBe("Permission Request");
  });
});

describe("groupedQuestionFallbackNote (iOS: fixed note when a matched item can't reply natively)", () => {
  const NOTE =
    "This question supports multiple selections. The current cmux bridge cannot safely preserve grouped answers, so this stays in OpenCode's terminal.";

  it("returns the note when any matched item lacks native reply", () => {
    const grouped = baseItem({
      kind: "question",
      questions: [{ id: "q1", header: null, question: "Q", multiSelect: true, options: [] }],
    });
    expect(groupedQuestionFallbackNote([grouped])).toBe(NOTE);

    // native-supported items alone -> no note
    expect(groupedQuestionFallbackNote([baseItem({ kind: "question" }), grouped])).toBe(NOTE);
    expect(groupedQuestionFallbackNote([baseItem({ kind: "question" })])).toBeNull();
  });

  it("returns null for no matched items", () => {
    expect(groupedQuestionFallbackNote([])).toBeNull();
  });
});
