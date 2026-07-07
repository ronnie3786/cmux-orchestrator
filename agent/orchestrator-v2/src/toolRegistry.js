import { tool } from "ai";
import { z } from "zod";
import { EventType, event, panelEvent, validatePanel } from "./agui.js";

const anyArgs = z.object({}).catchall(z.any());

export const toolSpecs = Object.freeze({
  list_tasks: ["read", "List durable Orchestrator V2 tasks."],
  get_task: ["read", "Get one durable Orchestrator V2 task by id."],
  search_tasks: ["read", "Search active and historical tasks."],
  list_cmux_sessions: ["read", "List live cmux sessions."],
  read_cmux_session: ["read", "Read a cmux terminal screen excerpt."],
  search_cmux_sessions: ["read", "Search cmux sessions by content."],
  inspect_cmux_session: ["read", "Inspect a cmux session, classify running tool state, and return a screen excerpt."],
  summarize_task_sessions: ["local_update", "Refresh a task-linked session summary from cmux output."],
  read_goal_markdown: ["read", "Read a task goal markdown document."],
  find_jira_ticket: ["read", "Find a Jira ticket by key or URL."],
  list_assigned_jira: ["read", "List Ronnie's assigned Jira work."],
  list_my_open_prs: ["read", "List Ronnie's open non-draft PRs."],
  list_my_draft_prs: ["read", "List Ronnie's draft PRs."],
  list_prs_waiting_for_review: ["read", "List PRs waiting for Ronnie's review."],
  get_git_status: ["read", "Read git status for a workspace."],
  get_git_diff: ["read", "Read git diff for a specific changed file."],
  create_task: ["local_update", "Create an Orchestrator V2 task and optional cmux session."],
  update_task_status: ["local_update", "Update task status."],
  update_task_priority: ["local_update", "Update task priority."],
  update_task_tags: ["local_update", "Update task tags."],
  attach_jira_to_task: ["local_update", "Attach a Jira ticket to a task."],
  attach_pr_to_task: ["local_update", "Attach a GitHub PR to a task."],
  attach_cmux_session_to_task: ["local_update", "Attach a cmux session to a task."],
  detach_cmux_session_from_task: ["local_update", "Detach a cmux session from a task."],
  create_cmux_session: ["local_update", "Create a cmux session."],
  launch_coding_agent: ["local_update", "Launch a Codex, Claude Code, OpenCode, or Empty shell cmux session."],
  send_cmux_prompt: ["local_update", "Send text to a cmux session."],
  send_cmux_key: ["local_update", "Send a key to a cmux session."],
  update_goal_markdown: ["local_update", "Update a task goal markdown document."],
  create_approval_request: ["local_update", "Create a reviewed approval request."],
  post_jira_comment: ["external_write", "Create an approval request for posting a Jira comment. Does not post directly."],
  transition_jira_status: ["external_write", "Transition a Jira issue status without approval."],
  post_pr_reply: ["not_implemented", "Not implemented. Return an explicit unsupported capability."],
  submit_pr_review: ["not_implemented", "Not implemented. Return an explicit unsupported capability."],
  run_destructive_git_operation: ["not_implemented", "Not implemented. Return an explicit unsupported capability."],
  kill_cmux_session: ["cmux_lifecycle", "Create an approval request to stop a cmux session. Ronnie must approve before it executes."],
  restart_cmux_session: ["cmux_lifecycle", "Create an approval request to restart a cmux session. Ronnie must approve before it executes."]
});

const APPROVAL_GATED_TOOLS = new Set(["post_jira_comment", "kill_cmux_session", "restart_cmux_session"]);

export function capabilities() {
  return Object.fromEntries(Object.entries(toolSpecs).map(([name, [kind, description]]) => [
    name,
    {
      name,
      kind,
      description,
      status: kind === "not_implemented" ? "not_implemented" : APPROVAL_GATED_TOOLS.has(name) ? "approval_required" : "available"
    }
  ]));
}

export function createAiTools({ client, runId, emit }) {
  return Object.fromEntries(Object.entries(toolSpecs).map(([name, [, description]]) => [
    name,
    tool({
      description,
      inputSchema: anyArgs,
      execute: async (args) => executeTool({ client, runId, toolName: name, args, emit })
    })
  ]));
}

export async function executeTool({ client, runId, toolName, args, emit }) {
  const toolCallId = `${toolName}_${Date.now().toString(36)}`;
  emit?.(event(EventType.TOOL_CALL_START, runId, { toolCallId, toolCallName: toolName }));
  emit?.(event(EventType.TOOL_CALL_ARGS, runId, { toolCallId, delta: JSON.stringify(args || {}) }));
  emit?.(event(EventType.TOOL_CALL_END, runId, { toolCallId }));
  const payload = await client.runTool(runId, toolName, args || {});
  const result = payload.result ?? payload;
  emit?.(event(EventType.TOOL_CALL_RESULT, runId, { toolCallId, message: JSON.stringify(result), result }));
  const panel = panelForTool(toolName, result);
  if (panel) emit?.(panelEvent(runId, validatePanel(panel)));
  return result;
}

export function panelForTool(toolName, result) {
  if (result?.status === "not_implemented" || result?.result?.status === "not_implemented") {
    return {
      component: "NotImplementedCapabilityPanel",
      props: result?.status === "not_implemented" ? result : result.result
    };
  }
  if (toolName === "list_tasks" || toolName === "search_tasks" || toolName === "get_task") {
    const tasks = result?.tasks || (result?.task ? [result.task] : []);
    return { component: "TaskStatusPanel", props: { tasks, freshness: "durable-state" } };
  }
  if (toolName === "inspect_cmux_session") {
    return { component: "CmuxSessionInspectorPanel", props: result };
  }
  if (toolName === "get_git_status" || toolName === "get_git_diff") {
    return { component: "GitDiffSummaryPanel", props: result };
  }
  if (toolName === "post_jira_comment" || result?.approval?.kind === "post_jira_comment") {
    return { component: "JiraCommentApprovalPanel", props: result?.approval || result };
  }
  if (toolName === "kill_cmux_session" || toolName === "restart_cmux_session" || ["kill_cmux_session", "restart_cmux_session"].includes(result?.approval?.kind)) {
    return { component: "SessionLifecycleApprovalPanel", props: result?.approval || result };
  }
  if (toolName === "transition_jira_status") {
    return { component: "JiraTransitionPanel", props: result };
  }
  if (toolName === "update_goal_markdown" || toolName === "read_goal_markdown") {
    return { component: "GoalDraftPanel", props: result?.goal || result };
  }
  return null;
}

export function realtimeToolDefinitions() {
  return Object.entries(toolSpecs)
    .filter(([, [kind]]) => kind !== "not_implemented")
    .map(([name, [, description]]) => ({
      type: "function",
      name,
      description,
      parameters: {
        type: "object",
        properties: {},
        additionalProperties: true
      }
    }));
}
