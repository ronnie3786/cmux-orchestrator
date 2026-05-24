import { createFireworks } from "@ai-sdk/fireworks";
import { generateText } from "ai";
import { z } from "zod";
import { config, redactText } from "./env.js";

globalThis.AI_SDK_LOG_WARNINGS = false;

export const DEFAULT_AUTO_POLICY_MODEL = "accounts/fireworks/models/minimax-m2p7";

export const policySchema = z.object({
  approvalNeeded: z.boolean(),
  terminalState: z.enum([
    "running",
    "idle_prompt",
    "approval_prompt",
    "question_prompt",
    "completed",
    "unknown"
  ]),
  action: z.enum(["approve", "submit", "alert", "ignore"]),
  submit: z.enum(["enter", "y", "yes", "1", "2", "3", "4", "none"]),
  level: z.number().int().min(1).max(5).nullable(),
  confidence: z.number().min(0).max(1),
  reason: z.string().min(1).max(240)
});

export function buildAutoPolicySystemPrompt() {
  return [
    "You are a JSON API for cmux Auto Approval Bot.",
    "Inspect the terminal tail and return exactly one compact JSON object. No markdown. No commentary.",
    "Required shape: {\"approvalNeeded\":boolean,\"terminalState\":\"running|idle_prompt|approval_prompt|question_prompt|completed|unknown\",\"action\":\"approve|submit|alert|ignore\",\"submit\":\"enter|y|yes|1|2|3|4|none\",\"level\":1|2|3|4|5|null,\"confidence\":0..1,\"reason\":\"short\"}.",
    "",
    "First decide whether the terminal currently needs approval or trivial continuation input.",
    "Approval/input is needed only when the visible terminal is asking the user to allow, approve, confirm, continue, proceed, trust, run, apply, save, select an affirmative option, or answer a yes/no approval question.",
    "If the session is running, printing logs, at a shell prompt, finished and waiting for a new user prompt, or simply idle without an approval request, set approvalNeeded false, terminalState accordingly, action ignore, submit none.",
    "",
    "Severity scale:",
    "1 - Read-only project access: reading files, listing dirs, searching.",
    "2 - Safe local writes or safe shell commands: edit/write files, build, test, ls, cat, grep.",
    "3 - Known external service reads/writes in normal dev workflow: Jira, GitHub, Slack, web fetch.",
    "4 - Ambiguous or human-judgment work: multi-option choices, unclear prompts, unknown tools, design/product decisions.",
    "5 - Dangerous or destructive work: deleting files, force push, reset --hard, dropping databases, production changes, secrets.",
    "",
    "Action rules:",
    "- In auto mode, approve or submit only when approvalNeeded is true, level is at or below threshold, confidence is at least 0.85, and there is a safe submit value.",
    "- In auto mode, use alert when approvalNeeded is true but level is above threshold, confidence is low, the prompt asks for secrets, or the safe selection is unclear.",
    "- In super mode, approve or submit any clear approval/input prompt regardless of threshold and confidence. Alert only when there is no clear affirmative input to submit.",
    "- Use approve for permission/confirmation prompts. Use submit for trivial continuation input such as pressing Enter to continue.",
    "- submit must be enter, y, yes, 1, 2, 3, 4, or none. Prefer enter when the terminal already has an affirmative option highlighted.",
    "- Never invent arbitrary text to type. Never include secrets in reason.",
    "Return compact JSON only."
  ].join("\n");
}

export function buildAutoPolicyPrompt(input) {
  const screen = String(input.screen || "")
    .split(/\r?\n/)
    .slice(-80)
    .join("\n");
  return [
    `Workspace name: ${input.workspaceName || ""}`,
    `Workspace cwd: ${input.cwd || ""}`,
    `Workspace branch: ${input.branch || ""}`,
    `Auto mode: ${input.autoMode || "auto"}`,
    `Auto threshold: ${input.threshold ?? 3}`,
    `Screen fingerprint: ${input.screenFingerprint || ""}`,
    "",
    "Terminal tail:",
    screen
  ].join("\n");
}

export function normalizePolicyObject(value, autoMode = "auto", threshold = 3) {
  const parsed = policySchema.safeParse(coercePolicyObject(value));
  if (!parsed.success) {
    return {
      approvalNeeded: true,
      terminalState: "unknown",
      action: "alert",
      submit: "none",
      level: 5,
      confidence: 0,
      reason: "Model returned an invalid auto-approval policy object."
    };
  }

  const policy = { ...parsed.data };
  const superAuto = String(autoMode || "").toLowerCase() === "super";
  const level = policy.level ?? (policy.approvalNeeded ? 5 : null);

  if (!policy.approvalNeeded) {
    policy.action = "ignore";
    policy.submit = "none";
    policy.level = level;
    return policy;
  }

  policy.level = level;
  if (superAuto) {
    if (policy.submit === "none") {
      policy.action = "alert";
    } else if (policy.action === "alert" || policy.action === "ignore") {
      policy.action = "approve";
    }
    return policy;
  }

  if (policy.action === "approve" || policy.action === "submit") {
    if (policy.submit === "none") {
      policy.action = "alert";
      policy.reason = policy.reason || "No safe submit key was selected.";
    } else if (!level || level > Number(threshold || 3)) {
      policy.action = "alert";
      policy.submit = "none";
      policy.reason = policy.reason || `Level ${level || 5} is above threshold ${threshold}.`;
    } else if (policy.confidence < 0.85) {
      policy.action = "alert";
      policy.submit = "none";
      policy.reason = policy.reason || "Low confidence approval decision.";
    }
  }

  return policy;
}

export function parsePolicyText(text) {
  const raw = String(text || "").trim();
  if (!raw) throw new Error("Model returned empty policy text.");

  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidate = fenced ? fenced[1].trim() : extractJsonObject(raw);
  let parsed;
  try {
    parsed = JSON.parse(candidate);
  } catch (error) {
    throw new Error(`Model returned invalid policy JSON: ${error.message}`);
  }

  return coercePolicyObject(parsed) || parsed;
}

function coercePolicyObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;

  const terminalStateValue = cleanEnum(value.terminalState ?? value.terminal_state ?? value.state, {
    running: "running",
    active: "running",
    working: "running",
    processing: "running",
    idle: "idle_prompt",
    idle_prompt: "idle_prompt",
    prompt: "idle_prompt",
    shell_prompt: "idle_prompt",
    user_prompt: "idle_prompt",
    approval: "approval_prompt",
    approval_prompt: "approval_prompt",
    permission_prompt: "approval_prompt",
    confirm_prompt: "approval_prompt",
    confirmation: "approval_prompt",
    waiting: "approval_prompt",
    waiting_for_approval: "approval_prompt",
    awaiting_approval: "approval_prompt",
    waiting_for_confirmation: "approval_prompt",
    awaiting_confirmation: "approval_prompt",
    confirmation_prompt: "approval_prompt",
    question: "question_prompt",
    question_prompt: "question_prompt",
    waiting_for_input: "question_prompt",
    awaiting_input: "question_prompt",
    completed: "completed",
    complete: "completed",
    done: "completed",
    finished: "completed",
    unknown: "unknown"
  });
  const inactiveState = terminalStateValue === "running" || terminalStateValue === "idle_prompt" || terminalStateValue === "completed";
  const rawAction = cleanEnum(value.action ?? value.decision ?? value.recommendation ?? value.policy, {
    approve: "approve",
    approved: "approve",
    allow: "approve",
    accept: "approve",
    auto_approve: "approve",
    permitted: "approve",
    submit: "submit",
    continue: "submit",
    send: "submit",
    press: "submit",
    alert: "alert",
    ask: "alert",
    human: "alert",
    escalate: "alert",
    needs_human: "alert",
    ignore: "ignore",
    skip: "ignore",
    wait: "ignore",
    none: "ignore"
  });
  const submit = cleanEnum(value.submit ?? value.submitKey ?? value.submit_key ?? value.key ?? value.selection ?? value.answer ?? value.response, {
    enter: "enter",
    return: "enter",
    press_enter: "enter",
    newline: "enter",
    y: "y",
    yes: "yes",
    "1": "1",
    "2": "2",
    "3": "3",
    "4": "4",
    none: "none"
  });
  const approvalNeeded = booleanOrNull(value.approvalNeeded)
    ?? booleanOrNull(value.needsApproval)
    ?? booleanOrNull(value.approval_needed)
    ?? booleanOrNull(value.requiresApproval)
    ?? booleanOrNull(value.requires_approval)
    ?? booleanOrNull(value.inputNeeded)
    ?? booleanOrNull(value.needsInput)
    ?? (!inactiveState && rawAction !== "ignore");
  const action = rawAction || (
    approvalNeeded
      ? (submit && submit !== "none" ? "approve" : "alert")
      : "ignore"
  );
  const normalizedSubmit = submit || (approvalNeeded ? "none" : "none");
  const reason = String(value.reason ?? value.rationale ?? value.explanation ?? value.decisionReason ?? value.decision_reason ?? "").trim().slice(0, 240)
    || (approvalNeeded ? "Approval prompt detected without a complete model reason." : "No approval or continuation prompt is visible.");

  if (!action || !normalizedSubmit || !reason) return null;

  const terminalState = terminalStateValue || (
    approvalNeeded
      ? (action === "submit" ? "question_prompt" : "approval_prompt")
      : "unknown"
  );

  return {
    approvalNeeded,
    terminalState,
    action,
    submit: normalizedSubmit,
    level: levelOrNull(value.level ?? value.severity ?? value.severityLevel ?? value.severity_level ?? value.riskLevel ?? value.risk_level),
    confidence: confidenceOrDefault(value.confidence, approvalNeeded ? 0 : 1),
    reason
  };
}

function cleanEnum(value, aliases) {
  const normalized = String(value ?? "").trim().toLowerCase().replace(/[\s-]+/g, "_");
  return aliases[normalized] || null;
}

function extractJsonObject(text) {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return text;
  return text.slice(start, end + 1);
}

export function usagePayload(usage) {
  const inputTokens = numberOrNull(usage?.inputTokens);
  const outputTokens = numberOrNull(usage?.outputTokens);
  const totalTokens = numberOrNull(usage?.totalTokens) ?? (
    inputTokens != null && outputTokens != null ? inputTokens + outputTokens : null
  );
  return {
    inputTokens,
    outputTokens,
    totalTokens,
    cachedInputTokens: numberOrNull(usage?.cachedInputTokens),
    reasoningTokens: numberOrNull(usage?.reasoningTokens)
  };
}

function numberOrNull(value) {
  return Number.isFinite(Number(value)) ? Number(value) : null;
}

function booleanOrNull(value) {
  if (typeof value === "boolean") return value;
  const normalized = String(value ?? "").trim().toLowerCase();
  if (["true", "yes", "y", "1", "needed", "required"].includes(normalized)) return true;
  if (["false", "no", "n", "0", "none", "not_needed", "not_required"].includes(normalized)) return false;
  return null;
}

function confidenceOrDefault(value, fallback) {
  const raw = String(value ?? "").trim();
  if (raw.endsWith("%")) {
    const percent = Number(raw.slice(0, -1));
    if (Number.isFinite(percent)) return Math.max(0, Math.min(1, percent / 100));
  }
  const numeric = numberOrNull(value);
  if (numeric == null) return fallback;
  return Math.max(0, Math.min(1, numeric > 1 ? numeric / 100 : numeric));
}

function levelOrNull(value) {
  const numeric = numberOrNull(value);
  if (numeric != null) return numeric;
  const normalized = String(value ?? "").trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (!normalized) return null;
  const explicitLevel = normalized.match(/\blevel_?([1-5])\b/);
  if (explicitLevel) return Number(explicitLevel[1]);
  if (/read|readonly|low|safe_read/.test(normalized)) return 1;
  if (/safe|write|local|test|build/.test(normalized)) return 2;
  if (/external|service|medium|network|api/.test(normalized)) return 3;
  if (/ambiguous|judgment|human|unclear|high/.test(normalized)) return 4;
  if (/danger|destructive|critical|secret|production|force|delete/.test(normalized)) return 5;
  return null;
}

export async function runAutoApprovalPolicy(input) {
  const cfg = config();
  const modelName = process.env.CMUX_AUTO_POLICY_MODEL || cfg.model || DEFAULT_AUTO_POLICY_MODEL;
  const provider = "fireworks";
  const startedAt = Date.now();

  if (!cfg.fireworksApiKey) {
    return {
      ok: false,
      error: "FIREWORKS_API_KEY is not configured.",
      provider,
      model: modelName,
      usage: usagePayload(null),
      latencyMs: Date.now() - startedAt
    };
  }

  const fireworks = createFireworks({ apiKey: cfg.fireworksApiKey });
  const prompt = buildAutoPolicyPrompt(input);
  let modelResult;

  try {
    modelResult = await generateText({
      model: fireworks(modelName),
      system: buildAutoPolicySystemPrompt(),
      prompt,
      temperature: 0,
      maxOutputTokens: Number(process.env.CMUX_AUTO_POLICY_MAX_OUTPUT_TOKENS || 900),
      timeout: Number(process.env.CMUX_AUTO_POLICY_TIMEOUT_MS || 45000)
    });
    const policy = normalizePolicyObject(parsePolicyText(modelResult.text), input.autoMode, input.threshold);
    return {
      ok: true,
      provider,
      model: modelName,
      policy,
      usage: usagePayload(modelResult.totalUsage || modelResult.usage),
      finishReason: modelResult.finishReason,
      latencyMs: Date.now() - startedAt,
      promptChars: prompt.length
    };
  } catch (error) {
    return {
      ok: false,
      error: redactText(error?.message || error),
      provider,
      model: modelName,
      usage: usagePayload(modelResult?.totalUsage || modelResult?.usage || error?.usage),
      finishReason: modelResult?.finishReason,
      latencyMs: Date.now() - startedAt,
      promptChars: prompt.length
    };
  }
}
