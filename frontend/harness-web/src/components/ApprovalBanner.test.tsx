/**
 * ApprovalBanner render check (renderToString, no jsdom — none is installed
 * and no new dependencies are allowed).
 *
 * zustand v5 serves `getInitialState()` as the SSR snapshot, so seeded store
 * state is invisible to renderToString; the store hook is therefore mocked to
 * read from a plain object. The derivation logic under test (banner text,
 * matching, newest-selection) comes from the REAL `lib/approvalNotification`
 * functions — only the state source is stubbed.
 *
 * The live server cannot produce an UNREAD approval notification on demand
 * (cmux has no mark_unread method), so this test is the executable proof
 * that the banner appears with the right text when the store holds one.
 */
import { createElement } from "react";
import { renderToString } from "react-dom/server";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { ApprovalBanner } from "./ApprovalBanner";
import type { CmuxNotification, Workspace } from "../api/types";

type StoreState = {
  hasReceivedStatus: boolean;
  notifications: CmuxNotification[];
  workspaces: Workspace[];
  selectWorkspace: (id: string) => void;
};

const mocked = vi.hoisted(() => {
  let state: StoreState = {
    hasReceivedStatus: true,
    notifications: [],
    workspaces: [],
    selectWorkspace: () => {},
  };
  const useWorkspacesStore = ((selector: (s: StoreState) => unknown) =>
    selector(state)) as ((selector: (s: StoreState) => unknown) => unknown) & {
    getState: () => StoreState;
    setState: (partial: Partial<StoreState>) => void;
  };
  useWorkspacesStore.getState = () => state;
  useWorkspacesStore.setState = (partial) => {
    state = { ...state, ...partial };
  };
  return { useWorkspacesStore, reset: () => useWorkspacesStore.setState({ hasReceivedStatus: true, notifications: [], workspaces: [], selectWorkspace: () => {} }) };
});

vi.mock("../store/workspacesStore", () => ({
  useWorkspacesStore: mocked.useWorkspacesStore,
}));

function notification(overrides: Partial<CmuxNotification> = {}): CmuxNotification {
  return {
    id: "notif-1",
    title: "Resuming opencode session investigation",
    body: "Permission needs input",
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

function seed(notifications: CmuxNotification[], workspaces: Workspace[]) {
  mocked.useWorkspacesStore.setState({ notifications, workspaces });
}

describe("ApprovalBanner (SSR render)", () => {
  beforeEach(() => mocked.reset());

  it("renders nothing while there are no unread approvals", () => {
    seed([], [workspace()]);
    expect(renderToString(createElement(ApprovalBanner))).toBe("");
  });

  it("renders nothing before the first status arrives", () => {
    seed([notification()], [workspace()]);
    mocked.useWorkspacesStore.setState({ hasReceivedStatus: false });
    expect(renderToString(createElement(ApprovalBanner))).toBe("");
  });

  it("renders the workspace name, the detail line, and role=status", () => {
    seed([notification()], [workspace()]);
    const html = renderToString(createElement(ApprovalBanner));
    expect(html).toContain("approval-banner");
    expect(html).toContain("role=\"status\"");
    expect(html).toContain("aria-live=\"polite\"");
    expect(html).toContain("cmux-harness");
    expect(html).toContain("Permission needs input");
  });

  it("falls back to the notification title when no workspace matches and there is no tab title", () => {
    seed(
      [notification({ workspace_id: "UNKNOWN", tab_title: null })],
      [workspace()],
    );
    const html = renderToString(createElement(ApprovalBanner));
    // Title chain: workspace name → tab_title → notification title.
    expect(html).toContain("Resuming opencode session investigation");
    expect(html).toContain("Permission needs input");
    expect(html).not.toContain("cmux-harness");
  });

  it("omits the detail line when it duplicates the title", () => {
    seed(
      [
        notification({
          workspace_id: "UNKNOWN",
          tab_title: null,
          body: "Approval needed",
          title: "Approval needed",
        }),
      ],
      [workspace()],
    );
    const html = renderToString(createElement(ApprovalBanner));
    expect(html).toContain("Approval needed");
    expect(html).not.toContain("approval-banner-detail");
  });
});
