import assert from "node:assert/strict";
import test from "node:test";
import { runAgentChat } from "../src/agentRuntime.js";

class FailingBookkeepingClient {
  constructor() {
    this.finishCalls = [];
    this.messages = [];
    this.persistCalls = 0;
  }
  async createRun() {
    return { ok: true };
  }
  async finishRun(runId, status, output) {
    this.finishCalls.push({ runId, status, output });
    throw new Error("bookkeeping unavailable");
  }
  async persistEvents() {
    this.persistCalls += 1;
    throw new Error("bookkeeping unavailable");
  }
  async appendTranscript(role, content, metadata) {
    this.messages.push({ role, content, metadata });
    return { ok: true };
  }
  async context() {
    return { tasks: [], chatMessages: [] };
  }
  async runTool() {
    return { ok: true, result: {} };
  }
}

test("aborted live run finishes exactly once even when bookkeeping throws", { timeout: 20000 }, async () => {
  process.env.ORCHESTRATOR_V2_AGENT_DRY_RUN = "0";
  process.env.CMUX_ORCHESTRATOR_V2_AGENT_DRY_RUN = "0";
  process.env.FIREWORKS_API_KEY = "test-key";
  const client = new FailingBookkeepingClient();
  const events = [];
  const controller = new AbortController();
  controller.abort();

  const result = await runAgentChat({
    client,
    input: { runId: "run_abort", message: "hello there" },
    emit: (payload) => events.push(payload),
    abortSignal: controller.signal
  });

  assert.equal(result.aborted, true);
  assert.equal(result.runId, "run_abort");
  assert.equal(events.filter((item) => item.type === "RUN_FINISHED").length, 1);
  assert.equal(events.filter((item) => item.type === "TEXT_MESSAGE_END").length, 1);
  assert.equal(events.at(-1).type, "RUN_FINISHED");
  assert.equal(events.at(-1).status, "aborted");
  assert.equal(client.finishCalls.length, 1);
  assert.equal(client.finishCalls[0].status, "aborted");
  assert.equal(client.persistCalls, 1);
  assert.ok(client.messages.every((message) => message.role !== "assistant"));
});
