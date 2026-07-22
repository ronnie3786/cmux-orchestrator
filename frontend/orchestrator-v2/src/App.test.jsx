import React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
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

class FakeAnalyser {
  constructor() {
    this.fftSize = 256;
  }
  connect() {}
  disconnect() {}
  getByteTimeDomainData(data) {
    data.fill(128);
  }
}

class FakeBufferSource {
  connect() {}
  disconnect() {}
  start() {
    window.setTimeout(() => this.onended?.(), 0);
  }
  stop() {}
}

class FakeAudioContext {
  constructor() {
    this.sampleRate = 16000;
    this.destination = {};
    this.scriptProcessors = [];
    FakeAudioContext.instances.push(this);
  }
  resume() {
    return Promise.resolve();
  }
  close() {
    return Promise.resolve();
  }
  decodeAudioData() {
    return Promise.resolve({ duration: 0.05 });
  }
  createBufferSource() {
    return new FakeBufferSource();
  }
  createAnalyser() {
    return new FakeAnalyser();
  }
  createMediaStreamSource() {
    return { connect() {}, disconnect() {} };
  }
  createScriptProcessor() {
    const node = { onaudioprocess: null, connect() {}, disconnect() {} };
    this.scriptProcessors.push(node);
    return node;
  }
}
FakeAudioContext.instances = [];

function jsonResponse(payload) {
  return { ok: true, json: () => Promise.resolve(payload) };
}

function sseResponse(events, { signal, hangAfterFirstRead = false } = {}) {
  const encoder = new TextEncoder();
  const payload = encoder.encode(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""));
  let reads = 0;
  return {
    ok: true,
    json: () => Promise.resolve({ ok: true }),
    body: {
      getReader: () => ({
        read: () => {
          reads += 1;
          if (reads === 1) return Promise.resolve({ done: false, value: payload });
          if (hangAfterFirstRead) {
            return new Promise((resolve, reject) => {
              signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
            });
          }
          return Promise.resolve({ done: true, value: undefined });
        }
      })
    }
  };
}

const voiceTurnEvents = [
  { type: "RUN_STARTED", runId: "run_voice" },
  { type: "TEXT_MESSAGE_START", messageId: "voice_m1" },
  { type: "TOOL_CALL_START", toolCallId: "voice_t1", toolCallName: "list_cmux_sessions" },
  { type: "TOOL_CALL_RESULT", toolCallId: "voice_t1", result: { status: "completed", sessions: 2 } },
  { type: "TEXT_MESSAGE_CONTENT", messageId: "voice_m1", delta: "You have **2** sessions running." },
  { type: "TEXT_MESSAGE_END", messageId: "voice_m1" },
  { type: "RUN_FINISHED", runId: "run_voice" }
];

function makeVoiceFetch(overrides = {}) {
  return vi.fn((url, options = {}) => {
    const path = String(url);
    for (const [needle, handler] of Object.entries(overrides)) {
      if (path.includes(needle)) return Promise.resolve(handler(options));
    }
    if (path.includes("/copilotkit/info")) return Promise.resolve(jsonResponse({ version: "1", agents: {} }));
    if (path.includes("/bootstrap")) return Promise.resolve(jsonResponse(bootstrap));
    if (path.includes("/orphans")) return Promise.resolve(jsonResponse({ ok: true, orphans: [] }));
    if (path.includes("/ai/capabilities")) return Promise.resolve(jsonResponse({ ok: true, voiceModes: { visual: true } }));
    if (path.includes("/voice/local/transcribe")) return Promise.resolve(jsonResponse({ ok: true, text: "what sessions are running", backend: "parakeet" }));
    if (path.includes("/voice/local/speak")) return Promise.resolve(jsonResponse({ ok: true, provider: "kokoro", mimeType: "audio/wav", audioBase64: window.btoa("wav") }));
    if (path.includes("/voice/enrich")) return Promise.resolve(jsonResponse({ ok: true, html: "<html><body>Rich sessions panel</body></html>" }));
    if (path.includes("/chat/messages")) return Promise.resolve(jsonResponse({ ok: true, messages: [] }));
    if (path.includes("/ai/chat")) return Promise.resolve(sseResponse(voiceTurnEvents));
    return Promise.resolve(jsonResponse({ ok: true }));
  });
}

function installVoiceAudio() {
  FakeAudioContext.instances = [];
  window.AudioContext = FakeAudioContext;
  const track = { stop: vi.fn() };
  const getUserMedia = vi.fn(() => Promise.resolve({ getTracks: () => [track] }));
  Object.defineProperty(window.navigator, "mediaDevices", {
    configurable: true,
    value: { getUserMedia }
  });
  return { track, getUserMedia };
}

const voiceOverlay = () => document.querySelector(".voice-overlay");

async function openVoiceMode() {
  render(<AppShell />);
  await waitFor(() => expect(screen.getAllByText("Ship V2").length).toBeGreaterThan(0));
  fireEvent.click(screen.getByText("Visual Mode"));
  await waitFor(() => expect(voiceOverlay()).toBeTruthy());
}

async function startVoiceTurnSession() {
  await openVoiceMode();
  fireEvent.click(await screen.findByText("Start session"));
  await waitFor(() => expect(voiceOverlay().getAttribute("data-status")).toBe("followup"));
  const context = FakeAudioContext.instances.at(-1);
  const processor = context.scriptProcessors.at(-1);
  expect(processor.onaudioprocess).toBeTruthy();
  const loud = new Float32Array(4096).fill(0.2);
  act(() => {
    processor.onaudioprocess({ inputBuffer: { getChannelData: () => loud } });
    processor.onaudioprocess({ inputBuffer: { getChannelData: () => loud } });
  });
  await waitFor(() => expect(voiceOverlay().getAttribute("data-status")).toBe("listening"));
}

describe("VoiceVisualMode", () => {
  beforeEach(() => {
    window.localStorage.clear();
    installVoiceAudio();
    global.fetch = makeVoiceFetch();
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
    delete window.AudioContext;
    delete window.navigator.mediaDevices;
    window.history.replaceState({}, "", "/");
  });

  it("opens the voice view from the TopBar and returns to the dashboard", async () => {
    await openVoiceMode();

    expect(window.location.search).toContain("view=voice");
    expect(screen.getByText("Maestro")).toBeTruthy();
    expect(screen.getByText("Start session")).toBeTruthy();

    fireEvent.click(screen.getByText("Dashboard"));

    expect(voiceOverlay()).toBeNull();
    expect(window.location.search).not.toContain("view=voice");
  });

  it("opens the voice view from the ?view=voice deep link", async () => {
    window.history.replaceState({}, "", "/?view=voice");
    render(<AppShell />);

    await waitFor(() => expect(voiceOverlay()).toBeTruthy());
    expect(screen.getByText("Maestro")).toBeTruthy();
  });

  it("starts a session with a spoken greeting and opens the follow-up mic", async () => {
    await openVoiceMode();
    fireEvent.click(await screen.findByText("Start session"));

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/api/orchestrator-v2/voice/local/speak",
      expect.objectContaining({ method: "POST" })
    ));
    await waitFor(() => expect(voiceOverlay().getAttribute("data-status")).toBe("followup"));

    expect(window.navigator.mediaDevices.getUserMedia).toHaveBeenCalledWith({
      audio: { echoCancellation: true, noiseSuppression: true }
    });
    expect(document.querySelector(".voice-caption.assistant").textContent.length).toBeGreaterThan(0);
  });

  it("runs a full voice turn through transcribe, chat, speak, and enrich", async () => {
    await startVoiceTurnSession();

    fireEvent.click(screen.getByText("Talk"));

    await waitFor(() => {
      const transcribeCall = global.fetch.mock.calls.find(([url, options]) => (
        String(url).includes("/voice/local/transcribe") && !JSON.parse(options.body).partial
      ));
      expect(transcribeCall).toBeTruthy();
      expect(JSON.parse(transcribeCall[1].body).appendChat).toBe(false);
    });

    await waitFor(() => {
      const chatCall = global.fetch.mock.calls.find(([url]) => String(url).includes("/ai/chat"));
      expect(chatCall).toBeTruthy();
      const body = JSON.parse(chatCall[1].body);
      expect(body.mode).toBe("voice");
      expect(body.message).toBe("what sessions are running");
    });

    await waitFor(() => expect(screen.getAllByText("You have 2 sessions running.").length).toBeGreaterThan(0));
    expect(screen.getByText("list cmux sessions")).toBeTruthy();

    await waitFor(() => {
      const speakCall = global.fetch.mock.calls.find(([url, options]) => (
        String(url).includes("/voice/local/speak") && String(options.body).includes("You have 2 sessions running.")
      ));
      expect(speakCall).toBeTruthy();
    });

    const frame = await screen.findByTitle("Rich answer");
    expect(frame.getAttribute("sandbox")).toBe("");
    expect(frame.getAttribute("srcdoc")).toContain("Rich sessions panel");

    fireEvent.click(within(document.querySelector(".voice-panel-toggle")).getByText("Text"));
    expect(screen.queryByTitle("Rich answer")).toBeNull();
    expect(document.querySelector(".voice-panel-markdown")).toBeTruthy();
  });

  it("ends the session, releasing the mic and aborting the agent stream", async () => {
    let capturedSignal = null;
    const audio = installVoiceAudio();
    global.fetch = makeVoiceFetch({
      "/ai/chat": (options) => {
        capturedSignal = options.signal;
        return sseResponse(voiceTurnEvents.slice(0, 5), { signal: options.signal, hangAfterFirstRead: true });
      }
    });
    await startVoiceTurnSession();

    fireEvent.click(screen.getByText("Talk"));
    await waitFor(() => expect(voiceOverlay().getAttribute("data-status")).toBe("thinking"));
    expect(capturedSignal).toBeTruthy();

    fireEvent.click(screen.getByText("End session"));

    expect(capturedSignal.aborted).toBe(true);
    expect(audio.track.stop).toHaveBeenCalled();
    expect(voiceOverlay().getAttribute("data-status")).toBe("off");
    expect(await screen.findByText("Start session")).toBeTruthy();
  });

  it("cancels session startup when ended while the microphone request is pending", async () => {
    const track = { stop: vi.fn() };
    let resolveMedia = null;
    const getUserMedia = vi.fn(() => new Promise((resolve) => { resolveMedia = resolve; }));
    Object.defineProperty(window.navigator, "mediaDevices", { configurable: true, value: { getUserMedia } });
    await openVoiceMode();

    fireEvent.click(await screen.findByText("Start session"));
    await waitFor(() => expect(voiceOverlay().getAttribute("data-status")).toBe("greeting"));
    fireEvent.click(screen.getByText("End session"));
    expect(voiceOverlay().getAttribute("data-status")).toBe("off");

    await act(async () => {
      resolveMedia({ getTracks: () => [track] });
    });

    await waitFor(() => expect(track.stop).toHaveBeenCalled());
    expect(voiceOverlay().getAttribute("data-status")).toBe("off");
    expect(FakeAudioContext.instances.length).toBe(0);
    expect(global.fetch.mock.calls.some(([url]) => String(url).includes("/voice/local/speak"))).toBe(false);
  });

  it("surfaces RUN_ERROR without speaking or enriching the truncated answer", async () => {
    global.fetch = makeVoiceFetch({
      "/ai/chat": () => sseResponse([
        { type: "RUN_STARTED", runId: "run_err" },
        { type: "TEXT_MESSAGE_START", messageId: "err_m1" },
        { type: "TEXT_MESSAGE_CONTENT", messageId: "err_m1", delta: "Partial answer" },
        { type: "RUN_ERROR", message: "Agent runtime error: Fireworks 500" }
      ])
    });
    await startVoiceTurnSession();

    fireEvent.click(screen.getByText("Talk"));

    await waitFor(() => expect(screen.getByText("Agent runtime error: Fireworks 500")).toBeTruthy());
    expect(voiceOverlay().getAttribute("data-status")).toBe("idle");
    expect(document.querySelector(".voice-panel")).toBeNull();
    expect(global.fetch.mock.calls.some(([url]) => String(url).includes("/voice/enrich"))).toBe(false);
    expect(global.fetch.mock.calls.some(([url, options]) => (
      String(url).includes("/voice/local/speak") && String(options?.body).includes("Partial answer")
    ))).toBe(false);
  });

  it("applies late enrichment to the interrupted turn's panel", async () => {
    let resolveEnrich = null;
    global.fetch = makeVoiceFetch({
      "/voice/enrich": () => new Promise((resolve) => { resolveEnrich = resolve; })
    });
    await startVoiceTurnSession();

    fireEvent.click(screen.getByText("Talk"));
    await waitFor(() => expect(document.querySelector(".voice-panel")).toBeTruthy());
    await waitFor(() => expect(voiceOverlay().getAttribute("data-status")).toBe("followup"));

    fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => expect(voiceOverlay().getAttribute("data-status")).toBe("idle"));
    expect(within(document.querySelector(".voice-panel-toggle")).getByText("Rich…")).toBeTruthy();

    await act(async () => {
      resolveEnrich(jsonResponse({ ok: true, html: "<html><body>Late rich panel</body></html>" }));
    });

    const frame = await screen.findByTitle("Rich answer");
    expect(frame.getAttribute("srcdoc")).toContain("Late rich panel");
    expect(within(document.querySelector(".voice-panel-toggle")).getByText("Rich")).toBeTruthy();
  });

  it("renders global chat history in the drawer", async () => {
    const createdAt = new Date().toISOString();
    global.fetch = makeVoiceFetch({
      "/chat/messages": () => jsonResponse({
        ok: true,
        messages: [
          { id: "hist_1", role: "user", content: "voice question", createdAt, metadata: { mode: "voice" } },
          { id: "hist_2", role: "assistant", content: "voice answer", createdAt, metadata: { mode: "voice" } }
        ]
      })
    });
    await openVoiceMode();

    fireEvent.click(within(voiceOverlay()).getByText("History"));

    expect(await screen.findByText("voice question")).toBeTruthy();
    expect(screen.getByText("voice answer")).toBeTruthy();
    expect(screen.getByText("Today")).toBeTruthy();
    expect(document.querySelectorAll(".voice-mic-badge").length).toBe(2);

    fireEvent.click(document.querySelector(".voice-drawer-scrim"));
    expect(screen.queryByText("voice question")).toBeNull();
  });
});
