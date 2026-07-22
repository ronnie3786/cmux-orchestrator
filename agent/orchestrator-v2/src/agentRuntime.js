import { createFireworks } from "@ai-sdk/fireworks";
import { stepCountIs, streamText } from "ai";
import { EventType, event, id, panelEvent, validatePanel } from "./agui.js";
import { config, redactText } from "./env.js";
import { createAiTools, executeTool } from "./toolRegistry.js";

export function buildSystemPrompt(context, mode = "text") {
  const activeTasks = context?.tasks?.length ?? 0;
  const lines = [
    "You are Orchestrator V2, Ronnie's top-level local production agent runtime.",
    "Use durable Orchestrator V2 state and audited backend tools for facts. Do not pretend unsupported capabilities worked.",
    "Jira comments, cmux session kill, and cmux session restart must create approval requests; they execute only after Ronnie approves. Jira transitions may execute directly. PR replies/reviews and destructive git are not implemented.",
    "You can fully manage cmux sessions: list, read, search, inspect, create, launch coding agents, send prompts/keys, and propose kill/restart through approvals.",
    "Keep answers concise, operational, and grounded in task, cmux, Jira, PR, git, approval, audit, and activity state.",
    `Current active task count: ${activeTasks}.`
  ];
  if (mode === "voice") {
    lines.push(
      "Voice mode is active: your answer is spoken aloud while a visual panel renders the detail.",
      "Answer conversationally in at most 4 short sentences, around 45 words total. Do not use markdown tables, code blocks, URLs, or emoji. Round numbers.",
      "Always call tools before answering questions about sessions, tasks, PRs, or Jira. Speak counts and highlights; let the visual panel carry the detail.",
      "For send_cmux_prompt, create_cmux_session, or launch_coding_agent: first state exactly what will be sent or created and ask Ronnie to confirm verbally. Only call the tool after he explicitly confirms in a later turn."
    );
  }
  return lines.join("\n");
}

export async function runAgentChat({ client, input, emit, abortSignal }) {
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
  if (shouldUseGroundedTaskStatus(userText, context)) {
    const output = await runGroundedTaskStatusAgent({ client, runId, userText, context, emit: saveEmit, mode, abortSignal });
    await client.finishRun(runId, "completed", { text: output });
    await client.persistEvents(runId, events);
    return { runId, text: output, events };
  }

  if (cfg.dryRun || !cfg.fireworksApiKey) {
    const output = await runDryAgent({ client, runId, userText, context, emit: saveEmit, mode, abortSignal });
    await client.finishRun(runId, "completed", { text: output });
    await client.persistEvents(runId, events);
    return { runId, text: output, events };
  }

  let assistantText = "";
  const messageId = id("msg");
  let abortedOutcome = null;
  const finishAborted = async () => {
    if (abortedOutcome) return abortedOutcome;
    abortedOutcome = { runId, text: assistantText, events, aborted: true };
    saveEmit(event(EventType.TEXT_MESSAGE_END, runId, { messageId }));
    if (assistantText) {
      try {
        await client.appendTranscript("assistant", assistantText, { runId, mode, provider: "fireworks", model: cfg.model, aborted: true });
      } catch {}
    }
    saveEmit(event(EventType.RUN_FINISHED, runId, { status: "aborted" }));
    try {
      await client.finishRun(runId, "aborted", { text: assistantText });
    } catch {}
    try {
      await client.persistEvents(runId, events);
    } catch {}
    return abortedOutcome;
  };
  saveEmit(event(EventType.TEXT_MESSAGE_START, runId, { messageId, role: "assistant" }));
  try {
    const fireworks = createFireworks({ apiKey: cfg.fireworksApiKey });
    const result = streamText({
      model: fireworks(cfg.model),
      system: buildSystemPrompt(context, mode),
      messages: buildMessages(context, userText, mode),
      tools: createAiTools({ client, runId, emit: saveEmit }),
      stopWhen: stepCountIs(6),
      abortSignal
    });
    for await (const part of result.fullStream) {
      if (abortSignal?.aborted || part.type === "abort") break;
      if (part.type === "text-delta" || part.type === "text") {
        const delta = part.textDelta || part.text || part.delta || "";
        if (delta) {
          assistantText += delta;
          saveEmit(event(EventType.TEXT_MESSAGE_CONTENT, runId, { messageId, delta }));
        }
      } else if (part.type === "error") {
        throw part.error;
      }
    }
    if (abortSignal?.aborted) {
      return await finishAborted();
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
    if (abortSignal?.aborted) {
      return await finishAborted();
    }
    const message = `Agent runtime error: ${redactText(error?.message || error)}`;
    saveEmit(event(EventType.RUN_ERROR, runId, { message }));
    await client.appendTranscript("assistant", message, { runId, mode, error: true });
    await client.finishRun(runId, "error", { error: message });
    await client.persistEvents(runId, events);
    return { runId, text: message, events, error: message };
  }
}

export async function runDryAgent({ client, runId, userText, context, emit, mode = "text", abortSignal }) {
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
  } else if (/kill|stop.*session|restart/i.test(userText) && /session|cmux|workspace/i.test(userText)) {
    toolName = /restart/i.test(userText) ? "restart_cmux_session" : "kill_cmux_session";
    args = { workspaceId: extractWorkspaceId(userText, context) };
  } else if (/not implemented|destructive|pr review|pr reply/i.test(userText)) {
    toolName = /review/i.test(userText) ? "submit_pr_review" : /reply/i.test(userText) ? "post_pr_reply" : "run_destructive_git_operation";
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
    if (abortSignal?.aborted) break;
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

export function buildMessages(context, userText, mode = "text") {
  const chatMessages = Array.isArray(context?.chatMessages) ? context.chatMessages : [];
  const recentUserMessages = chatMessages.filter((message) => message.role !== "assistant").slice(-6);
  let recentMessages = recentUserMessages.map((message) => ({ role: "user", content: String(message.content || "") }));
  if (mode === "voice") {
    const includedUsers = new Set(recentUserMessages);
    const includedAssistants = new Set(chatMessages.filter((message) => message.role === "assistant").slice(-4));
    recentMessages = chatMessages
      .filter((message) => includedUsers.has(message) || includedAssistants.has(message))
      .map((message) => (message.role === "assistant"
        ? { role: "assistant", content: String(message.content || "").slice(0, 400) }
        : { role: "user", content: String(message.content || "") }));
  }
  const taskSummary = Array.isArray(context?.tasks)
    ? context.tasks.slice(0, 12).map((task) => ({
        id: task.id,
        title: task.title,
        status: task.status,
        workspaceDir: task.workspaceDir,
        sessions: (task.cmuxSessionLinks || []).map((session) => ({
          workspaceId: session.workspaceId,
          surfaceId: session.surfaceId,
          title: session.title,
          cwd: session.cwd
        }))
      }))
    : [];
  return [
    {
      role: "user",
      content: [
        "Durable Orchestrator V2 context snapshot follows. Treat previous assistant chat text as non-authoritative unless it is backed by a tool result in this run.",
        JSON.stringify({ tasks: taskSummary })
      ].join("\n")
    },
    ...recentMessages,
    { role: "user", content: userText }
  ];
}

async function runGroundedTaskStatusAgent({ client, runId, userText, context, emit, mode = "text", abortSignal }) {
  const messageId = id("msg");
  emit(event(EventType.TEXT_MESSAGE_START, runId, { messageId, role: "assistant" }));
  const tasks = await findStatusTasks({ client, runId, userText, context, emit });
  const inspections = [];
  for (const task of tasks.slice(0, 2)) {
    if (abortSignal?.aborted) break;
    for (const session of (task.cmuxSessionLinks || []).filter((item) => item?.active !== false).slice(0, 3)) {
      if (abortSignal?.aborted) break;
      if (!session?.workspaceId) continue;
      const inspection = await executeTool({
        client,
        runId,
        toolName: "inspect_cmux_session",
        args: { session, lines: 140 },
        emit
      });
      inspections.push({ taskId: task.id, taskTitle: task.title, session, inspection });
    }
  }
  const text = composeGroundedTaskStatusAnswer({ userText, tasks, inspections, context });
  for (const chunk of chunkText(text)) {
    if (abortSignal?.aborted) break;
    emit(event(EventType.TEXT_MESSAGE_CONTENT, runId, { messageId, delta: chunk }));
  }
  emit(event(EventType.TEXT_MESSAGE_END, runId, { messageId }));
  emit(panelEvent(runId, validatePanel({
    component: "ToolRunTimeline",
    props: { runId, mode, status: "completed", grounded: true }
  })));
  emit(event(EventType.RUN_FINISHED, runId, { status: "completed" }));
  await client.appendTranscript("assistant", text, { runId, mode, provider: "grounded-status" });
  return text;
}

async function findStatusTasks({ client, runId, userText, context, emit }) {
  const contextTasks = [
    ...(Array.isArray(context?.tasks) ? context.tasks : []),
    ...(Array.isArray(context?.history) ? context.history : [])
  ];
  const localMatches = rankTasksForText(contextTasks, userText).slice(0, 3);
  if (localMatches.length) return localMatches;

  const seen = new Map();
  for (const query of taskSearchQueries(userText)) {
    const result = await executeTool({
      client,
      runId,
      toolName: "search_tasks",
      args: { q: query },
      emit
    });
    for (const task of result?.tasks || []) {
      if (task?.id && !seen.has(task.id)) seen.set(task.id, task);
    }
    const ranked = rankTasksForText([...seen.values()], userText);
    if (ranked.length) return ranked.slice(0, 3);
  }
  return [...seen.values()].slice(0, 3);
}

function composeGroundedTaskStatusAnswer({ userText, tasks, inspections, context }) {
  if (!tasks.length) {
    const available = (context?.tasks || []).slice(0, 5).map((task) => task.title).filter(Boolean);
    const suffix = available.length ? ` Active tasks I can see: ${available.join("; ")}.` : "";
    return `I could not match "${userText}" to a durable Orchestrator V2 task, so I did not infer status from chat history.${suffix}`;
  }

  const lines = ["Grounded in live Orchestrator state and cmux output:"];
  for (const task of tasks.slice(0, 2)) {
    lines.push(`- ${task.title}: ${task.status || "Unknown status"}`);
    if (task.workspaceDir) lines.push(`  Workspace: ${task.workspaceDir}`);
    const taskInspections = inspections.filter((item) => item.taskId === task.id);
    if (!taskInspections.length) {
      lines.push("  No active linked cmux session was available to inspect.");
      continue;
    }
    for (const item of taskInspections) {
      const state = item.inspection?.state || "unknown";
      const runningKind = item.inspection?.runningKind ? `, ${item.inspection.runningKind}` : "";
      const title = item.session?.title || item.session?.workspaceId || "cmux session";
      lines.push(`  ${title}: ${state}${runningKind}`);
      const excerpt = lastUsefulLines(item.inspection?.screenExcerpt, 6);
      if (excerpt.length) {
        lines.push("  Latest visible output:");
        for (const line of excerpt) lines.push(`  ${line}`);
      }
    }
  }
  return lines.join("\n");
}

function shouldUseGroundedTaskStatus(userText, context) {
  const text = String(userText || "").trim();
  if (!text) return false;
  const asksForStatus = /\b(how'?s|how is|coming|progress|status|latest|update|what'?s happening|what is happening|what.*doing|still running|output)\b/i.test(text);
  if (!asksForStatus) return false;
  const tasks = [
    ...(Array.isArray(context?.tasks) ? context.tasks : []),
    ...(Array.isArray(context?.history) ? context.history : [])
  ];
  return rankTasksForText(tasks, text).length > 0;
}

function rankTasksForText(tasks, text) {
  const textTokens = tokenSet(text);
  return (tasks || [])
    .map((task) => {
      const titleTokens = tokenSet(task?.title || "");
      const workspaceTokens = tokenSet(task?.workspaceDir || "");
      const sessionTokens = new Set((task?.cmuxSessionLinks || []).flatMap((session) => [
        ...tokenSet(session?.title || ""),
        ...tokenSet(session?.cwd || "")
      ]));
      let score = 0;
      for (const token of titleTokens) if (textTokens.has(token)) score += 3;
      for (const token of sessionTokens) if (textTokens.has(token)) score += 2;
      for (const token of workspaceTokens) if (textTokens.has(token)) score += 1;
      return { task, score };
    })
    .filter(({ score }) => score >= 4)
    .sort((a, b) => b.score - a.score)
    .map(({ task }) => task);
}

function taskSearchQueries(text) {
  const cleaned = String(text || "")
    .replace(/\b(how'?s|how is|coming|along|progress|status|latest|update|what'?s|what is|happening|doing|still|running|task|session|cmux|the|a|an|please|can|you|check|tell|me|on)\b/gi, " ")
    .replace(/[^\w./-]+/g, " ")
    .trim();
  const queries = [cleaned, String(text || "").trim()].filter(Boolean);
  return [...new Set(queries.map((query) => query.toLowerCase()))];
}

function tokenSet(value) {
  return new Set(String(value || "")
    .toLowerCase()
    .split(/[^a-z0-9]+/i)
    .filter((token) => token.length > 1 && !STATUS_STOP_WORDS.has(token)));
}

const STATUS_STOP_WORDS = new Set([
  "how", "is", "the", "task", "session", "cmux", "coming", "progress", "status",
  "latest", "update", "what", "happening", "doing", "still", "running", "please",
  "check", "tell", "about", "with", "from", "for", "and", "you", "can", "our"
]);

function lastUsefulLines(value, limit) {
  return String(value || "")
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter((line) => line.trim())
    .slice(-limit);
}

function answerFromTool(toolName, result, context) {
  if (result?.status === "not_implemented") {
    return `${result.message} I recorded it as an unsupported capability instead of simulating success.`;
  }
  if (toolName === "post_jira_comment") {
    const approval = result?.approval || {};
    return `I created an approval request for ${approval.payload?.key || "the Jira issue"} instead of posting directly.`;
  }
  if (toolName === "kill_cmux_session" || toolName === "restart_cmux_session") {
    const approval = result?.approval || {};
    const action = toolName === "kill_cmux_session" ? "stop" : "restart";
    return `I created an approval request to ${action} ${approval.payload?.workspaceId || "the cmux session"}. It executes as soon as you approve it.`;
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

function extractWorkspaceId(text, context) {
  const sessions = (context?.tasks || []).flatMap((task) => task.cmuxSessionLinks || []);
  const tokens = String(text || "").toLowerCase().split(/[^a-z0-9_-]+/i).filter(Boolean);
  const match = sessions.find((session) => tokens.includes(String(session.workspaceId || "").toLowerCase())
    || tokens.includes(String(session.title || "").toLowerCase()));
  return match?.workspaceId || sessions[0]?.workspaceId || "";
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
