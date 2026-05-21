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
    draftPrs: { ok: true, items: [{ number: 13, title: "Draft PR", isDraft: true, url: "https://github.com/org/repo/pull/13" }] },
    reviewRequests: { ok: true, items: [] }
  },
  approvals: [],
  activity: [{ id: "activity_1", title: "Task created", summary: "Ship V2", kind: "task_created" }],
  chatMessages: [{ id: "chat_1", role: "assistant", content: "| Key | Status |\n| --- | --- |\n| APP-1 | In Progress |" }],
  taskStatuses: [],
  taskPriorities: [],
  sessionLaunchTypes: []
};

describe("AppShell", () => {
  beforeEach(() => {
    window.localStorage.clear();
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

  it("renders global chat markdown tables as tables", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getByRole("table")).toBeTruthy());
    expect(screen.getByRole("columnheader", { name: "Key" })).toBeTruthy();
    expect(screen.getByRole("cell", { name: "APP-1" })).toBeTruthy();
  });

  it("collapses the activity section from the right dock", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getByText("Task created")).toBeTruthy());
    fireEvent.click(screen.getByLabelText("Collapse activity"));

    expect(screen.queryByText("Task created")).toBeNull();
    expect(screen.getByLabelText("Expand activity")).toBeTruthy();
  });

  it("styles draft PR rail items gray and open PR rail items green", async () => {
    const { container } = render(<AppShell />);

    await waitFor(() => expect(screen.getByText("#13")).toBeTruthy());

    const openCard = screen.getAllByText("#12").find((element) => element.closest(".rail-card"))?.closest(".rail-card");
    const draftCard = screen.getByText("#13").closest(".rail-card");
    expect(openCard.querySelector(".rail-card-state").className).toContain("pr-open");
    expect(openCard.querySelector(".green-dot")).toBeTruthy();
    expect(draftCard.querySelector(".rail-card-state").className).toContain("pr-draft");
    expect(draftCard.querySelector(".gray-dot")).toBeTruthy();
    expect(container.querySelector(".rail-card-state.pr-draft").textContent).toBe("Draft");
  });

  it("sends terminal commands to the active cmux session on enter", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getByText("1 active")).toBeTruthy());
    fireEvent.click(screen.getByText("1 active"));

    const input = await screen.findByPlaceholderText("Type a command or ask AI...");
    fireEvent.change(input, { target: { value: "git status" } });
    fireEvent.keyDown(input, { key: "Enter" });

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/cmux/sessions/workspace-1/input",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ surfaceId: "surface-1", text: "git status\n" })
      })
    ));
  });

  it("renames a task from its card", async () => {
    global.fetch = vi.fn((url, options = {}) => {
      if (String(url).includes("/copilotkit/info")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ version: "1", agents: {} }) });
      }
      if (String(url).includes("/bootstrap")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(bootstrap) });
      }
      if (String(url).includes("/orphans")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true, orphans: [] }) });
      }
      if (String(url).includes("/tasks/task_1") && options.method === "PATCH") {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve({ ok: true, task: { ...bootstrap.tasks[0], title: "Renamed Task" } })
        });
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true }) });
    });

    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    fireEvent.click(screen.getByLabelText("Rename task"));
    fireEvent.change(screen.getByLabelText("Task name"), { target: { value: "Renamed Task" } });
    fireEvent.click(screen.getByLabelText("Save task name"));

    await waitFor(() => expect(screen.getByText("Renamed Task")).toBeTruthy());
    expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/tasks/task_1",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ title: "Renamed Task" })
      })
    );
  });

  it("can disable proactive background updates", async () => {
    const setIntervalSpy = vi.spyOn(window, "setInterval");
    const clearIntervalSpy = vi.spyOn(window, "clearInterval");
    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    expect(setIntervalSpy).toHaveBeenCalled();

    fireEvent.click(screen.getByLabelText("Toggle proactive updates"));

    expect(window.localStorage.getItem("orchestrator-v2-proactive-updates")).toBe("off");
    expect(clearIntervalSpy).toHaveBeenCalled();
  });

  it("defaults new tasks to empty shell launch type", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    fireEvent.click(screen.getByLabelText("Add from Jira Tickets"));

    const emptyShell = screen.getByText("Empty shell").closest("button");
    expect(emptyShell.className).toContain("active");
  });

  it("locks inherited project folder and hides harness choices for orphan sessions", async () => {
    global.fetch = vi.fn((url) => {
      if (String(url).includes("/copilotkit/info")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ version: "1", agents: {} }) });
      }
      if (String(url).includes("/bootstrap")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(bootstrap) });
      }
      if (String(url).includes("/orphans")) {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve({
            ok: true,
            orphans: [{ sessionKey: "loose:surface", workspaceId: "loose", surfaceId: "surface", title: "Loose shell", cwd: "/repo/service", raw: {} }]
          })
        });
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true }) });
    });

    render(<AppShell />);

    await waitFor(() => expect(screen.getByText("Loose shell")).toBeTruthy());
    fireEvent.click(screen.getByText("Turn into Task"));

    const folder = screen.getByDisplayValue("/repo/service");
    expect(folder.readOnly).toBe(true);
    expect(screen.queryByText("Coding Agent Harness")).toBeNull();
    expect(screen.queryByText("Empty shell")).toBeNull();
  });
});
