import assert from "node:assert/strict";
import test from "node:test";
import { runAgentChat } from "../src/agentRuntime.js";

class FakeClient {
  constructor() {
    this.toolRuns = [];
    this.messages = [];
  }
  async createRun(runId, mode, input) {
    this.run = { runId, mode, input };
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
    if (toolName === "kill_cmux_session") {
      return {
        ok: true,
        result: {
          status: "not_implemented",
          capability: "kill_cmux_session",
          message: "cmux kill is intentionally not implemented."
        }
      };
    }
    if (toolName === "post_jira_comment") {
      return {
        ok: true,
        result: {
          approval: {
            id: "approval_1",
            kind: "post_jira_comment",
            status: "pending",
            payload: {
              key: args.key,
              body: args.body,
              toolName
            }
          }
        }
      };
    }
    return {
      ok: true,
      result: {
        tasks: [{ id: "task_1", title: "Ship runtime", status: "In Progress" }]
      }
    };
  }
}

test("dry run streams AG-UI events and persists transcript", async () => {
  process.env.ORCHESTRATOR_V2_AGENT_DRY_RUN = "1";
  const client = new FakeClient();
  const events = [];

  const result = await runAgentChat({
    client,
    input: { runId: "run_test", message: "status please" },
    emit: (payload) => events.push(payload)
  });

  assert.equal(result.runId, "run_test");
  assert.equal(client.toolRuns[0].toolName, "list_tasks");
  assert.ok(events.some((item) => item.type === "TEXT_MESSAGE_CONTENT"));
  assert.ok(events.some((item) => item.name === "ORCHESTRATOR_PANEL" && item.value.component === "TaskStatusPanel"));
  assert.equal(client.messages[0].role, "user");
  assert.equal(client.messages.at(-1).role, "assistant");
  assert.equal(client.finished.status, "completed");
});

test("dry run returns explicit unsupported capability panel", async () => {
  process.env.ORCHESTRATOR_V2_AGENT_DRY_RUN = "1";
  const client = new FakeClient();
  const events = [];

  await runAgentChat({
    client,
    input: { runId: "run_nope", message: "please kill this cmux session" },
    emit: (payload) => events.push(payload)
  });

  assert.equal(client.toolRuns[0].toolName, "kill_cmux_session");
  assert.ok(events.some((item) => item.name === "ORCHESTRATOR_PANEL" && item.value.component === "NotImplementedCapabilityPanel"));
});

test("dry run creates Jira comment approval panel", async () => {
  process.env.ORCHESTRATOR_V2_AGENT_DRY_RUN = "1";
  const client = new FakeClient();
  const events = [];

  await runAgentChat({
    client,
    input: { runId: "run_approval", message: 'Post a Jira comment on APP-123 saying "Ready for review"' },
    emit: (payload) => events.push(payload)
  });

  assert.equal(client.toolRuns[0].toolName, "post_jira_comment");
  assert.deepEqual(client.toolRuns[0].args, { key: "APP-123", body: "Ready for review" });
  assert.ok(events.some((item) => item.name === "ORCHESTRATOR_PANEL" && item.value.component === "JiraCommentApprovalPanel"));
});
