/**
 * Pi conversation store (P7) — deterministic port of
 * `herdr-harness-ios/State/PiConversationStore.swift` (source of truth).
 *
 * Ownership model: the Swift store is bound to ONE pane per instance
 * (`follow(model:pane:)`); like terminalStore (the shell only observes the
 * selected pane), this store keeps one ACTIVE pane — `follow()` rebinds,
 * `stop(paneId)` tears down. The reducer instance + stream handles live in a
 * module-scoped entry (not serializable); zustand holds the published
 * view state (Swift `publishReducerState` + the store's published vars).
 *
 * Swift state machine → this store:
 *  - `follow()` main loop → `runFollowLoop` (snapshot → gate → replace →
 *    legacy poll OR live SSE; catch → `.reconnecting(attempt:)` + backoff
 *    0.65 s ×1.7 cap 6 s)
 *  - `followSnapshotPolling` → `runSnapshotPolling` (2 s poll,
 *    content-change detection, backoff ×1.7 cap 8 s, auto-upgrade when a
 *    newer bridge reports context usage AND is connected)
 *  - `consume(_:)` + per-envelope bookkeeping → `consumeStream` (Swift
 *    applies the reducer, then sets `connection`/`lastError` from
 *    `reducer.bridgeConnected` — done here per envelope, not deferred)
 *  - `submit/abort/setModel/setThinkingLevel/respond/loadModels/reset`
 *    → same-named actions with the same guards and byte-exact strings
 *
 * Strings come from the Swift store, not the doc 01 §6 view banners (the
 * view-layer banner map is a later phase). `error.localizedDescription` →
 * `errorMessage` (the ApiError's server message).
 *
 * SSE wiring: `openSSE` (cursorKind "opaque-after" → `?after=<cursor>` URL
 * + Last-Event-ID header) frames the wire; its parsed blocks are re-fed as
 * SSE lines through `PiConversationSSEParser` (event-name gating,
 * `pi.error`/`pi.stream.closed` → PiStreamEndedError, id fallback), and the
 * resulting stream events feed the reducer. When openSSE itself reports a
 * drop (`onState "reconnecting"`), the store closes the handle and lets the
 * follow loop own the backoff — mirroring the Swift loop, which re-fetches
 * the snapshot before every (re)connect.
 */

import { create } from "zustand";
import { ApiError } from "../api/client";
import {
  piAbort,
  piEventsUrl,
  piFollowUp,
  piModels,
  piPrompt,
  piRespond,
  piSetModel,
  piSetThinkingLevel,
  piSnapshot,
  piSteer,
  type PiCommandPayload,
} from "../api/pi";
import { openSSE, type SseHandle } from "../api/sse";
import { PiConversationSSEParser, PiStreamEndedError } from "../pi/envelope";
import { PiConversationReducer } from "../pi/reducer";
import {
  PI_THINKING_LEVELS,
  decodePiConversationSnapshot,
  decodePiModelCatalogResponse,
  decodePiSetThinkingLevelResponse,
  piAvailableModelDisplayName,
  piConnectionIsConnected,
  piSnapshotReportsContextUsage,
  piThinkingLevelDisplayName,
  piTurnHasVisibleContent,
} from "../pi/types";
import type {
  PiAvailableModel,
  PiContextUsage,
  PiConversationConnection,
  PiConversationPhase,
  PiConversationSnapshot,
  PiConversationStreamEvent,
  PiConversationTurn,
  PiInteractionResponseBody,
  PiModelIdentity,
  PiPendingInteraction,
  PiPromptDisposition,
  PiSemanticCapability,
} from "../pi/types";

/** Swift `APIError` names / doc 01 §4.4. */
const PI_PROTOCOL_NAME = "herdr.pi.semantic";
const PI_PROTOCOL_VERSION = 1;

// Byte-exact strings from PiConversationStore.swift.
const UNAVAILABLE_MESSAGE = "This Pi session does not expose a compatible native transcript.";
const BRIDGE_OFFLINE_MESSAGE = "Pi is offline. The saved transcript is still available.";
const RECONNECTING_MESSAGE = "Live updates paused. Reconnecting…";
const SEND_OFFLINE_MESSAGE = "Pi is offline. Reconnect before sending a message.";
const RESPOND_OFFLINE_MESSAGE = "Pi is offline. Reconnect before responding.";
const MODEL_501_MESSAGE = "Model switching isn't supported by this Pi session";
const THINKING_501_MESSAGE = "Thinking control isn't supported by this Pi session";
const MODELS_ERROR_MESSAGE = "Couldn't load models";

/** Swift `follow()`: retryDelay 0.65 s, ×1.7, cap 6 s. */
const LIVE_BACKOFF_INITIAL_MS = 650;
const LIVE_BACKOFF_FACTOR = 1.7;
const LIVE_BACKOFF_CAP_MS = 6_000;
/** Swift `followSnapshotPolling`: 2 s poll, ×1.7, cap 8 s. */
const SNAPSHOT_POLL_MS = 2_000;
const POLL_BACKOFF_FACTOR = 1.7;
const POLL_BACKOFF_CAP_MS = 8_000;

export interface PiStoreState {
  paneId: string | null;
  /** Capability gate: `available && protocolVersion == 1`. */
  supportsPiSemanticChat: boolean;
  turns: PiConversationTurn[];
  pendingInteractions: PiPendingInteraction[];
  phase: PiConversationPhase;
  connection: PiConversationConnection;
  revision: number;
  isTruncated: boolean;
  bridgeConnected: boolean;
  contextUsage: PiContextUsage | null;
  currentModel: PiModelIdentity | null;
  availableModels: PiAvailableModel[];
  isLoadingModels: boolean;
  isSettingModel: boolean;
  thinkingLevel: string | null;
  isSettingThinkingLevel: boolean;
  modelCatalogError: string | null;
  isModelSwitchingUnsupported: boolean;
  isSubmitting: boolean;
  isAborting: boolean;
  lastError: string | null;
  commandNotice: string | null;

  follow: (paneId: string, token: string, piSemantic: PiSemanticCapability) => void;
  stop: (paneId: string) => void;
  prompt: (text: string) => Promise<boolean>;
  steer: (text: string) => Promise<boolean>;
  followUp: (text: string) => Promise<boolean>;
  abort: () => Promise<boolean>;
  setModel: (provider: string, id: string) => Promise<boolean>;
  setThinkingLevel: (level: string) => Promise<boolean>;
  respond: (interactionId: string, body: PiInteractionResponseBody) => Promise<boolean>;
  retryLoadModels: () => Promise<void>;
  clearCommandNotice: () => void;
}

// ---------------------------------------------------------------------------
// Module-scoped entry (mirrors terminalStore's module-scoped handles)
// ---------------------------------------------------------------------------

interface PiEventQueue extends AsyncIterable<PiConversationStreamEvent> {
  push(event: PiConversationStreamEvent): void;
  close(): void;
}

function createPiEventQueue(): PiEventQueue {
  const buffer: PiConversationStreamEvent[] = [];
  let resolve: ((result: IteratorResult<PiConversationStreamEvent>) => void) | null = null;
  let done = false;
  return {
    push(event) {
      if (done) return;
      buffer.push(event);
      if (resolve) {
        const next = resolve;
        resolve = null;
        next({ value: buffer.shift() as PiConversationStreamEvent, done: false });
      }
    },
    close() {
      if (done) return;
      done = true;
      if (resolve) {
        const end = resolve;
        resolve = null;
        end({ value: undefined, done: true });
      }
    },
    [Symbol.asyncIterator]() {
      return {
        next(): Promise<IteratorResult<PiConversationStreamEvent>> {
          while (buffer.length > 0) {
            return Promise.resolve({ value: buffer.shift() as PiConversationStreamEvent, done: false });
          }
          if (done) {
            return Promise.resolve({ value: undefined, done: true });
          }
          return new Promise((r) => {
            resolve = r;
          });
        },
      };
    },
  };
}

interface PiEntry {
  generation: number;
  paneId: string;
  token: string;
  piSemantic: PiSemanticCapability;
  reducer: PiConversationReducer;
  sseHandle: SseHandle | null;
  queue: PiEventQueue | null;
}

let entry: PiEntry | null = null;
let generation = 0;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function is501(error: unknown): boolean {
  return error instanceof ApiError && error.status === 501;
}

/** Swift `error.localizedDescription` — server messages arrive as Error.message. */
function commandOutcome(payload: PiCommandPayload): { ok: true } | { ok: false; message: string } {
  if (payload.ok === true || payload.success === true) return { ok: true };
  const message = payload.error?.message;
  return { ok: false, message: message ?? "Command was not accepted." };
}

function isUnsupportedProtocol(snapshot: PiConversationSnapshot): boolean {
  return (
    snapshot.protocolInfo.name !== PI_PROTOCOL_NAME ||
    snapshot.protocolInfo.version !== PI_PROTOCOL_VERSION ||
    !snapshot.available
  );
}

/**
 * Swift `snapshotContentChanged(from:to:)` — the legacy poll only re-replaces
 * the reducer when one of these actually changed (Swift compares by value):
 *
 *   previous.ok != current.ok || previous.protocolInfo != current.protocolInfo
 *     || previous.paneID != current.paneID || previous.available != current.available
 *     || previous.connected != current.connected || previous.session != current.session
 *     || previous.state != current.state || previous.entries != current.entries
 *     || previous.pendingInteractions != current.pendingInteractions
 *     || previous.cursor != current.cursor || previous.oldestCursor != current.oldestCursor
 *     || previous.truncated != current.truncated
 */
function snapshotContentChanged(
  previous: PiConversationSnapshot,
  current: PiConversationSnapshot,
): boolean {
  const json = (value: unknown): string => JSON.stringify(value ?? null);
  return (
    previous.ok !== current.ok ||
    previous.protocolInfo.name !== current.protocolInfo.name ||
    previous.protocolInfo.version !== current.protocolInfo.version ||
    previous.paneID !== current.paneID ||
    previous.available !== current.available ||
    previous.connected !== current.connected ||
    json(previous.session) !== json(current.session) ||
    json(previous.state) !== json(current.state) ||
    json(previous.entries) !== json(current.entries) ||
    json(previous.pendingInteractions) !== json(current.pendingInteractions) ||
    previous.cursor !== current.cursor ||
    previous.oldestCursor !== current.oldestCursor ||
    previous.truncated !== current.truncated
  );
}

const LOADING_CONNECTION: PiConversationConnection = { state: "loading" };

const INITIAL_PANE_STATE: Omit<
  PiStoreState,
  | "follow"
  | "stop"
  | "prompt"
  | "steer"
  | "followUp"
  | "abort"
  | "setModel"
  | "setThinkingLevel"
  | "respond"
  | "retryLoadModels"
  | "clearCommandNotice"
> = {
  paneId: null,
  supportsPiSemanticChat: false,
  turns: [],
  pendingInteractions: [],
  phase: "idle",
  connection: LOADING_CONNECTION,
  revision: 0,
  isTruncated: false,
  bridgeConnected: false,
  contextUsage: null,
  currentModel: null,
  availableModels: [],
  isLoadingModels: false,
  isSettingModel: false,
  thinkingLevel: null,
  isSettingThinkingLevel: false,
  modelCatalogError: null,
  isModelSwitchingUnsupported: false,
  isSubmitting: false,
  isAborting: false,
  lastError: null,
  commandNotice: null,
};

// ---------------------------------------------------------------------------
// Loop internals (operate on the entry; `g` is the generation guard — the
// TS form of Swift's `Task.isCancelled` checks)
// ---------------------------------------------------------------------------

function get(): PiStoreState {
  return usePiStore.getState();
}

function set(state: Partial<PiStoreState>): void {
  usePiStore.setState(state);
}

function alive(g: number): boolean {
  return entry !== null && entry.generation === g;
}

/** Swift `publishReducerState` (revision `&+= 1` on every publish). */
function publish(g: number): void {
  if (!alive(g)) return;
  const reducer = entry as PiEntry;
  usePiStore.setState((s) => ({
    turns: [...reducer.reducer.turns],
    pendingInteractions: [...reducer.reducer.pendingInteractions],
    phase: reducer.reducer.phase,
    isTruncated: reducer.reducer.isTruncated,
    bridgeConnected: reducer.reducer.bridgeConnected,
    contextUsage: reducer.reducer.contextUsage,
    currentModel: reducer.reducer.currentModel,
    thinkingLevel: reducer.reducer.thinkingLevel,
    revision: s.revision + 1,
  }));
}

function hasContent(g: number): boolean {
  if (!alive(g)) return false;
  return (entry as PiEntry).reducer.turns.some(piTurnHasVisibleContent);
}

function setBridgeState(g: number, connected: boolean): void {
  if (!alive(g)) return;
  set({
    connection: connected ? { state: "connected" } : { state: "bridgeOffline" },
    lastError: connected ? null : BRIDGE_OFFLINE_MESSAGE,
  });
}

/**
 * Feed one openSSE block back through the PiConversationSSEParser as SSE
 * lines and push the dispatched events into the queue. Parser errors
 * (PiStreamEndedError / PiInvalidResponseError) end the stream — the follow
 * loop owns the backoff (Swift `consume` throwing → the catch path).
 */
function feedParser(
  parser: PiConversationSSEParser,
  queue: PiEventQueue,
  eventName: string,
  data: string,
  id: string | null,
): void {
  const feedLine = (line: string): void => {
    const event = parser.consume(line);
    if (event !== null) queue.push(event);
  };
  try {
    if (eventName !== "message") feedLine(`event: ${eventName}`);
    if (id !== null) feedLine(`id: ${id}`);
    for (const line of data.split("\n")) feedLine(`data: ${line}`);
    feedLine("");
  } catch {
    queue.close();
  }
}

/**
 * Swift `consume(_:)` + the per-envelope store bookkeeping that follows it
 * (`publishReducerState`, `connection`/`lastError` from `reducer.bridgeConnected`).
 * Returns true when the reducer requested an authoritative snapshot.
 */
async function consumeStream(g: number, e: PiEntry, queue: PiEventQueue): Promise<boolean> {
  for await (const streamEvent of queue) {
    if (!alive(g)) return false;
    if (streamEvent.kind !== "envelope") continue;
    const effect = e.reducer.apply(streamEvent.envelope);
    publish(g);
    setBridgeState(g, e.reducer.bridgeConnected);
    if (!alive(g)) return false;
    if (effect === "needsSnapshot") return true;
  }
  return false;
}

/** Swift `followSnapshotPolling` — returns true on auto-upgrade to live SSE. */
async function runSnapshotPolling(
  g: number,
  e: PiEntry,
  initialSnapshot: PiConversationSnapshot,
): Promise<boolean> {
  let previousSnapshot = initialSnapshot;
  let retryDelayMs = SNAPSHOT_POLL_MS;

  while (alive(g)) {
    await sleep(SNAPSHOT_POLL_MS);
    if (!alive(g)) return false;
    try {
      const snapshot = decodePiConversationSnapshot(await piSnapshot(e.paneId));
      if (!alive(g)) return false;
      if (isUnsupportedProtocol(snapshot)) {
        set({ connection: { state: "unavailable" }, lastError: UNAVAILABLE_MESSAGE });
        return false;
      }

      if (snapshotContentChanged(previousSnapshot, snapshot)) {
        e.reducer.replace(snapshot);
        publish(g);
        if (!alive(g)) return false;
        previousSnapshot = snapshot;
      }
      setBridgeState(g, snapshot.connected);
      retryDelayMs = SNAPSHOT_POLL_MS;

      if (piSnapshotReportsContextUsage(snapshot) && snapshot.connected) {
        return true;
      }
    } catch (error) {
      if (!alive(g)) return false;
      retryDelayMs = Math.min(retryDelayMs * POLL_BACKOFF_FACTOR, POLL_BACKOFF_CAP_MS);
      set({
        connection: { state: "reconnecting", attempt: 1 },
        lastError: hasContent(g) ? RECONNECTING_MESSAGE : errorMessage(error),
      });
      await sleep(retryDelayMs);
      if (!alive(g)) return false;
    }
  }
  return false;
}

/** Swift `follow(_:)` main loop. */
async function runFollowLoop(e: PiEntry): Promise<void> {
  const g = e.generation;
  let retryAttempt = 0;
  let retryDelayMs = LIVE_BACKOFF_INITIAL_MS;

  while (alive(g)) {
    try {
      const snapshot = decodePiConversationSnapshot(await piSnapshot(e.paneId));
      if (!alive(g)) return;
      if (isUnsupportedProtocol(snapshot)) {
        set({ connection: { state: "unavailable" }, lastError: UNAVAILABLE_MESSAGE });
        return;
      }

      e.reducer.replace(snapshot);
      publish(g);
      if (!alive(g)) return;
      setBridgeState(g, snapshot.connected);

      if (!piSnapshotReportsContextUsage(snapshot) || !snapshot.connected) {
        const upgraded = await runSnapshotPolling(g, e, snapshot);
        if (!alive(g)) return;
        if (upgraded) {
          retryAttempt = 0;
          retryDelayMs = LIVE_BACKOFF_INITIAL_MS;
          continue;
        }
        return;
      }

      if (e.piSemantic.capabilities.listModels && get().availableModels.length === 0) {
        void loadModels(g, e);
      }

      const queue = createPiEventQueue();
      const parser = new PiConversationSSEParser();
      e.queue = queue;
      e.sseHandle = openSSE({
        cursorKind: "opaque-after",
        token: e.token,
        backoff: {
          initialMs: LIVE_BACKOFF_INITIAL_MS,
          factor: LIVE_BACKOFF_FACTOR,
          capMs: LIVE_BACKOFF_CAP_MS,
        },
        buildUrl: (lastId) => piEventsUrl(e.paneId, lastId ?? e.reducer.cursor),
        onEvent: (eventName, data, id) => feedParser(parser, queue, eventName, data, id),
        onState: (state) => {
          if (state === "reconnecting" && alive(g)) {
            // A drop hands the backoff to the follow loop (Swift re-fetches
            // the snapshot before every reconnect attempt).
            queue.close();
            e.sseHandle?.close();
            e.sseHandle = null;
          }
        },
      });
      const needsSnapshot = await consumeStream(g, e, queue);
      e.sseHandle?.close();
      e.sseHandle = null;
      e.queue?.close();
      e.queue = null;
      if (!alive(g)) return;
      if (needsSnapshot) {
        retryAttempt = 0;
        retryDelayMs = LIVE_BACKOFF_INITIAL_MS;
        continue;
      }
      throw new PiStreamEndedError();
    } catch (error) {
      if (!alive(g)) return;
      retryAttempt += 1;
      set({
        connection: { state: "reconnecting", attempt: retryAttempt },
        lastError: hasContent(g) ? RECONNECTING_MESSAGE : errorMessage(error),
      });
      await sleep(retryDelayMs);
      if (!alive(g)) return;
      retryDelayMs = Math.min(retryDelayMs * LIVE_BACKOFF_FACTOR, LIVE_BACKOFF_CAP_MS);
    }
  }
}

async function loadModels(g: number, e: PiEntry): Promise<void> {
  if (!alive(g) || get().isLoadingModels) return;
  set({ isLoadingModels: true });
  try {
    const response = decodePiModelCatalogResponse(await piModels(e.paneId));
    if (!alive(g)) return;
    usePiStore.setState((s) => ({
      availableModels: response.models,
      modelCatalogError: null,
      currentModel: s.currentModel ?? response.current,
    }));
  } catch (error) {
    if (!alive(g)) return;
    if (is501(error)) {
      set({ isModelSwitchingUnsupported: true });
    } else {
      set({ modelCatalogError: MODELS_ERROR_MESSAGE });
    }
  } finally {
    if (alive(g)) set({ isLoadingModels: false });
  }
}

function canSendCommands(): boolean {
  const s = get();
  return s.bridgeConnected && piConnectionIsConnected(s.connection);
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

export const usePiStore = create<PiStoreState>()((set, get) => {
  const tearDownEntry = (): void => {
    generation += 1;
    if (entry) {
      entry.sseHandle?.close();
      entry.sseHandle = null;
      entry.queue?.close();
      entry.queue = null;
      entry = null;
    }
  };

  const submit = async (text: string, disposition: PiPromptDisposition): Promise<boolean> => {
    const e = entry;
    if (e === null) return false;
    const prompt = text.trim();
    if (prompt === "" || get().isSubmitting) return false;
    if (!canSendCommands()) {
      set({ lastError: SEND_OFFLINE_MESSAGE });
      return false;
    }
    set({ isSubmitting: true, commandNotice: null });
    try {
      const payload =
        disposition === "prompt"
          ? await piPrompt(e.paneId, { text: prompt })
          : disposition === "steer"
            ? await piSteer(e.paneId, { text: prompt })
            : await piFollowUp(e.paneId, { text: prompt });
      const outcome = commandOutcome(payload);
      if (!outcome.ok) {
        set({ lastError: outcome.message, commandNotice: null });
        return false;
      }
      set({ lastError: null, commandNotice: disposition === "followUp" ? "Follow-up queued" : null });
      return true;
    } catch (error) {
      set({ lastError: errorMessage(error), commandNotice: null });
      return false;
    } finally {
      set({ isSubmitting: false });
    }
  };

  return {
    ...INITIAL_PANE_STATE,

    follow: (paneId, token, piSemantic) => {
      tearDownEntry();
      const e: PiEntry = {
        generation,
        paneId,
        token,
        piSemantic,
        reducer: new PiConversationReducer(),
        sseHandle: null,
        queue: null,
      };
      entry = e;
      set({
        ...INITIAL_PANE_STATE,
        paneId,
        supportsPiSemanticChat:
          piSemantic.available && piSemantic.protocolVersion === PI_PROTOCOL_VERSION,
        revision: get().revision + 1,
      });
      void runFollowLoop(e);
    },

    stop: (paneId) => {
      if (entry === null || entry.paneId !== paneId) return;
      tearDownEntry();
      set({ ...INITIAL_PANE_STATE, revision: get().revision + 1 });
    },

    prompt: (text) => submit(text, "prompt"),
    steer: (text) => submit(text, "steer"),
    followUp: (text) => submit(text, "followUp"),

    abort: async () => {
      const e = entry;
      if (e === null || get().isAborting || !canSendCommands()) return false;
      set({ isAborting: true, commandNotice: null });
      try {
        const outcome = commandOutcome(await piAbort(e.paneId, {}));
        if (!outcome.ok) {
          set({ lastError: outcome.message, commandNotice: null });
          return false;
        }
        set({ lastError: null, commandNotice: "Stop requested" });
        return true;
      } catch (error) {
        set({ lastError: errorMessage(error), commandNotice: null });
        return false;
      } finally {
        set({ isAborting: false });
      }
    },

    setModel: async (provider, id) => {
      const e = entry;
      if (e === null || get().isSettingModel || !canSendCommands()) return false;
      set({ isSettingModel: true, commandNotice: null });
      try {
        const payload = await piSetModel(e.paneId, { provider, id });
        const outcome = commandOutcome(payload);
        if (!outcome.ok) {
          set({ lastError: outcome.message });
          return false;
        }
        const known = get().availableModels.find(
          (model) => model.provider === provider && model.modelID === id,
        );
        set({
          lastError: null,
          commandNotice: `Model set to ${known ? piAvailableModelDisplayName(known) : id}`,
        });
        return true;
      } catch (error) {
        set({ lastError: is501(error) ? MODEL_501_MESSAGE : errorMessage(error) });
        return false;
      } finally {
        set({ isSettingModel: false });
      }
    },

    setThinkingLevel: async (level) => {
      const e = entry;
      if (e === null || get().isSettingThinkingLevel || !canSendCommands()) return false;
      set({ isSettingThinkingLevel: true, commandNotice: null });
      try {
        const payload = await piSetThinkingLevel(e.paneId, { level });
        const outcome = commandOutcome(payload);
        if (!outcome.ok) {
          set({ lastError: outcome.message, commandNotice: null });
          return false;
        }
        const response = decodePiSetThinkingLevelResponse(payload);
        const effectiveDisplay =
          response.level !== null
            ? (PI_THINKING_LEVELS as readonly string[]).includes(response.level)
              ? piThinkingLevelDisplayName(response.level as (typeof PI_THINKING_LEVELS)[number])
              : response.level
            : displayThinkingLevel(level);
        set({ lastError: null, commandNotice: `Thinking set to ${effectiveDisplay}` });
        return true;
      } catch (error) {
        set({ lastError: is501(error) ? THINKING_501_MESSAGE : errorMessage(error) });
        return false;
      } finally {
        set({ isSettingThinkingLevel: false });
      }
    },

    respond: async (interactionId, body) => {
      const e = entry;
      if (e === null || !canSendCommands()) {
        set({ lastError: RESPOND_OFFLINE_MESSAGE });
        return false;
      }
      try {
        const outcome = commandOutcome(await piRespond(e.paneId, interactionId, body));
        if (!outcome.ok) {
          set({ lastError: outcome.message });
          return false;
        }
        e.reducer.removeInteraction(interactionId);
        publish(e.generation);
        set({ lastError: null });
        return true;
      } catch (error) {
        set({ lastError: errorMessage(error) });
        return false;
      }
    },

    retryLoadModels: async () => {
      const e = entry;
      if (e === null) return;
      set({ modelCatalogError: null, isModelSwitchingUnsupported: false });
      await loadModels(e.generation, e);
    },

    clearCommandNotice: () => set({ commandNotice: null }),
  };
});

function displayThinkingLevel(level: string): string {
  return (PI_THINKING_LEVELS as readonly string[]).includes(level)
    ? piThinkingLevelDisplayName(level as (typeof PI_THINKING_LEVELS)[number])
    : level;
}
