import { createFireworks } from "@ai-sdk/fireworks";
import { stepCountIs, streamText } from "ai";
import { EventType, event, id, panelEvent, validatePanel } from "./agui.js";
import { config, redactText } from "./env.js";
import { createAiTools, executeTool, panelForTool } from "./toolRegistry.js";

export function buildSystemPrompt(context) {
  const activeTasks = context?.tasks?.length ?? 0;
  return [
    "You are Orchestrator V2, Ronnie's top-level local production agent runtime.",
    "Use durable Orchestrator V2 state and audited backend tools for facts. Do not pretend unsupported capabilities worked.",
    "Jira comments must create approval requests. Jira transitions may execute. PR replies/reviews, destructive git, cmux kill, and cmux restart are not implemented.",
    "Keep answers concise, operational, and grounded in task, cmux, Jira, PR, git, approval, audit, and activity state.",
    `Current active task count: ${activeTasks}.`
  ].join("\n");
}

export async function runAgentChat({ client, input, emit }) {
  const cfg = config();
  const runId = input.runId || id("run");
  const mode = input.mode || "text";
  const events = [];
  const saveEmit = (payload) => {
    events.push(payload);
    emit(payload);
  };
  const userText = extractUserText(input);

  saveEmit(event(EventType.RUN_STARTED, runId, { threadId: input.threadId || "global", mode }));
  await client.createRun(runId, mode, { message: userText });
  if (userText) {
    await client.appendTranscript("user", userText, { runId, mode });
  }

  const context = await client.context();
  if (cfg.dryRun || !cfg.fireworksApiKey) {
    const output = await runDryAgent({ client, runId, userText, context, emit: saveEmit, mode });
    await client.finishRun(runId, "completed", { text: output });
    await client.persistEvents(runId, events);
    return { runId, text: output, events };
  }

  let assistantText = "";
  const messageId = id("msg");
  saveEmit(event(EventType.TEXT_MESSAGE_START, runId, { messageId, role: "assistant" }));
  try {
    const fireworks = createFireworks({ apiKey: cfg.fireworksApiKey });
    const result = streamText({
      model: fireworks(cfg.model),
      system: buildSystemPrompt(context),
      messages: buildMessages(context, userText),
      tools: createAiTools({ client, runId, emit: saveEmit }),
      stopWhen: stepCountIs(6)
    });
    for await (const part of result.fullStream) {
      if (part.type === "text-delta" || part.type === "text") {
        const delta = part.textDelta || part.text || part.delta || "";
        if (delta) {
          assistantText += delta;
          saveEmit(event(EventType.TEXT_MESSAGE_CONTENT, runId, { messageId, delta }));
        }
      } else if (part.type === "tool-call") {
        saveEmit(event(EventType.TOOL_CALL_START, runId, {
          toolCallId: part.toolCallId,
          toolCallName: part.toolName
        }));
        saveEmit(event(EventType.TOOL_CALL_ARGS, runId, {
          toolCallId: part.toolCallId,
          delta: JSON.stringify(part.input || {})
        }));
        saveEmit(event(EventType.TOOL_CALL_END, runId, { toolCallId: part.toolCallId }));
      } else if (part.type === "tool-result") {
        saveEmit(event(EventType.TOOL_CALL_RESULT, runId, {
          toolCallId: part.toolCallId,
          result: part.output ?? part.result
        }));
        const panel = panelForTool(part.toolName, part.output ?? part.result);
        if (panel) saveEmit(panelEvent(runId, validatePanel(panel)));
      } else if (part.type === "error") {
        throw part.error;
      }
    }
    saveEmit(event(EventType.TEXT_MESSAGE_END, runId, { messageId }));
    if (assistantText) {
      await client.appendTranscript("assistant", assistantText, { runId, mode, provider: "fireworks", model: cfg.model });
    }
    saveEmit(panelEvent(runId, validatePanel({
      component: "ToolRunTimeline",
      props: { runId, status: "completed" }
    })));
    saveEmit(event(EventType.RUN_FINISHED, runId, { status: "completed" }));
    await client.finishRun(runId, "completed", { text: assistantText });
    await client.persistEvents(runId, events);
    return { runId, text: assistantText, events };
  } catch (error) {
    const message = `Agent runtime error: ${redactText(error?.message || error)}`;
    saveEmit(event(EventType.RUN_ERROR, runId, { message }));
    await client.appendTranscript("assistant", message, { runId, mode, error: true });
    await client.finishRun(runId, "error", { error: message });
    await client.persistEvents(runId, events);
    return { runId, text: message, events, error: message };
  }
}

export async function runDryAgent({ client, runId, userText, context, emit, mode = "text" }) {
  const messageId = id("msg");
  emit(event(EventType.TEXT_MESSAGE_START, runId, { messageId, role: "assistant" }));
  let toolName = "list_tasks";
  let args = { includeHistory: /history|done|archived/i.test(userText), q: "" };
  if (/jira.*comment|comment.*jira|post.*comment/i.test(userText)) {
    toolName = "post_jira_comment";
    args = {
      key: extractJiraKey(userText) || "APP-123",
      body: extractQuotedText(userText) || "Dry-run approval preview from Orchestrator V2."
    };
  } else if (/jira.*transition|transition.*jira/i.test(userText)) {
    toolName = "transition_jira_status";
    args = {
      key: extractJiraKey(userText) || "APP-123",
      status: /done/i.test(userText) ? "Done" : "In Progress"
    };
  } else if (/not implemented|kill|restart|destructive|pr review|pr reply/i.test(userText)) {
    toolName = /review/i.test(userText) ? "submit_pr_review" : /reply/i.test(userText) ? "post_pr_reply" : /kill/i.test(userText) ? "kill_cmux_session" : /restart/i.test(userText) ? "restart_cmux_session" : "run_destructive_git_operation";
    args = {};
  } else if (/git|diff/i.test(userText) && context?.tasks?.[0]?.workspaceDir) {
    toolName = "get_git_status";
    args = { path: context.tasks[0].workspaceDir };
  } else if (/cmux|session/i.test(userText)) {
    toolName = "list_cmux_sessions";
    args = {};
  }
  const result = await executeTool({ client, runId, toolName, args, emit });
  const text = answerFromTool(toolName, result, context);
  for (const chunk of chunkText(text)) {
    emit(event(EventType.TEXT_MESSAGE_CONTENT, runId, { messageId, delta: chunk }));
  }
  emit(event(EventType.TEXT_MESSAGE_END, runId, { messageId }));
  emit(panelEvent(runId, validatePanel({
    component: "ToolRunTimeline",
    props: { runId, mode, status: "completed", dryRun: true }
  })));
  emit(event(EventType.RUN_FINISHED, runId, { status: "completed" }));
  await client.appendTranscript("assistant", text, { runId, mode, provider: "dry-run" });
  return text;
}

function extractUserText(input) {
  if (input.message) return String(input.message);
  if (Array.isArray(input.messages) && input.messages.length) {
    const last = input.messages[input.messages.length - 1];
    return String(last?.content || last?.text || "");
  }
  return "";
}

function buildMessages(context, userText) {
  const recent = Array.isArray(context?.chatMessages) ? context.chatMessages.slice(-16) : [];
  return [
    ...recent.map((message) => ({ role: message.role === "assistant" ? "assistant" : "user", content: String(message.content || "") })),
    { role: "user", content: userText }
  ];
}

function answerFromTool(toolName, result, context) {
  if (result?.status === "not_implemented") {
    return `${result.message} I recorded it as an unsupported capability instead of simulating success.`;
  }
  if (toolName === "post_jira_comment") {
    const approval = result?.approval || {};
    return `I created an approval request for ${approval.payload?.key || "the Jira issue"} instead of posting directly.`;
  }
  if (toolName === "transition_jira_status") {
    return `I sent the Jira transition through the audited backend for ${result?.key || "the issue"}.`;
  }
  if (toolName === "get_git_status") {
    const changed = (result.staged?.length || 0) + (result.unstaged?.length || 0) + (result.untracked?.length || 0);
    return `Git status is loaded from the backend: ${changed} changed file(s) on ${result.branch || "the current branch"}.`;
  }
  if (toolName === "list_cmux_sessions") {
    return `I found ${(result.sessions || []).length} cmux session(s) from the audited backend.`;
  }
  const tasks = result?.tasks || context?.tasks || [];
  if (!tasks.length) return "I do not see any matching active tasks in durable Orchestrator V2 state.";
  return `I checked durable Orchestrator V2 state and found ${tasks.length} task(s). ${tasks.slice(0, 3).map((task) => `${task.title}: ${task.status}`).join("; ")}.`;
}

function extractJiraKey(text) {
  const match = String(text || "").match(/\b([A-Z][A-Z0-9]+-\d+)\b/i);
  return match ? match[1].toUpperCase() : "";
}

function extractQuotedText(text) {
  const match = String(text || "").match(/["“]([^"”]+)["”]/);
  return match ? match[1].trim() : "";
}

function chunkText(text) {
  const chunks = [];
  for (let index = 0; index < text.length; index += 80) {
    chunks.push(text.slice(index, index + 80));
  }
  return chunks.length ? chunks : [""];
}
