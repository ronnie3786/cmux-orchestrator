import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const sidecarRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const repoRoot = path.resolve(sidecarRoot, "..", "..");

const SECRET_PATTERNS = [
  /sk-[A-Za-z0-9_-]{16,}/g,
  /ek_[A-Za-z0-9_-]{16,}/g,
  /fw_[A-Za-z0-9_-]{16,}/g,
  /\bBearer\s+[A-Za-z0-9._-]{12,}/gi,
  /(FIREWORKS_API_KEY|OPENAI_API_KEY|ELEVENLABS_API_KEY)\s*=\s*[^\s]+/gi
];

export function loadLocalEnv() {
  const envPath = path.join(repoRoot, ".env.local");
  if (!fs.existsSync(envPath)) return {};
  const loaded = {};
  for (const raw of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || !line.includes("=")) continue;
    const index = line.indexOf("=");
    const key = line.slice(0, index).trim();
    const value = line.slice(index + 1).trim().replace(/^['"]|['"]$/g, "");
    if (!key) continue;
    if (!process.env[key]) process.env[key] = value;
    loaded[key] = value;
  }
  return loaded;
}

export function redactText(value) {
  let text = String(value ?? "");
  for (const pattern of SECRET_PATTERNS) {
    text = text.replace(pattern, "[REDACTED]");
  }
  return text;
}

export function redactValue(value) {
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === "object") {
    const out = {};
    for (const [key, item] of Object.entries(value)) {
      out[key] = isSecretKey(key)
        ? "[REDACTED]"
        : redactValue(item);
    }
    return out;
  }
  return typeof value === "string" ? redactText(value) : value;
}

function isSecretKey(key) {
  if (/^(input|output|total|cachedInput|reasoning)Tokens$/i.test(key)) return false;
  return /api[_-]?key|authorization|bearer|token|secret|password|credential/i.test(key);
}

export function config() {
  loadLocalEnv();
  const dryRunFlag =
    process.env.ORCHESTRATOR_V2_AGENT_DRY_RUN ||
    process.env.CMUX_ORCHESTRATOR_V2_AGENT_DRY_RUN ||
    "";
  return {
    port: Number(process.env.PORT || process.env.ORCHESTRATOR_V2_AGENT_PORT || 8792),
    host: process.env.ORCHESTRATOR_V2_AGENT_HOST || "127.0.0.1",
    pythonBaseUrl: (process.env.ORCHESTRATOR_V2_PYTHON_BASE_URL || "http://127.0.0.1:9091").replace(/\/$/, ""),
    provider: process.env.ORCHESTRATOR_V2_AGENT_PROVIDER || "fireworks",
    model: process.env.ORCHESTRATOR_V2_AGENT_MODEL || "accounts/fireworks/models/minimax-m2p7",
    fireworksApiKey: process.env.FIREWORKS_API_KEY || "",
    dryRun: /^(1|true|yes|on)$/i.test(dryRunFlag)
  };
}
