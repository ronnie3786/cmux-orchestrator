#!/usr/bin/env node
import { runAutoApprovalPolicy } from "./autoApprovalPolicy.js";
import { redactValue } from "./env.js";

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
}

try {
  const input = await readStdin();
  const result = await runAutoApprovalPolicy(input);
  process.stdout.write(`${JSON.stringify(redactValue(result))}\n`);
  process.exit(result.ok ? 0 : 2);
} catch (error) {
  process.stdout.write(`${JSON.stringify({
    ok: false,
    error: String(error?.message || error)
  })}\n`);
  process.exit(2);
}
