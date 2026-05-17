import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { AppShell } from "./App.jsx";

vi.mock("@copilotkit/react-core", () => ({
  CopilotKit: ({ children }) => <>{children}</>,
  useCopilotReadable: () => {},
  useCopilotAction: () => {}
}));

const bootstrap = {
  ok: true,
  tasks: [{
    id: "task_1",
    title: "Ship V2",
    status: "Running",
    priority: "High",
    workspaceDir: "/repo",
    featureBranch: "orchestrator-v2",
    jiraLinks: [{ id: "jira_1", key: "APP-1", title: "Ticket", status: "In Progress", url: "https://jira.example/APP-1" }],
    pullRequestLinks: [{ id: "pr_1", number: 12, title: "PR", url: "https://github.com/org/repo/pull/12", isPrimary: true }],
    cmuxSessionLinks: [{ id: "cmux_1", workspaceId: "workspace-1", surfaceId: "surface-1", title: "Shell" }],
    tags: [{ tag: "frontend" }],
    pendingApprovals: []
  }],
  history: [{ id: "task_done", title: "Finished task", status: "Done", priority: "Low", workspaceDir: "/repo", updatedAt: new Date().toISOString(), jiraLinks: [], pullRequestLinks: [], cmuxSessionLinks: [], tags: [] }],
  leftRail: {
    assignedJira: { ok: true, items: [{ key: "APP-1", title: "Ticket", status: "In Progress", url: "https://jira.example/APP-1" }] },
    openPrs: { ok: true, items: [{ number: 12, title: "PR", branch: "orchestrator-v2", url: "https://github.com/org/repo/pull/12" }] },
    draftPrs: { ok: true, items: [] },
    reviewRequests: { ok: true, items: [] }
  },
  approvals: [],
  activity: [{ id: "activity_1", title: "Task created", summary: "Ship V2", kind: "task_created" }],
  chatMessages: [],
  taskStatuses: [],
  taskPriorities: [],
  sessionLaunchTypes: []
};

describe("AppShell", () => {
  beforeEach(() => {
    global.fetch = vi.fn((url) => {
      if (String(url).includes("/copilotkit/info")) {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve({
            version: "1",
            agents: { default: { description: "Orchestrator V2", capabilities: {} } }
          })
        });
      }
      if (String(url).includes("/bootstrap")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(bootstrap) });
      }
      if (String(url).includes("/orphans")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true, orphans: [] }) });
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true }) });
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("renders task board data from the V2 bootstrap API", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));

    expect(screen.getByText("Tasks / Objectives")).toBeTruthy();
    expect(screen.getAllByText("APP-1").length).toBeGreaterThan(0);
    expect(screen.getAllByText("#12").length).toBeGreaterThan(0);
    expect(screen.getByText("Orphaned cmux sessions")).toBeTruthy();
    expect(screen.getByText("Done / Archived")).toBeTruthy();
    expect(screen.getByText("Voice Mode")).toBeTruthy();
    expect(screen.getByText("Text chat")).toBeTruthy();
  });

  it("defaults new tasks to empty shell launch type", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    fireEvent.click(screen.getByLabelText("Add from Jira Tickets"));

    const emptyShell = screen.getByText("Empty shell").closest("button");
    expect(emptyShell.className).toContain("active");
  });
});
