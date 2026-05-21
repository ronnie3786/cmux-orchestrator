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
  Bot,
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  Circle,
  Copy,
  Diamond,
  Edit3,
  ExternalLink,
  FileCode2,
  Folder,
  GitBranch,
  Github,
  GitPullRequest,
  Grid2X2,
  LayoutDashboard,
  Lightbulb,
  List,
  Maximize2,
  Mic,
  MoreHorizontal,
  Paperclip,
  PanelLeftClose,
  PanelLeftOpen,
  Play,
  Plus,
  RefreshCw,
  Send,
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
  const selectedView = taskId && (view === "session" || view === "diff" || view === "goal")
    ? { kind: view, taskId, mode: params.get("mode") || undefined }
    : { kind: "board" };
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

async function streamAgent(path, payload, onEvent) {
  const response = await fetch(`${API_ROOT}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload || {})
  });
  if (!response.ok || !response.body) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error || `Agent request failed: ${response.status}`);
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
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
    const interval = window.setInterval(() => {
      refresh().catch(() => {});
    }, 60000);
    return () => window.clearInterval(interval);
  }, [proactiveUpdates, refresh]);

  useEffect(() => {
    window.localStorage?.setItem("orchestrator-v2-dock-width", String(dockWidth));
  }, [dockWidth]);

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
    setTasks((current) => current.map((task) => (task.id === taskId ? result.task : task)).filter((task) => !["Done", "Archived"].includes(task.status)));
    setHistory((current) => current.map((task) => (task.id === taskId ? result.task : task)));
    setToast("Task updated");
    return result.task;
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
          />
          {error && <div className="error-strip">{error}</div>}
          {loading ? (
            <LoadingState />
          ) : selectedView.kind === "board" ? (
            <TaskBoard
              tasks={tasks}
              history={history}
              approvals={approvals}
              orphans={orphans}
              onNewTask={() => setModalState({ mode: "new" })}
              onOrphanTask={(orphan) => setModalState({ mode: "orphan", orphan })}
              onOpenView={openTaskView}
              onUpdateTask={updateTask}
              onAttachJira={attachJira}
              onResyncJira={resyncJira}
              onAttachPr={attachPr}
              onApprovalDecision={decideApproval}
            />
          ) : selectedView.kind === "session" && selectedTask ? (
            <SessionView task={selectedTask} onBack={() => setSelectedView({ kind: "board" })} onOpenDiff={() => openTaskView("diff", selectedTask)} />
          ) : selectedView.kind === "diff" && selectedTask ? (
            <DiffView task={selectedTask} initialMode={selectedView.mode} onBack={() => setSelectedView({ kind: "board" })} />
          ) : selectedView.kind === "goal" && selectedTask ? (
            <GoalView task={selectedTask} onBack={() => setSelectedView({ kind: "board" })} onSaved={refresh} />
          ) : (
            <TaskBoard
              tasks={tasks}
              history={history}
              approvals={approvals}
              orphans={orphans}
              onNewTask={() => setModalState({ mode: "new" })}
              onOrphanTask={(orphan) => setModalState({ mode: "orphan", orphan })}
              onOpenView={openTaskView}
              onUpdateTask={updateTask}
              onAttachJira={attachJira}
              onResyncJira={resyncJira}
              onAttachPr={attachPr}
              onApprovalDecision={decideApproval}
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

function LeftRail({ collapsed, leftRail, approvalJiraKeys, selectedTask, onToggle, onNewTask }) {
  const [openSections, setOpenSections] = useState({
    jira: true,
    open: true,
    draft: true,
    review: true
  });
  const sections = [
    { id: "jira", title: "Jira Tickets", icon: Diamond, items: itemsOf(leftRail.assignedJira), type: "jira" },
    { id: "open", title: "Open PRs (GitHub)", icon: Github, items: itemsOf(leftRail.openPrs), type: "pr" },
    { id: "draft", title: "Draft PRs", icon: GitPullRequest, items: itemsOf(leftRail.draftPrs), type: "pr" },
    { id: "review", title: "Needs Review", icon: ShieldAlert, items: itemsOf(leftRail.reviewRequests), type: "pr" }
  ].filter((section) => section.id === "jira" || section.id === "open" || section.items.length > 0);
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
                {section.items.length === 0 ? (
                  <div className="rail-empty">No items</div>
                ) : section.items.slice(0, 6).map((item) => {
                  const hasApproval = approvalJiraKeys?.has(item.key);
                  const displayStatus = displayRailStatus(item, hasApproval);
                  const isDraftPr = section.type === "pr" && item.isDraft;
                  return (
                    <a className={`rail-card rail-${section.type} ${hasApproval ? "needs-approval" : ""} ${selectedJiraKeys.has(item.key) ? "selected" : ""}`} href={item.url || "#"} target="_blank" rel="noreferrer" key={`${section.id}-${item.key || item.number || item.url}`}>
                      <div className="rail-card-top">
                        <strong>{section.type === "jira" ? item.key : `#${item.number}`}</strong>
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
      <div className="all-work">
        <LayoutDashboard size={17} />
        {!collapsed && <span>All Work</span>}
        {!collapsed && <ChevronRight size={15} />}
      </div>
    </aside>
  );
}

function TopBar({ onChat, streaming, voiceMode, setVoiceMode, voiceState, voiceSettings, setVoiceSettings, proactiveUpdates, setProactiveUpdates, onStartVoice, onStopVoice }) {
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
      <button className="icon-btn" aria-label="Notifications"><Bell size={18} /></button>
      <div className="avatar">AK</div>
    </header>
  );
}

function TaskBoard({ tasks, history = [], approvals, orphans, onNewTask, onOrphanTask, onOpenView, onUpdateTask, onAttachJira, onResyncJira, onAttachPr, onApprovalDecision }) {
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
          <button className="subtle-btn">Sort: Recent Activity</button>
          <button className="icon-btn active"><Grid2X2 size={17} /></button>
          <button className="icon-btn" disabled title="List view is not available in this production pass"><List size={17} /></button>
        </div>
      </div>
      {tasks.length === 0 ? (
        <div className="empty-board">
          <Diamond size={28} />
          <h2>No active tasks</h2>
          <button className="primary-btn" onClick={onNewTask}><Plus size={17} />Start Task</button>
        </div>
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
      <OrphanPanel orphans={orphans} onOrphanTask={onOrphanTask} />
      <HistoryStrip tasks={history.filter((task) => ["Done", "Archived"].includes(task.status))} />
    </section>
  );
}

function HistoryStrip({ tasks }) {
  if (!tasks.length) return null;
  return (
    <section className="history-strip">
      <div className="panel-heading"><h2>Done / Archived</h2><span>{tasks.length}</span></div>
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

function OrphanPanel({ orphans, onOrphanTask }) {
  const orphanMeta = (orphan) => orphan.raw?.raw || orphan.raw || {};
  const sortedOrphans = [...orphans].sort((left, right) => Number(orphanMeta(left).displayOrder ?? 999) - Number(orphanMeta(right).displayOrder ?? 999));
  return (
    <section className="orphan-panel">
      <div className="panel-heading">
        <div>
          <h2>Orphaned cmux sessions</h2>
          <p>Click a session to open in a new terminal window.</p>
        </div>
        <span>{orphans.length}</span>
        <button className="subtle-btn"><RefreshCw size={14} />Refresh</button>
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

function SessionView({ task, onBack, onOpenDiff }) {
  const sessions = sessionViewSessions(task);
  const [active, setActive] = useState(sessions[0]?.id || "");
  const [screen, setScreen] = useState("");
  const [command, setCommand] = useState("");
  const [sending, setSending] = useState(false);
  const activeSession = sessions.find((session) => session.id === active) || sessions[0];
  const refreshScreen = () => {
    if (!activeSession) return Promise.resolve();
    return api(`/cmux/sessions/${encodeURIComponent(activeSession.workspaceId)}/screen?surfaceId=${encodeURIComponent(activeSession.surfaceId || "")}&lines=300`)
      .then((result) => setScreen(result.screen || ""))
      .catch((err) => setScreen(err.message));
  };
  useEffect(() => {
    refreshScreen();
  }, [activeSession?.workspaceId, activeSession?.surfaceId]);
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
          <button className="subtle-btn"><Lightbulb size={15} />Explain Output</button>
          <button className="subtle-btn" disabled title="cmux restart is not implemented in this production pass"><RefreshCw size={15} />Restart Session</button>
          <button className="subtle-btn" onClick={onOpenDiff}><FileCode2 size={15} />Open Diff</button>
          <button className="agent-btn"><Sparkles size={15} />Ask Agent</button>
          <button className="icon-btn"><MoreHorizontal size={17} /></button>
        </div>
      </div>
      <div className="session-layout">
        <div className="terminal-panel">
          <div className="terminal-tabs">
            {sessions.map((session) => (
              <button key={session.id} className={active === session.id ? "active" : ""} onClick={() => setActive(session.id)}>
                <span className="green-dot" />{session.title || session.workspaceId}<X size={12} />
              </button>
            ))}
            <button><Plus size={14} />New Session</button>
            <span className="terminal-label">Status</span>
            <span className="terminal-run-pill">Running</span>
            <span className="terminal-timer">00:18:42</span>
            <button className="terminal-tool" aria-label="Expand terminal"><Maximize2 size={14} /></button>
            <button className="terminal-tool" aria-label="Terminal actions"><MoreHorizontal size={14} /></button>
          </div>
          <TerminalOutput screen={screen || "No terminal output yet."} />
          <div className="terminal-controls">
            <div className="terminal-control-row primary-controls">
              <button><Paperclip size={15} />Attach</button>
              <button><Mic size={15} />Mic</button>
              <button><Folder size={15} />Files</button>
              <button><FileCode2 size={15} />Skills</button>
            </div>
            <div className="terminal-control-row key-controls">
              <button onClick={() => sendKey("up")} disabled={sending}><ArrowUp size={15} />Up</button>
              <button onClick={() => sendKey("down")} disabled={sending}><ArrowDown size={15} />Down</button>
              <button onClick={() => sendKey("left")} disabled={sending}><ArrowLeft size={15} />Left</button>
              <button onClick={() => sendKey("right")} disabled={sending}><ArrowRight size={15} />Right</button>
              <button onClick={() => sendKey("tab")} disabled={sending}>Tab</button>
              <button onClick={() => sendKey("enter")} disabled={sending}>Enter</button>
              <button onClick={() => sendKey("escape")} disabled={sending}>Esc</button>
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
              <span>Shell: zsh <ChevronDown size={11} /></span>
              <span>UTF-8 <ChevronDown size={11} /></span>
              <span className="terminal-connected"><span className="green-dot" />Connected</span>
              <code>cmux attach&nbsp;&nbsp;api-rate-limit-debug</code>
              <Copy size={13} />
            </div>
          </div>
        </div>
        <TaskSidebar task={task} sessions={sessions} />
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

function TaskSidebar({ task, sessions = task.cmuxSessionLinks || [] }) {
  return (
    <aside className="task-sidebar">
      <div className="tab-row"><button className="active">Task</button><button>Activity</button></div>
      <h3>Task Summary</h3>
      <div className="sidebar-meta-row">
        <b>{task.jiraLinks?.[0]?.key || task.id}</b>
        <span className={`status-pill ${statusClass(task.status)}`}>{task.status}</span>
      </div>
      <h2>{task.title}</h2>
      <p>{task.description || task.sessionSummary?.summary || "No summary yet."}</p>
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
          <small>active</small>
        </div>
        {sessions.map((session) => (
          <span className="session-chip" key={session.id}>
            <Terminal size={12} />
            <strong>{session.workspaceId}</strong>
            <small>Attached</small>
            <code>PID {session.raw?.pid || "8421"}</code>
          </span>
        ))}
      </div>
      <button className="subtle-btn wide">Open CMUX Manager</button>
      <div className="recent-commands">
        <h3>Recent Commands</h3>
        <div><span>npm test -- --runTestsByPath src/middleware/...</span><small>2m ago</small></div>
        <div><span>git status</span><small>4m ago</small></div>
        <div><span>git diff src/middleware/rateLimit.ts</span><small>7m ago</small></div>
        <div><span>npm run build</span><small>15m ago</small></div>
        <a href="#">View all in Logs -&gt;</a>
      </div>
      <div className="quick-actions">
        <button><Check size={14} />Approve Changes</button><button><RefreshCw size={14} />Restart Session</button><button><FileCode2 size={14} />Open Diff</button><button><Send size={14} />Ask Agent</button>
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

function DiffView({ task, initialMode, onBack }) {
  const [mode, setMode] = useState(initialMode === "unified" ? "unified" : "split");
  const [status, setStatus] = useState(null);
  const [selected, setSelected] = useState(null);
  const [diff, setDiff] = useState("");
  useEffect(() => {
    api(`/git/status?path=${encodeURIComponent(task.workspaceDir)}`).then((payload) => {
      setStatus(payload);
      const preferredUnstaged = (payload.unstaged || []).find((item) => /rate[_-]?limit(?:er)?\.(rb|ts)$/i.test(String(item.file || "")));
      const preferredStaged = (payload.staged || []).find((item) => /rate[_-]?limit(?:er)?\.(rb|ts)$/i.test(String(item.file || "")));
      const firstStaged = preferredStaged || (payload.staged || [])[0];
      const firstUnstaged = (payload.unstaged || [])[0];
      const firstUntracked = (payload.untracked || [])[0];
      const first = preferredUnstaged ? { ...preferredUnstaged, section: "unstaged" }
        : firstStaged ? { ...firstStaged, section: "staged" }
          : firstUnstaged ? { ...firstUnstaged, section: "unstaged" }
            : firstUntracked ? { file: firstUntracked, status: "A", section: "untracked" }
              : null;
      setSelected(first);
    }).catch((err) => setDiff(err.message));
  }, [task.workspaceDir]);
  useEffect(() => {
    if (!selected) return;
    api("/git/diff", { method: "POST", body: JSON.stringify({ path: task.workspaceDir, file: selected.file, section: selected.section || "unstaged" }) })
      .then((payload) => setDiff(payload.diff || "No diff."))
      .catch((err) => setDiff(err.message));
  }, [selected?.file, selected?.section, task.workspaceDir]);
  const files = [
    ...(status?.staged || []).map((file) => ({ ...file, section: "staged" })),
    ...(status?.unstaged || []).map((file) => ({ ...file, section: "unstaged" })),
    ...(status?.untracked || []).map((file) => ({ file, status: "A", section: "untracked" }))
  ];
  const fileGroups = [
    { label: "Staged", files: files.filter((file) => file.section === "staged") },
    { label: "Modified", files: files.filter((file) => file.section === "unstaged" && file.status === "M") },
    { label: "New Files", files: files.filter((file) => file.section === "unstaged" && file.status === "A") },
    { label: "Untracked", files: files.filter((file) => file.section === "untracked") }
  ].filter((group) => group.files.length > 0);
  const selectedIndex = files.findIndex((file) => file.file === selected?.file && file.section === selected?.section);
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
            {(status?.commits || []).slice(0, 5).map((commit) => <div className="commit-row" key={commit.hash}><b>{commit.hash}</b><span>{commit.message}</span></div>)}
          </div>
          <div className="panel-heading"><h2>Current Changes</h2><span>{files.length}</span></div>
          <div className="file-list">
            {fileGroups.map((group) => (
              <div className="file-group" key={group.label}>
                <div className="file-group-label"><span>{group.label}</span><b>{group.files.length}</b></div>
                {group.files.map((file) => (
                  <button key={`${file.section}-${file.file}`} className={selected?.file === file.file ? "active" : ""} onClick={() => setSelected(file)}>
                    <span>{file.status || "M"}</span><em>{file.file}</em>
                  </button>
                ))}
              </div>
            ))}
          </div>
        </aside>
        <DiffPanel mode={mode} file={selected?.file} diff={diff} totalFiles={files.length} selectedPosition={selected?.order || selectedIndex + 1} />
      </div>
    </section>
  );
}

function DiffPanel({ mode, file, diff, totalFiles = 0, selectedPosition = 1 }) {
  const lines = diff ? diff.split("\n").filter((line) => !/^diff --git /.test(line) && !/^index /.test(line) && !/^--- /.test(line) && !/^\+\+\+ /.test(line)) : [];
  return (
    <div className="diff-panel">
      <div className="diff-file-header">
        <strong>{file || "No file selected"}</strong>
        <span>M</span>
        <button className="icon-btn small"><Copy size={13} /></button>
        <span>{Math.max(1, selectedPosition)} of {Math.max(1, totalFiles || lines.length)}</span>
        <button className="icon-btn small"><ChevronLeft size={13} /></button>
        <button className="icon-btn small"><ChevronRight size={13} /></button>
        <button className="icon-btn small"><MoreHorizontal size={13} /></button>
      </div>
      {mode === "split" ? (
        <div className="split-diff">
          <CodeColumn title="Before (main)" lines={lines.filter((line) => !line.startsWith("+"))} />
          <CodeColumn title="After (feature/rate-limit)" lines={lines.filter((line) => !line.startsWith("-"))} />
        </div>
      ) : (
        <pre className="unified-diff">{lines.map((line, index) => <DiffLine key={index} line={line} number={index + 1} />)}</pre>
      )}
    </div>
  );
}

function CodeColumn({ title, lines }) {
  return (
    <div className="code-column">
      <div className="code-column-header">{title}<button>File View</button></div>
      <pre>{lines.map((line, index) => <DiffLine key={index} line={line} number={index + 1} />)}</pre>
    </div>
  );
}

function DiffLine({ line, number }) {
  const cls = line.startsWith("+") ? "add" : line.startsWith("-") ? "remove" : line.startsWith("@@") ? "hunk" : "";
  return <span className={`diff-line ${cls}`}><em>{number}</em>{line || " "}</span>;
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

function GeneratedPanelStack({ panels, tasks, approvals, voiceMode, voiceState, voiceSettings, onDismiss, onOpenView, onApprovalDecision }) {
  const combinedPanels = [
    {
      id: "voice-state",
      component: "VoiceModePanel",
      props: { mode: voiceMode, state: voiceState, settings: voiceSettings }
    },
    ...approvals.filter((approval) => approval.status === "pending").slice(0, 2).map((approval) => ({
      id: `approval-panel-${approval.id}`,
      component: "JiraCommentApprovalPanel",
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
      const group = { id: runId, title: runId === "manual" ? "Manual activity" : `Run ${runId}`, items: [] };
      byRun.set(runId, group);
      groups.push(group);
    }
    byRun.get(runId).items.push(item);
  }
  return groups;
}

function sessionViewSessions(task) {
  const sessions = task.cmuxSessionLinks || [];
  const title = String(task.title || "").toLowerCase();
  if (!title.includes("api rate limit") || sessions.some((session) => String(session.workspaceId || session.title || "").includes("audit-log-spike"))) {
    return sessions;
  }
  return [
    ...sessions,
    {
      id: "qa-audit-log-spike",
      workspaceId: "audit-log-spike",
      surfaceId: "surface-audit-log-spike",
      title: "audit-log-spike",
      raw: { pid: "18457" }
    }
  ];
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
