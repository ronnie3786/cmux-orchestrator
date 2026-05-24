import assert from "node:assert/strict";
import test from "node:test";
import {
  buildAutoPolicyPrompt,
  normalizePolicyObject,
  parsePolicyText,
  usagePayload
} from "../src/autoApprovalPolicy.js";
import { redactValue } from "../src/env.js";

const approvalPolicy = {
  approvalNeeded: true,
  terminalState: "approval_prompt",
  action: "approve",
  submit: "enter",
  level: 2,
  confidence: 0.95,
  reason: "Safe approval prompt."
};

test("auto policy prompt includes terminal tail and workspace context", () => {
  const prompt = buildAutoPolicyPrompt({
    workspaceName: "Feature",
    cwd: "/repo",
    branch: "feature/auto",
    autoMode: "auto",
    threshold: 3,
    screenFingerprint: "abc123",
    screen: "line 1\nAllow Read?\n(Y/n)"
  });

  assert.match(prompt, /Workspace name: Feature/);
  assert.match(prompt, /Auto threshold: 3/);
  assert.match(prompt, /Allow Read\?/);
});

test("auto mode alerts when level is above threshold", () => {
  const policy = normalizePolicyObject({
    ...approvalPolicy,
    level: 4,
    reason: "Needs human judgment."
  }, "auto", 3);

  assert.equal(policy.action, "alert");
  assert.equal(policy.submit, "none");
});

test("super auto approves clear prompts regardless of threshold", () => {
  const policy = normalizePolicyObject({
    ...approvalPolicy,
    action: "alert",
    submit: "enter",
    level: 5,
    confidence: 0.2,
    reason: "Risky but explicit confirmation."
  }, "super", 3);

  assert.equal(policy.action, "approve");
  assert.equal(policy.submit, "enter");
});

test("non-approval terminal state is normalized to ignore", () => {
  const policy = normalizePolicyObject({
    ...approvalPolicy,
    approvalNeeded: false,
    terminalState: "idle_prompt",
    action: "approve",
    reason: "Shell prompt only."
  }, "auto", 3);

  assert.equal(policy.action, "ignore");
  assert.equal(policy.submit, "none");
});

test("invalid model policy is contained", () => {
  const policy = normalizePolicyObject({ action: "approve" }, "auto", 3);

  assert.equal(policy.approvalNeeded, true);
  assert.equal(policy.action, "alert");
  assert.equal(policy.submit, "none");
  assert.equal(policy.level, 5);
});

test("policy text parser accepts raw and fenced JSON", () => {
  assert.equal(parsePolicyText(JSON.stringify(approvalPolicy)).action, "approve");
  assert.equal(parsePolicyText(`\`\`\`json\n${JSON.stringify(approvalPolicy)}\n\`\`\``).submit, "enter");
});

test("policy text parser normalizes MiniMax terminal state aliases", () => {
  const policy = parsePolicyText(JSON.stringify({
    ...approvalPolicy,
    terminalState: "awaiting_confirmation"
  }));

  assert.equal(policy.terminalState, "approval_prompt");
});

test("policy text parser infers terminal state when MiniMax omits it", () => {
  const { terminalState, ...withoutTerminalState } = approvalPolicy;
  const policy = parsePolicyText(JSON.stringify(withoutTerminalState));

  assert.equal(policy.terminalState, "approval_prompt");
});

test("policy text parser tolerates no-approval objects missing action and submit", () => {
  const policy = parsePolicyText(JSON.stringify({
    approvalNeeded: false,
    terminalState: "running",
    confidence: "100%",
    reason: "Still running."
  }));

  assert.equal(policy.action, "ignore");
  assert.equal(policy.submit, "none");
  assert.equal(policy.confidence, 1);
});

test("policy text parser accepts common MiniMax field aliases", () => {
  const policy = parsePolicyText(JSON.stringify({
    needsApproval: true,
    state: "waiting_for_confirmation",
    decision: "allow",
    submitKey: "return",
    severityLevel: "Level 2 safe local write",
    confidence: "95%",
    rationale: "Safe local edit."
  }));

  assert.equal(policy.terminalState, "approval_prompt");
  assert.equal(policy.action, "approve");
  assert.equal(policy.submit, "enter");
  assert.equal(policy.level, 2);
  assert.equal(policy.confidence, 0.95);
  assert.equal(policy.reason, "Safe local edit.");
});

test("malformed policy objects are normalized into human alerts instead of CLI errors", () => {
  const policy = normalizePolicyObject(parsePolicyText(JSON.stringify({
    action: "approve"
  })), "auto", 3);

  assert.equal(policy.approvalNeeded, true);
  assert.equal(policy.action, "alert");
  assert.equal(policy.submit, "none");
});

test("usage payload preserves token counts", () => {
  assert.deepEqual(usagePayload({
    inputTokens: 100,
    outputTokens: 20,
    totalTokens: 120,
    cachedInputTokens: 10,
    reasoningTokens: 5
  }), {
    inputTokens: 100,
    outputTokens: 20,
    totalTokens: 120,
    cachedInputTokens: 10,
    reasoningTokens: 5
  });
});

test("redaction preserves token usage counters", () => {
  assert.deepEqual(redactValue({
    inputTokens: 100,
    outputTokens: 20,
    apiKey: "fw_example_secret_value_1234567890"
  }), {
    inputTokens: 100,
    outputTokens: 20,
    apiKey: "[REDACTED]"
  });
});
