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

  it("sends backspace from the terminal key controls", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getByText("1 active")).toBeTruthy());
    fireEvent.click(screen.getByText("1 active"));
    fireEvent.click(await screen.findByText("Bkspc"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/cmux/sessions/workspace-1/input",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ surfaceId: "surface-1", key: "backspace" })
      })
    ));
  });

  it("opens the git context menu and stages or unstages files", async () => {
    const statusPayload = {
      ok: true,
      branch: "orchestrator-v2",
      commits: [],
      staged: [{ file: "src/staged.js", status: "M" }],
      unstaged: [{ file: "src/app.js", status: "M" }],
      untracked: ["notes/new.md"]
    };
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
      if (String(url).includes("/git/status")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(statusPayload) });
      }
      if (String(url).includes("/git/diff")) {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve({
            ok: true,
            diff: "diff --git a/src/app.js b/src/app.js\n@@ -1,2 +1,2 @@\n-old value\n+new value"
          })
        });
      }
      if (String(url).includes("/git/stage") || String(url).includes("/git/unstage")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true }) });
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true }) });
    });

    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    fireEvent.click(screen.getByText("Git Diff"));

    const modifiedFile = await screen.findByText("src/app.js");
    fireEvent.contextMenu(modifiedFile.closest("button"), { clientX: 24, clientY: 32 });

    expect(screen.getByText("View Diff")).toBeTruthy();
    const stageAction = screen.getAllByText("Stage").find((element) => element.closest(".git-context-menu"));
    fireEvent.click(stageAction);

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/git/stage",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ path: "/repo", file: "src/app.js" })
      })
    ));

    const stagedFile = await screen.findByText("src/staged.js");
    fireEvent.contextMenu(stagedFile.closest("button"), { clientX: 24, clientY: 32 });
    fireEvent.click(screen.getByText("Unstage"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/git/unstage",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ path: "/repo", file: "src/staged.js" })
      })
    ));
  });

  it("expands commit history and opens a committed file diff", async () => {
    const statusPayload = {
      ok: true,
      branch: "orchestrator-v2",
      commits: [{ hash: "abc1234", message: "Add old file changes" }],
      staged: [],
      unstaged: [],
      untracked: []
    };
    global.fetch = vi.fn((url) => {
      if (String(url).includes("/copilotkit/info")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ version: "1", agents: {} }) });
      }
      if (String(url).includes("/bootstrap")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(bootstrap) });
      }
      if (String(url).includes("/orphans")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true, orphans: [] }) });
      }
      if (String(url).includes("/git/status")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(statusPayload) });
      }
      if (String(url).includes("/git/commit-files")) {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve({ ok: true, files: [{ status: "M", file: "src/old.js" }] })
        });
      }
      if (String(url).includes("/git/commit-diff")) {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve({
            ok: true,
            diff: "diff --git a/src/old.js b/src/old.js\n@@ -1 +1 @@\n-before\n+after"
          })
        });
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true }) });
    });

    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    fireEvent.click(screen.getByText("Git Diff"));
    fireEvent.click(await screen.findByText("abc1234"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/git/commit-files",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ path: "/repo", hash: "abc1234" })
      })
    ));

    fireEvent.click(await screen.findByText("src/old.js"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/git/commit-diff",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ path: "/repo", hash: "abc1234", file: "src/old.js" })
      })
    ));
    expect(await screen.findByText("src/old.js @ abc1234")).toBeTruthy();
    expect(screen.getByText("Commit")).toBeTruthy();
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

  it("stops a cmux session from the session view after confirmation", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<AppShell />);

    await waitFor(() => expect(screen.getByText("1 active")).toBeTruthy());
    fireEvent.click(screen.getByText("1 active"));
    fireEvent.click(await screen.findByText("Stop Session"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/cmux/sessions/workspace-1/kill",
      expect.objectContaining({ method: "POST" })
    ));
  });

  it("restarts a cmux session from the session view after confirmation", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<AppShell />);

    await waitFor(() => expect(screen.getByText("1 active")).toBeTruthy());
    fireEvent.click(screen.getByText("1 active"));
    fireEvent.click((await screen.findAllByText("Restart Session"))[0]);

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/cmux/sessions/workspace-1/restart",
      expect.objectContaining({ method: "POST" })
    ));
  });

  it("does not stop a session when the confirmation is declined", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(false);
    render(<AppShell />);

    await waitFor(() => expect(screen.getByText("1 active")).toBeTruthy());
    fireEvent.click(screen.getByText("1 active"));
    fireEvent.click(await screen.findByText("Stop Session"));

    expect(global.fetch).not.toHaveBeenCalledWith(
      "/api/orchestrator-v2/cmux/sessions/workspace-1/kill",
      expect.anything()
    );
  });

  it("switches the board to list view", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    fireEvent.click(screen.getByLabelText("List view"));

    expect(document.querySelector(".task-list-view")).toBeTruthy();
    expect(window.localStorage.getItem("orchestrator-v2-board-layout")).toBe("list");
  });

  it("opens the history view from the rail navigation and reopens a task", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    fireEvent.click(screen.getByText("History"));

    expect(await screen.findByText("Finished task")).toBeTruthy();
    fireEvent.click(screen.getByText("Reopen"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/tasks/task_done",
      expect.objectContaining({ method: "PATCH", body: JSON.stringify({ status: "To Do" }) })
    ));
  });

  it("runs the watcher from the activity view", async () => {
    render(<AppShell />);

    await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
    fireEvent.click(screen.getByText("Activity", { selector: ".rail-nav-btn span" }));
    fireEvent.click(await screen.findByText("Run Watcher Now"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/watcher/run",
      expect.objectContaining({ method: "POST" })
    ));
  });

  it("renders session lifecycle approvals with approve and deny controls", async () => {
    const lifecycleBootstrap = {
      ...bootstrap,
      approvals: [{
        id: "approval_kill",
        kind: "kill_cmux_session",
        status: "pending",
        title: "Stop cmux session workspace-1",
        summary: "The agent wants to stop workspace-1.",
        payload: { workspaceId: "workspace-1", toolName: "kill_cmux_session", reversible: false }
      }]
    };
    global.fetch = vi.fn((url, options = {}) => {
      if (String(url).includes("/copilotkit/info")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ version: "1", agents: {} }) });
      }
      if (String(url).includes("/bootstrap")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(lifecycleBootstrap) });
      }
      if (String(url).includes("/orphans")) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true, orphans: [] }) });
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true }) });
    });

    render(<AppShell />);

    await waitFor(() => expect(screen.getByText("Session Lifecycle Approval")).toBeTruthy());
    fireEvent.click(screen.getByText("Approve Stop"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/approvals/approval_kill/decision",
      expect.objectContaining({ method: "POST", body: JSON.stringify({ status: "approved" }) })
    ));
  });
});
