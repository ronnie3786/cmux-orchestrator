import assert from "node:assert/strict";
import test from "node:test";
import { EventType, allowedPanels, event, panelEvent, validatePanel } from "../src/agui.js";
import { capabilities, panelForTool, realtimeToolDefinitions } from "../src/toolRegistry.js";

test("AG-UI events use stable lifecycle names", () => {
  const payload = event(EventType.TEXT_MESSAGE_CONTENT, "run_1", {
    messageId: "msg_1",
    delta: "hello"
  });

  assert.equal(payload.type, "TEXT_MESSAGE_CONTENT");
  assert.equal(payload.runId, "run_1");
  assert.equal(payload.delta, "hello");
  assert.ok(payload.timestamp);
});

test("controlled panel events reject unallowlisted components", () => {
  assert.throws(() => validatePanel({ component: "RawHtmlPanel", props: {} }), /Unsupported/);
  const panel = validatePanel({ component: "TaskStatusPanel", props: { tasks: [] } });
  const payload = panelEvent("run_2", panel);
  assert.equal(payload.name, "ORCHESTRATOR_PANEL");
  assert.equal(payload.value.component, "TaskStatusPanel");
  assert.ok(allowedPanels.has("JiraCommentApprovalPanel"));
});

test("tool registry exposes every production goal capability", () => {
  const names = Object.keys(capabilities());
  for (const name of [
    "list_tasks",
    "get_task",
    "send_cmux_key",
    "post_jira_comment",
    "transition_jira_status",
    "post_pr_reply",
    "submit_pr_review",
    "run_destructive_git_operation",
    "kill_cmux_session",
    "restart_cmux_session"
  ]) {
    assert.ok(names.includes(name), `${name} missing`);
  }
  assert.equal(capabilities().post_jira_comment.status, "approval_required");
  assert.equal(capabilities().kill_cmux_session.status, "not_implemented");
});

test("realtime tools omit future unsupported writes", () => {
  const names = realtimeToolDefinitions().map((item) => item.name);
  assert.ok(names.includes("list_tasks"));
  assert.ok(names.includes("post_jira_comment"));
  assert.ok(!names.includes("kill_cmux_session"));
});

test("panel selection maps unsupported capability to NotImplementedCapabilityPanel", () => {
  const panel = panelForTool("kill_cmux_session", {
    status: "not_implemented",
    capability: "kill_cmux_session",
    message: "not yet"
  });
  assert.equal(panel.component, "NotImplementedCapabilityPanel");
});
