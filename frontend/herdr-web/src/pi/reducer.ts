/**
 * Deterministic TS port of `herdr-harness-ios/State/PiConversationReducer.swift`
 * (the Swift file is the source of truth; doc 01 §4.4 agrees with it).
 *
 * Method mapping (Swift → TS):
 *  - `Effect` enum → `PiConversationEffect` string union
 *  - `replace(with:)` → `replace(snapshot)`
 *  - `apply(_:)` → `apply(envelope)`
 *  - `removeInteraction(id:)` → `removeInteraction(id)`
 *  - `PiConversationStore.consume(_:)` core (stream loop, exit on
 *    `.needsSnapshot`) → `consumePiConversationStream` (store-level
 *    connection/error bookkeeping stays with the store port, P6-run-C)
 *
 * Swift `Date?` fields are epoch-millisecond `number | null`; `Date()`
 * (".now" defaults in the Swift reducer) becomes `Date.now()`.
 *
 * Cursor de-dup: `remember(cursor:)` in Swift is a Set + insertion-ordered
 * array; once the order array exceeds 2048 it evicts the oldest 512 from
 * both. Ported 1:1 with `Set` + `string[]` (no new data structure needed —
 * the array IS the LRU order).
 */
import {
  piArray,
  piBool,
  piContextUsageFrom,
  piEnvelopeEventType,
  piKey,
  piModelIdentityFrom,
  piString,
  piStringValue,
  piTimestampFrom,
  piValue,
} from "./types";
import type {
  PiAssistantBlock,
  PiContextUsage,
  PiConversationEnvelope,
  PiConversationItem,
  PiConversationNoticeTone,
  PiConversationPhase,
  PiConversationSnapshot,
  PiConversationStreamEvent,
  PiConversationTurn,
  PiJSONValue,
  PiModelIdentity,
  PiPendingInteraction,
  PiPendingInteractionKind,
  PiThinkingBlock,
  PiToolInvocation,
  PiToolInvocationStatus,
  PiUserMessage,
} from "./types";

/** Swift `PiConversationReducer.Effect`. */
export type PiConversationEffect =
  | "none"
  | "needsSnapshot"
  | "completed"
  | "failed"
  | "interactionRequested";

export class PiConversationReducer {
  turns: PiConversationTurn[] = [];
  pendingInteractions: PiPendingInteraction[] = [];
  phase: PiConversationPhase = "idle";
  cursor: string | null = null;
  sessionID: string | null = null;
  isTruncated = false;
  bridgeConnected = false;
  contextUsage: PiContextUsage | null = null;
  currentModel: PiModelIdentity | null = null;
  thinkingLevel: string | null = null;

  private activeTurnID: string | null = null;
  private activeMessageID: string | null = null;
  private seenCursors = new Set<string>();
  private cursorOrder: string[] = [];

  replace(snapshot: PiConversationSnapshot): void {
    this.turns = [];
    this.pendingInteractions = [];
    this.seenCursors = new Set();
    this.cursorOrder = [];
    this.activeTurnID = null;
    this.activeMessageID = null;
    this.cursor = snapshot.cursor;
    this.sessionID = sessionIdentifier(snapshot.session);
    this.isTruncated = snapshot.truncated;
    this.bridgeConnected = snapshot.connected;
    this.contextUsage = piContextUsageFrom(piKey(snapshot.state, "context"));
    this.currentModel = piModelIdentityFrom(piKey(snapshot.state, "model"));
    this.thinkingLevel = piString(snapshot.state, "thinkingLevel", "thinking_level");

    for (const entry of snapshot.entries) {
      this.projectSessionEntry(entry);
    }
    this.pendingInteractions = snapshot.pendingInteractions
      .map((value) => interactionFrom(value))
      .filter((interaction): interaction is PiPendingInteraction => interaction !== null);
    this.phase = isWorking(snapshot.state) ? "working" : "idle";
    if (this.phase === "idle") {
      this.markTurnsSettled();
    } else {
      const last = this.turns[this.turns.length - 1];
      if (last) {
        last.isActive = true;
        this.activeTurnID = last.id;
      }
    }
  }

  apply(envelope: PiConversationEnvelope): PiConversationEffect {
    const event = envelope.event;
    const type = normalizedEventType(piEnvelopeEventType(envelope));

    // Ready and reset frames describe the replay cursor itself, rather
    // than a journal entry. The server can legitimately give both frames
    // the same cursor, so they must bypass durable-event de-duplication.
    if (type === "ready") {
      if (envelope.cursor !== null) this.cursor = envelope.cursor;
      this.bridgeConnected = piBool(event, "connected") ?? envelope.connected ?? false;
      return "none";
    }
    if (type === "stream.reset") {
      if (envelope.cursor !== null) this.cursor = envelope.cursor;
      return "needsSnapshot";
    }

    if (envelope.cursor !== null) {
      if (this.seenCursors.has(envelope.cursor)) return "none";
      this.remember(envelope.cursor);
      this.cursor = envelope.cursor;
    }

    if (envelope.sessionID !== null) {
      if (this.sessionID !== null && this.sessionID !== envelope.sessionID) {
        return "needsSnapshot";
      }
      this.sessionID = envelope.sessionID;
    }

    switch (type) {
      case "bridge.connection":
        this.bridgeConnected = piBool(event, "connected") ?? envelope.connected ?? false;
        return "none";
      case "model_select": {
        const updated = piModelIdentityFrom(piKey(event, "model"));
        if (updated !== null) this.currentModel = updated;
        return "none";
      }
      case "thinking_level_select": {
        const level = piString(event, "level");
        if (level !== null) this.thinkingLevel = level;
        return "none";
      }
      case "session_tree":
      case "session_compact":
        // Both can replace the current context without changing the Pi
        // session ID, so the only safe projection is authoritative reload.
        return "needsSnapshot";
      case "session_start":
      case "session_switch":
        return this.sessionChanged(event) ? "needsSnapshot" : "none";
      case "agent_start":
      case "turn_start":
        this.phase = "working";
        // Pi emits agent/turn start before the user message. Wait for the
        // first semantic item so we do not render an empty orphan rail.
        return "none";
      case "agent_end":
        return "none";
      case "turn_end":
        // Per-turn context reading lets the meter update live during a run.
        // Keep the last known value while Pi reports unknown (post-compaction).
        this.contextUsage =
          piContextUsageFrom(piKey(event, "context")) ?? this.contextUsage;
        return "none";
      case "agent_settled": {
        const wasWorking = this.phase === "working";
        this.phase = "idle";
        this.markTurnsSettled();
        return wasWorking ? "completed" : "none";
      }
      case "message_start":
        this.projectLiveMessage(piKey(event, "message"), envelope, false);
        return "none";
      case "message_update":
        this.projectMessageUpdate(event, envelope);
        return "none";
      case "message_end": {
        const message = piKey(event, "message");
        this.projectLiveMessage(message, envelope, true);
        if (messageFailed(message)) {
          this.phase = "failed";
          return "failed";
        }
        return "none";
      }
      case "tool_execution_start":
        this.upsertToolExecution(event, "running", false);
        return "none";
      case "tool_execution_update":
        this.upsertToolExecution(event, "running", false);
        return "none";
      case "tool_execution_end": {
        const failed = piBool(event, "isError", "is_error") ?? false;
        this.upsertToolExecution(event, failed ? "failed" : "succeeded", true);
        return failed ? "failed" : "none";
      }
      case "extension_ui_request":
      case "interaction_request": {
        const interaction = interactionFrom(event);
        if (interaction !== null) {
          this.upsertInteraction(interaction);
          return "interactionRequested";
        }
        return "none";
      }
      case "extension_ui_response":
      case "interaction_response":
      case "interaction_cancelled": {
        const id = piString(event, "id", "interactionId", "interaction_id");
        if (id !== null) {
          this.pendingInteractions = this.pendingInteractions.filter(
            (pending) => pending.id !== id,
          );
        }
        return "none";
      }
      case "error":
        this.appendNotice(
          `event:${envelope.cursor ?? crypto.randomUUID()}`,
          "Pi reported an error",
          piString(event, "message", "error"),
          "error",
        );
        this.phase = "failed";
        return "failed";
      default:
        return "none";
    }
  }

  removeInteraction(id: string): void {
    this.pendingInteractions = this.pendingInteractions.filter(
      (pending) => pending.id !== id,
    );
  }

  // -------------------------------------------------------------------
  // Snapshot entry projection
  // -------------------------------------------------------------------

  private projectSessionEntry(entry: PiJSONValue): void {
    const type = piString(entry, "type") ?? "unknown";
    const entryID = piString(entry, "id") ?? `entry:${this.turns.length}`;
    const timestamp = piTimestampFrom(piValue(entry, "timestamp"));
    if (type === "message") {
      this.projectPersistedMessage(piKey(entry, "message"), entryID, timestamp);
    } else if (type === "compaction") {
      this.appendNotice(entryID, "Context compacted", piString(entry, "summary"), "neutral", timestamp);
    } else if (type === "branch_summary") {
      this.appendNotice(entryID, "Branch context summarized", piString(entry, "summary"), "neutral", timestamp);
    } else if (type === "model_change") {
      const provider = piString(entry, "provider");
      const model = piString(entry, "modelId", "model_id");
      const detail = [provider, model]
        .filter((part): part is string => part !== null)
        .join(" / ");
      this.appendNotice(
        entryID,
        "Model changed",
        detail === "" ? null : detail,
        "neutral",
        timestamp,
      );
    } else if (type === "custom_message") {
      if (piBool(entry, "display") === false) return;
      const text = textFrom(piKey(entry, "content"));
      if (text === "") return;
      this.appendNotice(
        entryID,
        piString(entry, "customType", "custom_type") ?? "Pi",
        text,
        "neutral",
        timestamp,
      );
    }
  }

  private projectPersistedMessage(
    message: PiJSONValue | null,
    entryID: string,
    timestamp: number | null,
  ): void {
    if (message === null) return;
    const role = piString(message, "role");
    if (role === "user") {
      this.startTurn(`turn:${entryID}`, {
        id: entryID,
        text: textFrom(piKey(message, "content")),
        timestamp: piTimestampFrom(piKey(message, "timestamp")) ?? timestamp,
      });
    } else if (role === "assistant") {
      this.ensureActiveTurn(entryID);
      this.activeMessageID = entryID;
      this.syncAssistantMessage(message, entryID, true);
    } else if (role === "toolResult" || role === "tool_result") {
      this.ensureActiveTurn(entryID);
      this.projectToolResult(message, entryID);
    }
  }

  // -------------------------------------------------------------------
  // Live message projection
  // -------------------------------------------------------------------

  private projectLiveMessage(
    message: PiJSONValue | null,
    envelope: PiConversationEnvelope,
    final: boolean,
  ): void {
    if (message === null) return;
    const messageID = liveMessageIdentifier(message, envelope);
    const role = piString(message, "role");
    if (role === "user") {
      const text = textFrom(piKey(message, "content"));
      const last = this.turns[this.turns.length - 1];
      if (last && last.user?.text === text && last.items.length === 0) {
        this.activeTurnID = last.id;
      } else {
        this.startTurn(`turn:${messageID}`, {
          id: messageID,
          text,
          timestamp: piTimestampFrom(piKey(message, "timestamp")),
        });
      }
    } else if (role === "assistant") {
      this.phase = final && messageFailed(message) ? "failed" : "working";
      this.ensureActiveTurn(messageID);
      this.activeMessageID = messageID;
      this.syncAssistantMessage(message, messageID, final);
    } else if (role === "toolResult" || role === "tool_result") {
      this.ensureActiveTurn(messageID);
      this.projectToolResult(message, messageID);
    }
  }

  private projectMessageUpdate(event: PiJSONValue, envelope: PiConversationEnvelope): void {
    const message = piKey(event, "message");
    const messageID = this.activeMessageID ?? liveMessageIdentifier(message, envelope);
    this.activeMessageID = messageID;
    this.ensureActiveTurn(messageID);

    const assistantEvent = piValue(event, "assistantMessageEvent", "assistant_message_event");
    const updateType = piString(assistantEvent, "type") ?? "";
    const contentIndex = intFrom(
      piStringValue(piValue(assistantEvent, "contentIndex", "content_index")) ?? "0",
    );
    if (updateType === "text_start" || updateType === "text_delta" || updateType === "text_end") {
      const id = `${messageID}:text:${contentIndex}`;
      const existing = this.assistantBlock(id);
      let text: string;
      let status: PiAssistantBlock["status"];
      let timestamp: number | null;
      if (updateType === "text_start") {
        text = existing?.text ?? "";
        status = "streaming";
        timestamp = existing?.timestamp ?? Date.now();
      } else if (updateType === "text_delta") {
        text = (existing?.text ?? "") + (piString(assistantEvent, "delta") ?? "");
        status = "streaming";
        timestamp = existing?.timestamp ?? Date.now();
      } else {
        text = piString(assistantEvent, "content") ?? existing?.text ?? "";
        status = "complete";
        timestamp = existing?.timestamp ?? null;
      }
      this.upsertAssistant({
        id,
        text,
        status,
        timestamp,
      });
    } else if (
      updateType === "thinking_start" ||
      updateType === "thinking_delta" ||
      updateType === "thinking_end"
    ) {
      const id = `${messageID}:thinking:${contentIndex}`;
      const existing = this.thinkingBlock(id);
      let text: string;
      let isStreaming: boolean;
      let startedAt: number | null;
      if (updateType === "thinking_start") {
        text = existing?.text ?? "";
        isStreaming = true;
        startedAt = existing?.startedAt ?? Date.now();
      } else if (updateType === "thinking_delta") {
        text = (existing?.text ?? "") + (piString(assistantEvent, "delta") ?? "");
        isStreaming = true;
        startedAt = existing?.startedAt ?? Date.now();
      } else {
        text = piString(assistantEvent, "content") ?? existing?.text ?? "";
        isStreaming = false;
        startedAt = existing?.startedAt ?? null;
      }
      this.upsertThinking({
        id,
        text,
        isStreaming,
        isRedacted: existing?.isRedacted ?? false,
        startedAt,
      });
    } else if (updateType === "toolcall_start") {
      const callID = `pending:${messageID}:${contentIndex}`;
      this.upsertTool({
        id: `tool:${callID}`,
        callID,
        name: "Preparing tool",
        arguments: null,
        result: null,
        status: "waiting",
        startedAt: Date.now(),
        finishedAt: null,
      });
    } else if (updateType === "toolcall_delta") {
      const callID = `pending:${messageID}:${contentIndex}`;
      const existing = this.tool(callID);
      const accumulated = (piStringValue(existing?.arguments) ?? "") + (piString(assistantEvent, "delta") ?? "");
      this.upsertTool({
        id: `tool:${callID}`,
        callID,
        name: existing?.name ?? "Preparing tool",
        arguments: accumulated === "" ? null : accumulated,
        result: null,
        status: "waiting",
        startedAt: existing?.startedAt ?? Date.now(),
        finishedAt: null,
      });
    } else if (updateType === "toolcall_end") {
      const pendingCallID = `pending:${messageID}:${contentIndex}`;
      this.removeTool(pendingCallID);
      const toolCall = piKey(assistantEvent, "toolCall");
      const callID = piString(toolCall, "id");
      if (toolCall !== null && callID !== null) {
        this.upsertTool({
          id: `tool:${callID}`,
          callID,
          name: piString(toolCall, "name") ?? "Tool",
          arguments: piValue(toolCall, "arguments", "args"),
          result: null,
          status: "waiting",
          startedAt: Date.now(),
          finishedAt: null,
        });
      }
    } else if (updateType === "done") {
      this.syncAssistantMessage(piKey(assistantEvent, "message") ?? message, messageID, true);
    } else if (updateType === "error") {
      this.syncAssistantMessage(piKey(assistantEvent, "error") ?? message, messageID, true);
      this.phase = "failed";
    } else {
      this.syncAssistantMessage(message, messageID, false);
    }
  }

  private syncAssistantMessage(
    message: PiJSONValue | null,
    messageID: string,
    final: boolean,
  ): void {
    if (message === null) return;
    const content = piArray(piKey(message, "content")) ?? [];
    const timestamp = piTimestampFrom(piKey(message, "timestamp"));
    const stopReason = piString(message, "stopReason", "stop_reason");
    const errorMessage = piString(message, "errorMessage", "error_message");
    const failed = stopReason === "error" || stopReason === "aborted";

    content.forEach((part, index) => {
      const partType = piString(part, "type");
      if (partType === "text") {
        this.upsertAssistant({
          id: `${messageID}:text:${index}`,
          text: piString(part, "text") ?? "",
          status: failed ? { failed: true, detail: errorMessage } : final ? "complete" : "streaming",
          timestamp,
        });
      } else if (partType === "thinking") {
        this.upsertThinking({
          id: `${messageID}:thinking:${index}`,
          text: piString(part, "thinking") ?? "",
          isStreaming: !final,
          isRedacted: piBool(part, "redacted") ?? false,
          startedAt: timestamp,
        });
      } else if (partType === "toolCall" || partType === "tool_call") {
        const callID = piString(part, "id");
        if (callID === null) return;
        const existing = this.tool(callID);
        this.upsertTool({
          id: `tool:${callID}`,
          callID,
          name: piString(part, "name") ?? existing?.name ?? "Tool",
          arguments: piValue(part, "arguments", "args") ?? existing?.arguments ?? null,
          result: existing?.result ?? null,
          status: existing?.status ?? "waiting",
          startedAt: existing?.startedAt ?? null,
          finishedAt: existing?.finishedAt ?? null,
        });
      }
    });

    if (failed && !content.some((part) => piString(part, "type") === "text")) {
      this.appendNotice(
        `${messageID}:failure`,
        stopReason === "aborted" ? "Response stopped" : "Pi could not finish",
        errorMessage ??
          (stopReason === "aborted"
            ? "The response was interrupted."
            : "No error details were provided."),
        stopReason === "aborted" ? "warning" : "error",
        timestamp,
      );
    }
  }

  private projectToolResult(message: PiJSONValue, fallbackID: string): void {
    const callID = piString(message, "toolCallId", "tool_call_id") ?? fallbackID;
    const existing = this.tool(callID);
    this.upsertTool({
      id: `tool:${callID}`,
      callID,
      name: piString(message, "toolName", "tool_name") ?? existing?.name ?? "Tool",
      arguments: existing?.arguments ?? null,
      result: piValue(message, "content", "result"),
      status: (piBool(message, "isError", "is_error") ?? false) ? "failed" : "succeeded",
      startedAt: existing?.startedAt ?? null,
      finishedAt: piTimestampFrom(piKey(message, "timestamp")),
    });
  }

  private upsertToolExecution(
    event: PiJSONValue,
    status: PiToolInvocationStatus,
    final: boolean,
  ): void {
    const callID = piString(event, "toolCallId", "tool_call_id");
    if (callID === null) return;
    this.ensureActiveTurn(callID);
    const existing = this.tool(callID);
    const result = piValue(event, "result", "partialResult", "partial_result");
    this.upsertTool({
      id: `tool:${callID}`,
      callID,
      name: piString(event, "toolName", "tool_name") ?? existing?.name ?? "Tool",
      arguments: piValue(event, "args", "arguments") ?? existing?.arguments ?? null,
      result: result ?? existing?.result ?? null,
      status,
      startedAt: existing?.startedAt ?? Date.now(),
      finishedAt: final ? Date.now() : null,
    });
  }

  // -------------------------------------------------------------------
  // Turn / item storage
  // -------------------------------------------------------------------

  private startTurn(id: string, user: PiUserMessage): void {
    const last = this.turns[this.turns.length - 1];
    if (last) last.isActive = false;
    this.turns.push({
      id,
      user,
      items: [],
      startedAt: user.timestamp,
      isActive: this.phase === "working",
    });
    this.activeTurnID = id;
    this.activeMessageID = null;
  }

  private ensureActiveTurn(seed: string | null): void {
    if (this.activeTurnID !== null && this.turns.some((turn) => turn.id === this.activeTurnID)) {
      return;
    }
    const last = this.turns[this.turns.length - 1];
    if (last) {
      this.activeTurnID = last.id;
      return;
    }
    const id = `turn:orphan:${seed ?? "initial"}`;
    this.turns.push({ id, user: null, items: [], startedAt: Date.now(), isActive: true });
    this.activeTurnID = id;
  }

  private append(item: PiConversationItem): void {
    this.ensureActiveTurn(item.value.id);
    const index = this.turns.findIndex((turn) => turn.id === this.activeTurnID);
    if (index < 0) return;
    const itemIndex = this.turns[index].items.findIndex(
      (existing) => existing.value.id === item.value.id,
    );
    if (itemIndex >= 0) this.turns[index].items[itemIndex] = item;
    else this.turns[index].items.push(item);
  }

  private upsertAssistant(block: PiAssistantBlock): void {
    this.append({ kind: "assistant", value: block });
  }

  private upsertThinking(block: PiThinkingBlock): void {
    this.append({ kind: "thinking", value: block });
  }

  private assistantBlock(id: string): PiAssistantBlock | null {
    for (const turn of this.turns) {
      for (const item of turn.items) {
        if (item.kind === "assistant" && item.value.id === id) return item.value;
      }
    }
    return null;
  }

  private thinkingBlock(id: string): PiThinkingBlock | null {
    for (const turn of this.turns) {
      for (const item of turn.items) {
        if (item.kind === "thinking" && item.value.id === id) return item.value;
      }
    }
    return null;
  }

  private upsertTool(invocation: PiToolInvocation): void {
    for (const turn of this.turns) {
      const itemIndex = turn.items.findIndex(
        (item) => item.kind === "tool" && item.value.callID === invocation.callID,
      );
      if (itemIndex >= 0) {
        turn.items[itemIndex] = { kind: "tool", value: invocation };
        return;
      }
    }
    this.append({ kind: "tool", value: invocation });
  }

  private tool(callID: string): PiToolInvocation | null {
    for (const turn of this.turns) {
      for (const item of turn.items) {
        if (item.kind === "tool" && item.value.callID === callID) return item.value;
      }
    }
    return null;
  }

  private removeTool(callID: string): void {
    for (const turn of this.turns) {
      turn.items = turn.items.filter(
        (item) => !(item.kind === "tool" && item.value.callID === callID),
      );
    }
  }

  private appendNotice(
    id: string,
    title: string,
    detail: string | null,
    tone: PiConversationNoticeTone,
    timestamp: number | null = null,
  ): void {
    this.ensureActiveTurn(id);
    this.append({ kind: "notice", value: { id, title, detail, tone, timestamp } });
  }

  private upsertInteraction(interaction: PiPendingInteraction): void {
    const index = this.pendingInteractions.findIndex(
      (pending) => pending.id === interaction.id,
    );
    if (index >= 0) this.pendingInteractions[index] = interaction;
    else this.pendingInteractions.push(interaction);
  }

  private markTurnsSettled(): void {
    for (const turn of this.turns) {
      turn.isActive = false;
      turn.items = turn.items.map((item) => {
        if (item.kind === "assistant" && item.value.status === "streaming") {
          return { ...item, value: { ...item.value, status: "complete" as const } };
        }
        if (item.kind === "thinking" && item.value.isStreaming) {
          return { ...item, value: { ...item.value, isStreaming: false } };
        }
        return item;
      });
    }
    const last = this.turns[this.turns.length - 1];
    this.activeTurnID = last ? last.id : null;
    this.activeMessageID = null;
  }

  private remember(cursor: string): void {
    this.seenCursors.add(cursor);
    this.cursorOrder.push(cursor);
    if (this.cursorOrder.length > 2_048) {
      const removed = this.cursorOrder.splice(0, 512);
      for (const old of removed) this.seenCursors.delete(old);
    }
  }

  private sessionChanged(event: PiJSONValue): boolean {
    const incomingID = piString(event, "sessionId", "session_id", "id");
    if (incomingID === null) return false;
    if (this.sessionID !== null && this.sessionID !== incomingID) return true;
    this.sessionID = incomingID;
    return false;
  }
}

/**
 * Port of `PiConversationStore.consume(_:)`'s stream loop: `.activity`
 * frames are skipped, envelopes are applied, and the loop exits (true) as
 * soon as the reducer requests an authoritative snapshot. Store-level
 * connection/error bookkeeping (`publishReducerState`, `lastError`,
 * `connection`) belongs to the store port, not the reducer.
 */
export async function consumePiConversationStream(
  stream: AsyncIterable<PiConversationStreamEvent>,
  reducer: PiConversationReducer,
): Promise<boolean> {
  for await (const streamEvent of stream) {
    if (streamEvent.kind !== "envelope") continue;
    const effect = reducer.apply(streamEvent.envelope);
    if (effect === "needsSnapshot") return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Module-level helpers (Swift `static func` / `Self.*`)
// ---------------------------------------------------------------------------

/** Swift `normalizedEventType`: strips the `pi.` event-name prefix. */
function normalizedEventType(type: string): string {
  return type.startsWith("pi.") ? type.slice(3) : type;
}

/** Swift `sessionIdentifier(in:)`. */
function sessionIdentifier(session: PiJSONValue | null): string | null {
  if (session === null) return null;
  return piString(session, "id", "sessionId", "session_id") ?? piStringValue(session);
}

/** Swift `isWorking(_:)`. */
function isWorking(state: PiJSONValue | null): boolean {
  const flag = piBool(state, "isStreaming", "is_streaming", "running", "working");
  if (flag !== null) return flag;
  const status = piString(state, "status", "phase") ?? "";
  return ["working", "running", "streaming"].includes(status);
}

/** Swift `liveMessageIdentifier(_:envelope:)`. */
function liveMessageIdentifier(
  message: PiJSONValue | null,
  envelope: PiConversationEnvelope,
): string {
  const id = piString(message, "id", "messageId", "message_id");
  if (id !== null) return id;
  const timestamp = piStringValue(piValue(message, "timestamp"));
  return `live:${envelope.sessionID ?? "session"}:${timestamp ?? envelope.cursor ?? "message"}`;
}

/** Swift `messageFailed(_:)`. */
function messageFailed(message: PiJSONValue | null): boolean {
  const reason = piString(message, "stopReason", "stop_reason");
  return reason === "error" || reason === "aborted";
}

/** Swift `text(from:)` — plain string or parts array ("text"/"image" only). */
function textFrom(content: PiJSONValue | null): string {
  if (content === null) return "";
  const string = piStringValue(content);
  if (string !== null) return string;
  const parts = piArray(content);
  if (parts === null) return "";
  return parts
    .map((part) => {
      const type = piString(part, "type");
      if (type === "text") return piString(part, "text");
      if (type === "image") return "[Image]";
      return null;
    })
    .filter((part): part is string => part !== null)
    .join("\n");
}

/** Swift `PiPendingInteraction.Kind(rawValue:) ?? .unknown`. */
function interactionFrom(value: PiJSONValue): PiPendingInteraction | null {
  const request = piKey(value, "request") ?? value;
  const id = piString(request, "id", "interactionId", "interaction_id", "requestId", "request_id");
  if (id === null) return null;
  const rawKind = piString(request, "method", "kind", "requestType", "request_type") ?? "unknown";
  const kind: PiPendingInteractionKind =
    rawKind === "select" ||
    rawKind === "confirm" ||
    rawKind === "input" ||
    rawKind === "editor"
      ? rawKind
      : "unknown";
  const optionsRaw = piValue(request, "options", "choices");
  const options = (piArray(optionsRaw) ?? [])
    .map((option) => piStringValue(option) ?? piString(option, "label", "value"))
    .filter((option): option is string => option !== null);
  return {
    id,
    kind,
    title: piString(request, "title", "prompt") ?? "Pi needs your input",
    message: piString(request, "message", "description"),
    options,
    placeholder: piString(request, "placeholder"),
  };
}

/** Swift `Int(string) ?? 0`. */
function intFrom(raw: string): number {
  const parsed = Number(raw);
  return Number.isInteger(parsed) ? parsed : 0;
}
