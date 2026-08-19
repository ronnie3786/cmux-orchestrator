/**
 * Deterministic TS port of the herdr-harness-ios Pi* model files (the 28
 * `Pi*.swift` sources under `herdr-harness-ios/Models/`). The Swift files are
 * the source of truth:
 *
 *  - Field names match the Swift property names (`paneID`, `sessionID`,
 *    `modelID`, `contextWindow`, ...). Wire JSON keys — including the
 *    camel/snake aliases the Swift `CodingKeys` accept — are handled by the
 *    `decodePi*` functions below, which mirror each Swift
 *    `init(from decoder:)` line for line.
 *  - Optionality mirrors Swift `Optional` exactly (`null`, not absent).
 *  - Swift `Date?` fields are represented as epoch-milliseconds `number | null`.
 *  - `PiJSONValue` mirrors the lossless JSON value used at the protocol
 *    boundary: unknown keys are retained, not dropped.
 *
 * The two files in the Swift set with no wire/model shape to port in this run:
 *  - `PiMarkdownParser.swift` — pure parsing logic (its output types,
 *    `PiMarkdownBlock` & friends, are ported here).
 *  - `PiToolPresentation.swift` — SwiftUI view-model (uses `Color`/HerdrTheme).
 */

// ---------------------------------------------------------------------------
// PiJSONValue.swift
// ---------------------------------------------------------------------------

export interface PiJsonObject {
  [key: string]: PiJSONValue;
}

type PiJSONArray = PiJSONValue[];

export type PiJSONValue =
  | string
  | number
  | boolean
  | PiJsonObject
  | PiJSONArray
  | null;

function isPiObject(value: unknown): value is PiJsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function piObject(
  value: PiJSONValue | null | undefined,
): PiJsonObject | null {
  return isPiObject(value) ? value : null;
}

export function piArray(value: PiJSONValue | null | undefined): PiJSONArray | null {
  return Array.isArray(value) ? value : null;
}

/** Swift `stringValue`: numbers render integral (no trailing ".0"). */
export function piStringValue(value: PiJSONValue | null | undefined): string | null {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  if (typeof value === "boolean") return String(value);
  return null;
}

/** Swift `boolValue`: only booleans and `Bool(String)` ("true"/"false"/"1"/"0", any case). */
export function piBoolValue(value: PiJSONValue | null | undefined): boolean | null {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const lowered = value.toLowerCase();
    if (lowered === "true" || lowered === "1") return true;
    if (lowered === "false" || lowered === "0") return false;
  }
  return null;
}

export function piNumber(value: PiJSONValue | null | undefined): number | null {
  return typeof value === "number" ? value : null;
}

/** Swift `subscript(_:)`. */
export function piKey(
  value: PiJSONValue | null | undefined,
  key: string,
): PiJSONValue | null {
  return piObject(value)?.[key] ?? null;
}

/** Swift `value(for:)`: first present key (a null value still counts as present). */
export function piValue(
  value: PiJSONValue | null | undefined,
  ...keys: string[]
): PiJSONValue | null {
  const object = piObject(value);
  if (!object) return null;
  for (const key of keys) {
    if (key in object) return object[key];
  }
  return null;
}

export function piString(
  value: PiJSONValue | null | undefined,
  ...keys: string[]
): string | null {
  const object = piObject(value);
  if (!object) return null;
  for (const key of keys) {
    const string = piStringValue(object[key]);
    if (string !== null) return string;
  }
  return null;
}

export function piBool(
  value: PiJSONValue | null | undefined,
  ...keys: string[]
): boolean | null {
  const object = piObject(value);
  if (!object) return null;
  for (const key of keys) {
    const bool = piBoolValue(object[key]);
    if (bool !== null) return bool;
  }
  return null;
}

export function piNumberForKey(
  value: PiJSONValue | null | undefined,
  ...keys: string[]
): number | null {
  const object = piObject(value);
  if (!object) return null;
  for (const key of keys) {
    const number = piNumber(object[key]);
    if (number !== null) return number;
  }
  return null;
}

/** Swift `displayString` (object/array via pretty JSON; key order may differ from Swift). */
export function piDisplayString(value: PiJSONValue): string {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  if (typeof value === "boolean") return String(value);
  if (value === null) return "null";
  return JSON.stringify(value, null, 2) ?? "";
}

// ---------------------------------------------------------------------------
// PiProtocolInfo.swift
// ---------------------------------------------------------------------------

export interface PiProtocolInfo {
  name: string;
  version: number;
}

export const DEFAULT_PI_PROTOCOL_INFO: PiProtocolInfo = {
  name: "herdr.pi.semantic",
  version: 1,
};

/** Swift `decodeIfPresent(PiProtocolInfo) ?? .init(name:version:)`. */
function readProtocolInfo(object: Record<string, unknown>): PiProtocolInfo {
  const raw = object["protocol"];
  if (raw === undefined) return { ...DEFAULT_PI_PROTOCOL_INFO };
  if (
    !isPiObject(raw) ||
    typeof raw["name"] !== "string" ||
    typeof raw["version"] !== "number"
  ) {
    throw new TypeError("invalid Pi protocol info object");
  }
  return { name: raw["name"], version: raw["version"] };
}

// ---------------------------------------------------------------------------
// PiSemanticCapabilities.swift / PiSemanticCapability.swift
// ---------------------------------------------------------------------------

export interface PiSemanticCapabilities {
  prompt: boolean;
  steer: boolean;
  followUp: boolean;
  abort: boolean;
  listModels: boolean;
  setModel: boolean;
  setThinkingLevel: boolean;
  interactionResponse: boolean;
}

export const PI_SEMANTIC_CAPABILITIES_UNAVAILABLE: PiSemanticCapabilities = {
  prompt: false,
  steer: false,
  followUp: false,
  abort: false,
  listModels: false,
  setModel: false,
  setThinkingLevel: false,
  interactionResponse: false,
};

function pickString(
  object: Record<string, unknown>,
  ...keys: string[]
): string | null {
  for (const key of keys) {
    const value = object[key];
    if (typeof value === "string") return value;
  }
  return null;
}

function pickBool(object: Record<string, unknown>, ...keys: string[]): boolean | null {
  for (const key of keys) {
    const value = object[key];
    if (typeof value === "boolean") return value;
  }
  return null;
}

function pickNumber(
  object: Record<string, unknown>,
  ...keys: string[]
): number | null {
  for (const key of keys) {
    const value = object[key];
    if (typeof value === "number") return value;
  }
  return null;
}

/** Swift `try? decodeIfPresent(String) ?? try? decodeIfPresent(Int64)` cursor rule. */
function decodeCursorValue(value: unknown): string | null {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  return null;
}

function toDecodeObject(
  payload: string | PiJSONValue,
  label: string,
): Record<string, unknown> {
  const parsed: unknown = typeof payload === "string" ? JSON.parse(payload) : payload;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new TypeError(`${label} must be a JSON object`);
  }
  return parsed as Record<string, unknown>;
}

/** Mirror of `PiSemanticCapabilities.init(from:)` — camel + snake aliases, default false. */
export function decodePiSemanticCapabilities(
  payload: string | PiJSONValue,
): PiSemanticCapabilities {
  const object = toDecodeObject(payload, "Pi semantic capabilities");
  return {
    prompt: pickBool(object, "prompt") ?? false,
    steer: pickBool(object, "steer") ?? false,
    followUp: pickBool(object, "followUp", "follow_up") ?? false,
    abort: pickBool(object, "abort") ?? false,
    listModels: pickBool(object, "listModels", "list_models") ?? false,
    setModel: pickBool(object, "setModel", "set_model") ?? false,
    setThinkingLevel: pickBool(object, "setThinkingLevel", "set_thinking_level") ?? false,
    interactionResponse: pickBool(object, "interactionResponse", "interaction_response") ?? false,
  };
}

export interface PiSemanticCapability {
  available: boolean;
  connected: boolean;
  protocolVersion: number;
  sessionID: string | null;
  cursor: string | null;
  oldestCursor: string | null;
  capabilities: PiSemanticCapabilities;
  generatedAt: string | null;
}

/** Mirror of `PiSemanticCapability.init(from:)`. */
export function decodePiSemanticCapability(
  payload: string | PiJSONValue,
): PiSemanticCapability {
  const object = toDecodeObject(payload, "Pi semantic capability");
  return {
    available: pickBool(object, "available") ?? false,
    connected: pickBool(object, "connected") ?? false,
    protocolVersion:
      pickNumber(object, "protocolVersion", "protocol_version") ?? 0,
    sessionID: pickString(object, "sessionID", "sessionId", "session_id"),
    cursor: decodeCursorValue(object["cursor"]),
    oldestCursor:
      decodeCursorValue(object["oldestCursor"]) ??
      decodeCursorValue(object["oldest_cursor"]),
    capabilities:
      object["capabilities"] !== undefined
        ? decodePiSemanticCapabilities(object["capabilities"] as PiJSONValue)
        : { ...PI_SEMANTIC_CAPABILITIES_UNAVAILABLE },
    generatedAt: pickString(object, "generatedAt", "generated_at"),
  };
}

// ---------------------------------------------------------------------------
// PiModelIdentity.swift / PiModelCatalog.swift
// ---------------------------------------------------------------------------

export interface PiModelIdentity {
  provider: string;
  id: string;
  name: string | null;
}

/** Mirror of `PiModelIdentity.init?(json:)`. */
export function piModelIdentityFrom(
  json: PiJSONValue | null | undefined,
): PiModelIdentity | null {
  const provider = piString(json, "provider");
  const id = piString(json, "id", "modelId", "model_id");
  if (provider === null || id === null) return null;
  return { provider, id, name: piString(json, "name") };
}

/** Swift `displayName`: non-empty name wins, else id. */
export function piModelIdentityDisplayName(identity: PiModelIdentity): string {
  return identity.name !== null && identity.name !== "" ? identity.name : identity.id;
}

export interface PiAvailableModel {
  provider: string;
  /** Wire key: `"id"`. */
  modelID: string;
  name: string | null;
  reasoning: boolean | null;
  contextWindow: number | null;
}

/** Mirror of `PiAvailableModel.init(from:)`. */
export function decodePiAvailableModel(
  payload: string | PiJSONValue,
): PiAvailableModel {
  const object = toDecodeObject(payload, "Pi available model");
  const provider = object["provider"];
  const modelID = object["id"];
  if (typeof provider !== "string" || typeof modelID !== "string") {
    throw new TypeError('Pi available model requires string "provider" and "id"');
  }
  return {
    provider,
    modelID,
    name: pickString(object, "name"),
    reasoning: pickBool(object, "reasoning"),
    contextWindow: pickNumber(object, "contextWindow", "context_window"),
  };
}

/** Swift `PiAvailableModel.id` (`"provider/modelID"`). */
export function piAvailableModelID(model: PiAvailableModel): string {
  return `${model.provider}/${model.modelID}`;
}

/** Swift `PiAvailableModel.displayName`. */
export function piAvailableModelDisplayName(model: PiAvailableModel): string {
  return model.name !== null && model.name !== "" ? model.name : model.modelID;
}

export interface PiModelCatalogResponse {
  accepted: boolean;
  models: PiAvailableModel[];
  current: PiModelIdentity | null;
}

/** Mirror of `PiModelCatalogResponse.init(from:)` (ok/success + `result` nesting). */
export function decodePiModelCatalogResponse(
  payload: string | PiJSONValue,
): PiModelCatalogResponse {
  const object = toDecodeObject(payload, "Pi model catalog response");
  const result = isPiObject(object["result"]) ? object["result"] : null;
  const models =
    result !== null && Array.isArray(result["models"])
      ? (result["models"] as PiJSONValue[]).map((model) => decodePiAvailableModel(model))
      : [];
  return {
    accepted: pickBool(object, "ok") ?? pickBool(object, "success") ?? false,
    models,
    current: result === null ? null : piModelIdentityFrom(result["current"]),
  };
}

// ---------------------------------------------------------------------------
// PiCommandResponse.swift
// ---------------------------------------------------------------------------

export interface PiCommandResponse {
  accepted: boolean;
}

/** Mirror of `PiCommandResponse.init(from:)`: `ok` ?? `success` ?? false. */
export function decodePiCommandResponse(payload: string | PiJSONValue): PiCommandResponse {
  const object = toDecodeObject(payload, "Pi command response");
  return { accepted: pickBool(object, "ok") ?? pickBool(object, "success") ?? false };
}

// ---------------------------------------------------------------------------
// PiThinkingLevel.swift
// ---------------------------------------------------------------------------

export const PI_THINKING_LEVELS = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
] as const;

export type PiThinkingLevel = (typeof PI_THINKING_LEVELS)[number];

export function piThinkingLevelDisplayName(level: PiThinkingLevel): string {
  switch (level) {
    case "off":
      return "Off";
    case "minimal":
      return "Minimal";
    case "low":
      return "Low";
    case "medium":
      return "Medium";
    case "high":
      return "High";
    case "xhigh":
      return "Extra High";
    case "max":
      return "Max";
  }
}

export interface PiSetThinkingLevelResponse {
  accepted: boolean;
  level: string | null;
}

/** Mirror of `PiSetThinkingLevelResponse.init(from:)` (ok/success + `result.level`). */
export function decodePiSetThinkingLevelResponse(
  payload: string | PiJSONValue,
): PiSetThinkingLevelResponse {
  const object = toDecodeObject(payload, "Pi set-thinking-level response");
  const result = isPiObject(object["result"]) ? object["result"] : null;
  return {
    accepted: pickBool(object, "ok") ?? pickBool(object, "success") ?? false,
    level: result !== null && typeof result["level"] === "string" ? result["level"] : null,
  };
}

// ---------------------------------------------------------------------------
// PiPromptDisposition.swift / PiConversationPhase.swift
// ---------------------------------------------------------------------------

export const PI_PROMPT_DISPOSITIONS = ["prompt", "steer", "followUp"] as const;

export type PiPromptDisposition = (typeof PI_PROMPT_DISPOSITIONS)[number];

export function piPromptDispositionLabel(disposition: PiPromptDisposition): string {
  switch (disposition) {
    case "prompt":
      return "Send";
    case "steer":
      return "Steer";
    case "followUp":
      return "Follow up";
  }
}

export function piPromptDispositionShortLabel(disposition: PiPromptDisposition): string {
  switch (disposition) {
    case "prompt":
      return "Send";
    case "steer":
      return "Steer";
    case "followUp":
      return "Next";
  }
}

export type PiConversationPhase = "idle" | "working" | "failed";

// ---------------------------------------------------------------------------
// PiConversationConnection.swift
// ---------------------------------------------------------------------------

export type PiConversationConnection =
  | { readonly state: "loading" }
  | { readonly state: "connected" }
  | { readonly state: "bridgeOffline" }
  | { readonly state: "reconnecting"; readonly attempt: number }
  | { readonly state: "unavailable" };

export function piConnectionIsConnected(connection: PiConversationConnection): boolean {
  return connection.state === "connected";
}

// ---------------------------------------------------------------------------
// PiConversationEnvelope.swift
// ---------------------------------------------------------------------------

export interface PiConversationEnvelope {
  protocolInfo: PiProtocolInfo;
  paneID: string;
  sessionID: string | null;
  cursor: string | null;
  connected: boolean | null;
  event: PiJSONValue;
  generatedAt: string | null;
}

/** Mirror of `PiConversationEnvelope.init(from:)` (alias keys, int→string cursor). */
export function decodePiConversationEnvelope(
  payload: string | PiJSONValue,
): PiConversationEnvelope {
  const object = toDecodeObject(payload, "Pi conversation envelope");
  if (!("event" in object)) {
    throw new TypeError('Pi conversation envelope requires an "event" field');
  }
  return {
    protocolInfo: readProtocolInfo(object),
    paneID: pickString(object, "paneID", "paneId", "pane_id") ?? "",
    sessionID: pickString(object, "sessionID", "sessionId", "session_id"),
    cursor: decodeCursorValue(object["cursor"]),
    connected: pickBool(object, "connected"),
    event: object["event"] as PiJSONValue,
    generatedAt: pickString(object, "generatedAt", "generated_at"),
  };
}

/** Swift `PiConversationEnvelope.eventType`. */
export function piEnvelopeEventType(envelope: PiConversationEnvelope): string {
  return piString(envelope.event, "type") ?? "unknown";
}

/** Swift `PiConversationEnvelope.withCursor(_:)` — SSE `id:` line fallback. */
export function piEnvelopeWithCursor(
  envelope: PiConversationEnvelope,
  fallbackCursor: string | null,
): PiConversationEnvelope {
  if (envelope.cursor !== null || fallbackCursor === null) return envelope;
  return { ...envelope, cursor: fallbackCursor };
}

// ---------------------------------------------------------------------------
// PiConversationSnapshot.swift
// ---------------------------------------------------------------------------

export interface PiConversationSnapshot {
  ok: boolean;
  protocolInfo: PiProtocolInfo;
  paneID: string;
  available: boolean;
  connected: boolean;
  session: PiJSONValue | null;
  state: PiJSONValue | null;
  entries: PiJSONValue[];
  pendingInteractions: PiJSONValue[];
  cursor: string | null;
  oldestCursor: string | null;
  truncated: boolean;
  generatedAt: string | null;
}

function decodeSnapshotCursor(
  object: Record<string, unknown>,
  ...keys: string[]
): string | null {
  for (const key of keys) {
    const value = decodeCursorValue(object[key]);
    if (value !== null) return value;
  }
  return null;
}

/** Mirror of `PiConversationSnapshot.init(from:)`. */
export function decodePiConversationSnapshot(
  payload: string | PiJSONValue,
): PiConversationSnapshot {
  const object = toDecodeObject(payload, "Pi conversation snapshot");
  const pendingInteractions =
    object["pendingInteractions"] ?? object["pending_interactions"];
  return {
    ok: pickBool(object, "ok") ?? true,
    protocolInfo: readProtocolInfo(object),
    paneID: pickString(object, "paneID", "paneId", "pane_id") ?? "",
    available: pickBool(object, "available") ?? true,
    connected: pickBool(object, "connected") ?? false,
    session: (object["session"] ?? null) as PiJSONValue | null,
    state: (object["state"] ?? null) as PiJSONValue | null,
    entries: Array.isArray(object["entries"])
      ? (object["entries"] as PiJSONValue[])
      : [],
    pendingInteractions: Array.isArray(pendingInteractions)
      ? (pendingInteractions as PiJSONValue[])
      : [],
    cursor: decodeSnapshotCursor(object, "cursor"),
    oldestCursor: decodeSnapshotCursor(object, "oldestCursor", "oldest_cursor"),
    truncated: pickBool(object, "truncated") ?? false,
    generatedAt: pickString(object, "generatedAt", "generated_at"),
  };
}

/**
 * Swift `PiConversationSnapshot.reportsContextUsage` — the `context` key must
 * be PRESENT (even null) to distinguish a new bridge from a legacy one.
 */
export function piSnapshotReportsContextUsage(snapshot: PiConversationSnapshot): boolean {
  const state = piObject(snapshot.state);
  return state !== null && "context" in state;
}

// ---------------------------------------------------------------------------
// PiConversationStreamEvent.swift
// ---------------------------------------------------------------------------

export type PiConversationStreamEvent =
  | { readonly kind: "activity" }
  | { readonly kind: "envelope"; readonly envelope: PiConversationEnvelope };

// ---------------------------------------------------------------------------
// PiContextUsage.swift
// ---------------------------------------------------------------------------

export interface PiContextUsage {
  /** Legitimately null right after compaction (before the next LLM response). */
  tokens: number | null;
  contextWindow: number | null;
  percent: number | null;
}

/** Mirror of `PiContextUsage.init?(from:)` — nil when all three fields are null/absent. */
export function piContextUsageFrom(
  value: PiJSONValue | null | undefined,
): PiContextUsage | null {
  const rawTokens = piNumberForKey(value, "tokens");
  const rawWindow = piNumberForKey(value, "contextWindow", "context_window");
  const percent = piNumberForKey(value, "percent");
  const tokens = rawTokens === null ? null : Math.trunc(rawTokens);
  const contextWindow = rawWindow === null ? null : Math.trunc(rawWindow);
  if (tokens === null && contextWindow === null && percent === null) return null;
  return { tokens, contextWindow, percent };
}

/** Swift `fraction`: 0...1 fraction of the context window. */
export function piContextUsageFraction(usage: PiContextUsage): number | null {
  if (
    usage.tokens !== null &&
    usage.contextWindow !== null &&
    usage.contextWindow > 0
  ) {
    return Math.min(1, usage.tokens / usage.contextWindow);
  }
  if (usage.percent !== null) {
    return Math.min(1, Math.max(0, usage.percent / 100));
  }
  return null;
}

function compactTokens(value: number): string {
  if (value >= 1_000_000) {
    const millions = value / 1_000_000;
    return millions >= 10 ? `${Math.round(millions)}M` : `${millions.toFixed(1)}M`;
  }
  if (value >= 100_000) {
    return `${Math.round(value / 1_000)}k`;
  }
  if (value >= 1_000) {
    return `${(value / 1_000).toFixed(1)}k`;
  }
  return String(value);
}

/** Swift `summary`, e.g. "12.3k / 192k". */
export function piContextUsageSummary(usage: PiContextUsage): string | null {
  if (
    usage.tokens !== null &&
    usage.contextWindow !== null &&
    usage.contextWindow > 0
  ) {
    return `${compactTokens(usage.tokens)} / ${compactTokens(usage.contextWindow)}`;
  }
  if (usage.tokens !== null) {
    return compactTokens(usage.tokens);
  }
  return null;
}

/** Swift `percentText`, e.g. "87%". */
export function piContextUsagePercentText(usage: PiContextUsage): string | null {
  const fraction = piContextUsageFraction(usage);
  return fraction === null ? null : `${Math.round(fraction * 100)}%`;
}

// ---------------------------------------------------------------------------
// PiConversationTimestamp.swift
// ---------------------------------------------------------------------------

/**
 * Mirror of `PiConversationTimestamp.date(from:)`, returned as epoch
 * milliseconds. Pi message timestamps are milliseconds; extension metadata
 * occasionally uses seconds (threshold 10,000,000,000).
 */
export function piTimestampFrom(
  value: PiJSONValue | null | undefined,
): number | null {
  if (typeof value === "number") {
    return value > 10_000_000_000 ? value : value * 1_000;
  }
  if (typeof value === "string") {
    if (value.trim() !== "") {
      const number = Number(value);
      if (!Number.isNaN(number)) {
        return number > 10_000_000_000 ? number : number * 1_000;
      }
    }
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Conversation items (PiAssistantBlock, PiThinkingBlock, PiToolInvocation,
// PiConversationNotice, PiUserMessage, PiConversationItem, PiConversationTurn)
// ---------------------------------------------------------------------------

/** Swift `PiAssistantBlock.Status` — `case failed(String?)`. */
export type PiAssistantStatus =
  | "streaming"
  | "complete"
  | { readonly failed: true; readonly detail: string | null };

export interface PiAssistantBlock {
  id: string;
  text: string;
  status: PiAssistantStatus;
  timestamp: number | null;
}

export interface PiThinkingBlock {
  id: string;
  text: string;
  isStreaming: boolean;
  isRedacted: boolean;
  startedAt: number | null;
}

export type PiToolInvocationStatus = "waiting" | "running" | "succeeded" | "failed";

export interface PiToolInvocation {
  id: string;
  callID: string;
  name: string;
  arguments: PiJSONValue | null;
  result: PiJSONValue | null;
  status: PiToolInvocationStatus;
  startedAt: number | null;
  finishedAt: number | null;
}

export type PiConversationNoticeTone = "neutral" | "warning" | "error";

export interface PiConversationNotice {
  id: string;
  title: string;
  detail: string | null;
  tone: PiConversationNoticeTone;
  timestamp: number | null;
}

export interface PiUserMessage {
  id: string;
  text: string;
  timestamp: number | null;
}

export type PiConversationItem =
  | { readonly kind: "assistant"; readonly value: PiAssistantBlock }
  | { readonly kind: "thinking"; readonly value: PiThinkingBlock }
  | { readonly kind: "tool"; readonly value: PiToolInvocation }
  | { readonly kind: "notice"; readonly value: PiConversationNotice };

export function piItemID(item: PiConversationItem): string {
  return item.value.id;
}

export interface PiConversationTurn {
  id: string;
  user: PiUserMessage | null;
  items: PiConversationItem[];
  startedAt: number | null;
  isActive: boolean;
}

/** Swift `PiConversationTurn.hasVisibleContent`. */
export function piTurnHasVisibleContent(turn: PiConversationTurn): boolean {
  return turn.user !== null || turn.items.length > 0;
}

// ---------------------------------------------------------------------------
// PiPendingInteraction.swift / PiInteractionResponseBody.swift
// ---------------------------------------------------------------------------

export type PiPendingInteractionKind =
  | "select"
  | "confirm"
  | "input"
  | "editor"
  | "unknown";

export interface PiPendingInteraction {
  id: string;
  kind: PiPendingInteractionKind;
  title: string;
  message: string | null;
  options: string[];
  placeholder: string | null;
}

export interface PiInteractionResponseBody {
  value: PiJSONValue | null;
  confirmed: boolean | null;
  cancelled: boolean | null;
}

export function piInteractionSelection(value: string): PiInteractionResponseBody {
  return { value, confirmed: null, cancelled: null };
}

export function piInteractionText(value: string): PiInteractionResponseBody {
  return { value, confirmed: null, cancelled: null };
}

export function piInteractionConfirmation(value: boolean): PiInteractionResponseBody {
  return { value: null, confirmed: value, cancelled: null };
}

export const PI_INTERACTION_CANCELLED: PiInteractionResponseBody = {
  value: null,
  confirmed: null,
  cancelled: true,
};

// ---------------------------------------------------------------------------
// Pi bridge event types (doc 02 §3.3: `pi-semantic-bridge.ts:786-795` + the
// 3 events the harness synthesizes). Event names arrive on the wire as
// `event: pi.<type>`; the inner `event.type` carries the bare type.
// ---------------------------------------------------------------------------

/** 26 bridge-emitted event types per doc 02 §3.3. */
export const PI_BRIDGE_EVENT_TYPES = [
  "session_start",
  "session_shutdown",
  "session_info_changed",
  "session_before_switch",
  "session_before_fork",
  "session_before_compact",
  "session_compact",
  "session_before_tree",
  "session_tree",
  "before_agent_start",
  "agent_start",
  "agent_end",
  "agent_settled",
  "turn_start",
  "turn_end",
  "message_start",
  "message_update",
  "message_end",
  "tool_execution_start",
  "tool_execution_update",
  "tool_execution_end",
  "model_select",
  "thinking_level_select",
  "input",
  "tool_call",
  "tool_result",
] as const;

export type PiBridgeEventType = (typeof PI_BRIDGE_EVENT_TYPES)[number];

/** Events the herdr harness synthesizes (not emitted by the Pi bridge). */
export const PI_SYNTHETIC_EVENT_TYPES = [
  "bridge.connection",
  "stream.reset",
  "bridge.payload_omitted",
] as const;

export type PiSyntheticEventType = (typeof PI_SYNTHETIC_EVENT_TYPES)[number];

/** All event types that can appear in the Pi journal stream. */
export type PiEventType = PiBridgeEventType | PiSyntheticEventType;

// ---------------------------------------------------------------------------
// PiMarkdownBlock.swift (types only — PiMarkdownParser.swift is logic and is
// ported in the reducer phase, P6-run-B)
// ---------------------------------------------------------------------------

export type PiMarkdownListItemMarker =
  | { readonly kind: "bullet" }
  | { readonly kind: "number"; readonly value: string }
  | { readonly kind: "task"; readonly isCompleted: boolean };

export interface PiMarkdownListItem {
  marker: PiMarkdownListItemMarker;
  text: string;
  depth: number;
}

export type PiMarkdownColumnAlignment = "leading" | "center" | "trailing";

export interface PiMarkdownTable {
  headers: string[];
  alignments: PiMarkdownColumnAlignment[];
  rows: string[][];
}

export type PiMarkdownBlock =
  | { readonly kind: "paragraph"; readonly id: number; readonly text: string }
  | {
      readonly kind: "heading";
      readonly id: number;
      readonly level: number;
      readonly text: string;
    }
  | {
      readonly kind: "code";
      readonly id: number;
      readonly language: string | null;
      readonly code: string;
    }
  | { readonly kind: "list"; readonly id: number; readonly items: PiMarkdownListItem[] }
  | { readonly kind: "quote"; readonly id: number; readonly text: string }
  | { readonly kind: "table"; readonly id: number; readonly table: PiMarkdownTable }
  | { readonly kind: "thematicBreak"; readonly id: number };

export function piMarkdownBlockID(block: PiMarkdownBlock): number {
  return block.id;
}
