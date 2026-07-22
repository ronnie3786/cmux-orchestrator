import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { createServer } from "../src/server.js";

class SlowContextClient {
  constructor({ contextDelayMs = 2600 } = {}) {
    this.contextDelayMs = contextDelayMs;
    this.messages = [];
  }
  async createRun() {
    return { ok: true };
  }
  async finishRun(runId, status, output) {
    this.finished = { runId, status, output };
    return { ok: true };
  }
  async persistEvents() {
    return { ok: true };
  }
  async appendTranscript(role, content, metadata) {
    this.messages.push({ role, content, metadata });
    return { ok: true };
  }
  async context() {
    await new Promise((resolve) => setTimeout(resolve, this.contextDelayMs));
    return { tasks: [], chatMessages: [] };
  }
  async runTool() {
    return { ok: true, result: { tasks: [] } };
  }
}

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

function postChat(port, payload) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: "127.0.0.1",
      port,
      method: "POST",
      path: "/api/orchestrator-v2/ai/chat",
      headers: { "Content-Type": "application/json" }
    }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end(JSON.stringify(payload));
  });
}

test("chat stream emits comment heartbeats while the run is silent and stops after finish", { timeout: 25000 }, async () => {
  process.env.ORCHESTRATOR_V2_AGENT_DRY_RUN = "1";
  const server = createServer({ client: new SlowContextClient() });
  const port = await listen(server);
  try {
    const raw = await postChat(port, { runId: "run_heartbeat", message: "hello" });
    const frames = raw.split("\n\n").filter(Boolean);
    const pings = frames.filter((frame) => frame.startsWith(": ping"));
    assert.ok(pings.length >= 1);
    assert.ok(pings.every((frame) => !frame.includes("data:")));
    assert.ok(raw.indexOf(": ping") > raw.indexOf("RUN_STARTED"));
    assert.ok(raw.lastIndexOf("RUN_FINISHED") > raw.lastIndexOf(": ping"));
    for (const frame of frames) {
      const dataLine = frame.split("\n").find((line) => line.startsWith("data:"));
      if (!dataLine) continue;
      JSON.parse(dataLine.slice(5).trim());
    }
    await new Promise((resolve) => setTimeout(resolve, 2300));
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("client disconnect mid-run stops heartbeats and keeps the server healthy", { timeout: 25000 }, async () => {
  process.env.ORCHESTRATOR_V2_AGENT_DRY_RUN = "1";
  const client = new SlowContextClient({ contextDelayMs: 3000 });
  const server = createServer({ client });
  const port = await listen(server);
  try {
    await new Promise((resolve, reject) => {
      const req = http.request({
        host: "127.0.0.1",
        port,
        method: "POST",
        path: "/api/orchestrator-v2/ai/chat",
        headers: { "Content-Type": "application/json" }
      }, (res) => {
        res.on("error", () => {});
        setTimeout(() => {
          res.destroy();
          resolve();
        }, 500);
      });
      req.on("error", reject);
      req.end(JSON.stringify({ runId: "run_disconnect", message: "hello" }));
    });
    await new Promise((resolve) => setTimeout(resolve, 5200));
    const health = await new Promise((resolve, reject) => {
      http.get({ host: "127.0.0.1", port, path: "/health" }, (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))));
      }).on("error", reject);
    });
    assert.equal(health.ok, true);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
