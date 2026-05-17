import { config, redactText, redactValue } from "./env.js";

export class PythonClient {
  constructor(baseUrl = config().pythonBaseUrl) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
  }

  async get(path) {
    const response = await fetch(`${this.baseUrl}${path}`);
    return this.#json(response);
  }

  async post(path, payload = {}) {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(redactValue(payload))
    });
    return this.#json(response);
  }

  async #json(response) {
    const text = await response.text();
    let payload = {};
    try {
      payload = text ? JSON.parse(text) : {};
    } catch {
      payload = { ok: false, error: redactText(text) };
    }
    if (!response.ok || payload.ok === false) {
      const error = new Error(redactText(payload.error || `Python API failed: ${response.status}`));
      error.status = response.status;
      error.payload = payload;
      throw error;
    }
    return payload;
  }

  context() {
    return this.post("/api/orchestrator-v2/agent/context", {});
  }

  appendTranscript(role, content, metadata = {}) {
    return this.post("/api/orchestrator-v2/agent/transcript", { role, content, metadata });
  }

  createRun(runId, mode, input) {
    return this.post("/api/orchestrator-v2/agent/runs", { runId, mode, input });
  }

  finishRun(runId, status, output) {
    return this.post(`/api/orchestrator-v2/agent/runs/${encodeURIComponent(runId)}/finish`, { status, output });
  }

  persistEvents(runId, events) {
    return this.post("/api/orchestrator-v2/agent/agui-events", { runId, events });
  }

  runTool(runId, toolName, args) {
    return this.post(`/api/orchestrator-v2/agent/tools/${encodeURIComponent(toolName)}`, { runId, args });
  }
}
