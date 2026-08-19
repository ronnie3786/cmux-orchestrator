/**
 * Unit tests for the Command Lens pure helpers (P9-run-A) — no DOM needed.
 *
 * Agent values are the real ones seen in the live 9092 check during this
 * phase (`GET /api/v1/workspaces` pane `agent` fields are lowercase: "pi";
 * "opencode" appears in the workspaces.json fixture; "claude" is a
 * documented agent value, doc 02 §2 start-agent kinds).
 */
import { describe, expect, it } from "vitest";
import type { AgentStatus, Pane } from "../../types/herdr";
import { canSend, composerDispatch, composerPlaceholder } from "./PromptComposerView";

type ComposerPane = Pick<Pane, "agent" | "agent_status">;

function pane(agent: string | undefined, status: AgentStatus = "idle"): ComposerPane {
  return { agent, agent_status: status };
}

describe("composerPlaceholder", () => {
  it("is byte-exact for shell panes (agent absent, status unknown)", () => {
    expect(composerPlaceholder(pane(undefined, "unknown"))).toBe("run or type into this shell");
  });

  it("treats an empty agent string as a shell pane", () => {
    expect(composerPlaceholder(pane(""))).toBe("run or type into this shell");
  });

  it("renders 'message <agent>' for agent panes (server values are lowercase)", () => {
    expect(composerPlaceholder(pane("pi"))).toBe("message pi");
    expect(composerPlaceholder(pane("opencode"))).toBe("message opencode");
    expect(composerPlaceholder(pane("claude"))).toBe("message claude");
  });

  it("falls back to the shell placeholder when an agent exists but status is unknown", () => {
    expect(composerPlaceholder(pane("claude", "unknown"))).toBe("run or type into this shell");
  });
});

describe("composerDispatch", () => {
  it("dispatches shell panes to run with {command}", () => {
    expect(composerDispatch(pane(undefined, "unknown"), "ls -la")).toEqual({
      kind: "run",
      payload: { command: "ls -la" },
    });
  });

  it("dispatches agent panes to prompt with bare {text}", () => {
    expect(composerDispatch(pane("pi"), "hello agent")).toEqual({
      kind: "prompt",
      payload: { text: "hello agent" },
    });
  });
});

describe("canSend", () => {
  it("allows Live and Demo", () => {
    expect(canSend("Live")).toBe(true);
    expect(canSend("Demo")).toBe(true);
  });

  it("blocks Offline, Connecting, and Unavailable", () => {
    expect(canSend("Offline")).toBe(false);
    expect(canSend("Connecting")).toBe(false);
    expect(canSend("Unavailable")).toBe(false);
  });
});
