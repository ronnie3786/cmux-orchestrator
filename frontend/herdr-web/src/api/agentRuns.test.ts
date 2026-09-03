import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { configureClient } from "./client";
import {
  cancelAgentRun,
  getAgentRun,
  isTerminalRunStatus,
  startAgentRun,
} from "./agentRuns";

const BASE_URL = "http://127.0.0.1:9092/api/v1";

let fetchMock: ReturnType<typeof vi.fn>;

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(
    jsonResponse({
      ok: true,
      run: {
        id: "agr_0123456789ab",
        status: "queued",
        mode: "ask",
        model: null,
        thinkingLevel: null,
        prompt: "Why?",
        response: null,
        error: null,
        createdAt: "2026-09-01T00:00:00Z",
        startedAt: null,
        finishedAt: null,
        threadRootRunId: "agr_0123456789ab",
        sessionId: "s1",
        sessionFile: null,
        costUSD: 0,
        promotedWorkspaceId: null,
        promotedPaneId: null,
        attachments: [],
      },
    }),
  );
  vi.stubGlobal("fetch", fetchMock);
  configureClient({ baseUrl: BASE_URL, onUnauthorized: undefined });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("startAgentRun", () => {
  it("sends only the supported fields, pane-scoped", async () => {
    await startAgentRun({
      prompt: "Why is this here?",
      paneId: "w1:p1",
      label: "Ask about Pane.swift",
    });

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(`${BASE_URL}/agent-runs`);
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body)).toEqual({
      prompt: "Why is this here?",
      label: "Ask about Pane.swift",
      paneId: "w1:p1",
    });
  });

  it("continues a thread when a prior run is supplied", async () => {
    await startAgentRun({
      prompt: "And this?",
      mode: "ask",
      continueFromRunId: "agr_0123456789ab",
    });

    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      prompt: "And this?",
      mode: "ask",
      continueFromRunId: "agr_0123456789ab",
    });
  });
});

describe("getAgentRun", () => {
  it("polls the run by id", async () => {
    await getAgentRun("agr_0123456789ab");

    expect(fetchMock.mock.calls[0][0]).toBe(`${BASE_URL}/agent-runs/agr_0123456789ab`);
  });

  it("encodes run ids", async () => {
    await getAgentRun("agr abc");

    expect(fetchMock.mock.calls[0][0]).toBe(`${BASE_URL}/agent-runs/agr%20abc`);
  });
});

describe("cancelAgentRun", () => {
  it("posts an empty body", async () => {
    await cancelAgentRun("agr_0123456789ab");

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(`${BASE_URL}/agent-runs/agr_0123456789ab/cancel`);
    expect(init.method).toBe("POST");
    expect(init.body).toBe("{}");
  });
});

describe("isTerminalRunStatus", () => {
  it("treats finished states as terminal", () => {
    expect(isTerminalRunStatus("completed")).toBe(true);
    expect(isTerminalRunStatus("failed")).toBe(true);
    expect(isTerminalRunStatus("cancelled")).toBe(true);
    expect(isTerminalRunStatus("promoted")).toBe(true);
    expect(isTerminalRunStatus("queued")).toBe(false);
    expect(isTerminalRunStatus("running")).toBe(false);
  });
});