import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import {
  Archive,
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  Bell,
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  Circle,
  Copy,
  Delete,
  Diamond,
  Edit3,
  ExternalLink,
  FileCode2,
  Folder,
  GitBranch,
  Github,
  GitPullRequest,
  Grid2X2,
  History,
  LayoutDashboard,
  Lightbulb,
  List,
  Mic,
  MoreHorizontal,
  Orbit,
  PanelLeftClose,
  PanelLeftOpen,
  Play,
  Plus,
  RefreshCw,
  Send,
  Settings,
  ShieldAlert,
  Sparkles,
  SplitSquareHorizontal,
  Terminal,
  X
} from "lucide-react";
import { CopilotKit, useCopilotAction, useCopilotReadable } from "@copilotkit/react-core";
import "./styles.css";

const API_ROOT = "/api/orchestrator-v2";
const STATUSES = ["Backlog", "Investigating", "To Do", "Running", "In Progress", "Blocked", "In Review", "Done", "Archived"];
const PRIORITIES = ["Low", "Medium", "High"];
const LAUNCH_TYPES = ["Empty shell", "Codex", "Claude Code", "OpenCode"];

function initialUiState() {
  if (typeof window === "undefined") return { selectedView: { kind: "board" }, modalState: null };
  const params = new URLSearchParams(window.location.search);
  const taskId = params.get("task");
  const view = params.get("view");
  let selectedView = { kind: "board" };
  if (taskId && (view === "session" || view === "diff" || view === "goal")) {
    selectedView = { kind: view, taskId, mode: params.get("mode") || undefined };
  } else if (view === "activity" || view === "history" || view === "voice") {
    selectedView = { kind: view };
  }
  return {
    selectedView,
    modalState: params.get("modal") === "new" ? { mode: "new" } : null
  };
}

function api(path, options = {}) {
  const headers = { ...(options.headers || {}) };
  if (options.body && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
  return fetch(`${API_ROOT}${path}`, { ...options, headers }).then(async (response) => {
    const body = await response.json().catch(() => ({}));
    if (!response.ok || body.ok === false) {
      throw new Error(body.error || `Request failed: ${response.status}`);
    }
    return body;
  });
}

async function streamAgent(path, payload, onEvent, options = {}) {
  const response = await fetch(`${API_ROOT}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload || {}),
    signal: options.signal
  });
  if (!response.ok || !response.body) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error || `Agent request failed: ${response.status}`);
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    let chunk;
    try {
      chunk = await reader.read();
    } catch (err) {
      if (options.signal?.aborted) return;
      throw err;
    }
    const { value, done } = chunk;
    if (done) break;
    if (options.signal?.aborted) return;
    buffer += decoder.decode(value, { stream: true });
    const parts = buffer.split("\n\n");
    buffer = parts.pop() || "";
    for (const part of parts) {
      const dataLine = part.split("\n").find((line) => line.startsWith("data:"));
      if (!dataLine) continue;
      try {
        onEvent(JSON.parse(dataLine.slice(5).trim()));
      } catch {
        // Ignore malformed stream chunks; the backend persists the canonical run events.
      }
    }
  }
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onloadend = () => resolve(String(reader.result || "").split(",")[1] || "");
    reader.onerror = () => reject(reader.error || new Error("Failed to read audio"));
    reader.readAsDataURL(blob);
  });
}

function stopStream(stream) {
  stream?.getTracks?.().forEach((track) => track.stop());
}

const VOICE_PERSONA_NAME = "Maestro";
const VOICE_TARGET_SAMPLE_RATE = 16000;
const VOICE_PARTIAL_INTERVAL_MS = 1500;
const VOICE_FOLLOW_UP_MS = 6000;
const VOICE_VAD = { speechRms: 0.012, minSpeechMs: 450, silenceMs: 900, maxUtteranceMs: 20000 };
const VOICE_MAX_PCM_MS = 60000;
const VOICE_BARGE_IN = { rms: 0.018, sustainMs: 220, cooldownMs: 700, prebufferMs: 500, noSpeechMs: 3000 };
const VOICE_GREETINGS = [
  "Hey — what are we doing today?",
  "Ready when you are. What do you need?",
  "Hello. What should we look at first?",
  "I'm listening. Where do we start?"
];
const VOICE_ACKS = [
  "Checking that now.",
  "On it — one moment.",
  "Let me take a look.",
  "Working on it."
];
const VOICE_STATE_LABELS = {
  off: "Standing by",
  greeting: "Waking up",
  idle: "Ready",
  listening: "Listening",
  transcribing: "Transcribing",
  thinking: "Thinking",
  speaking: "Speaking",
  followup: "Follow-up"
};
const VOICE_CAPTURE_WORKLET = `
class VoiceCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = [];
    this.length = 0;
  }
  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (channel && channel.length) {
      this.buffer.push(new Float32Array(channel));
      this.length += channel.length;
      if (this.length >= 2048) {
        const merged = new Float32Array(this.length);
        let offset = 0;
        for (const chunk of this.buffer) {
          merged.set(chunk, offset);
          offset += chunk.length;
        }
        this.port.postMessage(merged, [merged.buffer]);
        this.buffer = [];
        this.length = 0;
      }
    }
    return true;
  }
}
registerProcessor("voice-capture", VoiceCaptureProcessor);
`;

async function createVoiceCapture(audioContext, stream, onChunk) {
  const source = audioContext.createMediaStreamSource(stream);
  if (audioContext.audioWorklet?.addModule && typeof window.AudioWorkletNode === "function" && typeof URL.createObjectURL === "function") {
    const moduleUrl = URL.createObjectURL(new Blob([VOICE_CAPTURE_WORKLET], { type: "application/javascript" }));
    try {
      await audioContext.audioWorklet.addModule(moduleUrl);
      const node = new window.AudioWorkletNode(audioContext, "voice-capture");
      node.port.onmessage = (event) => onChunk(event.data);
      source.connect(node);
      return {
        stop() {
          node.port.onmessage = null;
          try { source.disconnect(); } catch { /* already disconnected */ }
          try { node.disconnect(); } catch { /* already disconnected */ }
        }
      };
    } catch {
      // Fall back to ScriptProcessorNode below.
    } finally {
      URL.revokeObjectURL(moduleUrl);
    }
  }
  const node = audioContext.createScriptProcessor(4096, 1, 1);
  node.onaudioprocess = (event) => onChunk(new Float32Array(event.inputBuffer.getChannelData(0)));
  source.connect(node);
  node.connect(audioContext.destination);
  return {
    stop() {
      node.onaudioprocess = null;
      try { source.disconnect(); } catch { /* already disconnected */ }
      try { node.disconnect(); } catch { /* already disconnected */ }
    }
  };
}

function mergeFloat32(chunks) {
  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const merged = new Float32Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }
  return merged;
}

function downsampleFloat32(samples, sourceRate, targetRate) {
  if (!samples.length || sourceRate <= targetRate) return samples;
  const ratio = sourceRate / targetRate;
  const length = Math.floor(samples.length / ratio);
  const result = new Float32Array(length);
  for (let index = 0; index < length; index += 1) {
    const start = Math.floor(index * ratio);
    const end = Math.min(samples.length, Math.floor((index + 1) * ratio));
    let sum = 0;
    for (let cursor = start; cursor < end; cursor += 1) sum += samples[cursor];
    result[index] = end > start ? sum / (end - start) : samples[start] || 0;
  }
  return result;
}

function encodeWavPcm16(samples, sampleRate) {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  const writeAscii = (offset, text) => {
    for (let index = 0; index < text.length; index += 1) view.setUint8(offset + index, text.charCodeAt(index));
  };
  writeAscii(0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  writeAscii(8, "WAVE");
  writeAscii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(36, "data");
  view.setUint32(40, samples.length * 2, true);
  let offset = 44;
  for (let index = 0; index < samples.length; index += 1, offset += 2) {
    const sample = Math.max(-1, Math.min(1, samples[index]));
    view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
  }
  return buffer;
}

function wavBase64FromChunks(chunks, sourceRate) {
  const merged = mergeFloat32(chunks);
  if (!merged.length) return Promise.resolve("");
  const rate = Math.min(sourceRate || VOICE_TARGET_SAMPLE_RATE, VOICE_TARGET_SAMPLE_RATE);
  const samples = downsampleFloat32(merged, sourceRate, rate);
  const wav = encodeWavPcm16(samples, rate);
  return blobToBase64(new Blob([wav], { type: "audio/wav" }));
}

function base64ToArrayBuffer(base64) {
  const binary = window.atob(base64 || "");
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function chunkRms(chunk) {
  if (!chunk?.length) return 0;
  let sum = 0;
  for (let index = 0; index < chunk.length; index += 1) sum += chunk[index] * chunk[index];
  return Math.sqrt(sum / chunk.length);
}

function stripMarkdownForCaption(text) {
  return String(text || "")
    .replace(/```[\s\S]*?(```|$)/g, " ")
    .replace(/`([^`]*)`/g, "$1")
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/^\s*>\s?/gm, "")
    .replace(/(\*\*|__)(.*?)\1/g, "$2")
    .replace(/(\*|_)(.*?)\1/g, "$2")
    .replace(/~~(.*?)~~/g, "$1")
    .replace(/^\s*[-+*]\s+/gm, "")
    .replace(/^\s*\d+\.\s+/gm, "")
    .replace(/^[-=_]{3,}\s*$/gm, " ")
    .replace(/\|/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function realtimeClientSecretValue(payload) {
  return payload?.clientSecret?.value ||
    payload?.clientSecret?.client_secret?.value ||
    payload?.clientSecret?.secret?.value ||
    payload?.value ||
    "";
}

function parseToolArguments(value) {
  if (!value) return {};
  if (typeof value === "object") return value;
  try {
    return JSON.parse(value);
  } catch {
    return {};
  }
}

function realtimeToolCallFromEvent(event) {
  if (event?.type === "response.function_call_arguments.done") {
    return {
      callId: event.call_id || event.callId || event.item_id,
      name: event.name,
      arguments: parseToolArguments(event.arguments)
    };
  }
  if (event?.type === "response.output_item.done" && event.item?.type === "function_call") {
    return {
      callId: event.item.call_id || event.item.callId || event.item.id,
      name: event.item.name,
      arguments: parseToolArguments(event.item.arguments)
    };
  }
  return null;
}

function itemsOf(section) {
  if (Array.isArray(section)) return section;
  return Array.isArray(section?.items) ? section.items : [];
}

function AppShell() {
  const initialUi = useMemo(() => initialUiState(), []);
  const realtimeRef = useRef(null);
  const localRecorderRef = useRef(null);
  const localChunksRef = useRef([]);
  const localStreamRef = useRef(null);
  const audioRef = useRef(null);
  const [tasks, setTasks] = useState([]);
  const [history, setHistory] = useState([]);
  const [leftRail, setLeftRail] = useState({});
  const [activity, setActivity] = useState([]);
  const [approvals, setApprovals] = useState([]);
  const [chatMessages, setChatMessages] = useState([]);
  const [agentCapabilities, setAgentCapabilities] = useState(null);
  const [generatedPanels, setGeneratedPanels] = useState([]);
  const [agentStreaming, setAgentStreaming] = useState(false);
  const [voiceMode, setVoiceMode] = useState("text");
  const [voiceState, setVoiceState] = useState({ status: "idle", message: "", localTranscript: "" });
  const [voiceSettings, setVoiceSettings] = useState({ pushToTalk: true, ttsProvider: "piper" });
  const [proactiveUpdates, setProactiveUpdates] = useState(() => {
    if (typeof window === "undefined") return true;
    return window.localStorage.getItem("orchestrator-v2-proactive-updates") !== "off";
  });
  const [orphans, setOrphans] = useState([]);
  const [selectedView, setSelectedView] = useState(initialUi.selectedView);
  const [railCollapsed, setRailCollapsed] = useState(false);
  const [modalState, setModalState] = useState(initialUi.modalState);
  const [dockWidth, setDockWidth] = useState(() => {
    if (typeof window === "undefined") return 360;
    return clamp(Number(window.localStorage.getItem("orchestrator-v2-dock-width") || 360), 300, 640);
  });
  const [loading, setLoading] = useState(true);
  const [toast, setToast] = useState("");
  const [error, setError] = useState("");
  const [liveStatus, setLiveStatus] = useState("connecting");

  const refresh = useCallback(async () => {
    setError("");
    const [bootstrap, orphanPayload] = await Promise.all([
      api("/bootstrap"),
      api("/orphans").catch(() => ({ orphans: [] }))
    ]);
    setTasks(bootstrap.tasks || []);
    setHistory(bootstrap.history || []);
    setLeftRail(bootstrap.leftRail || {});
    setActivity(bootstrap.activity || []);
    setApprovals(bootstrap.approvals || []);
    setChatMessages(bootstrap.chatMessages || []);
    setAgentCapabilities(bootstrap.agentCapabilities || null);
    setOrphans(orphanPayload.orphans || []);
  }, []);

  useEffect(() => {
    refresh()
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false));
  }, [refresh]);

  useEffect(() => {
    window.localStorage?.setItem("orchestrator-v2-proactive-updates", proactiveUpdates ? "on" : "off");
    if (!proactiveUpdates) return undefined;
    // Polling is the safety net; the SSE stream below delivers changes as they happen.
    const interval = window.setInterval(() => {
      refresh().catch(() => {});
    }, liveStatus === "live" ? 120000 : 30000);
    return () => window.clearInterval(interval);
  }, [proactiveUpdates, refresh, liveStatus]);

  useEffect(() => {
    if (!proactiveUpdates || typeof window === "undefined" || typeof window.EventSource === "undefined") {
      setLiveStatus("polling");
      return undefined;
    }
    let source = null;
    let retryTimer = null;
    let closed = false;
    const connect = () => {
      if (closed) return;
      source = new window.EventSource(`${API_ROOT}/events/stream`);
      source.addEventListener("connected", () => setLiveStatus("live"));
      source.addEventListener("update", () => {
        refresh().catch(() => {});
      });
      source.onerror = () => {
        setLiveStatus("polling");
        source?.close();
        if (!closed) retryTimer = window.setTimeout(connect, 15000);
      };
    };
    connect();
    return () => {
      closed = true;
      source?.close();
      if (retryTimer) window.clearTimeout(retryTimer);
    };
  }, [proactiveUpdates, refresh]);

  useEffect(() => {
    window.localStorage?.setItem("orchestrator-v2-dock-width", String(dockWidth));
  }, [dockWidth]);

  const previousViewRef = useRef({ kind: "board" });

  useEffect(() => {
    const onPopState = () => {
      const params = new URLSearchParams(window.location.search);
      if (params.get("view") === "voice") {
        setSelectedView((current) => (current.kind === "voice" ? current : { kind: "voice" }));
      } else {
        setSelectedView((current) => (current.kind === "voice" ? previousViewRef.current || { kind: "board" } : current));
      }
    };
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, []);

  const enterVoiceMode = () => {
    if (selectedView.kind === "voice") return;
    previousViewRef.current = selectedView;
    const url = new URL(window.location.href);
    url.searchParams.set("view", "voice");
    window.history.pushState({ view: "voice" }, "", url.toString());
    setSelectedView({ kind: "voice" });
  };

  const exitVoiceMode = () => {
    const url = new URL(window.location.href);
    url.searchParams.delete("view");
    window.history.pushState({}, "", url.toString());
    setSelectedView(previousViewRef.current || { kind: "board" });
  };

  const createTask = async (payload) => {
    const result = await api("/tasks", { method: "POST", body: JSON.stringify(payload) });
    setTasks((current) => [result.task, ...current.filter((task) => task.id !== result.task.id)]);
    setToast(`Started ${result.task.title}`);
    setModalState(null);
    await refresh();
    return result.task;
  };

  const updateTask = async (taskId, patch) => {
    const result = await api(`/tasks/${encodeURIComponent(taskId)}`, { method: "PATCH", body: JSON.stringify(patch) });
    const updated = result.task;
    if (!updated) {
      await refresh();
      setToast("Task updated");
      return null;
    }
    setTasks((current) => {
      const known = current.some((task) => task.id === taskId);
      const next = known
        ? current.map((task) => (task.id === taskId ? updated : task))
        : [updated, ...current];
      return next.filter((task) => !["Done", "Archived"].includes(task.status));
    });
    setHistory((current) => current.map((task) => (task.id === taskId ? updated : task)));
    setToast("Task updated");
    return updated;
  };

  const attachJira = async (task, key) => {
    if (!key) return;
    await api(`/tasks/${encodeURIComponent(task.id)}/jira-links`, { method: "POST", body: JSON.stringify({ key }) });
    setToast(`Attached ${key.toUpperCase()}`);
    await refresh();
  };

  const resyncJira = async (task, link) => {
    if (!link?.id) return;
    const result = await api(`/tasks/${encodeURIComponent(task.id)}/jira-links/${encodeURIComponent(link.id)}/resync`, { method: "POST", body: JSON.stringify({}) });
    setToast(`Resynced ${result.jiraLink.key}`);
    await refresh();
  };

  const attachPr = async (task, url) => {
    const match = String(url || "").match(/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
    if (!match) {
      setToast("PR URL required");
      return;
    }
    await api(`/tasks/${encodeURIComponent(task.id)}/pr-links`, {
      method: "POST",
      body: JSON.stringify({ owner: match[1], repo: match[2], number: Number(match[3]), url, title: `PR #${match[3]}` })
    });
    setToast(`Attached PR #${match[3]}`);
    await refresh();
  };

  const openTaskView = (kind, task, extra = {}) => {
    setSelectedView({ kind, taskId: task.id, ...extra });
  };

  const decideApproval = async (approval, status) => {
    if (!approval?.id) return;
    await api(`/approvals/${encodeURIComponent(approval.id)}/decision`, { method: "POST", body: JSON.stringify({ status }) });
    setToast(status === "approved" ? "Approval recorded" : "Approval denied");
    await refresh();
  };

  const killSession = async (workspaceId) => {
    if (!workspaceId) return;
    if (!window.confirm(`Stop cmux session ${workspaceId}? The running process will be terminated.`)) return;
    try {
      await api(`/cmux/sessions/${encodeURIComponent(workspaceId)}/kill`, { method: "POST", body: JSON.stringify({}) });
      setToast(`Stopped ${workspaceId}`);
      await refresh();
    } catch (err) {
      setToast(err.message);
    }
  };

  const restartSession = async (workspaceId) => {
    if (!workspaceId) return;
    if (!window.confirm(`Restart cmux session ${workspaceId}? The current process will be replaced with a fresh session.`)) return;
    try {
      const result = await api(`/cmux/sessions/${encodeURIComponent(workspaceId)}/restart`, { method: "POST", body: JSON.stringify({}) });
      setToast(`Restarted as ${result.session?.workspaceId || "new session"}`);
      await refresh();
      return result;
    } catch (err) {
      setToast(err.message);
    }
    return null;
  };

  const startPrReview = async (pr) => {
    if (!pr?.number) return;
    try {
      const repoName = pr.owner && pr.repo ? `${pr.owner}/${pr.repo}` : undefined;
      const result = await api("/pr-reviews/start", {
        method: "POST",
        body: JSON.stringify({ number: pr.number, repo: repoName, pullRequest: pr })
      });
      setToast(`Review session started for PR #${pr.number}`);
      await refresh();
      if (result.task) setSelectedView({ kind: "session", taskId: result.task.id });
    } catch (err) {
      setToast(err.message);
    }
  };

  const runWatcherNow = async () => {
    const result = await api("/watcher/run", { method: "POST", body: JSON.stringify({}) });
    await refresh();
    return result;
  };

  const addTaskSession = async (task) => {
    try {
      const created = await api("/cmux/sessions", {
        method: "POST",
        body: JSON.stringify({ title: task.title, workspaceDir: task.workspaceDir })
      });
      await api(`/tasks/${encodeURIComponent(task.id)}/cmux-sessions`, {
        method: "POST",
        body: JSON.stringify({ session: created.session })
      });
      setToast("New session attached");
      await refresh();
    } catch (err) {
      setToast(err.message);
    }
  };

  const handleAgentEvent = (event) => {
    if (event.type === "TEXT_MESSAGE_START") {
      setChatMessages((current) => [...current, { id: event.messageId, role: "assistant", content: "", streaming: true }]);
      return;
    }
    if (event.type === "TEXT_MESSAGE_CONTENT") {
      setChatMessages((current) => current.map((message) => (
        message.id === event.messageId ? { ...message, content: `${message.content || ""}${event.delta || ""}` } : message
      )));
      return;
    }
    if (event.type === "TEXT_MESSAGE_END") {
      setChatMessages((current) => current.map((message) => (
        message.id === event.messageId ? { ...message, streaming: false } : message
      )));
      return;
    }
    if (event.type === "TOOL_CALL_START") {
      setActivity((current) => [{
        id: event.toolCallId,
        runId: event.runId,
        kind: "tool_call",
        title: event.toolCallName,
        summary: "running",
        createdAt: event.timestamp
      }, ...current]);
      return;
    }
    if (event.type === "TOOL_CALL_RESULT") {
      setActivity((current) => current.map((item) => (
        item.id === event.toolCallId ? { ...item, summary: event.result?.status || "completed" } : item
      )));
      return;
    }
    if (event.name === "ORCHESTRATOR_PANEL" && event.value?.component) {
      setGeneratedPanels((current) => [{ id: event.id, runId: event.runId, ...event.value }, ...current].slice(0, 8));
    }
  };

  const sendAgentMessage = async (message, mode = voiceMode) => {
    const text = message.trim();
    if (!text) return;
    setAgentStreaming(true);
    setError("");
    setChatMessages((current) => [...current, { role: "user", content: text }]);
    let assistantText = "";
    try {
      await streamAgent("/ai/chat", {
        message: text,
        mode,
        context: {
          selectedTaskId: selectedTask?.id,
          visiblePanel: selectedView.kind,
          voiceMode
        }
      }, (event) => {
        if (event.type === "TEXT_MESSAGE_CONTENT") assistantText += event.delta || "";
        handleAgentEvent(event);
      });
      await refresh();
      return assistantText;
    } catch (err) {
      setError(err.message);
      setChatMessages((current) => [...current, { role: "assistant", content: err.message }]);
      return "";
    } finally {
      setAgentStreaming(false);
    }
  };

  const runRealtimeToolCall = async (call, channel) => {
    if (!call?.name) return;
    try {
      const result = await api("/realtime/tool", {
        method: "POST",
        body: JSON.stringify({
          runId: `realtime_${Date.now().toString(36)}`,
          toolName: call.name,
          args: call.arguments || {}
        })
      });
      channel?.send(JSON.stringify({
        type: "conversation.item.create",
        item: {
          type: "function_call_output",
          call_id: call.callId,
          output: JSON.stringify(result.result || result)
        }
      }));
      channel?.send(JSON.stringify({ type: "response.create" }));
      await refresh();
    } catch (err) {
      setVoiceState((current) => ({ ...current, status: "error", message: err.message }));
    }
  };

  const handleRealtimeEvent = async (event, channel) => {
    if (event?.type === "conversation.item.input_audio_transcription.completed" && event.transcript) {
      setChatMessages((current) => [...current, { role: "user", content: event.transcript }]);
      await api("/agent/transcript", {
        method: "POST",
        body: JSON.stringify({ role: "user", content: event.transcript, metadata: { mode: "realtime_voice" } })
      }).catch(() => {});
    }
    if ((event?.type === "response.audio_transcript.done" || event?.type === "response.output_text.done") && (event.transcript || event.text)) {
      const content = event.transcript || event.text;
      setChatMessages((current) => [...current, { role: "assistant", content }]);
      await api("/agent/transcript", {
        method: "POST",
        body: JSON.stringify({ role: "assistant", content, metadata: { mode: "realtime_voice" } })
      }).catch(() => {});
    }
    const call = realtimeToolCallFromEvent(event);
    if (call) await runRealtimeToolCall(call, channel);
  };

  const startRealtimeSession = async () => {
    setVoiceState({ status: "connecting", message: "Connecting GPT Realtime 2", localTranscript: "" });
    const session = await api("/realtime/session", { method: "POST", body: JSON.stringify({}) });
    const token = realtimeClientSecretValue(session);
    if (!token) throw new Error("Realtime client secret missing from backend response");
    const pc = new RTCPeerConnection();
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    localStreamRef.current = stream;
    const remoteAudio = audioRef.current || new Audio();
    remoteAudio.autoplay = true;
    audioRef.current = remoteAudio;
    pc.ontrack = (event) => {
      remoteAudio.srcObject = event.streams[0];
    };
    stream.getTracks().forEach((track) => {
      track.enabled = true;
      pc.addTrack(track, stream);
    });
    const channel = pc.createDataChannel("oai-events");
    channel.onopen = () => setVoiceState({
      status: "connected",
      message: `Realtime 2 connected with ${session.voice || "marin"} voice`,
      localTranscript: "",
      pushToTalk: voiceSettings.pushToTalk
    });
    channel.onmessage = (message) => {
      try {
        handleRealtimeEvent(JSON.parse(message.data), channel);
      } catch {
        setVoiceState((current) => ({ ...current, message: "Realtime event could not be parsed" }));
      }
    };
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    const sdpResponse = await fetch("https://api.openai.com/v1/realtime/calls", {
      method: "POST",
      body: offer.sdp,
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/sdp"
      }
    });
    if (!sdpResponse.ok) throw new Error(`Realtime WebRTC connection failed: HTTP ${sdpResponse.status}`);
    await pc.setRemoteDescription({ type: "answer", sdp: await sdpResponse.text() });
    realtimeRef.current = { pc, channel, stream };
  };

  const startLocalRecording = async () => {
    if (localRecorderRef.current?.state === "recording") {
      localRecorderRef.current.stop();
      return;
    }
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    localStreamRef.current = stream;
    const recorder = new MediaRecorder(stream);
    localChunksRef.current = [];
    recorder.ondataavailable = (event) => {
      if (event.data?.size) localChunksRef.current.push(event.data);
    };
    recorder.onstop = async () => {
      try {
        setVoiceState({ status: "transcribing", message: "Transcribing local audio", localTranscript: "" });
        const blob = new Blob(localChunksRef.current, { type: recorder.mimeType || "audio/webm" });
        const audioBase64 = await blobToBase64(blob);
        const transcript = await api("/voice/local/transcribe", {
          method: "POST",
          body: JSON.stringify({ audioBase64, filename: "voice.webm", mimeType: blob.type })
        });
        setVoiceState({ status: "thinking", message: "Running local voice request through Fireworks", localTranscript: transcript.text || "" });
        const assistantText = await sendAgentMessage(transcript.text || "", "local");
        if (assistantText) {
          setVoiceState((current) => ({ ...current, status: "speaking", message: "Generating local speech output" }));
          const spoken = await api("/voice/local/speak", {
            method: "POST",
            body: JSON.stringify({ text: assistantText, provider: voiceSettings.ttsProvider })
          });
          const player = new Audio(`data:${spoken.mimeType};base64,${spoken.audioBase64}`);
          audioRef.current = player;
          await player.play().catch(() => {});
        }
        setVoiceState((current) => ({ ...current, status: "ready", message: "Local voice turn complete" }));
      } catch (err) {
        setVoiceState({ status: "error", message: err.message, localTranscript: "" });
      } finally {
        stopStream(stream);
        localRecorderRef.current = null;
      }
    };
    localRecorderRef.current = recorder;
    recorder.start();
    setVoiceState({ status: "recording", message: "Recording local voice", localTranscript: "" });
  };

  const startVoiceSession = async () => {
    if (voiceMode === "realtime") {
      try {
        await startRealtimeSession();
      } catch (err) {
        realtimeRef.current?.channel?.close?.();
        realtimeRef.current?.pc?.close?.();
        stopStream(realtimeRef.current?.stream);
        stopStream(localStreamRef.current);
        realtimeRef.current = null;
        localStreamRef.current = null;
        setVoiceState({ status: "error", message: err.message, localTranscript: "" });
      }
      return;
    }
    if (voiceMode === "local") {
      try {
        await startLocalRecording();
      } catch (err) {
        setVoiceState({ status: "error", message: err.message, localTranscript: "" });
      }
    }
  };

  const stopVoiceSession = () => {
    if (localRecorderRef.current?.state === "recording") {
      localRecorderRef.current.stop();
      return;
    }
    realtimeRef.current?.channel?.close?.();
    realtimeRef.current?.pc?.close?.();
    stopStream(realtimeRef.current?.stream);
    stopStream(localStreamRef.current);
    realtimeRef.current = null;
    localStreamRef.current = null;
    setVoiceState((current) => ({ ...current, status: "idle", message: "Voice session stopped" }));
  };

  const selectedTask = useMemo(
    () => tasks.concat(history).find((task) => task.id === selectedView.taskId),
    [tasks, history, selectedView.taskId]
  );
  const approvalJiraKeys = useMemo(() => {
    const pendingApprovals = approvals.filter((approval) => approval.status === "pending");
    const pendingTaskIds = new Set(pendingApprovals.map((approval) => approval.taskId || approval.task_id).filter(Boolean));
    const hasUnassignedPending = pendingApprovals.some((approval) => !(approval.taskId || approval.task_id));
    return new Set(tasks.flatMap((task) => {
      const hasTaskApproval = pendingTaskIds.has(task.id) || (hasUnassignedPending && task === tasks[0]) || (task.pendingApprovals || []).some((approval) => approval.status === "pending");
      return hasTaskApproval ? (task.jiraLinks || []).map((jira) => jira.key) : [];
    }));
  }, [tasks, approvals]);

  const startDockResize = (event) => {
    event.preventDefault();
    const startX = event.clientX;
    const startWidth = dockWidth;
    const onMove = (moveEvent) => {
      setDockWidth(clamp(startWidth + startX - moveEvent.clientX, 300, 640));
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  };

  return (
    <CopilotKit runtimeUrl={`${API_ROOT}/copilotkit`} showDevConsole={false} enableInspector={false} useSingleEndpoint={false}>
      <CopilotBridge
        tasks={tasks}
        selectedTask={selectedTask}
        approvals={approvals}
        activity={activity}
        voiceMode={voiceMode}
        openTaskView={openTaskView}
        refresh={refresh}
        setGeneratedPanels={setGeneratedPanels}
        setVoiceMode={setVoiceMode}
        startVoiceSession={startVoiceSession}
        stopVoiceSession={stopVoiceSession}
      />
      <div className={`app-shell ${railCollapsed ? "rail-mini" : ""}`} style={{ "--dock-width": `${dockWidth}px` }}>
        <LeftRail
          collapsed={railCollapsed}
          leftRail={leftRail}
          approvalJiraKeys={approvalJiraKeys}
          selectedTask={selectedTask}
          selectedView={selectedView}
          onNavigate={(kind) => setSelectedView({ kind })}
          onStartPrReview={startPrReview}
          onToggle={() => setRailCollapsed((value) => !value)}
          onNewTask={() => setModalState({ mode: "new" })}
        />
        <main className="main-stage">
          <TopBar
            onChat={(message) => {
              setSelectedView({ kind: "board" });
              return sendAgentMessage(message);
            }}
            streaming={agentStreaming}
            voiceMode={voiceMode}
            setVoiceMode={setVoiceMode}
            voiceState={voiceState}
            voiceSettings={voiceSettings}
            setVoiceSettings={setVoiceSettings}
            proactiveUpdates={proactiveUpdates}
            setProactiveUpdates={(enabled) => {
              setProactiveUpdates(enabled);
              setToast(enabled ? "Proactive updates on" : "Proactive updates off");
              if (enabled) refresh().catch(() => {});
            }}
            onStartVoice={startVoiceSession}
            onStopVoice={stopVoiceSession}
            onOpenVisualMode={enterVoiceMode}
            liveStatus={liveStatus}
          />
          {error && (
            <div className="error-strip">
              <span>{error}</span>
              <button className="subtle-btn" onClick={() => refresh().catch((err) => setError(err.message))}>
                <RefreshCw size={13} />Retry
              </button>
            </div>
          )}
          {loading ? (
            <LoadingState />
          ) : selectedView.kind === "session" && selectedTask ? (
            <SessionView
              task={selectedTask}
              activity={activity}
              onBack={() => setSelectedView({ kind: "board" })}
              onOpenDiff={() => openTaskView("diff", selectedTask)}
              onKillSession={killSession}
              onRestartSession={restartSession}
              onNewSession={() => addTaskSession(selectedTask)}
              onAskAgent={(message) => sendAgentMessage(message)}
            />
          ) : selectedView.kind === "diff" && selectedTask ? (
            <DiffView task={selectedTask} initialMode={selectedView.mode} onBack={() => setSelectedView({ kind: "board" })} />
          ) : selectedView.kind === "goal" && selectedTask ? (
            <GoalView task={selectedTask} onBack={() => setSelectedView({ kind: "board" })} onSaved={refresh} />
          ) : selectedView.kind === "activity" ? (
            <ActivityView
              activity={activity}
              onBack={() => setSelectedView({ kind: "board" })}
              onRunWatcher={runWatcherNow}
            />
          ) : selectedView.kind === "history" ? (
            <HistoryView
              history={history}
              onBack={() => setSelectedView({ kind: "board" })}
              onReopen={(task) => updateTask(task.id, { status: "To Do" })}
              onOpenView={openTaskView}
            />
          ) : (
            <TaskBoard
              tasks={tasks}
              history={history}
              approvals={approvals}
              orphans={orphans}
              onNewTask={() => setModalState({ mode: "new" })}
              onOrphanTask={(orphan) => setModalState({ mode: "orphan", orphan })}
              onOpenView={openTaskView}
              onOpenHistory={() => setSelectedView({ kind: "history" })}
              onUpdateTask={updateTask}
              onAttachJira={attachJira}
              onResyncJira={resyncJira}
              onAttachPr={attachPr}
              onApprovalDecision={decideApproval}
              onRefreshOrphans={() => refresh().catch(() => {})}
            />
          )}
          <GeneratedPanelStack
            panels={generatedPanels}
            tasks={tasks}
            approvals={approvals}
            voiceMode={voiceMode}
            voiceState={voiceState}
            voiceSettings={voiceSettings}
            onDismiss={(id) => setGeneratedPanels((current) => current.filter((panel) => panel.id !== id))}
            onOpenView={openTaskView}
            onApprovalDecision={decideApproval}
          />
        </main>
        <RightDock
          messages={chatMessages}
          activity={activity}
          generatedPanels={generatedPanels}
          streaming={agentStreaming}
          onSend={sendAgentMessage}
          onResizeStart={startDockResize}
        />
        {modalState && (
          <NewTaskModal
            mode={modalState.mode}
            orphan={modalState.orphan}
            onClose={() => setModalState(null)}
            onSubmit={createTask}
          />
        )}
        {selectedView.kind === "voice" && (
          <VoiceVisualMode
            capabilities={agentCapabilities}
            onExit={exitVoiceMode}
            onTurnComplete={() => refresh().catch(() => {})}
          />
        )}
        {toast && <Toast message={toast} onDone={() => setToast("")} />}
      </div>
    </CopilotKit>
  );
}

function CopilotBridge({ tasks, selectedTask, approvals, activity, voiceMode, openTaskView, refresh, setGeneratedPanels, setVoiceMode, startVoiceSession, stopVoiceSession }) {
  useCopilotReadable({
    description: "Current Orchestrator V2 task, approval, panel, voice, cmux, git, and activity state",
    value: {
      tasks,
      selectedTask,
      approvals,
      recentActivity: activity.slice(0, 20),
      visiblePanel: selectedTask ? "task-detail" : "board",
      voiceMode
    }
  });
  useCopilotAction({
    name: "openTask",
    description: "Open a task by id.",
    parameters: [{ name: "taskId", type: "string", required: true }],
    handler: ({ taskId }) => {
      const task = tasks.find((item) => item.id === taskId);
      if (task) openTaskView("session", task);
    }
  });
  useCopilotAction({
    name: "openTaskGoal",
    description: "Open the goal document for a task by id.",
    parameters: [{ name: "taskId", type: "string", required: true }],
    handler: ({ taskId }) => {
      const task = tasks.find((item) => item.id === taskId);
      if (task) openTaskView("goal", task);
    }
  });
  useCopilotAction({
    name: "openTaskSession",
    description: "Open the cmux session view for a task by id.",
    parameters: [{ name: "taskId", type: "string", required: true }],
    handler: ({ taskId }) => {
      const task = tasks.find((item) => item.id === taskId);
      if (task) openTaskView("session", task);
    }
  });
  useCopilotAction({
    name: "openTaskDiff",
    description: "Open the git diff view for a task by id.",
    parameters: [{ name: "taskId", type: "string", required: true }],
    handler: ({ taskId }) => {
      const task = tasks.find((item) => item.id === taskId);
      if (task) openTaskView("diff", task);
    }
  });
  useCopilotAction({
    name: "focusApproval",
    description: "Show an approval panel by id.",
    parameters: [{ name: "approvalId", type: "string", required: true }],
    handler: ({ approvalId }) => {
      const approval = approvals.find((item) => item.id === approvalId);
      if (approval) setGeneratedPanels((current) => [{ id: `approval-${approval.id}`, component: "JiraCommentApprovalPanel", props: approval }, ...current]);
    }
  });
  useCopilotAction({
    name: "showGeneratedPanel",
    description: "Show a controlled Orchestrator V2 generated panel.",
    parameters: [
      { name: "component", type: "string", required: true },
      { name: "props", type: "object", required: false }
    ],
    handler: ({ component, props }) => {
      setGeneratedPanels((current) => [{ id: `panel-${Date.now()}`, component, props: props || {} }, ...current]);
    }
  });
  useCopilotAction({
    name: "replaceGeneratedPanel",
    description: "Replace generated panels with one controlled panel.",
    parameters: [
      { name: "component", type: "string", required: true },
      { name: "props", type: "object", required: false }
    ],
    handler: ({ component, props }) => setGeneratedPanels([{ id: `panel-${Date.now()}`, component, props: props || {} }])
  });
  useCopilotAction({
    name: "dismissGeneratedPanel",
    description: "Dismiss a generated panel by id.",
    parameters: [{ name: "panelId", type: "string", required: true }],
    handler: ({ panelId }) => setGeneratedPanels((current) => current.filter((panel) => panel.id !== panelId))
  });
  useCopilotAction({
    name: "setBoardFilter",
    description: "Set the current board filter. The current UI accepts the request and refreshes data.",
    parameters: [{ name: "filter", type: "string", required: true }],
    handler: () => refresh()
  });
  useCopilotAction({
    name: "refreshOrchestratorData",
    description: "Refresh Orchestrator V2 data.",
    parameters: [],
    handler: refresh
  });
  useCopilotAction({
    name: "switchVoiceMode",
    description: "Switch voice mode.",
    parameters: [{ name: "mode", type: "string", required: true }],
    handler: ({ mode }) => setVoiceMode(["text", "realtime", "local"].includes(mode) ? mode : "text")
  });
  useCopilotAction({ name: "startVoiceSession", description: "Start the current voice session.", parameters: [], handler: startVoiceSession });
  useCopilotAction({ name: "stopVoiceSession", description: "Stop the current voice session.", parameters: [], handler: stopVoiceSession });
  return null;
}

function LeftRail({ collapsed, leftRail, approvalJiraKeys, selectedTask, selectedView, onNavigate, onStartPrReview, onToggle, onNewTask }) {
  const [openSections, setOpenSections] = useState({
    jira: true,
    open: true,
    draft: true,
    review: true
  });
  const sections = [
    { id: "jira", title: "Jira Tickets", icon: Diamond, items: itemsOf(leftRail.assignedJira), error: errorOf(leftRail.assignedJira), type: "jira" },
    { id: "open", title: "Open PRs (GitHub)", icon: Github, items: itemsOf(leftRail.openPrs), error: errorOf(leftRail.openPrs), type: "pr" },
    { id: "draft", title: "Draft PRs", icon: GitPullRequest, items: itemsOf(leftRail.draftPrs), error: errorOf(leftRail.draftPrs), type: "pr" },
    { id: "review", title: "Needs Review", icon: ShieldAlert, items: itemsOf(leftRail.reviewRequests), error: errorOf(leftRail.reviewRequests), type: "pr" }
  ].filter((section) => section.id === "jira" || section.id === "open" || section.items.length > 0 || section.error);
  const selectedJiraKeys = new Set((selectedTask?.jiraLinks || []).map((jira) => jira.key));
  return (
    <aside className="left-rail">
      <div className="brand-row">
        <div className="brand-mark" aria-hidden="true">
          <span className="brand-slash" />
          <span className="brand-spark one" />
          <span className="brand-spark two" />
        </div>
        {!collapsed && (
          <div>
            <div className="brand-title">Orchestrate AI</div>
            <div className="brand-subtitle">AI Agents Orchestration</div>
          </div>
        )}
        <button className="icon-btn rail-toggle" onClick={onToggle} aria-label="Toggle rail">
          {collapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
        </button>
      </div>
      {!collapsed && <div className="rail-kicker">Work Intake</div>}
      <div className="rail-sections">
        {sections.map((section) => (
          <div className="rail-section" key={section.id}>
            <div className="rail-section-heading">
              <button className="rail-section-header" onClick={() => setOpenSections((state) => ({ ...state, [section.id]: !state[section.id] }))}>
                <section.icon size={16} />
                {!collapsed && <span>{section.title}</span>}
                {!collapsed && <ChevronDown className={openSections[section.id] ? "chev open" : "chev"} size={14} />}
              </button>
              {!collapsed && <button className="rail-add-btn" onClick={onNewTask} aria-label={`Add from ${section.title}`}><Plus size={15} /></button>}
            </div>
            {!collapsed && openSections[section.id] && (
              <div className="rail-card-list">
                {section.error ? (
                  <div className="rail-empty rail-error" title={section.error}>Unavailable: {section.error}</div>
                ) : section.items.length === 0 ? (
                  <div className="rail-empty">No items</div>
                ) : section.items.slice(0, 6).map((item) => {
                  const hasApproval = approvalJiraKeys?.has(item.key);
                  const displayStatus = displayRailStatus(item, hasApproval);
                  const isDraftPr = section.type === "pr" && item.isDraft;
                  return (
                    <a className={`rail-card rail-${section.type} ${hasApproval ? "needs-approval" : ""} ${selectedJiraKeys.has(item.key) ? "selected" : ""}`} href={item.url || "#"} target="_blank" rel="noreferrer" key={`${section.id}-${item.key || item.number || item.url}`}>
                      <div className="rail-card-top">
                        <strong>{section.type === "jira" ? item.key : `#${item.number}`}</strong>
                        {section.id === "review" && (
                          <button
                            type="button"
                            className="rail-review-btn"
                            title="Launch a PR review session"
                            onClick={(event) => {
                              event.preventDefault();
                              event.stopPropagation();
                              onStartPrReview?.(item);
                            }}
                          >
                            <Play size={11} />Review
                          </button>
                        )}
                      </div>
                      <div className="rail-card-title">{item.title}</div>
                      <div className="rail-meta-row">
                        <span className={`rail-card-state ${section.type === "jira" ? statusClass(displayStatus) : isDraftPr ? "pr-draft" : "pr-open"}`}>{section.type === "jira" ? displayStatus : isDraftPr ? "Draft" : item.branch || item.state || "Open"}</span>
                        {section.type === "jira" && hasApproval ? <span className="approval-rail-pill">Approval required</span> : null}
                        {section.type === "pr" && <span className={isDraftPr ? "gray-dot" : "green-dot"} />}
                      </div>
                    </a>
                  );
                })}
              </div>
            )}
          </div>
        ))}
      </div>
      <nav className="rail-nav" aria-label="Orchestrator views">
        <button className={`rail-nav-btn ${selectedView?.kind === "board" ? "active" : ""}`} onClick={() => onNavigate?.("board")}>
          <LayoutDashboard size={17} />
          {!collapsed && <span>Board</span>}
        </button>
        <button className={`rail-nav-btn ${selectedView?.kind === "activity" ? "active" : ""}`} onClick={() => onNavigate?.("activity")}>
          <Sparkles size={17} />
          {!collapsed && <span>Activity</span>}
        </button>
        <button className={`rail-nav-btn ${selectedView?.kind === "history" ? "active" : ""}`} onClick={() => onNavigate?.("history")}>
          <Archive size={17} />
          {!collapsed && <span>History</span>}
        </button>
      </nav>
    </aside>
  );
}

function errorOf(section) {
  if (Array.isArray(section)) return "";
  return section && section.ok === false ? String(section.error || "provider unavailable") : "";
}

function TopBar({ onChat, streaming, voiceMode, setVoiceMode, voiceState, voiceSettings, setVoiceSettings, proactiveUpdates, setProactiveUpdates, onStartVoice, onStopVoice, onOpenVisualMode, liveStatus }) {
  const [value, setValue] = useState("");
  const voiceActionStops = ["connected", "ready", "recording"].includes(voiceState.status);
  const voiceProcessing = ["connecting", "transcribing", "thinking", "speaking"].includes(voiceState.status);
  const voiceLabel = voiceStateLabel(voiceMode, voiceState.status);
  const send = () => {
    const message = value.trim();
    if (!message) return;
    setValue("");
    onChat(message).catch(() => {});
  };
  return (
    <header className="top-bar">
      <div className="command-input">
        <input
          value={value}
          onChange={(event) => setValue(event.target.value)}
          onKeyDown={(event) => event.key === "Enter" && send()}
          placeholder="Ask anything or say a command..."
        />
        <button className="icon-btn" onClick={send} aria-label="Send command" disabled={streaming}>{streaming ? <RefreshCw size={17} className="spin" /> : <Send size={17} />}</button>
      </div>
      <div className="voice-controls">
        <button className="visual-mode-btn" onClick={onOpenVisualMode} title="Open the full-screen voice visual mode">
          <Orbit size={16} />
          <span>Visual Mode</span>
        </button>
        <div className="segmented voice-mode-picker" role="tablist" aria-label="Voice mode">
          {["text", "realtime", "local"].map((mode) => (
            <button key={mode} className={voiceMode === mode ? "active" : ""} onClick={() => setVoiceMode(mode)}>{mode === "realtime" ? "Realtime 2" : mode === "local" ? "Local" : "Text"}</button>
          ))}
        </div>
        <label className="voice-toggle">
          <input
            type="checkbox"
            checked={voiceSettings.pushToTalk}
            onChange={(event) => setVoiceSettings((current) => ({ ...current, pushToTalk: event.target.checked }))}
          />
          <span>Push to talk</span>
        </label>
        <label className="proactive-toggle" title="When off, the dashboard stops its automatic background refresh loop. Manual actions still refresh the data they change.">
          <span>Proactive updates</span>
          <input
            type="checkbox"
            checked={proactiveUpdates}
            onChange={(event) => setProactiveUpdates(event.target.checked)}
            aria-label="Toggle proactive updates"
          />
        </label>
        {voiceMode === "local" && (
          <select
            aria-label="Local TTS provider"
            value={voiceSettings.ttsProvider}
            onChange={(event) => setVoiceSettings((current) => ({ ...current, ttsProvider: event.target.value }))}
          >
            <option value="piper">Piper</option>
            <option value="elevenlabs">ElevenLabs Jessica</option>
          </select>
        )}
        <div className={`voice-status ${voiceState.status}`}>
          <span className={`voice-state-dot ${voiceState.status}`} />
          <span>{voiceLabel}</span>
        </div>
        <button
          className={`mic-btn ${voiceMode} ${voiceState.status}`}
          aria-label={voiceActionStops ? "Stop voice input" : "Start voice input"}
          aria-pressed={["connected", "ready", "recording"].includes(voiceState.status)}
          disabled={voiceProcessing && voiceMode === "local"}
          onClick={voiceActionStops ? onStopVoice : onStartVoice}
        >
          {voiceProcessing ? <RefreshCw size={20} className="spin" /> : <Mic size={20} />}
        </button>
      </div>
      <div
        className={`live-indicator ${liveStatus || "polling"}`}
        title={liveStatus === "live"
          ? "Live updates connected: changes stream in as they happen."
          : liveStatus === "connecting"
            ? "Connecting to the live update stream..."
            : "Live stream unavailable: falling back to periodic polling."}
      >
        <span className="live-dot" />
        <span>{liveStatus === "live" ? "Live" : liveStatus === "connecting" ? "Connecting" : "Polling"}</span>
      </div>
      <button className="icon-btn" aria-label="Notifications"><Bell size={18} /></button>
    </header>
  );
}

function TaskBoard({ tasks, history = [], approvals, orphans, onNewTask, onOrphanTask, onOpenView, onOpenHistory, onUpdateTask, onAttachJira, onResyncJira, onAttachPr, onApprovalDecision, onRefreshOrphans }) {
  const [layout, setLayout] = useState(() => {
    if (typeof window === "undefined") return "grid";
    return window.localStorage.getItem("orchestrator-v2-board-layout") === "list" ? "list" : "grid";
  });
  useEffect(() => {
    window.localStorage?.setItem("orchestrator-v2-board-layout", layout);
  }, [layout]);
  const activeApprovals = approvals.filter((approval) => approval.status === "pending");
  const unassignedApprovals = activeApprovals.filter((approval) => !(approval.taskId || approval.task_id));
  const approvalForTask = (task, index) => {
    const taskApproval = (task.pendingApprovals || []).find((approval) => approval.status === "pending");
    if (taskApproval) return taskApproval;
    const matchingApproval = activeApprovals.find((approval) => (approval.taskId || approval.task_id) === task.id);
    if (matchingApproval) return matchingApproval;
    return index === 0 ? unassignedApprovals[0] : null;
  };
  return (
    <section className={`board-view ${activeApprovals.length ? "has-approval" : ""}`}>
      <div className="board-header">
        <div>
          <h1>Tasks / Objectives <span>{tasks.length}</span></h1>
        </div>
        <div className="board-controls">
          <button className={`icon-btn ${layout === "grid" ? "active" : ""}`} aria-label="Grid view" onClick={() => setLayout("grid")}><Grid2X2 size={17} /></button>
          <button className={`icon-btn ${layout === "list" ? "active" : ""}`} aria-label="List view" onClick={() => setLayout("list")}><List size={17} /></button>
        </div>
      </div>
      {tasks.length === 0 ? (
        <div className="empty-board">
          <Diamond size={28} />
          <h2>No active tasks</h2>
          <p>Start a task, adopt an orphaned cmux session below, or ask the agent to plan one for you.</p>
          <button className="primary-btn" onClick={onNewTask}><Plus size={17} />Start Task</button>
        </div>
      ) : layout === "list" ? (
        <TaskListView tasks={tasks} approvalForTask={approvalForTask} onOpenView={onOpenView} onUpdateTask={onUpdateTask} />
      ) : (
        <div className={`task-grid ${activeApprovals.length ? "has-approval" : ""}`}>
          {tasks.map((task, index) => (
            <TaskCard
              key={task.id}
              task={task}
              approval={approvalForTask(task, index)}
              onOpenView={onOpenView}
              onUpdateTask={onUpdateTask}
              onAttachJira={onAttachJira}
              onResyncJira={onResyncJira}
              onAttachPr={onAttachPr}
              onApprovalDecision={onApprovalDecision}
            />
          ))}
        </div>
      )}
      <OrphanPanel orphans={orphans} onOrphanTask={onOrphanTask} onRefresh={onRefreshOrphans} />
      <HistoryStrip tasks={history.filter((task) => ["Done", "Archived"].includes(task.status))} onOpenHistory={onOpenHistory} />
    </section>
  );
}

function TaskListView({ tasks, approvalForTask, onOpenView, onUpdateTask }) {
  return (
    <div className="task-list-view">
      <div className="task-list-row head">
        <span>Task</span>
        <span>Status</span>
        <span>Jira</span>
        <span>PR</span>
        <span>Sessions</span>
        <span>Actions</span>
      </div>
      {tasks.map((task, index) => {
        const approval = approvalForTask(task, index);
        const primaryPr = task.pullRequestLinks?.find((link) => link.isPrimary) || task.pullRequestLinks?.[0];
        return (
          <div className={`task-list-row ${approval ? "needs-approval" : ""}`} key={task.id}>
            <span className="task-list-title">
              <strong>{task.title}</strong>
              {approval && <span className="approval-rail-pill">Approval required</span>}
            </span>
            <select
              value={displayTaskStatus(task, approval)}
              onChange={(event) => onUpdateTask(task.id, { status: event.target.value })}
              className={`status-pill ${statusClass(displayTaskStatus(task, approval))}`}
            >
              {STATUSES.map((status) => <option key={status}>{status}</option>)}
            </select>
            <span>{task.jiraLinks?.[0] ? <a className="resource-chip jira" href={task.jiraLinks[0].url || "#"} target="_blank" rel="noreferrer">{task.jiraLinks[0].key}</a> : <small>-</small>}</span>
            <span>{primaryPr ? <a className="resource-chip pr" href={primaryPr.url || "#"} target="_blank" rel="noreferrer">#{primaryPr.number}</a> : <small>-</small>}</span>
            <span><Terminal size={13} /> {task.cmuxSessionLinks?.length || 0}</span>
            <span className="task-list-actions">
              <button className="subtle-btn" onClick={() => onOpenView("session", task)}><Terminal size={13} />Session</button>
              <button className="subtle-btn" onClick={() => onOpenView("diff", task)}><FileCode2 size={13} />Diff</button>
              <button className="subtle-btn" onClick={() => onOpenView("goal", task)}><Edit3 size={13} />Goal</button>
            </span>
          </div>
        );
      })}
    </div>
  );
}

function HistoryStrip({ tasks, onOpenHistory }) {
  if (!tasks.length) return null;
  return (
    <section className="history-strip">
      <div className="panel-heading">
        <h2>Done / Archived</h2>
        <span>{tasks.length}</span>
        <button className="subtle-btn" onClick={onOpenHistory}>View all<ChevronRight size={13} /></button>
      </div>
      <div className="history-list">
        {tasks.slice(0, 8).map((task) => (
          <div className="history-row" key={task.id}>
            <Check size={14} />
            <strong>{task.title}</strong>
            <span className={`status-pill ${statusClass(task.status)}`}>{task.status}</span>
            <small>{relativeAge(task.updatedAt)}</small>
          </div>
        ))}
      </div>
    </section>
  );
}

function TaskCard({ task, approval, onOpenView, onUpdateTask, onAttachJira, onResyncJira, onAttachPr, onApprovalDecision }) {
  const [jiraDraft, setJiraDraft] = useState("");
  const [prDraft, setPrDraft] = useState("");
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState(task.title || "");
  const [savingTitle, setSavingTitle] = useState(false);
  const primaryPr = task.pullRequestLinks?.find((link) => link.isPrimary) || task.pullRequestLinks?.[0];
  const primaryJira = task.jiraLinks?.[0];
  const displayStatus = displayTaskStatus(task, approval);
  useEffect(() => {
    if (!editingTitle) setTitleDraft(task.title || "");
  }, [editingTitle, task.title]);
  const saveTitle = async (event) => {
    event.preventDefault();
    const nextTitle = titleDraft.trim();
    if (!nextTitle || nextTitle === task.title) {
      setTitleDraft(task.title || "");
      setEditingTitle(false);
      return;
    }
    setSavingTitle(true);
    try {
      await onUpdateTask(task.id, { title: nextTitle });
      setEditingTitle(false);
    } finally {
      setSavingTitle(false);
    }
  };
  return (
    <article className="task-card">
      <div className="task-card-head">
        {editingTitle ? (
          <form className="task-title-edit" onSubmit={saveTitle}>
            <input
              value={titleDraft}
              onChange={(event) => setTitleDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Escape") {
                  setTitleDraft(task.title || "");
                  setEditingTitle(false);
                }
              }}
              aria-label="Task name"
              autoFocus
            />
            <button type="submit" className="menu-btn" aria-label="Save task name" disabled={savingTitle || !titleDraft.trim()}>
              {savingTitle ? <RefreshCw size={15} className="spin" /> : <Check size={15} />}
            </button>
            <button type="button" className="menu-btn" aria-label="Cancel rename" onClick={() => { setTitleDraft(task.title || ""); setEditingTitle(false); }}>
              <X size={15} />
            </button>
          </form>
        ) : (
          <>
            <h2>{task.title}</h2>
            <button className="menu-btn" type="button" aria-label="Rename task" title="Rename task" onClick={() => setEditingTitle(true)}><Edit3 size={15} /></button>
          </>
        )}
      </div>
      <div className="link-row">
        <div className="row-label">Jira</div>
        <div className="link-chip-set">
          {primaryJira ? (
            <a className="resource-chip jira" href={primaryJira.url || "#"} target="_blank" rel="noreferrer"><Diamond size={12} />{primaryJira.key}</a>
          ) : <span className="empty-value" />}
        </div>
        <InlineAttach value={jiraDraft} onChange={setJiraDraft} placeholder="APP-123" onSubmit={() => onAttachJira(task, jiraDraft).then(() => setJiraDraft(""))} label="Attach Jira" />
      </div>
      <div className="link-row">
        <div className="row-label">PRs</div>
        <div className="link-chip-set">
          {primaryPr ? (
            <a className="resource-chip pr" href={primaryPr.url || "#"} target="_blank" rel="noreferrer"><Github size={12} />#{primaryPr.number}</a>
          ) : <span className="empty-value" />}
        </div>
        <InlineAttach value={prDraft} onChange={setPrDraft} placeholder="GitHub PR URL" onSubmit={() => onAttachPr(task, prDraft).then(() => setPrDraft(""))} label="Attach PR" />
      </div>
      <div className="status-row">
        <div className="row-label">Status</div>
        <select value={displayStatus} onChange={(event) => onUpdateTask(task.id, { status: event.target.value })} className={`status-pill ${statusClass(displayStatus)}`}>
          {STATUSES.map((status) => <option key={status}>{status}</option>)}
        </select>
        <button className="subtle-btn" onClick={() => onOpenView("diff", task)}><Terminal size={15} />Git Diff</button>
      </div>
      <CopyRow label="Workspace Dir" value={task.workspaceDir} />
      <CopyRow label="Feature Branch" value={task.featureBranch || "main"} />
      <div className="session-line">
        <div className="row-label">CMUX Sessions</div>
        <button className="session-row" onClick={() => onOpenView("session", task)}>
          <Terminal size={16} />
          <span>{task.cmuxSessionLinks?.length || 0} active</span>
          <ChevronDown size={16} />
        </button>
      </div>
      {approval && <ApprovalCard approval={approval} onReview={() => onOpenView("diff", task)} onDecision={onApprovalDecision} />}
      <div className="tag-row">
        <div className="row-label">Tags</div>
        <div className="tag-set">
          {(task.tags || []).length === 0 ? <span className="tag">local</span> : task.tags.map((tag) => <span className={`tag ${tagClass(tag.tag)}`} key={tag.tag}>{tag.tag}</span>)}
        </div>
      </div>
    </article>
  );
}

function InlineAttach({ value, onChange, placeholder, onSubmit, label }) {
  const [expanded, setExpanded] = useState(false);
  if (!expanded) {
    return (
      <button className="attach-button" type="button" onClick={() => setExpanded(true)}>
        <Plus size={13} />{label}
      </button>
    );
  }
  return (
    <form className="inline-attach" onSubmit={async (event) => { event.preventDefault(); await onSubmit(); setExpanded(false); }}>
      <input value={value} onChange={(event) => onChange(event.target.value)} placeholder={placeholder} />
      <button type="submit" aria-label={label} title={label}><Plus size={13} /></button>
    </form>
  );
}

function CopyRow({ label, value }) {
  return (
    <div className="copy-row">
      <span>{label}</span>
      <code>{value || "-"}</code>
      <button className="icon-btn small" onClick={() => navigator.clipboard?.writeText(value || "")}><Copy size={13} /></button>
    </div>
  );
}

function ApprovalCard({ approval, onReview, onDecision }) {
  const payload = approval.payload || {};
  return (
    <div className="approval-card">
      <div className="approval-title">
        <ShieldAlert size={16} />
        <strong>Approval required</strong>
        <span>{approval.impact || "Medium"} impact</span>
      </div>
      <p>{approval.summary || approval.title}</p>
      <div className="approval-details">
        {payload.workspace && <><span>Affected workspace</span><b>{payload.workspace}</b></>}
        {payload.branch && <><span>Branch</span><b>{payload.branch}</b></>}
        {payload.key && <><span>Target</span><b>{payload.key}</b></>}
        <span>Backend tool</span><b>{payload.toolName || approval.kind}</b>
        <span>Requested action</span><b>{payload.requestedAction || approval.kind}</b>
        <span>Reversible</span><b>{payload.reversible === false ? "No" : "Depends"}</b>
        <span>Reason</span><b>{approval.title}</b>
      </div>
      {payload.body && <pre className="approval-payload-preview">{payload.body}</pre>}
      <div className="approval-actions">
        <button className="subtle-btn" onClick={onReview}><FileCode2 size={14} />Review Diff</button>
        <button className="approve-btn" onClick={() => onDecision(approval, "approved")}><Check size={14} />Approve</button>
        <button className="deny-btn" onClick={() => onDecision(approval, "denied")}><X size={14} />Deny</button>
      </div>
    </div>
  );
}

function OrphanPanel({ orphans, onOrphanTask, onRefresh }) {
  const orphanMeta = (orphan) => orphan.raw?.raw || orphan.raw || {};
  const sortedOrphans = [...orphans].sort((left, right) => Number(orphanMeta(left).displayOrder ?? 999) - Number(orphanMeta(right).displayOrder ?? 999));
  return (
    <section className="orphan-panel">
      <div className="panel-heading">
        <div>
          <h2>Orphaned cmux sessions</h2>
          <p>Live cmux sessions that are not linked to any task yet.</p>
        </div>
        <span>{orphans.length}</span>
        <button className="subtle-btn" onClick={onRefresh}><RefreshCw size={14} />Refresh</button>
      </div>
      <div className="orphan-list">
        {orphans.length === 0 ? (
          <div className="orphan-empty">No unlinked active sessions</div>
        ) : sortedOrphans.map((orphan) => {
          const meta = orphanMeta(orphan);
          return (
          <div className="orphan-row" key={orphan.sessionKey}>
            <span className={`orphan-state-dot ${meta.state || ""}`} />
            <span className="terminal-badge"><Terminal size={15} /></span>
            <div className="orphan-title-cell">
              <strong>{orphan.title || orphan.workspaceId}</strong>
            </div>
            <span className="orphan-started">Started {meta.startedLabel || relativeAge(orphan.firstSeenAt)}</span>
            <code>{displayWorkspacePath(orphan.cwd || orphan.workspaceId)}</code>
            <code>{meta.branch || meta.gitBranch || "unlinked-session"}</code>
            <button className="subtle-btn" onClick={() => onOrphanTask(orphan)}>Turn into Task</button>
            <button className="icon-btn"><MoreHorizontal size={16} /></button>
          </div>
        );})}
      </div>
    </section>
  );
}

function SessionView({ task, activity = [], onBack, onOpenDiff, onKillSession, onRestartSession, onNewSession, onAskAgent }) {
  const sessions = task.cmuxSessionLinks || [];
  const [active, setActive] = useState(sessions[0]?.id || "");
  const [screen, setScreen] = useState("");
  const [screenUpdatedAt, setScreenUpdatedAt] = useState(null);
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [command, setCommand] = useState("");
  const [sending, setSending] = useState(false);
  const activeSession = sessions.find((session) => session.id === active) || sessions[0];
  const refreshScreen = () => {
    if (!activeSession) return Promise.resolve();
    return api(`/cmux/sessions/${encodeURIComponent(activeSession.workspaceId)}/screen?surfaceId=${encodeURIComponent(activeSession.surfaceId || "")}&lines=300`)
      .then((result) => {
        setScreen(result.screen || "");
        setScreenUpdatedAt(new Date());
      })
      .catch((err) => setScreen(err.message));
  };
  useEffect(() => {
    refreshScreen();
  }, [activeSession?.workspaceId, activeSession?.surfaceId]);
  useEffect(() => {
    if (!autoRefresh || !activeSession) return undefined;
    const interval = window.setInterval(() => {
      refreshScreen();
    }, 5000);
    return () => window.clearInterval(interval);
  }, [autoRefresh, activeSession?.workspaceId, activeSession?.surfaceId]);
  const sendInput = async (payload) => {
    if (!activeSession || sending) return;
    setSending(true);
    try {
      await api(`/cmux/sessions/${encodeURIComponent(activeSession.workspaceId)}/input`, {
        method: "POST",
        body: JSON.stringify({ surfaceId: activeSession.surfaceId || "", ...payload })
      });
      await refreshScreen();
      window.setTimeout(refreshScreen, 350);
    } catch (err) {
      setScreen(err.message);
    } finally {
      setSending(false);
    }
  };
  const submitCommand = () => {
    const text = command.trim();
    if (!text) return;
    setCommand("");
    sendInput({ text: `${text}\n` });
  };
  const sendKey = (key) => sendInput({ key });
  const explainOutput = () => {
    const excerpt = screen.split("\n").filter((line) => line.trim()).slice(-30).join("\n");
    onAskAgent?.(`Explain what is happening in the cmux session "${activeSession?.title || activeSession?.workspaceId}" for task "${task.title}". Latest terminal output:\n\n${excerpt || "(no output captured yet)"}`);
  };
  const askAgent = () => {
    onAskAgent?.(`What is the status of task "${task.title}"? Inspect its cmux sessions and summarize what is running, what finished, and anything that needs my attention.`);
  };
  return (
    <section className="center-view session-view">
      <button className="back-btn" onClick={onBack}><ChevronLeft size={17} />Back to Work</button>
      <div className="center-header">
        <div>
          <div className="session-title-row">
            <Sparkles size={14} />
            <h1>{task.title}</h1>
          </div>
          <div className="header-chips">
            {task.jiraLinks?.[0] && <span className="resource-chip">{task.jiraLinks[0].key}</span>}
            <span className={`status-pill ${statusClass(task.status)}`}>{task.status}</span>
          </div>
        </div>
        <div className="header-actions">
          <button className="subtle-btn" onClick={explainOutput} disabled={!activeSession}><Lightbulb size={15} />Explain Output</button>
          <button className="subtle-btn" onClick={() => onRestartSession?.(activeSession?.workspaceId)} disabled={!activeSession} title="Close this cmux session and relaunch it with the same folder and harness"><RefreshCw size={15} />Restart Session</button>
          <button className="subtle-btn danger" onClick={() => onKillSession?.(activeSession?.workspaceId)} disabled={!activeSession} title="Terminate this cmux session"><X size={15} />Stop Session</button>
          <button className="subtle-btn" onClick={onOpenDiff}><FileCode2 size={15} />Open Diff</button>
          <button className="agent-btn" onClick={askAgent}><Sparkles size={15} />Ask Agent</button>
        </div>
      </div>
      <div className="session-layout">
        <div className="terminal-panel">
          <div className="terminal-tabs">
            {sessions.map((session) => (
              <span key={session.id} className={`terminal-tab ${active === session.id ? "active" : ""}`}>
                <button className="terminal-tab-label" onClick={() => setActive(session.id)}>
                  <span className="green-dot" />{session.title || session.workspaceId}
                </button>
                <button
                  className="terminal-tab-close"
                  aria-label={`Stop session ${session.title || session.workspaceId}`}
                  title="Stop this cmux session"
                  onClick={() => onKillSession?.(session.workspaceId)}
                >
                  <X size={12} />
                </button>
              </span>
            ))}
            <button onClick={onNewSession}><Plus size={14} />New Session</button>
            <label className="terminal-auto-refresh" title="Automatically re-read the terminal screen every 5 seconds">
              <input type="checkbox" checked={autoRefresh} onChange={(event) => setAutoRefresh(event.target.checked)} />
              <span>Auto-refresh</span>
            </label>
            {screenUpdatedAt && <span className="terminal-label">Updated {screenUpdatedAt.toLocaleTimeString()}</span>}
            <button className="terminal-tool" aria-label="Refresh terminal now" onClick={refreshScreen}><RefreshCw size={14} /></button>
          </div>
          <TerminalOutput screen={screen || (sessions.length ? "No terminal output yet." : "No cmux session is linked to this task yet. Use New Session to launch one.")} />
          <div className="terminal-controls">
            <div className="terminal-control-row key-controls">
              <button onClick={() => sendKey("up")} disabled={sending}><ArrowUp size={15} />Up</button>
              <button onClick={() => sendKey("down")} disabled={sending}><ArrowDown size={15} />Down</button>
              <button onClick={() => sendKey("left")} disabled={sending}><ArrowLeft size={15} />Left</button>
              <button onClick={() => sendKey("right")} disabled={sending}><ArrowRight size={15} />Right</button>
              <button onClick={() => sendKey("tab")} disabled={sending}>Tab</button>
              <button onClick={() => sendKey("enter")} disabled={sending}>Enter</button>
              <button onClick={() => sendKey("escape")} disabled={sending}>Esc</button>
              <button onClick={() => sendKey("backspace")} disabled={sending}><Delete size={15} />Bkspc</button>
            </div>
            <div className="terminal-command-row">
              <input
                value={command}
                onChange={(event) => setCommand(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault();
                    submitCommand();
                  }
                }}
                placeholder="Type a command or ask AI..."
                disabled={!activeSession || sending}
              />
              <button className="terminal-send-btn" onClick={submitCommand} disabled={!command.trim() || !activeSession || sending} aria-label="Send terminal command">
                {sending ? <RefreshCw size={15} className="spin" /> : <Send size={15} />}
              </button>
            </div>
            <div className="terminal-status-row">
              <span className="terminal-connected"><span className="green-dot" />{activeSession ? "Connected" : "No session"}</span>
              {activeSession && <code>cmux attach {activeSession.workspaceId}</code>}
              {activeSession && (
                <button
                  className="icon-btn small"
                  aria-label="Copy attach command"
                  onClick={() => navigator.clipboard?.writeText(`cmux attach ${activeSession.workspaceId}`)}
                >
                  <Copy size={13} />
                </button>
              )}
            </div>
          </div>
        </div>
        <TaskSidebar
          task={task}
          sessions={sessions}
          activity={activity}
          onOpenDiff={onOpenDiff}
          onRestartSession={() => onRestartSession?.(activeSession?.workspaceId)}
          onAskAgent={askAgent}
        />
      </div>
    </section>
  );
}

function TerminalOutput({ screen }) {
  return (
    <pre className="terminal-output">
      {screen.split("\n").map((line, index) => <TerminalLine key={index} line={line} />)}
    </pre>
  );
}

function TerminalLine({ line }) {
  const promptMatch = line.match(/^(dev@orchestrate:)(~\/services\/api)(\$.*)$/);
  if (promptMatch) {
    return (
      <span className="terminal-line">
        <span className="term-green">{promptMatch[1]}</span><span className="term-blue">{promptMatch[2]}</span>{promptMatch[3]}
      </span>
    );
  }
  if (line.includes("modified:")) {
    return <span className="terminal-line term-red">{line}</span>;
  }
  if (line.startsWith("PASS")) {
    return <span className="terminal-line"><span className="term-pass">PASS</span>{line.slice(4)}</span>;
  }
  if (/\b(passed)\b/.test(line)) {
    const parts = line.split(/(passed)/g);
    return <span className="terminal-line">{parts.map((part, index) => part === "passed" ? <span className="term-green" key={index}>{part}</span> : part)}</span>;
  }
  return <span className="terminal-line">{line || " "}</span>;
}

function TaskSidebar({ task, sessions = task.cmuxSessionLinks || [], activity = [], onOpenDiff, onRestartSession, onAskAgent }) {
  const [tab, setTab] = useState("task");
  const taskActivity = activity.filter((item) => {
    if (item.targetId === task.id) return true;
    return sessions.some((session) => session.workspaceId && item.targetId === session.workspaceId);
  });
  return (
    <aside className="task-sidebar">
      <div className="tab-row">
        <button className={tab === "task" ? "active" : ""} onClick={() => setTab("task")}>Task</button>
        <button className={tab === "activity" ? "active" : ""} onClick={() => setTab("activity")}>Activity</button>
      </div>
      {tab === "activity" ? (
        <div className="sidebar-activity">
          <h3>Task Activity</h3>
          {taskActivity.length === 0 ? (
            <p className="sidebar-empty">No activity recorded for this task yet.</p>
          ) : taskActivity.slice(0, 20).map((item) => (
            <div className="sidebar-activity-row" key={item.id || `${item.kind}-${item.createdAt}`}>
              <strong>{item.title}</strong>
              <span>{item.summary || item.kind}</span>
              <small>{relativeAge(item.createdAt)}</small>
            </div>
          ))}
        </div>
      ) : (
        <>
          <h3>Task Summary</h3>
          <div className="sidebar-meta-row">
            <b>{task.jiraLinks?.[0]?.key || task.id}</b>
            <span className={`status-pill ${statusClass(task.status)}`}>{task.status}</span>
          </div>
          <h2>{task.title}</h2>
          <p>{task.description || task.sessionSummary?.summary || "No summary yet."}</p>
          {task.sessionSummary?.refreshedAt && (
            <small className="sidebar-freshness">Session summary refreshed {relativeAge(task.sessionSummary.refreshedAt)}</small>
          )}
          <div className="sidebar-section">
            <h3>Links</h3>
            <div className="sidebar-link-grid">
              {(task.jiraLinks || []).map((jira) => (
                <React.Fragment key={jira.id}>
                  <span>Jira</span>
                  <a className="resource-chip" href={jira.url}>{jira.key}<ExternalLink size={12} /></a>
                </React.Fragment>
              ))}
              {(task.pullRequestLinks || []).map((pr) => (
                <React.Fragment key={pr.id}>
                  <span>PR</span>
                  <a className="resource-chip pr" href={pr.url}>#{pr.number}<ExternalLink size={12} /></a>
                </React.Fragment>
              ))}
            </div>
          </div>
          <div className="sidebar-copy-row"><Folder size={14} /><span>Workspace</span><code>{task.workspaceDir}</code></div>
          <div className="sidebar-copy-row"><GitBranch size={14} /><span>Branch</span><code>{task.featureBranch || "main"}</code></div>
          <div className="sidebar-section session-list">
            <div className="sidebar-section-title">
              <h3>CMUX Sessions</h3>
              <span>{sessions.length}</span>
              <small>linked</small>
            </div>
            {sessions.map((session) => (
              <span className="session-chip" key={session.id}>
                <Terminal size={12} />
                <strong>{session.workspaceId}</strong>
                <small>{session.launchType || "Attached"}</small>
              </span>
            ))}
          </div>
        </>
      )}
      <div className="quick-actions">
        <button onClick={onRestartSession}><RefreshCw size={14} />Restart Session</button>
        <button onClick={onOpenDiff}><FileCode2 size={14} />Open Diff</button>
        <button onClick={onAskAgent}><Send size={14} />Ask Agent</button>
      </div>
    </aside>
  );
}

function repoLabel(workspaceDir) {
  if (String(workspaceDir || "").includes("/orchestrate-ai/")) {
    return "orchestrate-ai / orchestrate-ai";
  }
  const parts = String(workspaceDir || "").split("/").filter(Boolean);
  const repo = parts[parts.length - 1] || "orchestrate-ai";
  return `${repo} / ${repo}`;
}

function normalizeGitEntry(entry, section) {
  if (!entry) return null;
  if (typeof entry === "string") {
    return { file: entry, status: section === "untracked" ? "A" : "M", section };
  }
  const file = String(entry.file || entry.path || "").trim();
  if (!file) return null;
  return {
    ...entry,
    file,
    status: entry.status || (section === "untracked" ? "A" : "M"),
    section
  };
}

function gitFilesFromStatus(status) {
  return [
    ...(status?.staged || []).map((entry) => normalizeGitEntry(entry, "staged")),
    ...(status?.unstaged || []).map((entry) => normalizeGitEntry(entry, "unstaged")),
    ...(status?.untracked || []).map((entry) => normalizeGitEntry(entry, "untracked"))
  ].filter(Boolean);
}

function gitFileKey(file) {
  if (file?.section === "commit") return `commit:${file?.commitHash || ""}:${file?.file || ""}`;
  return `${file?.section || "unstaged"}:${file?.file || ""}`;
}

function gitStatusBadge(status) {
  return String(status || "M").trim().charAt(0).toUpperCase() || "M";
}

function gitStatusClass(status) {
  return `status-${gitStatusBadge(status).toLowerCase()}`;
}

function pickGitFile(status, current) {
  const files = gitFilesFromStatus(status);
  if (current) {
    const matching = files.find((file) => gitFileKey(file) === gitFileKey(current));
    if (matching) return matching;
    const samePath = files.find((file) => file.file === current.file);
    if (samePath) return samePath;
  }
  const preferredUnstaged = files.find((item) => item.section === "unstaged" && /rate[_-]?limit(?:er)?\.(rb|ts)$/i.test(item.file));
  const preferredStaged = files.find((item) => item.section === "staged" && /rate[_-]?limit(?:er)?\.(rb|ts)$/i.test(item.file));
  return preferredUnstaged
    || preferredStaged
    || files.find((item) => item.section === "staged")
    || files.find((item) => item.section === "unstaged")
    || files.find((item) => item.section === "untracked")
    || files[0]
    || null;
}

function DiffView({ task, initialMode, onBack }) {
  const [mode, setMode] = useState(initialMode === "unified" ? "unified" : "split");
  const [status, setStatus] = useState(null);
  const [selected, setSelected] = useState(null);
  const [diff, setDiff] = useState("");
  const [gitMessage, setGitMessage] = useState("");
  const [contextMenu, setContextMenu] = useState(null);
  const [actioningKey, setActioningKey] = useState("");
  const [expandedCommit, setExpandedCommit] = useState("");
  const [commitFilesByHash, setCommitFilesByHash] = useState({});
  const [commitFilesLoading, setCommitFilesLoading] = useState("");
  const [commitFilesError, setCommitFilesError] = useState("");
  const files = useMemo(() => gitFilesFromStatus(status), [status]);
  const selectedIndex = files.findIndex((file) => gitFileKey(file) === gitFileKey(selected));
  const fetchStatus = useCallback(() => api(`/git/status?path=${encodeURIComponent(task.workspaceDir)}`), [task.workspaceDir]);

  useEffect(() => {
    let cancelled = false;
    setStatus(null);
    setSelected(null);
    setDiff("");
    setGitMessage("");
    setExpandedCommit("");
    setCommitFilesByHash({});
    setCommitFilesLoading("");
    setCommitFilesError("");
    fetchStatus().then((payload) => {
      if (cancelled) return;
      setStatus(payload);
      setSelected(pickGitFile(payload, null));
    }).catch((err) => {
      if (!cancelled) setDiff(err.message);
    });
    return () => {
      cancelled = true;
    };
  }, [fetchStatus]);

  useEffect(() => {
    if (!selected) return;
    let cancelled = false;
    setDiff("Loading diff...");
    const endpoint = selected.section === "commit" ? "/git/commit-diff" : "/git/diff";
    const body = selected.section === "commit"
      ? { path: task.workspaceDir, hash: selected.commitHash, file: selected.file }
      : { path: task.workspaceDir, file: selected.file, section: selected.section || "unstaged" };
    api(endpoint, { method: "POST", body: JSON.stringify(body) })
      .then((payload) => {
        if (!cancelled) setDiff(payload.diff || "No diff.");
      })
      .catch((err) => {
        if (!cancelled) setDiff(err.message);
      });
    return () => {
      cancelled = true;
    };
  }, [selected?.file, selected?.section, selected?.commitHash, task.workspaceDir]);

  useEffect(() => {
    const closeContextMenu = () => setContextMenu(null);
    const closeOnEscape = (event) => {
      if (event.key === "Escape") closeContextMenu();
    };
    window.addEventListener("click", closeContextMenu);
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      window.removeEventListener("click", closeContextMenu);
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, []);

  const fileGroups = [
    { label: "Staged", files: files.filter((file) => file.section === "staged") },
    { label: "Modified", files: files.filter((file) => file.section === "unstaged" && file.status !== "A") },
    { label: "New Files", files: files.filter((file) => file.section === "unstaged" && file.status === "A") },
    { label: "Untracked", files: files.filter((file) => file.section === "untracked") }
  ].filter((group) => group.files.length > 0);

  const refreshGitStatus = async (preferred = selected) => {
    const payload = await fetchStatus();
    setStatus(payload);
    setSelected(pickGitFile(payload, preferred));
    return payload;
  };
  const selectFile = (file) => {
    setSelected(file);
    setContextMenu(null);
    setGitMessage("");
  };
  const openContextMenu = (event, file) => {
    event.preventDefault();
    const menuWidth = 190;
    const menuHeight = 124;
    const left = Math.min(event.clientX, window.innerWidth - menuWidth - 8);
    const top = Math.min(event.clientY, window.innerHeight - menuHeight - 8);
    setContextMenu({ file, left: Math.max(8, left), top: Math.max(8, top) });
  };
  const runGitAction = async (action, file = selected) => {
    if (!file || file.section === "commit") return;
    const key = `${action}:${gitFileKey(file)}`;
    setActioningKey(key);
    setGitMessage("");
    try {
      await api(`/git/${action}`, { method: "POST", body: JSON.stringify({ path: task.workspaceDir, file: file.file }) });
      await refreshGitStatus(file);
      setGitMessage(`${action === "stage" ? "Staged" : "Unstaged"} ${file.file}`);
      setContextMenu(null);
    } catch (err) {
      setGitMessage(err.message);
    } finally {
      setActioningKey("");
    }
  };
  const openNative = async (file = selected) => {
    if (!file || file.section === "commit") return;
    const key = `open:${gitFileKey(file)}`;
    setActioningKey(key);
    setGitMessage("");
    try {
      await api("/open-in-native", { method: "POST", body: JSON.stringify({ path: task.workspaceDir, file: file.file }) });
      setGitMessage(`Opened ${file.file}`);
      setContextMenu(null);
    } catch (err) {
      setGitMessage(err.message);
    } finally {
      setActioningKey("");
    }
  };
  const toggleCommit = async (commit) => {
    const hash = String(commit.hash || "").trim();
    if (!hash) return;
    setContextMenu(null);
    setCommitFilesError("");
    if (expandedCommit === hash) {
      setExpandedCommit("");
      return;
    }
    setExpandedCommit(hash);
    if (commitFilesByHash[hash]) return;
    setCommitFilesLoading(hash);
    try {
      const payload = await api("/git/commit-files", { method: "POST", body: JSON.stringify({ path: task.workspaceDir, hash }) });
      setCommitFilesByHash((current) => ({ ...current, [hash]: payload.files || [] }));
    } catch (err) {
      setCommitFilesError(err.message);
      setCommitFilesByHash((current) => ({ ...current, [hash]: [] }));
    } finally {
      setCommitFilesLoading("");
    }
  };
  const selectCommitFile = (commit, file) => {
    const hash = String(commit.hash || "").trim();
    setSelected({
      ...file,
      status: gitStatusBadge(file.status),
      section: "commit",
      commitHash: hash,
      commitMessage: commit.message || ""
    });
    setGitMessage("");
    setContextMenu(null);
  };
  const selectedCommitFiles = selected?.section === "commit" ? commitFilesByHash[selected.commitHash] || [] : null;
  const selectedCommitIndex = selectedCommitFiles ? selectedCommitFiles.findIndex((file) => gitFileKey({ ...file, section: "commit", commitHash: selected.commitHash }) === gitFileKey(selected)) : -1;
  const panelTotalFiles = selectedCommitFiles ? selectedCommitFiles.length : files.length;
  const panelSelectedPosition = selectedCommitFiles ? selectedCommitIndex + 1 : selected?.order || selectedIndex + 1;

  return (
    <section className="center-view diff-view">
      <button className="back-btn" onClick={onBack}><ChevronLeft size={17} />Back to Tasks</button>
      <div className="diff-toolbar">
        <select><option>{repoLabel(task.workspaceDir)}</option></select>
        <select><option>{status?.branch || task.featureBranch || "main"}</option></select>
        <span className="count-pill">{files.length} changed files</span>
        <div className="segmented">
          <button className={mode === "unified" ? "active" : ""} onClick={() => setMode("unified")}><FileCode2 size={15} />Unified</button>
          <button className={mode === "split" ? "active" : ""} onClick={() => setMode("split")}><SplitSquareHorizontal size={15} />Split</button>
        </div>
        <button className="icon-btn"><MoreHorizontal size={17} /></button>
      </div>
      <div className="diff-layout">
        <aside className="diff-sidebar">
          <div className="panel-heading"><h2>Commit History</h2><span>{status?.commits?.length || 0}</span></div>
          <div className="commit-list">
            {(status?.commits || []).slice(0, 10).map((commit) => {
              const expanded = expandedCommit === commit.hash;
              const commitFiles = commitFilesByHash[commit.hash] || [];
              return (
                <div className="commit-block" key={commit.hash}>
                  <button type="button" className={`commit-row ${expanded ? "expanded" : ""}`} onClick={() => toggleCommit(commit)}>
                    <ChevronRight className="commit-chevron" size={13} />
                    <b>{commit.hash}</b>
                    <span>{commit.message}</span>
                  </button>
                  {expanded && (
                    <div className="commit-files">
                      {commitFilesLoading === commit.hash && <div className="commit-file-state">Loading files...</div>}
                      {commitFilesError && commitFilesLoading !== commit.hash && <div className="commit-file-state error">{commitFilesError}</div>}
                      {!commitFilesLoading && !commitFilesError && commitFiles.length === 0 && <div className="commit-file-state">No files changed</div>}
                      {commitFiles.map((file) => {
                        const commitFile = { ...file, section: "commit", commitHash: commit.hash };
                        return (
                          <button
                            type="button"
                            key={`${commit.hash}-${file.file}`}
                            className={`commit-file-row ${gitFileKey(selected) === gitFileKey(commitFile) ? "active" : ""}`}
                            onClick={() => selectCommitFile(commit, file)}
                          >
                            <span className={`git-status-badge ${gitStatusClass(file.status)}`}>{gitStatusBadge(file.status)}</span>
                            <em>{file.file}</em>
                          </button>
                        );
                      })}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
          <div className="panel-heading"><h2>Current Changes</h2><span>{files.length}</span></div>
          <div className="file-list">
            {fileGroups.map((group) => (
              <div className="file-group" key={group.label}>
                <div className="file-group-label"><span>{group.label}</span><b>{group.files.length}</b></div>
                {group.files.map((file) => (
                  <button
                    key={gitFileKey(file)}
                    className={gitFileKey(selected) === gitFileKey(file) ? "active" : ""}
                    onClick={() => selectFile(file)}
                    onContextMenu={(event) => openContextMenu(event, file)}
                  >
                    <span className={`git-status-badge ${gitStatusClass(file.status)}`}>{gitStatusBadge(file.status)}</span>
                    <em>{file.file}</em>
                  </button>
                ))}
              </div>
            ))}
          </div>
        </aside>
        <DiffPanel
          mode={mode}
          fileEntry={selected}
          diff={diff}
          totalFiles={panelTotalFiles}
          selectedPosition={panelSelectedPosition}
          gitMessage={gitMessage}
          actioningKey={actioningKey}
          onGitAction={runGitAction}
          onOpenNative={openNative}
        />
      </div>
      {contextMenu && (
        <div
          className="git-context-menu"
          style={{ left: contextMenu.left, top: contextMenu.top }}
          onClick={(event) => event.stopPropagation()}
          onContextMenu={(event) => event.preventDefault()}
        >
          <button onClick={() => selectFile(contextMenu.file)}><FileCode2 size={14} />View Diff</button>
          {contextMenu.file.section === "staged" ? (
            <button onClick={() => runGitAction("unstage", contextMenu.file)} disabled={actioningKey === `unstage:${gitFileKey(contextMenu.file)}`}>
              <ArrowDown size={14} />Unstage
            </button>
          ) : (
            <button onClick={() => runGitAction("stage", contextMenu.file)} disabled={actioningKey === `stage:${gitFileKey(contextMenu.file)}`}>
              <ArrowUp size={14} />Stage
            </button>
          )}
          <button onClick={() => openNative(contextMenu.file)} disabled={actioningKey === `open:${gitFileKey(contextMenu.file)}`}>
            <ExternalLink size={14} />Open in Native App
          </button>
        </div>
      )}
    </section>
  );
}

function commonDiffParts(before, after) {
  let start = 0;
  while (start < before.length && start < after.length && before[start] === after[start]) start += 1;
  let endBefore = before.length - 1;
  let endAfter = after.length - 1;
  while (endBefore >= start && endAfter >= start && before[endBefore] === after[endAfter]) {
    endBefore -= 1;
    endAfter -= 1;
  }
  const oldChanged = before.slice(start, endBefore + 1);
  const newChanged = after.slice(start, endAfter + 1);
  return {
    before: [
      { text: before.slice(0, start), highlight: false },
      { text: oldChanged, highlight: oldChanged.length > 0 },
      { text: before.slice(endBefore + 1), highlight: false }
    ].filter((part) => part.text.length > 0),
    after: [
      { text: after.slice(0, start), highlight: false },
      { text: newChanged, highlight: newChanged.length > 0 },
      { text: after.slice(endAfter + 1), highlight: false }
    ].filter((part) => part.text.length > 0)
  };
}

function plainParts(text) {
  return [{ text, highlight: false }];
}

function buildDiffRows(diffText) {
  if (!diffText) return [];
  const lines = String(diffText).split("\n");
  const rows = [];
  let oldLine = 0;
  let newLine = 0;
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (/^@@ /.test(line)) {
      const match = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
      if (match) {
        oldLine = Number(match[1]) - 1;
        newLine = Number(match[2]) - 1;
      }
      rows.push({ type: "hunk", marker: "", oldNumber: "", newNumber: "", parts: plainParts(line) });
      index += 1;
      continue;
    }
    if (/^(diff --git|index |--- |\+\+\+ )/.test(line)) {
      rows.push({ type: "header", marker: "", oldNumber: "", newNumber: "", parts: plainParts(line) });
      index += 1;
      continue;
    }
    if (line.startsWith("-")) {
      const removed = [];
      const added = [];
      while (index < lines.length && lines[index].startsWith("-") && !lines[index].startsWith("--- ")) {
        removed.push(lines[index].slice(1));
        index += 1;
      }
      while (index < lines.length && lines[index].startsWith("+") && !lines[index].startsWith("+++ ")) {
        added.push(lines[index].slice(1));
        index += 1;
      }
      const count = Math.max(removed.length, added.length);
      for (let pairIndex = 0; pairIndex < count; pairIndex += 1) {
        const removedText = removed[pairIndex];
        const addedText = added[pairIndex];
        const paired = removedText !== undefined && addedText !== undefined ? commonDiffParts(removedText, addedText) : null;
        if (removedText !== undefined) {
          oldLine += 1;
          rows.push({
            type: "remove",
            marker: "-",
            oldNumber: oldLine,
            newNumber: "",
            parts: paired ? paired.before : plainParts(removedText)
          });
        }
        if (addedText !== undefined) {
          newLine += 1;
          rows.push({
            type: "add",
            marker: "+",
            oldNumber: "",
            newNumber: newLine,
            parts: paired ? paired.after : plainParts(addedText)
          });
        }
      }
      continue;
    }
    if (line.startsWith("+") && !line.startsWith("+++ ")) {
      newLine += 1;
      rows.push({ type: "add", marker: "+", oldNumber: "", newNumber: newLine, parts: plainParts(line.slice(1)) });
      index += 1;
      continue;
    }
    if (line.startsWith(" ")) {
      oldLine += 1;
      newLine += 1;
      rows.push({ type: "context", marker: " ", oldNumber: oldLine, newNumber: newLine, parts: plainParts(line.slice(1)) });
      index += 1;
      continue;
    }
    rows.push({ type: "context", marker: "", oldNumber: "", newNumber: "", parts: plainParts(line || " ") });
    index += 1;
  }
  return rows;
}

function DiffPanel({ mode, fileEntry, diff, totalFiles = 0, selectedPosition = 1, gitMessage, actioningKey, onGitAction, onOpenNative }) {
  const rows = useMemo(() => buildDiffRows(diff), [diff]);
  const file = fileEntry?.file;
  const isCommitSelection = fileEntry?.section === "commit";
  const title = isCommitSelection && fileEntry?.commitHash ? `${file} @ ${fileEntry.commitHash.slice(0, 7)}` : file;
  const action = fileEntry?.section === "staged" ? "unstage" : "stage";
  const actionLabel = action === "stage" ? "Stage" : "Unstage";
  const actionIcon = action === "stage" ? <ArrowUp size={13} /> : <ArrowDown size={13} />;
  return (
    <div className="diff-panel">
      <div className="diff-file-header">
        <strong>{title || "No file selected"}</strong>
        <span>{gitStatusBadge(fileEntry?.status)}</span>
        {isCommitSelection ? (
          <span className="diff-context-pill"><GitBranch size={13} />Commit</span>
        ) : (
          <button className="diff-action-btn" onClick={() => onGitAction(action, fileEntry)} disabled={!fileEntry || actioningKey === `${action}:${gitFileKey(fileEntry)}`}>
            {actionIcon}{actionLabel}
          </button>
        )}
        {isCommitSelection ? (
          <span className="diff-header-spacer" />
        ) : (
          <button className="icon-btn small" aria-label="Open selected file in native app" onClick={() => onOpenNative(fileEntry)} disabled={!fileEntry || actioningKey === `open:${gitFileKey(fileEntry)}`}><ExternalLink size={13} /></button>
        )}
        <button className="icon-btn small"><Copy size={13} /></button>
        <span>{Math.max(1, selectedPosition)} of {Math.max(1, totalFiles || rows.length)}</span>
        <button className="icon-btn small"><ChevronLeft size={13} /></button>
        <button className="icon-btn small"><ChevronRight size={13} /></button>
        <button className="icon-btn small"><MoreHorizontal size={13} /></button>
      </div>
      {gitMessage && <div className="diff-message">{gitMessage}</div>}
      {mode === "split" ? (
        <SplitDiffTable rows={rows} />
      ) : (
        <UnifiedDiffTable rows={rows} />
      )}
    </div>
  );
}

function DiffContent({ row }) {
  return (
    <>
      <span className="diff-marker">{row.marker}</span>
      <span className="diff-text">
        {row.parts.map((part, index) => (
          <span key={index} className={part.highlight ? "diff-inline-highlight" : ""}>{part.text}</span>
        ))}
      </span>
    </>
  );
}

function UnifiedDiffTable({ rows }) {
  return (
    <div className="unified-diff">
      <table className="diff-table-v2">
        <tbody>
          {rows.map((row, index) => (
            <tr key={index} className={`diff-row-v2 ${row.type}`}>
              <td className="diff-line-no">{row.oldNumber}</td>
              <td className="diff-line-no">{row.newNumber}</td>
              <td className="diff-code"><DiffContent row={row} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function SplitDiffTable({ rows }) {
  return (
    <div className="split-diff">
      <div className="split-diff-header"><span>Before</span><span>After</span></div>
      <div className="split-diff-body">
        {rows.map((row, index) => {
          if (row.type === "header" || row.type === "hunk") {
            return (
              <div key={index} className={`split-diff-row meta ${row.type}`}>
                <div><DiffContent row={row} /></div>
              </div>
            );
          }
          return (
            <div key={index} className={`split-diff-row ${row.type}`}>
              <div className={`split-diff-cell before ${row.type === "remove" || row.type === "context" ? "filled" : ""}`}>
                <span className="diff-line-no">{row.type === "remove" || row.type === "context" ? row.oldNumber : ""}</span>
                {(row.type === "remove" || row.type === "context") && <span className="diff-code"><DiffContent row={row} /></span>}
              </div>
              <div className={`split-diff-cell after ${row.type === "add" || row.type === "context" ? "filled" : ""}`}>
                <span className="diff-line-no">{row.type === "add" || row.type === "context" ? row.newNumber : ""}</span>
                {(row.type === "add" || row.type === "context") && <span className="diff-code"><DiffContent row={row} /></span>}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function GoalView({ task, onBack, onSaved }) {
  const [goal, setGoal] = useState("");
  const [path, setPath] = useState("");
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    api(`/tasks/${encodeURIComponent(task.id)}/goal`).then((payload) => {
      setGoal(payload.goal.content || "");
      setPath(payload.goal.path || "");
    });
  }, [task.id]);
  const save = async () => {
    setSaving(true);
    await api(`/tasks/${encodeURIComponent(task.id)}/goal`, { method: "POST", body: JSON.stringify({ content: goal }) });
    await onSaved();
    setSaving(false);
  };
  return (
    <section className="center-view goal-view">
      <button className="back-btn" onClick={onBack}><ChevronLeft size={17} />Back to Tasks</button>
      <div className="center-header">
        <div><h1>{task.title}</h1><code>{path}</code></div>
        <button className="primary-btn" onClick={save} disabled={saving}><Check size={17} />{saving ? "Saving" : "Save Goal"}</button>
      </div>
      <textarea value={goal} onChange={(event) => setGoal(event.target.value)} spellCheck="false" />
    </section>
  );
}

function ActivityView({ activity, onBack, onRunWatcher }) {
  const [toolRuns, setToolRuns] = useState([]);
  const [loadError, setLoadError] = useState("");
  const [runningWatcher, setRunningWatcher] = useState(false);
  const [watcherNote, setWatcherNote] = useState("");
  const groupedActivity = useMemo(() => groupActivity(activity), [activity]);
  useEffect(() => {
    api("/agent/tool-runs?limit=100")
      .then((payload) => setToolRuns(payload.toolRuns || []))
      .catch((err) => setLoadError(err.message));
  }, [activity]);
  const runWatcher = async () => {
    setRunningWatcher(true);
    setWatcherNote("");
    try {
      const result = await onRunWatcher();
      const changes = result?.stateChanges?.length || 0;
      setWatcherNote(`Watcher finished: ${result?.sessions?.length ?? 0} session(s), ${result?.orphans?.length ?? 0} orphan(s), ${changes} state change(s).`);
    } catch (err) {
      setWatcherNote(err.message);
    } finally {
      setRunningWatcher(false);
    }
  };
  const toolRunsByRun = useMemo(() => {
    const map = new Map();
    for (const run of toolRuns) {
      const key = run.runId || "manual";
      if (!map.has(key)) map.set(key, []);
      map.get(key).push(run);
    }
    return map;
  }, [toolRuns]);
  return (
    <section className="center-view activity-view">
      <button className="back-btn" onClick={onBack}><ChevronLeft size={17} />Back to Board</button>
      <div className="center-header">
        <div>
          <h1>Activity</h1>
          <p className="view-subtitle">Everything the orchestrator and watcher did, grouped by run.</p>
        </div>
        <button className="primary-btn" onClick={runWatcher} disabled={runningWatcher}>
          {runningWatcher ? <RefreshCw size={15} className="spin" /> : <Play size={15} />}
          {runningWatcher ? "Watching..." : "Run Watcher Now"}
        </button>
      </div>
      {watcherNote && <div className="watcher-note">{watcherNote}</div>}
      {loadError && <div className="error-strip"><span>{loadError}</span></div>}
      {groupedActivity.length === 0 ? (
        <div className="empty-board">
          <Sparkles size={28} />
          <h2>No activity yet</h2>
          <p>Agent tool calls, approvals, session lifecycle events, and watcher runs will appear here.</p>
        </div>
      ) : (
        <div className="activity-full-list">
          {groupedActivity.map((group) => {
            const runs = toolRunsByRun.get(group.id) || [];
            return (
              <div className="activity-full-group" key={group.id}>
                <div className="activity-full-head">
                  <Circle size={9} />
                  <strong>{group.title}</strong>
                  <span>{group.items.length} event(s)</span>
                  {runs.length > 0 && <small>{runs.length} tool run(s)</small>}
                  <small>{relativeAge(group.items[0]?.createdAt)}</small>
                </div>
                {group.items.map((item) => (
                  <div className={`activity-full-row kind-${statusClass(item.kind)}`} key={item.id || `${item.kind}-${item.createdAt}`}>
                    <span className={`activity-kind-pill ${statusClass(item.kind)}`}>{String(item.kind || "event").replace(/_/g, " ")}</span>
                    <strong>{item.title}</strong>
                    <span className="activity-summary">{item.summary}</span>
                    <small>{relativeAge(item.createdAt)}</small>
                  </div>
                ))}
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}

function HistoryView({ history, onBack, onReopen, onOpenView }) {
  const finished = history.filter((task) => ["Done", "Archived"].includes(task.status));
  return (
    <section className="center-view history-view">
      <button className="back-btn" onClick={onBack}><ChevronLeft size={17} />Back to Board</button>
      <div className="center-header">
        <div>
          <h1>History <span className="count-inline">{finished.length}</span></h1>
          <p className="view-subtitle">Done and archived tasks. Reopen a task to bring it back to the board.</p>
        </div>
      </div>
      {finished.length === 0 ? (
        <div className="empty-board">
          <Archive size={28} />
          <h2>No finished tasks yet</h2>
          <p>Tasks marked Done or Archived land here.</p>
        </div>
      ) : (
        <div className="history-full-list">
          {finished.map((task) => (
            <div className="history-full-row" key={task.id}>
              <Check size={15} />
              <div className="history-full-main">
                <strong>{task.title}</strong>
                <small>{task.workspaceDir}</small>
              </div>
              <span className={`status-pill ${statusClass(task.status)}`}>{task.status}</span>
              {task.jiraLinks?.[0] && <a className="resource-chip jira" href={task.jiraLinks[0].url || "#"} target="_blank" rel="noreferrer">{task.jiraLinks[0].key}</a>}
              {task.pullRequestLinks?.[0] && <a className="resource-chip pr" href={task.pullRequestLinks[0].url || "#"} target="_blank" rel="noreferrer">#{task.pullRequestLinks[0].number}</a>}
              <small>{relativeAge(task.updatedAt)}</small>
              <button className="subtle-btn" onClick={() => onOpenView("diff", task)}><FileCode2 size={13} />Diff</button>
              <button className="subtle-btn" onClick={() => onReopen(task)}><RefreshCw size={13} />Reopen</button>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

function GeneratedPanelStack({ panels, tasks, approvals, voiceMode, voiceState, voiceSettings, onDismiss, onOpenView, onApprovalDecision }) {
  const combinedPanels = [
    {
      id: "voice-state",
      component: "VoiceModePanel",
      props: { mode: voiceMode, state: voiceState, settings: voiceSettings }
    },
    ...approvals.filter((approval) => approval.status === "pending").slice(0, 2).map((approval) => ({
      id: `approval-panel-${approval.id}`,
      component: ["kill_cmux_session", "restart_cmux_session"].includes(approval.kind)
        ? "SessionLifecycleApprovalPanel"
        : "JiraCommentApprovalPanel",
      props: approval
    })),
    ...panels
  ];
  if (!combinedPanels.length) return null;
  return (
    <section className="generated-panel-stack" aria-label="Agent generated panels">
      {combinedPanels.slice(0, 6).map((panel) => (
        <GeneratedPanel
          key={panel.id}
          panel={panel}
          tasks={tasks}
          onDismiss={onDismiss}
          onOpenView={onOpenView}
          onApprovalDecision={onApprovalDecision}
        />
      ))}
    </section>
  );
}

function GeneratedPanel({ panel, tasks, onDismiss, onOpenView, onApprovalDecision }) {
  const props = panel.props || {};
  const close = panel.id === "voice-state" ? null : <button className="icon-btn small" onClick={() => onDismiss(panel.id)}><X size={13} /></button>;
  if (panel.component === "TaskStatusPanel") return <PanelFrame title="Task Status" close={close}><TaskStatusPanel tasks={props.tasks || tasks} onOpenView={onOpenView} /></PanelFrame>;
  if (panel.component === "CmuxSessionInspectorPanel") return <PanelFrame title="cmux Inspector" close={close}><CmuxSessionInspectorPanel {...props} /></PanelFrame>;
  if (panel.component === "GitDiffSummaryPanel") return <PanelFrame title="Git Diff Summary" close={close}><GitDiffSummaryPanel {...props} /></PanelFrame>;
  if (panel.component === "GoalDraftPanel") return <PanelFrame title="Goal Draft" close={close}><GoalDraftPanel {...props} /></PanelFrame>;
  if (panel.component === "JiraCommentApprovalPanel") return <PanelFrame title="Jira Comment Approval" close={close}><JiraCommentApprovalPanel approval={props} onApprovalDecision={onApprovalDecision} /></PanelFrame>;
  if (panel.component === "SessionLifecycleApprovalPanel") return <PanelFrame title="Session Lifecycle Approval" close={close}><SessionLifecycleApprovalPanel approval={props.approval || props} onApprovalDecision={onApprovalDecision} /></PanelFrame>;
  if (panel.component === "JiraTransitionPanel") return <PanelFrame title="Jira Transition" close={close}><JiraTransitionPanel {...props} /></PanelFrame>;
  if (panel.component === "VoiceModePanel") return <PanelFrame title="Voice Mode" close={close}><VoiceModePanel {...props} /></PanelFrame>;
  if (panel.component === "ToolRunTimeline") return <PanelFrame title="Tool Timeline" close={close}><ToolRunTimeline {...props} /></PanelFrame>;
  if (panel.component === "NotImplementedCapabilityPanel") return <PanelFrame title="Not Implemented" close={close}><NotImplementedCapabilityPanel {...props} /></PanelFrame>;
  return null;
}

function PanelFrame({ title, close, children }) {
  return (
    <article className="generated-panel">
      <div className="generated-panel-head"><Sparkles size={14} /><strong>{title}</strong>{close}</div>
      {children}
    </article>
  );
}

function TaskStatusPanel({ tasks, onOpenView }) {
  return (
    <div className="panel-task-list">
      {(tasks || []).slice(0, 4).map((task) => (
        <button key={task.id} onClick={() => onOpenView("session", task)}>
          <strong>{task.title}</strong>
          <span className={`status-pill ${statusClass(task.status)}`}>{task.status}</span>
          <small>{task.jiraLinks?.[0]?.key || task.cmuxSessionLinks?.[0]?.workspaceId || "durable state"}</small>
        </button>
      ))}
      {!(tasks || []).length && <div className="panel-empty">No matching tasks</div>}
    </div>
  );
}

function CmuxSessionInspectorPanel({ workspaceId, runningKind, state, screenExcerpt, freshness }) {
  return (
    <div className="cmux-inspector-panel">
      <div><b>{workspaceId || "Unknown session"}</b><span>{runningKind || "Shell"}</span><span>{state || "snapshot"}</span><span>{freshness || "unknown"}</span></div>
      <pre>{screenExcerpt || "No live screen excerpt available."}</pre>
    </div>
  );
}

function GitDiffSummaryPanel(props) {
  const staged = props.staged || [];
  const unstaged = props.unstaged || [];
  const untracked = props.untracked || [];
  return (
    <div className="git-summary-panel">
      <div className="metric-row"><span>Staged</span><b>{staged.length}</b><span>Modified</span><b>{unstaged.length}</b><span>Untracked</span><b>{untracked.length}</b></div>
      <p>{props.diff ? "Diff content is loaded for the selected file." : "Status grouped by changed file risk."}</p>
    </div>
  );
}

function GoalDraftPanel({ path, content }) {
  return <pre className="goal-draft-panel">{content || path || "No goal draft content."}</pre>;
}

function JiraCommentApprovalPanel({ approval, onApprovalDecision }) {
  const payload = approval.payload || {};
  return (
    <div className="jira-approval-panel">
      <div className="approval-details">
        <span>Tool</span><b>{payload.toolName || approval.kind}</b>
        <span>Target</span><b>{payload.key || approval.taskId || "Jira issue"}</b>
        <span>Status</span><b>{approval.status}</b>
      </div>
      <pre>{payload.body || approval.summary || "No preview body"}</pre>
      {approval.status === "pending" && (
        <div className="approval-actions">
          <button className="approve-btn" onClick={() => onApprovalDecision(approval, "approved")}><Check size={14} />Approve</button>
          <button className="deny-btn" onClick={() => onApprovalDecision(approval, "denied")}><X size={14} />Deny</button>
        </div>
      )}
    </div>
  );
}

function SessionLifecycleApprovalPanel({ approval, onApprovalDecision }) {
  const payload = approval.payload || {};
  const action = approval.kind === "restart_cmux_session" ? "Restart" : "Stop";
  return (
    <div className="jira-approval-panel lifecycle">
      <div className="approval-details">
        <span>Action</span><b>{action} cmux session</b>
        <span>Target</span><b>{payload.workspaceId || "unknown session"}</b>
        <span>Reversible</span><b>{payload.reversible ? "Yes (relaunches)" : "No (process terminates)"}</b>
        <span>Status</span><b>{approval.status}</b>
      </div>
      <p>{approval.summary || approval.title}</p>
      {approval.status === "pending" && (
        <div className="approval-actions">
          <button className="approve-btn" onClick={() => onApprovalDecision(approval, "approved")}><Check size={14} />Approve {action}</button>
          <button className="deny-btn" onClick={() => onApprovalDecision(approval, "denied")}><X size={14} />Deny</button>
        </div>
      )}
    </div>
  );
}

function JiraTransitionPanel({ key, targetStatus, transition }) {
  return <div className="transition-panel"><b>{key || transition?.key}</b><span>{targetStatus || transition?.status || "transition requested"}</span></div>;
}

function VoiceModePanel({ mode, state, settings }) {
  return (
    <div className="voice-mode-panel">
      <span className={`voice-state-dot ${state?.status || "idle"}`} />
      <b>{mode === "realtime" ? "GPT Realtime 2" : mode === "local" ? "Local STT / Fireworks / Piper" : "Text chat"}</b>
      <span>{state?.status || "idle"}</span>
      {mode !== "text" && <span>{settings?.pushToTalk ? "push-to-talk" : "open mic"}</span>}
      {mode === "local" && <span>{settings?.ttsProvider === "elevenlabs" ? "Jessica" : "Piper"}</span>}
      <small>{state?.message || "Shared global transcript is active."}</small>
    </div>
  );
}

function VoiceVisualMode({ capabilities, onExit, onTurnComplete }) {
  const [status, setStatus] = useState("off");
  const [caps, setCaps] = useState(capabilities || null);
  const [userCaption, setUserCaption] = useState("");
  const [assistantCaption, setAssistantCaption] = useState("");
  const [toolCalls, setToolCalls] = useState([]);
  const [panel, setPanel] = useState(null);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [voiceToast, setVoiceToast] = useState("");
  const [sessionStartedAt, setSessionStartedAt] = useState(0);
  const [clock, setClock] = useState(() => Date.now());
  const [talkMode, setTalkMode] = useState(() => {
    if (typeof window === "undefined") return "toggle";
    return window.localStorage.getItem("orchestrator-v2-voice-talk-mode") === "hold" ? "hold" : "toggle";
  });

  const statusRef = useRef("off");
  const sessionRef = useRef(null);
  const sessionGenRef = useRef(0);
  const captureRef = useRef(null);
  const recordingRef = useRef(null);
  const playbackRef = useRef(null);
  const bargeInRef = useRef(null);
  const abortRef = useRef(null);
  const turnRef = useRef(null);
  const turnCounterRef = useRef(0);
  const partialTimerRef = useRef(null);
  const followupTimerRef = useRef(null);
  const toastTimerRef = useRef(null);
  const meterFrameRef = useRef(null);
  const orbRef = useRef(null);
  const endSessionRef = useRef(() => {});

  const setStatusSafe = (value) => {
    statusRef.current = value;
    setStatus(value);
  };

  const showToast = (message) => {
    setVoiceToast(message);
    if (toastTimerRef.current) window.clearTimeout(toastTimerRef.current);
    toastTimerRef.current = window.setTimeout(() => setVoiceToast(""), 5200);
  };

  const setOrbLevel = (value) => {
    orbRef.current?.style?.setProperty("--voice-level", String(Math.max(0, Math.min(1, value))));
  };

  const stopOrbMeter = () => {
    if (meterFrameRef.current) window.cancelAnimationFrame(meterFrameRef.current);
    meterFrameRef.current = null;
    setOrbLevel(0);
  };

  const startOrbMeter = (analyser) => {
    stopOrbMeter();
    if (typeof analyser?.getByteTimeDomainData !== "function" || typeof window.requestAnimationFrame !== "function") return;
    const data = new Uint8Array(analyser.fftSize || 256);
    const tick = () => {
      analyser.getByteTimeDomainData(data);
      let sum = 0;
      for (let index = 0; index < data.length; index += 1) {
        const value = (data[index] - 128) / 128;
        sum += value * value;
      }
      setOrbLevel(Math.sqrt(sum / data.length) * 3.2);
      meterFrameRef.current = window.requestAnimationFrame(tick);
    };
    meterFrameRef.current = window.requestAnimationFrame(tick);
  };

  const clearPartialTimer = () => {
    if (partialTimerRef.current) window.clearInterval(partialTimerRef.current);
    partialTimerRef.current = null;
  };

  const clearFollowupTimer = () => {
    if (followupTimerRef.current) window.clearTimeout(followupTimerRef.current);
    followupTimerRef.current = null;
  };

  const stopPlayback = () => playbackRef.current?.finish(false);

  const playAudioBase64 = async (audioBase64, kind) => {
    const session = sessionRef.current;
    if (!session?.active || !audioBase64) return false;
    stopPlayback();
    let buffer = null;
    try {
      buffer = await session.audioContext.decodeAudioData(base64ToArrayBuffer(audioBase64));
    } catch {
      return false;
    }
    if (!buffer || !sessionRef.current?.active) return false;
    return new Promise((resolve) => {
      const source = session.audioContext.createBufferSource();
      const analyser = session.audioContext.createAnalyser();
      analyser.fftSize = 256;
      source.buffer = buffer;
      source.connect(analyser);
      analyser.connect(session.audioContext.destination);
      const playback = {
        kind,
        startedAt: Date.now(),
        done: false,
        finish(completed) {
          if (playback.done) return;
          playback.done = true;
          try { source.stop(); } catch { /* already stopped */ }
          try { source.disconnect(); } catch { /* already disconnected */ }
          try { analyser.disconnect(); } catch { /* already disconnected */ }
          if (playbackRef.current === playback) playbackRef.current = null;
          stopOrbMeter();
          resolve(completed);
        }
      };
      playbackRef.current = playback;
      source.onended = () => playback.finish(true);
      startOrbMeter(analyser);
      try {
        source.start(0);
      } catch {
        playback.finish(false);
      }
    });
  };

  const startRecording = ({ vad = true, followup = false, barge = false, seedChunks = null } = {}) => {
    if (!sessionRef.current?.active || recordingRef.current) return;
    recordingRef.current = {
      chunks: seedChunks?.length ? seedChunks.slice() : [],
      startedAt: Date.now(),
      speechMs: 0,
      silenceMs: 0,
      pcmMs: 0,
      heardSpeech: barge,
      vad,
      followup,
      barge,
      partialBusy: false,
      finalized: false
    };
    if (!followup) {
      setUserCaption("");
      setStatusSafe("listening");
    }
    clearPartialTimer();
    partialTimerRef.current = window.setInterval(() => {
      sendPartialTranscribe();
    }, VOICE_PARTIAL_INTERVAL_MS);
  };

  const cancelRecording = () => {
    const rec = recordingRef.current;
    if (rec) rec.finalized = true;
    recordingRef.current = null;
    clearPartialTimer();
    clearFollowupTimer();
    setOrbLevel(0);
  };

  const promoteFollowup = (hold = false) => {
    const rec = recordingRef.current;
    if (!rec || rec.finalized) {
      startRecording({ vad: !hold });
      return;
    }
    clearFollowupTimer();
    rec.followup = false;
    rec.vad = !hold;
    setUserCaption("");
    setStatusSafe("listening");
  };

  const handleChunk = (chunk) => {
    if (!sessionRef.current?.active || !chunk?.length) return;
    const sampleRate = captureRef.current?.sampleRate || VOICE_TARGET_SAMPLE_RATE;
    const chunkMs = (chunk.length / sampleRate) * 1000;
    const rms = chunkRms(chunk);
    const rec = recordingRef.current;
    if (rec && !rec.finalized) {
      rec.chunks.push(chunk);
      rec.pcmMs += chunkMs;
      if (rms >= VOICE_VAD.speechRms) {
        rec.speechMs += chunkMs;
        rec.silenceMs = 0;
        if (!rec.heardSpeech && rec.speechMs >= VOICE_VAD.minSpeechMs) {
          rec.heardSpeech = true;
          if (rec.followup) promoteFollowup();
        }
      } else {
        rec.silenceMs += chunkMs;
      }
      if (statusRef.current === "listening" || statusRef.current === "followup") setOrbLevel(rms * 9);
      if (rec.vad && rec.heardSpeech && rec.silenceMs >= VOICE_VAD.silenceMs) finalizeRecording();
      else if (Date.now() - rec.startedAt >= VOICE_VAD.maxUtteranceMs) finalizeRecording();
      else if (rec.pcmMs >= VOICE_MAX_PCM_MS) finalizeRecording();
      else if (rec.barge && !rec.speechMs && Date.now() - rec.startedAt >= VOICE_BARGE_IN.noSpeechMs) finalizeRecording();
    }
    const monitor = bargeInRef.current;
    const playback = playbackRef.current;
    if (monitor && playback?.kind === "answer" && !playback.done) {
      monitor.prebuffer.push(chunk);
      monitor.prebufferMs += chunkMs;
      while (monitor.prebuffer.length > 1 && monitor.prebufferMs - (monitor.prebuffer[0].length / sampleRate) * 1000 >= VOICE_BARGE_IN.prebufferMs) {
        monitor.prebufferMs -= (monitor.prebuffer[0].length / sampleRate) * 1000;
        monitor.prebuffer.shift();
      }
      if (Date.now() - playback.startedAt < VOICE_BARGE_IN.cooldownMs) {
        monitor.sustainMs = 0;
      } else if (rms >= VOICE_BARGE_IN.rms) {
        monitor.sustainMs += chunkMs;
        if (monitor.sustainMs >= VOICE_BARGE_IN.sustainMs) {
          const seedChunks = monitor.prebuffer;
          bargeInRef.current = null;
          interruptToListening(false, seedChunks);
        }
      } else {
        monitor.sustainMs = 0;
      }
    }
  };

  const sendPartialTranscribe = async () => {
    const rec = recordingRef.current;
    if (!rec || rec.finalized || rec.partialBusy || !rec.heardSpeech || !rec.chunks.length) return;
    rec.partialBusy = true;
    try {
      const audioBase64 = await wavBase64FromChunks(rec.chunks.slice(), captureRef.current?.sampleRate || VOICE_TARGET_SAMPLE_RATE);
      if (!audioBase64 || rec.finalized) return;
      const result = await api("/voice/local/transcribe", {
        method: "POST",
        body: JSON.stringify({ audioBase64, filename: "voice.wav", mimeType: "audio/wav", partial: true, appendChat: false })
      });
      if (!rec.finalized && recordingRef.current === rec && result.text) setUserCaption(result.text);
    } catch {
      // Partial captions are best-effort; the final transcribe surfaces real failures.
    } finally {
      rec.partialBusy = false;
    }
  };

  const finalizeRecording = async () => {
    const rec = recordingRef.current;
    if (!rec || rec.finalized) return;
    rec.finalized = true;
    recordingRef.current = null;
    clearPartialTimer();
    clearFollowupTimer();
    setOrbLevel(0);
    if (!sessionRef.current?.active) return;
    if (!rec.barge && rec.speechMs < VOICE_VAD.minSpeechMs) {
      setStatusSafe("idle");
      return;
    }
    setStatusSafe("transcribing");
    let text = "";
    try {
      const audioBase64 = await wavBase64FromChunks(rec.chunks, captureRef.current?.sampleRate || VOICE_TARGET_SAMPLE_RATE);
      const result = await api("/voice/local/transcribe", {
        method: "POST",
        body: JSON.stringify({ audioBase64, filename: "voice.wav", mimeType: "audio/wav", appendChat: false })
      });
      text = String(result.text || "").trim();
    } catch (err) {
      if (statusRef.current === "transcribing" && sessionRef.current?.active) {
        setStatusSafe("idle");
        showToast(`Transcription failed — check the Parakeet tunnel (127.0.0.1:18793). ${err.message}`);
      }
      return;
    }
    if (statusRef.current !== "transcribing" || !sessionRef.current?.active) return;
    if (!text) {
      if (rec.barge) {
        openFollowupWindow();
        return;
      }
      setStatusSafe("idle");
      showToast("I didn't catch that — press Talk and try again.");
      return;
    }
    setUserCaption(text);
    runTurn(text);
  };

  const runTurn = async (text) => {
    turnCounterRef.current += 1;
    const turn = { id: turnCounterRef.current, ackFired: false, answerReady: false, toolNames: {}, toolResults: [] };
    turnRef.current = turn;
    const controller = new AbortController();
    abortRef.current = controller;
    setToolCalls([]);
    setPanel(null);
    setAssistantCaption("");
    setStatusSafe("thinking");
    let answerText = "";
    try {
      await streamAgent("/ai/chat", {
        message: text,
        mode: "voice",
        context: { visiblePanel: "voice", voiceMode: "visual" }
      }, (event) => {
        if (turnRef.current !== turn) return;
        if (event.type === "TEXT_MESSAGE_CONTENT") {
          answerText += event.delta || "";
          setAssistantCaption(stripMarkdownForCaption(answerText));
          return;
        }
        if (event.type === "TOOL_CALL_START") {
          turn.toolNames[event.toolCallId] = event.toolCallName;
          setToolCalls((current) => [...current, { id: event.toolCallId, name: event.toolCallName, status: "running" }]);
          if (!turn.ackFired) {
            turn.ackFired = true;
            playQuickAck(turn);
          }
          return;
        }
        if (event.type === "TOOL_CALL_RESULT") {
          turn.toolResults.push({
            name: turn.toolNames[event.toolCallId] || "tool",
            preview: JSON.stringify(event.result ?? {}).slice(0, 600)
          });
          setToolCalls((current) => current.map((call) => (
            call.id === event.toolCallId ? { ...call, status: event.result?.status || "done" } : call
          )));
          return;
        }
        if (event.type === "RUN_ERROR") {
          turn.runError = event.message || "The agent run failed.";
          return;
        }
        if (event.type === "RUN_FINISHED") {
          turn.runStatus = event.status || "completed";
        }
      }, { signal: controller.signal });
    } catch (err) {
      if (controller.signal.aborted || turnRef.current !== turn || !sessionRef.current?.active) return;
      setStatusSafe("idle");
      showToast(err.message);
      return;
    }
    if (controller.signal.aborted || turnRef.current !== turn || !sessionRef.current?.active) return;
    if (turn.runStatus === "aborted") {
      setStatusSafe("idle");
      return;
    }
    if (turn.runError) {
      setStatusSafe("idle");
      showToast(turn.runError);
      return;
    }
    const answer = answerText.trim();
    if (!answer) {
      setStatusSafe("idle");
      showToast("The agent finished without an answer — try rephrasing.");
      return;
    }
    setPanel({ turnId: turn.id, question: text, answer, html: "", view: "text", enriching: true });
    requestEnrichment(turn, text, answer);
    onTurnComplete?.();
    await speakAnswer(turn, answer);
  };

  const playQuickAck = async (turn) => {
    const ack = VOICE_ACKS[(turn.id - 1) % VOICE_ACKS.length];
    try {
      const spoken = await api("/voice/local/speak", { method: "POST", body: JSON.stringify({ text: ack }) });
      if (turnRef.current !== turn || turn.answerReady || playbackRef.current || !sessionRef.current?.active) return;
      await playAudioBase64(spoken.audioBase64, "ack");
    } catch {
      // The quick ack is best-effort; the answer audio still plays.
    }
  };

  const requestEnrichment = async (turn, question, answer) => {
    let html = "";
    try {
      const result = await api("/voice/enrich", {
        method: "POST",
        body: JSON.stringify({ question, answer, toolResults: turn.toolResults.slice(0, 8) })
      });
      html = result.html || "";
    } catch {
      // Enrichment is best-effort; the text answer stays available.
    }
    setPanel((current) => (current?.turnId === turn.id ? {
      ...current,
      html: html || current.html,
      view: html ? "rich" : current.view,
      enriching: false
    } : current));
  };

  const speakAnswer = async (turn, answer) => {
    let spoken = null;
    try {
      spoken = await api("/voice/local/speak", {
        method: "POST",
        body: JSON.stringify({ text: stripMarkdownForCaption(answer).slice(0, 1180) })
      });
    } catch (err) {
      if (turnRef.current !== turn || !sessionRef.current?.active) return;
      showToast(`Speech is unavailable — check the Kokoro service (127.0.0.1:8898). ${err.message}`);
      openFollowupWindow();
      return;
    }
    if (turnRef.current !== turn || !sessionRef.current?.active) return;
    turn.answerReady = true;
    if (playbackRef.current?.kind === "ack") stopPlayback();
    setStatusSafe("speaking");
    bargeInRef.current = { sustainMs: 0, prebuffer: [], prebufferMs: 0 };
    try {
      await playAudioBase64(spoken.audioBase64, "answer");
    } catch {
      // Playback failure falls through to the follow-up window below.
    }
    bargeInRef.current = null;
    if (turnRef.current !== turn || !sessionRef.current?.active) return;
    openFollowupWindow();
  };

  const openFollowupWindow = () => {
    if (!sessionRef.current?.active) return;
    setStatusSafe("followup");
    startRecording({ vad: true, followup: true });
    clearFollowupTimer();
    followupTimerRef.current = window.setTimeout(() => {
      const rec = recordingRef.current;
      if (statusRef.current === "followup" && rec && !rec.heardSpeech) {
        cancelRecording();
        setStatusSafe("idle");
      }
    }, VOICE_FOLLOW_UP_MS);
  };

  const interruptTurn = () => {
    abortRef.current?.abort();
    abortRef.current = null;
    turnRef.current = null;
    bargeInRef.current = null;
    stopPlayback();
    cancelRecording();
  };

  const interruptToListening = (hold = false, seedChunks = null) => {
    interruptTurn();
    if (!sessionRef.current?.active) return;
    startRecording({ vad: !hold, barge: Boolean(seedChunks), seedChunks });
  };

  const interruptToIdle = () => {
    interruptTurn();
    if (!sessionRef.current?.active) return;
    setStatusSafe("idle");
  };

  const beginTalk = (hold) => {
    const current = statusRef.current;
    if (current === "speaking" || current === "thinking") interruptToListening(hold);
    else if (current === "followup") promoteFollowup(hold);
    else if (current === "idle") startRecording({ vad: !hold });
  };

  const endTalkHold = () => {
    const rec = recordingRef.current;
    if (rec && !rec.vad && statusRef.current === "listening") finalizeRecording();
  };

  const handleTalkClick = () => {
    if (talkMode === "hold") return;
    if (statusRef.current === "listening") finalizeRecording();
    else beginTalk(false);
  };

  const startSession = async () => {
    if (statusRef.current !== "off") return;
    if (!navigator.mediaDevices?.getUserMedia) {
      showToast("Microphone access needs a secure context — open this dashboard on localhost or over HTTPS.");
      return;
    }
    const AudioContextImpl = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextImpl) {
      showToast("WebAudio is unavailable in this browser — voice mode cannot start.");
      return;
    }
    setStatusSafe("greeting");
    const generation = sessionGenRef.current;
    const cancelled = () => sessionGenRef.current !== generation;
    let stream = null;
    let audioContext = null;
    let capture = null;
    const discardStartup = () => {
      capture?.stop();
      if (stream) stopStream(stream);
      try {
        audioContext?.close?.()?.catch?.(() => {});
      } catch { /* context already closed */ }
    };
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
      if (cancelled()) {
        discardStartup();
        return;
      }
      audioContext = new AudioContextImpl();
      if (audioContext.resume) await audioContext.resume().catch(() => {});
      if (cancelled()) {
        discardStartup();
        return;
      }
      sessionRef.current = { audioContext, stream, active: true };
      capture = await createVoiceCapture(audioContext, stream, handleChunk);
      if (cancelled()) {
        discardStartup();
        return;
      }
      captureRef.current = { capture, sampleRate: audioContext.sampleRate || VOICE_TARGET_SAMPLE_RATE };
      setSessionStartedAt(Date.now());
      const greeting = VOICE_GREETINGS[Math.floor(Math.random() * VOICE_GREETINGS.length)];
      setAssistantCaption(greeting);
      let spoken = null;
      try {
        spoken = await api("/voice/local/speak", { method: "POST", body: JSON.stringify({ text: greeting }) });
      } catch (err) {
        if (!cancelled()) showToast(`Speech is unavailable — check the Kokoro service (127.0.0.1:8898). ${err.message}`);
      }
      if (cancelled() || !sessionRef.current?.active) return;
      if (spoken?.audioBase64) await playAudioBase64(spoken.audioBase64, "greeting");
      if (cancelled() || !sessionRef.current?.active) return;
      openFollowupWindow();
    } catch (err) {
      if (cancelled()) {
        discardStartup();
        return;
      }
      endSession();
      showToast(`Could not start the voice session — ${err.message}`);
    }
  };

  const endSession = () => {
    sessionGenRef.current += 1;
    clearPartialTimer();
    clearFollowupTimer();
    stopOrbMeter();
    abortRef.current?.abort();
    abortRef.current = null;
    turnRef.current = null;
    bargeInRef.current = null;
    recordingRef.current = null;
    stopPlayback();
    captureRef.current?.capture?.stop();
    captureRef.current = null;
    const session = sessionRef.current;
    sessionRef.current = null;
    if (session) {
      session.active = false;
      stopStream(session.stream);
      try {
        session.audioContext?.close?.()?.catch?.(() => {});
      } catch { /* context already closed */ }
    }
    setStatusSafe("off");
    setUserCaption("");
    setAssistantCaption("");
    setToolCalls([]);
    setPanel(null);
    setSessionStartedAt(0);
  };
  endSessionRef.current = endSession;

  useEffect(() => () => endSessionRef.current(), []);

  useEffect(() => {
    api("/ai/capabilities")
      .then((payload) => setCaps(payload.capabilities || payload))
      .catch(() => {});
  }, []);

  useEffect(() => {
    window.localStorage?.setItem("orchestrator-v2-voice-talk-mode", talkMode);
  }, [talkMode]);

  useEffect(() => {
    if (!sessionStartedAt) return undefined;
    const interval = window.setInterval(() => setClock(Date.now()), 1000);
    return () => window.clearInterval(interval);
  }, [sessionStartedAt]);

  useEffect(() => {
    const isTypingTarget = (target) => ["INPUT", "TEXTAREA", "SELECT"].includes(target?.tagName);
    const onKeyDown = (event) => {
      if (event.key === "Escape") {
        if (settingsOpen) {
          setSettingsOpen(false);
          return;
        }
        if (historyOpen) {
          setHistoryOpen(false);
          return;
        }
        if (["listening", "thinking", "speaking", "followup", "transcribing"].includes(statusRef.current)) interruptToIdle();
        return;
      }
      if (event.code === "Space" && !isTypingTarget(event.target)) {
        event.preventDefault();
        if (!event.repeat) beginTalk(true);
      }
    };
    const onKeyUp = (event) => {
      if (event.code === "Space" && !isTypingTarget(event.target)) endTalkHold();
    };
    const onBlur = () => endTalkHold();
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("keyup", onKeyUp);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("keyup", onKeyUp);
      window.removeEventListener("blur", onBlur);
    };
  }, [historyOpen, settingsOpen]);

  const active = status !== "off";
  const visualReady = !caps || caps.voiceModes?.visual !== false;
  const stateLabel = VOICE_STATE_LABELS[status] || "Standing by";
  const elapsed = sessionStartedAt ? Math.max(0, Math.floor((clock - sessionStartedAt) / 1000)) : 0;
  const timer = `${String(Math.floor(elapsed / 60)).padStart(2, "0")}:${String(elapsed % 60).padStart(2, "0")}`;

  return (
    <div className="voice-overlay" data-status={status} role="dialog" aria-label="Voice visual mode">
      <header className="voice-top">
        <div className="voice-top-group">
          <span className="voice-eyebrow voice-persona">{VOICE_PERSONA_NAME}</span>
          {active && <span className="voice-timer">{timer}</span>}
        </div>
        <div className="voice-tool-strip" aria-label="Tool activity">
          {toolCalls.slice(-4).map((call) => (
            <span className={`voice-tool-chip ${call.status === "running" ? "running" : "done"}`} key={call.id}>
              {call.status === "running" ? <RefreshCw size={11} className="spin" /> : <Check size={11} />}
              <span>{String(call.name || "tool").replace(/_/g, " ")}</span>
            </span>
          ))}
        </div>
        <div className="voice-top-group">
          <button className="voice-chip-btn" onClick={() => setHistoryOpen(true)}><History size={14} />History</button>
          <button className="voice-chip-btn" onClick={onExit}><LayoutDashboard size={14} />Dashboard</button>
        </div>
      </header>
      <main className={`voice-stage ${panel ? "has-panel" : ""}`}>
        <div className="voice-orb-wrap">
          <div className={`voice-orb ${status}`} ref={orbRef} aria-hidden="true">
            <span className="voice-orb-halo" />
            <span className="voice-orb-aurora" />
            <span className="voice-orb-core" />
            <span className="voice-orb-eyes">
              <span className="voice-orb-eye" />
              <span className="voice-orb-eye" />
            </span>
          </div>
        </div>
        <div className="voice-eyebrow voice-state-label" aria-live="polite">{stateLabel}</div>
        {status === "off" ? (
          <div className="voice-start-block">
            <p className="voice-caption assistant">Start a session, then ask about your cmux sessions, tasks, and PRs.</p>
            <button className="voice-start-btn" onClick={startSession} disabled={!visualReady}>
              <Mic size={17} />Start session
            </button>
            {!visualReady && (
              <p className="voice-hint">Voice services are offline — start Parakeet (127.0.0.1:18793) and Kokoro (127.0.0.1:8898), then reload.</p>
            )}
          </div>
        ) : (
          <div className="voice-captions">
            <p className="voice-caption user">{userCaption}</p>
            <p className="voice-caption assistant">{assistantCaption}</p>
          </div>
        )}
        {panel && (
          <section className="voice-panel">
            <div className="voice-panel-head">
              <span className="voice-eyebrow">Answer</span>
              <div className="voice-panel-toggle" role="tablist" aria-label="Answer format">
                <button
                  className={panel.view === "text" ? "active" : ""}
                  onClick={() => setPanel((current) => (current ? { ...current, view: "text" } : current))}
                >
                  Text
                </button>
                <button
                  className={panel.view === "rich" ? "active" : ""}
                  disabled={!panel.html}
                  onClick={() => setPanel((current) => (current ? { ...current, view: "rich" } : current))}
                >
                  {panel.enriching ? "Rich…" : "Rich"}
                </button>
              </div>
            </div>
            {panel.view === "rich" && panel.html ? (
              <iframe className="voice-panel-frame" sandbox="" srcDoc={panel.html} title="Rich answer" />
            ) : (
              <div className="voice-panel-markdown"><MarkdownMessage content={panel.answer} /></div>
            )}
          </section>
        )}
      </main>
      <footer className="voice-bottom">
        {active ? (
          <>
            <button className="voice-chip-btn danger" onClick={endSession}><X size={14} />End session</button>
            <button
              className={`voice-talk ${status}`}
              disabled={["greeting", "transcribing"].includes(status)}
              aria-pressed={status === "listening"}
              onClick={handleTalkClick}
              onPointerDown={talkMode === "hold" ? () => beginTalk(true) : undefined}
              onPointerUp={talkMode === "hold" ? endTalkHold : undefined}
              onPointerLeave={talkMode === "hold" ? endTalkHold : undefined}
            >
              <Mic size={19} />
              <span>Talk</span>
            </button>
            <div className="voice-settings-anchor">
              <button
                className="voice-chip-btn"
                aria-label="Voice settings"
                aria-expanded={settingsOpen}
                onClick={() => setSettingsOpen((open) => !open)}
              >
                <Settings size={14} />Settings
              </button>
              {settingsOpen && (
                <div className="voice-settings-pop" role="dialog" aria-label="Voice settings">
                  <span className="voice-eyebrow">Talk button</span>
                  <label>
                    <input type="radio" name="voice-talk-mode" checked={talkMode === "toggle"} onChange={() => setTalkMode("toggle")} />
                    <span>Tap to toggle — stops after silence</span>
                  </label>
                  <label>
                    <input type="radio" name="voice-talk-mode" checked={talkMode === "hold"} onChange={() => setTalkMode("hold")} />
                    <span>Hold to talk</span>
                  </label>
                  <small>Space holds the mic. Esc interrupts.</small>
                </div>
              )}
            </div>
          </>
        ) : (
          <span className="voice-hint quiet">Space holds the mic · Esc interrupts</span>
        )}
      </footer>
      {historyOpen && <VoiceHistoryDrawer onClose={() => setHistoryOpen(false)} />}
      {voiceToast && <div className="voice-toast" role="status">{voiceToast}</div>}
    </div>
  );
}

function VoiceHistoryDrawer({ onClose }) {
  const [messages, setMessages] = useState(null);
  const [error, setError] = useState("");
  useEffect(() => {
    api("/chat/messages")
      .then((payload) => setMessages((payload.messages || payload.chatMessages || []).slice().reverse()))
      .catch((err) => setError(err.message));
  }, []);
  const groups = useMemo(() => voiceHistoryGroups(messages || []), [messages]);
  return (
    <>
      <div className="voice-drawer-scrim" onClick={onClose} />
      <aside className="voice-drawer" role="dialog" aria-label="Conversation history">
        <div className="voice-drawer-head">
          <span className="voice-eyebrow">History</span>
          <button className="voice-chip-btn" onClick={onClose} aria-label="Close history"><X size={14} /></button>
        </div>
        <div className="voice-drawer-body">
          {error ? (
            <p className="voice-drawer-note">{error}</p>
          ) : messages === null ? (
            <p className="voice-drawer-note">Loading conversation…</p>
          ) : messages.length === 0 ? (
            <p className="voice-drawer-note">No conversation yet.</p>
          ) : groups.map((group) => (
            <div className="voice-drawer-day" key={`${group.day}-${group.items[0]?.id || "first"}`}>
              <div className="voice-eyebrow voice-drawer-divider">{group.day}</div>
              {group.items.map((message, index) => (
                <div className={`voice-drawer-message ${message.role}`} key={message.id || `${group.day}-${index}`}>
                  <div className="voice-drawer-meta">
                    <span className="voice-eyebrow">{message.role === "user" ? "You" : VOICE_PERSONA_NAME}</span>
                    {/voice/i.test(String(message.metadata?.mode || "")) && (
                      <span className="voice-mic-badge" title="Voice turn"><Mic size={10} /></span>
                    )}
                  </div>
                  <MarkdownMessage content={message.content} />
                </div>
              ))}
            </div>
          ))}
        </div>
      </aside>
    </>
  );
}

function ToolRunTimeline({ runId, status, dryRun }) {
  return <div className="tool-timeline-panel"><b>{runId}</b><span>{status || "running"}</span>{dryRun && <small>Dry-run fallback used until Fireworks is configured.</small>}</div>;
}

function NotImplementedCapabilityPanel({ capability, message, suggestedNextStep }) {
  return (
    <div className="not-implemented-panel">
      <ShieldAlert size={16} />
      <b>{capability}</b>
      <span>{message}</span>
      <small>{suggestedNextStep}</small>
    </div>
  );
}

function RightDock({ messages, activity, generatedPanels, streaming, onSend, onResizeStart }) {
  const [message, setMessage] = useState("");
  const [activityCollapsed, setActivityCollapsed] = useState(false);
  const groupedActivity = useMemo(() => groupActivity(activity), [activity]);
  const submit = (event) => {
    event.preventDefault();
    const text = message.trim();
    if (!text) return;
    setMessage("");
    onSend(text).catch(() => {});
  };
  return (
    <aside className={`right-dock ${activityCollapsed ? "activity-collapsed" : ""}`}>
      <div className="dock-resizer" onPointerDown={onResizeStart} role="separator" aria-orientation="vertical" aria-label="Resize global chat" />
      <div className="dock-section chat-section">
        <div className="panel-heading"><h2>Global Chat</h2><span>{messages.length}</span></div>
        <div className="chat-log">
          {messages.map((item, index) => (
            <div className={`chat-message ${item.role} ${item.streaming ? "streaming" : ""}`} key={item.id || `${item.role}-${index}`}>
              <MarkdownMessage content={item.content} />
            </div>
          ))}
        </div>
        <form className="chat-form" onSubmit={submit}>
          <input value={message} onChange={(event) => setMessage(event.target.value)} placeholder="Ask status..." />
          <button disabled={streaming}>{streaming ? <RefreshCw size={16} className="spin" /> : <Send size={16} />}</button>
        </form>
      </div>
      <div className="dock-section generated-mini-section">
        <div className="panel-heading"><h2>Generated Panels</h2><span>{generatedPanels.length}</span></div>
        <div className="generated-mini-list">
          {generatedPanels.slice(0, 5).map((panel) => <div key={panel.id}><Sparkles size={12} /><span>{panel.component}</span></div>)}
          {!generatedPanels.length && <div className="dock-empty">No generated panels yet</div>}
        </div>
      </div>
      <div className="dock-section activity-section">
        <div className="panel-heading activity-heading">
          <h2>Activity</h2>
          <button
            className="activity-collapse-btn"
            type="button"
            onClick={() => setActivityCollapsed((collapsed) => !collapsed)}
            aria-label={activityCollapsed ? "Expand activity" : "Collapse activity"}
            aria-expanded={!activityCollapsed}
          >
            {activityCollapsed ? <ChevronRight size={15} /> : <ChevronDown size={15} />}
            <span>{activity.length}</span>
          </button>
        </div>
        {!activityCollapsed && (
          <div className="activity-list">
            {groupedActivity.slice(0, 8).map((group) => (
              <div className="activity-group" key={group.id}>
                <div className="activity-group-head"><Circle size={9} /><strong>{group.title}</strong><span>{group.items.length}</span></div>
                {group.items.slice(0, 4).map((item) => (
                  <div className="activity-row" key={item.id || `${item.kind}-${item.createdAt}`}>
                    <div><strong>{item.title}</strong><span>{item.summary || item.kind}</span></div>
                  </div>
                ))}
              </div>
            ))}
          </div>
        )}
      </div>
    </aside>
  );
}

function MarkdownMessage({ content }) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      components={{
        table: ({ children }) => <div className="markdown-table-wrap"><table>{children}</table></div>
      }}
    >
      {String(content || "")}
    </ReactMarkdown>
  );
}

function NewTaskModal({ mode, orphan, onClose, onSubmit }) {
  const isOrphan = Boolean(mode === "orphan" && orphan);
  const inheritedWorkspace = orphanProjectDir(orphan);
  const [form, setForm] = useState({
    title: orphan?.title || "",
    workspaceDir: inheritedWorkspace,
    jiraUrl: "",
    launchType: "Empty shell",
    status: "To Do",
    priority: "Medium"
  });
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [pickingFolder, setPickingFolder] = useState(false);
  const setField = (key, value) => setForm((current) => ({ ...current, [key]: value }));
  const pickFolder = async () => {
    setPickingFolder(true);
    setError("");
    try {
      const result = await api("/folder-picker", { method: "POST", body: JSON.stringify({ currentPath: form.workspaceDir }) });
      if (result.path) setField("workspaceDir", result.path);
    } catch (err) {
      setError(err.message);
    } finally {
      setPickingFolder(false);
    }
  };
  const submit = async (event) => {
    event.preventDefault();
    if (!form.workspaceDir.trim()) return setError("Project folder required");
    if (!isOrphan && !form.launchType.trim()) return setError("Session launch type required");
    setSubmitting(true);
    setError("");
    try {
      await onSubmit({
        title: form.title.trim() || inferTaskTitle(form.jiraUrl) || "New Task",
        workspaceDir: form.workspaceDir,
        status: form.status,
        priority: form.priority,
        sessionLaunchType: isOrphan ? "Empty shell" : form.launchType,
        jira: form.jiraUrl ? { url: form.jiraUrl } : undefined,
        existingCmuxSession: orphan || undefined
      });
    } catch (err) {
      setError(err.message);
      setSubmitting(false);
    }
  };
  return (
    <div className="modal-overlay">
      <form className="new-task-modal" onSubmit={submit}>
        <button className="icon-btn modal-close" type="button" onClick={onClose}><X size={18} /></button>
        <div className="modal-title">
          <Sparkles size={19} />
          <h2>{mode === "orphan" ? "Turn Session into Task" : "Start New Task"}</h2>
        </div>
        <label className="numbered-field">
          <span>1. Project Folder</span>
          <small>{isOrphan ? "Inherited from the running cmux session." : "Select the workspace folder where this task will live."}</small>
          <div className={`field-control ${isOrphan ? "locked" : "folder-picker-control"}`} onClick={isOrphan ? undefined : pickFolder}>
            <Archive size={16} />
            <input
              value={form.workspaceDir}
              onChange={(event) => setField("workspaceDir", event.target.value)}
              placeholder="Choose a project folder..."
              readOnly
            />
            {isOrphan ? (
              <ShieldAlert size={15} />
            ) : (
              <button type="button" className="folder-picker-btn" onClick={(event) => { event.stopPropagation(); pickFolder(); }} disabled={pickingFolder}>
                {pickingFolder ? <RefreshCw size={15} className="spin" /> : <Folder size={15} />}
              </button>
            )}
          </div>
        </label>
        <label className="numbered-field">
          <span>{isOrphan ? "2. Jira Link (optional)" : "2. Jira Link (optional)"}</span>
          <small>Link this task to a Jira issue for context and tracking.</small>
          <input value={form.jiraUrl} onChange={(event) => setField("jiraUrl", event.target.value)} placeholder="Paste Jira issue link (e.g. https://company.atlassian.net/browse/IR-1427)" />
        </label>
        {!isOrphan && <div className="numbered-field">
          <span>3. Coding Agent Harness</span>
          <small>Choose the coding agent harness to power this task.</small>
          <div className="agent-options" role="radiogroup">
            {LAUNCH_TYPES.map((type) => (
              <button type="button" className={form.launchType === type ? "active" : ""} key={type} onClick={() => setField("launchType", type)}>
                <span className="agent-icon"><Terminal size={16} /></span>
                <strong>{type}</strong>
                <small>{launchDescription(type)}</small>
                <span className="radio-dot" />
              </button>
            ))}
          </div>
        </div>}
        <label className="numbered-field">
          <span>{isOrphan ? "3. Status" : "4. Status"}</span>
          <select value={form.status} onChange={(event) => setField("status", event.target.value)}>{STATUSES.map((status) => <option key={status}>{status}</option>)}</select>
        </label>
        {error && <div className="modal-error">{error}</div>}
        <div className="modal-actions">
          <button type="button" className="subtle-btn" onClick={onClose}>Cancel</button>
          <button className="primary-btn" disabled={submitting}>{submitting ? "Starting" : <><Play size={14} />Start Task</>}</button>
        </div>
      </form>
    </div>
  );
}

function LoadingState() {
  return <div className="loading-state"><RefreshCw size={24} />Loading Orchestrator V2</div>;
}

function Toast({ message, onDone }) {
  useEffect(() => {
    const timer = window.setTimeout(onDone, 2600);
    return () => window.clearTimeout(timer);
  }, [onDone]);
  return <div className="toast">{message}</div>;
}

function statusClass(status) {
  return String(status || "").toLowerCase().replace(/\s+/g, "-");
}

function clamp(value, min, max) {
  const number = Number(value);
  if (!Number.isFinite(number)) return min;
  return Math.max(min, Math.min(max, number));
}

function voiceStateLabel(mode, status) {
  if (mode === "text") return "Text only";
  return {
    idle: "Mic off",
    connecting: "Connecting",
    connected: "Listening",
    ready: "Ready",
    recording: "Listening",
    transcribing: "Processing audio",
    thinking: "Thinking",
    speaking: "Speaking",
    error: "Needs attention"
  }[status] || "Mic off";
}

function displayTaskStatus(task, approval) {
  const status = String(task?.status || "");
  if (approval?.status === "pending" && status === "In Progress") return "Running";
  return status || "To Do";
}

function displayRailStatus(item, hasApproval) {
  const status = String(item?.status || "");
  if (hasApproval && status === "In Progress") return "Running";
  return status || "Assigned";
}

function tagClass(tag) {
  const value = String(tag || "").toLowerCase();
  if (value.includes("design")) return "amber";
  if (value.includes("question") || value.includes("backend")) return "blue";
  if (value.includes("performance") || value.includes("refactor") || value.includes("blocked")) return "purple";
  if (value.includes("research")) return "cyan";
  if (value.includes("running") || value.includes("ready")) return "green";
  return "";
}

function displayWorkspacePath(value) {
  const text = String(value || "");
  const marker = ".qa/orchestrator-v2-pixel/fake-workspaces/";
  if (text.includes(marker)) {
    return `/workspaces/orchestrate-ai/${text.split(marker)[1]}`;
  }
  return text;
}

function orphanProjectDir(orphan) {
  const raw = orphan?.raw?.workspace || orphan?.raw?.raw?.workspace || orphan?.raw || {};
  return String(
    orphan?.cwd ||
    orphan?.currentDirectory ||
    raw.current_directory ||
    raw.cwd ||
    raw.currentDirectory ||
    ""
  );
}

function groupActivity(activity) {
  const groups = [];
  const byRun = new Map();
  for (const item of activity || []) {
    const runId = item.runId || item.run_id || "manual";
    if (!byRun.has(runId)) {
      const group = { id: runId, title: activityGroupTitle(runId), items: [] };
      byRun.set(runId, group);
      groups.push(group);
    }
    byRun.get(runId).items.push(item);
  }
  return groups;
}

function activityGroupTitle(runId) {
  if (runId === "manual") return "Manual activity";
  const short = runId.slice(-6);
  if (runId.startsWith("watch")) return `Watcher run ${short}`;
  if (runId.startsWith("chatrun") || runId.startsWith("run")) return `Agent run ${short}`;
  if (runId.startsWith("lifecycle")) return `Session lifecycle ${short}`;
  if (runId.startsWith("toolrun")) return `Tool run ${short}`;
  if (runId.startsWith("realtime")) return `Voice run ${short}`;
  return `Run ${short}`;
}

function voiceDayLabel(value) {
  const date = new Date(value || Date.now());
  if (!Number.isFinite(date.getTime())) return "Earlier";
  const startOfDay = (input) => new Date(input.getFullYear(), input.getMonth(), input.getDate()).getTime();
  const daysAgo = Math.round((startOfDay(new Date()) - startOfDay(date)) / 86400000);
  if (daysAgo <= 0) return "Today";
  if (daysAgo === 1) return "Yesterday";
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function voiceHistoryGroups(messages) {
  const groups = [];
  let current = null;
  for (const message of messages) {
    const day = voiceDayLabel(message.createdAt || message.created_at || message.timestamp);
    if (!current || current.day !== day) {
      current = { day, items: [] };
      groups.push(current);
    }
    current.items.push(message);
  }
  return groups;
}

function relativeAge(value) {
  if (!value) return "recently";
  const then = new Date(value).getTime();
  if (!Number.isFinite(then)) return "recently";
  const minutes = Math.max(1, Math.round((Date.now() - then) / 60000));
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}

function inferTaskTitle(jiraUrl) {
  const match = String(jiraUrl || "").match(/([A-Z][A-Z0-9]+-\d+)/i);
  return match ? `Work on ${match[1].toUpperCase()}` : "";
}

function launchDescription(type) {
  return {
    "Empty shell": "Start with no coding agent attached",
    Codex: "Best for general coding tasks",
    "Claude Code": "Strong reasoning and code understanding",
    OpenCode: "Fast, lightweight and open"
  }[type] || "";
}

const rootElement = document.getElementById("root");
if (rootElement) {
  createRoot(rootElement).render(<AppShell />);
}

export { AppShell };
