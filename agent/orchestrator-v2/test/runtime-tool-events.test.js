import assert from "node:assert/strict";
import test from "node:test";
import { runAgentChat } from "../src/agentRuntime.js";

class CountingClient {
  constructor() {
    this.toolRuns = [];
    this.messages = [];
  }
  async createRun() {
    return { ok: true };
  }
  async finishRun(runId, status, output) {
    this.finished = { runId, status, output };
    return { ok: true };
  }
  async persistEvents(runId, events) {
    this.persisted = { runId, events };
    return { ok: true };
  }
  async appendTranscript(role, content, metadata) {
    this.messages.push({ role, content, metadata });
    return { ok: true };
  }
  async context() {
    return {
      tasks: [{ id: "task_1", title: "Ship runtime", status: "In Progress", workspaceDir: "/tmp" }],
      chatMessages: []
    };
  }
  async runTool(runId, toolName, args) {
    this.toolRuns.push({ runId, toolName, args });
    return { ok: true, result: { sessions: [{ workspaceId: "workspace:1" }] } };
  }
}

test("each executed tool call emits exactly one TOOL_CALL_START/ARGS/END/RESULT set", async () => {
  process.env.ORCHESTRATOR_V2_AGENT_DRY_RUN = "1";
  const client = new CountingClient();
  const events = [];

  await runAgentChat({
    client,
    input: { runId: "run_tools", message: "list my cmux sessions" },
    emit: (payload) => events.push(payload)
  });

  assert.equal(client.toolRuns.length, 1);
  const starts = events.filter((item) => item.type === "TOOL_CALL_START");
  const args = events.filter((item) => item.type === "TOOL_CALL_ARGS");
  const ends = events.filter((item) => item.type === "TOOL_CALL_END");
  const results = events.filter((item) => item.type === "TOOL_CALL_RESULT");
  assert.equal(starts.length, client.toolRuns.length);
  assert.equal(args.length, client.toolRuns.length);
  assert.equal(ends.length, client.toolRuns.length);
  assert.equal(results.length, client.toolRuns.length);
  assert.equal(new Set(starts.map((item) => item.toolCallId)).size, starts.length);
  assert.equal(starts[0].toolCallId, results[0].toolCallId);
  assert.equal(starts[0].toolCallName, "list_cmux_sessions");
  const order = events
    .filter((item) => item.toolCallId === starts[0].toolCallId)
    .map((item) => item.type);
  assert.deepEqual(order, ["TOOL_CALL_START", "TOOL_CALL_ARGS", "TOOL_CALL_END", "TOOL_CALL_RESULT"]);
});
