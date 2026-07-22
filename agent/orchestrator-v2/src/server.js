import http from "node:http";
import { config, redactText, redactValue } from "./env.js";
import { EventType, event, sse, writeSse } from "./agui.js";
import { runAgentChat } from "./agentRuntime.js";
import { PythonClient } from "./pythonClient.js";
import { capabilities, realtimeToolDefinitions } from "./toolRegistry.js";

function sendJson(res, status, payload) {
  const body = JSON.stringify(redactValue(payload));
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body)
  });
  res.end(body);
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  } catch {
    return {};
  }
}

function isChatPath(pathname) {
  return pathname === "/api/orchestrator-v2/ai/chat" || pathname === "/api/orchestrator-v2/agui/run" || pathname === "/api/orchestrator-v2/copilotkit";
}

const HEARTBEAT_INTERVAL_MS = 2000;

export function createServer({ client = new PythonClient(), cfg = config() } = {}) {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
    try {
      if (req.method === "GET" && url.pathname === "/health") {
        sendJson(res, 200, {
          ok: true,
          provider: cfg.provider,
          model: cfg.model,
          fireworksConfigured: Boolean(cfg.fireworksApiKey),
          dryRun: cfg.dryRun,
          tools: capabilities()
        });
        return;
      }
      if (req.method === "GET" && url.pathname === "/api/orchestrator-v2/ai/capabilities") {
        sendJson(res, 200, {
          ok: true,
          provider: cfg.provider,
          model: cfg.model,
          streaming: true,
          agui: true,
          tools: capabilities(),
          realtimeTools: realtimeToolDefinitions()
        });
        return;
      }
      if (req.method === "POST" && isChatPath(url.pathname)) {
        const input = await readJson(req);
        const abortController = new AbortController();
        res.on("close", () => abortController.abort());
        res.writeHead(200, {
          "Content-Type": "text/event-stream; charset=utf-8",
          "Cache-Control": "no-cache, no-transform",
          "Connection": "keep-alive",
          "X-Accel-Buffering": "no"
        });
        const heartbeat = setInterval(() => {
          if (abortController.signal.aborted || res.writableEnded || res.destroyed) return;
          res.write(": ping\n\n");
        }, HEARTBEAT_INTERVAL_MS);
        abortController.signal.addEventListener("abort", () => clearInterval(heartbeat), { once: true });
        try {
          await runAgentChat({
            client,
            input,
            emit: (payload) => {
              if (abortController.signal.aborted) return;
              writeSse(res, payload);
            },
            abortSignal: abortController.signal
          });
        } finally {
          clearInterval(heartbeat);
        }
        if (!abortController.signal.aborted) res.end();
        return;
      }
      if (req.method === "GET" && url.pathname === "/api/orchestrator-v2/agui/schema") {
        sendJson(res, 200, {
          ok: true,
          events: Object.values(EventType),
          panels: [
            "TaskStatusPanel",
            "CmuxSessionInspectorPanel",
            "GitDiffSummaryPanel",
            "GoalDraftPanel",
            "JiraCommentApprovalPanel",
            "JiraTransitionPanel",
            "VoiceModePanel",
            "ToolRunTimeline",
            "NotImplementedCapabilityPanel"
          ]
        });
        return;
      }
      sendJson(res, 404, { ok: false, error: "not found" });
    } catch (error) {
      if (!res.headersSent) {
        sendJson(res, 500, { ok: false, error: redactText(error?.message || error) });
      } else {
        res.write(sse(event(EventType.RUN_ERROR, "unknown", { message: redactText(error?.message || error) })));
        res.end();
      }
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const cfg = config();
  const server = createServer({ cfg });
  server.listen(cfg.port, cfg.host, () => {
    process.stdout.write(`orchestrator-v2-agent listening on ${cfg.host}:${cfg.port}\n`);
  });
}
