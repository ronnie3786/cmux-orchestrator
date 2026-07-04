import crypto from "node:crypto";
import { redactValue } from "./env.js";

export const EventType = Object.freeze({
  RUN_STARTED: "RUN_STARTED",
  RUN_FINISHED: "RUN_FINISHED",
  RUN_ERROR: "RUN_ERROR",
  TEXT_MESSAGE_START: "TEXT_MESSAGE_START",
  TEXT_MESSAGE_CONTENT: "TEXT_MESSAGE_CONTENT",
  TEXT_MESSAGE_END: "TEXT_MESSAGE_END",
  TOOL_CALL_START: "TOOL_CALL_START",
  TOOL_CALL_ARGS: "TOOL_CALL_ARGS",
  TOOL_CALL_END: "TOOL_CALL_END",
  TOOL_CALL_RESULT: "TOOL_CALL_RESULT",
  STATE_DELTA: "STATE_DELTA",
  CUSTOM: "CUSTOM"
});

export function id(prefix) {
  return `${prefix}_${crypto.randomBytes(6).toString("hex")}`;
}

export function event(type, runId, payload = {}) {
  return redactValue({
    id: payload.id || id("evt"),
    type,
    runId,
    timestamp: new Date().toISOString(),
    ...payload
  });
}

export function panelEvent(runId, panel) {
  return event(EventType.CUSTOM, runId, {
    name: "ORCHESTRATOR_PANEL",
    value: panel
  });
}

export function sse(eventPayload) {
  return `event: ${eventPayload.type}\ndata: ${JSON.stringify(eventPayload)}\n\n`;
}

export function writeSse(res, eventPayload) {
  res.write(sse(eventPayload));
}

export const allowedPanels = new Set([
  "TaskStatusPanel",
  "CmuxSessionInspectorPanel",
  "GitDiffSummaryPanel",
  "GoalDraftPanel",
  "JiraCommentApprovalPanel",
  "SessionLifecycleApprovalPanel",
  "JiraTransitionPanel",
  "VoiceModePanel",
  "ToolRunTimeline",
  "NotImplementedCapabilityPanel"
]);

export function validatePanel(panel) {
  if (!panel || !allowedPanels.has(panel.component)) {
    throw new Error(`Unsupported generated panel: ${panel?.component || "unknown"}`);
  }
  return panel;
}
