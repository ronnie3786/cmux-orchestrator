/**
 * Preserve Pi's stock TUI while exposing its semantic event stream locally.
 *
 * The extension owns a pane-specific, mode-0600 Unix socket. The Herdr Harness
 * connects to it for an ordered event subscription and short command requests.
 * Event handlers only enqueue projected records; they never await socket I/O.
 */

import { createHash, randomUUID } from "node:crypto";
import { chmodSync, lstatSync, mkdirSync, unlinkSync, type Stats } from "node:fs";
import { createServer, Socket, type Server } from "node:net";
import { dirname, isAbsolute, join, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const PROTOCOL = { name: "herdr.pi.semantic", version: 1 } as const;
const MAX_LINE_BYTES = 512 * 1024;
const MAX_QUEUE_RECORDS = positiveEnvironmentInt("HERDR_PI_SEMANTIC_MAX_QUEUE_RECORDS", 2048, 8, 65_536);
const MAX_QUEUE_BYTES = positiveEnvironmentInt(
	"HERDR_PI_SEMANTIC_MAX_QUEUE_BYTES",
	4 * 1024 * 1024,
	64 * 1024,
	64 * 1024 * 1024,
);
const MAX_REPLAY_RECORDS = positiveEnvironmentInt("HERDR_PI_SEMANTIC_MAX_REPLAY_RECORDS", 4096, 16, 65_536);
const MAX_REPLAY_BYTES = positiveEnvironmentInt(
	"HERDR_PI_SEMANTIC_MAX_REPLAY_BYTES",
	32 * 1024 * 1024,
	1024 * 1024,
	256 * 1024 * 1024,
);
const MAX_SUBSCRIBE_REPLAY_BYTES = 256 * 1024;
const UNIX_PATH_BYTES = 100;
const SNAPSHOT_ENTRY_BYTES = Math.min(384 * 1024, Math.max(16 * 1024, Math.floor(MAX_QUEUE_BYTES / 2)));

type JsonObject = Record<string, unknown>;
type WireRecord = JsonObject & {
	protocol: typeof PROTOCOL;
	pane_id: string;
	instance_id: string;
	sequence: number;
	kind: string;
	generated_at: string;
};

function positiveEnvironmentInt(name: string, fallback: number, minimum: number, maximum: number): number {
	const value = Number.parseInt(process.env[name] ?? "", 10);
	return Number.isInteger(value) && value >= minimum && value <= maximum ? value : fallback;
}

function digest(value: string): string {
	return createHash("sha256").update(value).digest("hex");
}

function privateDirectories(): Set<string> {
	const uid = process.getuid?.() ?? 0;
	return new Set([`/tmp/herdr-pi-${uid}`, `/tmp/hp-${uid}`]);
}

function ensurePrivateDirectory(path: string): void {
	if (!privateDirectories().has(path)) throw new Error("Pi semantic socket directory is not bridge-owned");
	try {
		const metadata = lstatSync(path);
		if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error("Pi semantic socket directory is unsafe");
		if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) {
			throw new Error("Pi semantic socket directory belongs to another user");
		}
		if ((metadata.mode & 0o077) !== 0) chmodSync(path, 0o700);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
		mkdirSync(path, { recursive: true, mode: 0o700 });
		chmodSync(path, 0o700);
	}
}

export function semanticSocketPath(herdrPath: string, paneId: string): string {
	const source = resolve(herdrPath);
	if (!paneId || source.includes("\0") || paneId.includes("\0")) throw new Error("Herdr path and pane ID are required");
	const uid = process.getuid?.() ?? 0;
	const filename = `${digest(source).slice(0, 8)}-${digest(paneId)}.sock`;
	let path = join(`/tmp/herdr-pi-${uid}`, filename);
	if (Buffer.byteLength(path) > UNIX_PATH_BYTES) path = join(`/tmp/hp-${uid}`, filename);
	if (Buffer.byteLength(path) > UNIX_PATH_BYTES) throw new Error("Pi semantic socket path is too long");
	return path;
}

function jsonSafe(value: unknown, depth = 0, seen = new WeakSet<object>()): unknown {
	if (value === null || typeof value === "string" || typeof value === "boolean") return value;
	if (typeof value === "number") return Number.isFinite(value) ? value : String(value);
	if (typeof value === "bigint") return value.toString();
	if (typeof value === "undefined" || typeof value === "function" || typeof value === "symbol") return undefined;
	if (depth >= 24) return { omitted: true, reason: "depth_limit" };
	if (Array.isArray(value)) return value.map((item) => jsonSafe(item, depth + 1, seen));
	if (typeof value === "object") {
		if (seen.has(value)) return { omitted: true, reason: "cycle" };
		seen.add(value);
		const result: JsonObject = {};
		for (const [key, item] of Object.entries(value)) {
			// Provider signatures and raw image bytes are not useful to the native
			// transcript and can be both sensitive and enormous.
			const normalizedKey = key.replaceAll("_", "").toLowerCase();
			if (normalizedKey.endsWith("signature")) {
				result[key] = { omitted: true, reason: "provider_signature" };
				continue;
			}
			if ((key === "data" || key === "bytes") && typeof item === "string" && item.length > 16_384) {
				result[key] = { omitted: true, reason: "binary_payload", length: item.length };
				continue;
			}
			const projected = jsonSafe(item, depth + 1, seen);
			if (projected !== undefined) result[key] = projected;
		}
		seen.delete(value);
		return result;
	}
	return String(value);
}

function encoded(record: unknown): Buffer {
	return Buffer.from(`${JSON.stringify(record)}\n`, "utf8");
}

function stableEntryId(entry: unknown, index: number): string {
	if (entry && typeof entry === "object" && typeof (entry as JsonObject).id === "string") {
		return (entry as JsonObject).id as string;
	}
	return `entry-${index}-${digest(JSON.stringify(jsonSafe(entry))).slice(0, 16)}`;
}

function projectedEntries(ctx: ExtensionContext): { entries: unknown[]; truncated: boolean } {
	const source = ctx.sessionManager.buildContextEntries();
	let omittedOversized = false;
	const projected = source.flatMap((entry, index) => {
		const safe = jsonSafe(entry) as JsonObject;
		const projectedEntry = {
			...safe,
			id: typeof safe?.id === "string" ? safe.id : stableEntryId(entry, index),
			parentId: safe?.parentId ?? safe?.parent_id ?? null,
			timestamp: safe?.timestamp ?? null,
		};
		if (Buffer.byteLength(JSON.stringify(projectedEntry)) > SNAPSHOT_ENTRY_BYTES) {
			omittedOversized = true;
			return [];
		}
		return [projectedEntry];
	});
	const entries: unknown[] = [];
	let size = 0;
	for (let index = projected.length - 1; index >= 0; index -= 1) {
		const item = projected[index];
		const itemSize = Buffer.byteLength(JSON.stringify(item));
		if (entries.length > 0 && size + itemSize > SNAPSHOT_ENTRY_BYTES) break;
		if (itemSize > SNAPSHOT_ENTRY_BYTES) continue;
		entries.unshift(item);
		size += itemSize;
	}
	return { entries, truncated: omittedOversized || entries.length !== projected.length };
}

function projectAssistantUpdate(event: JsonObject): JsonObject {
	const update = event.assistantMessageEvent as JsonObject | undefined;
	if (!update) return {};
	const result: JsonObject = { type: update.type };
	for (const key of ["contentIndex", "delta", "content", "reason", "toolCall"] as const) {
		if (update[key] !== undefined) result[key] = jsonSafe(update[key]);
	}
	// `partial` and the outer cumulative `message` are intentionally excluded.
	// Pi emits them on every token, which otherwise produces quadratic traffic.
	return { assistantMessageEvent: result };
}

function projectEvent(type: string, event: unknown): JsonObject | undefined {
	const value = event && typeof event === "object" ? event as JsonObject : {};
	switch (type) {
		case "before_agent_start":
		case "tool_call":
		case "tool_result":
		case "session_before_switch":
		case "session_before_fork":
		case "session_before_compact":
		case "session_before_tree":
			return undefined;
		case "agent_end":
			return {};
		case "turn_end":
			return { turnIndex: value.turnIndex, timestamp: value.timestamp };
		case "message_start":
		case "message_end":
			return { message: jsonSafe(value.message) };
		case "message_update":
			return projectAssistantUpdate(value);
		case "tool_execution_start":
			return jsonSafe({ toolCallId: value.toolCallId, toolName: value.toolName, args: value.args }) as JsonObject;
		case "tool_execution_update":
			return jsonSafe({ toolCallId: value.toolCallId, toolName: value.toolName, partialResult: value.partialResult }) as JsonObject;
		case "tool_execution_end":
			return jsonSafe({ toolCallId: value.toolCallId, toolName: value.toolName, result: value.result, isError: value.isError }) as JsonObject;
		case "input":
			return jsonSafe({ source: value.source, streamingBehavior: value.streamingBehavior }) as JsonObject;
		case "model_select":
			return {
				model: modelIdentity(value.model),
				previousModel: modelIdentity(value.previousModel),
				source: value.source,
			};
		default:
			return jsonSafe(value) as JsonObject;
	}
}

function session(ctx: ExtensionContext): JsonObject {
	return {
		id: ctx.sessionManager.getSessionId(),
		file: ctx.sessionManager.getSessionFile(),
		cwd: ctx.sessionManager.getCwd(),
		leafId: ctx.sessionManager.getLeafId(),
		name: ctx.sessionManager.getSessionName(),
		header: jsonSafe(ctx.sessionManager.getHeader()),
	};
}

function modelIdentity(value: unknown): JsonObject | null {
	if (!value || typeof value !== "object") return null;
	const model = value as JsonObject;
	return {
		provider: model.provider,
		id: model.id ?? model.modelId,
		name: model.name,
	};
}

type SocketIdentity = { device: number; inode: number };

function socketIdentity(metadata: Stats): SocketIdentity {
	return { device: metadata.dev, inode: metadata.ino };
}

function sameSocket(metadata: Stats, expected: SocketIdentity): boolean {
	return metadata.isSocket()
		&& !metadata.isSymbolicLink()
		&& metadata.dev === expected.device
		&& metadata.ino === expected.inode;
}

class BridgeRuntime {
	private readonly paneId: string;
	private readonly path: string;
	private instanceId = randomUUID();
	private server?: Server;
	private sequence = 0;
	private queue: Array<{ record: WireRecord; bytes: Buffer; replaceKey?: string }> = [];
	private queueBytes = 0;
	private replay: Array<{ record: WireRecord; bytes: Buffer }> = [];
	private replayBytes = 0;
	private subscribers = new Set<Socket>();
	private blocked = new Set<Socket>();
	private latestContext?: ExtensionContext;
	private active = false;
	private ownsSocket = false;
	private ownedSocketIdentity?: SocketIdentity;
	private lastSessionId?: string;
	private hasStarted = false;

	constructor(private readonly pi: ExtensionAPI, herdrPath: string, paneId: string) {
		this.paneId = paneId;
		this.path = semanticSocketPath(herdrPath, paneId);
	}

	start(ctx: ExtensionContext): void {
		this.latestContext = ctx;
		const sessionId = ctx.sessionManager.getSessionId();
		if (this.hasStarted && (!this.active || this.lastSessionId !== sessionId)) this.rotateSource();
		this.hasStarted = true;
		this.lastSessionId = sessionId;
		if (this.active) return;
		this.active = true;
		ensurePrivateDirectory(dirname(this.path));
		try {
			const metadata = lstatSync(this.path);
			if (!metadata.isSocket() || metadata.isSymbolicLink()) throw new Error("Existing Pi bridge path is unsafe");
			if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) {
				throw new Error("Existing Pi bridge socket belongs to another user");
			}
			if ((metadata.mode & 0o077) !== 0) throw new Error("Existing Pi bridge socket permissions are unsafe");
			const expected = socketIdentity(metadata);
			const probe = new Socket();
			probe.once("connect", () => {
				probe.destroy();
				this.active = false;
			});
			probe.once("error", () => {
				probe.destroy();
				try {
					const current = lstatSync(this.path);
					if (!sameSocket(current, expected)) {
						this.active = false;
						return;
					}
					unlinkSync(this.path);
					this.listen();
				} catch (error) {
					if ((error as NodeJS.ErrnoException).code === "ENOENT") this.listen();
					else this.active = false;
				}
			});
			probe.connect(this.path);
			probe.unref();
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
			this.listen();
		}
	}

	private rotateSource(): void {
		this.instanceId = randomUUID();
		this.sequence = 0;
		this.queue = [];
		this.queueBytes = 0;
		this.replay = [];
		this.replayBytes = 0;
	}

	private listen(): void {
		if (!this.active || this.server) return;
		const server = createServer((socket) => this.accept(socket));
		this.server = server;
		server.on("error", () => {
			this.ownsSocket = false;
			this.ownedSocketIdentity = undefined;
			this.active = false;
		});
		server.listen(this.path, () => {
			try {
				chmodSync(this.path, 0o600);
				const metadata = lstatSync(this.path);
				if (!metadata.isSocket() || metadata.isSymbolicLink()) throw new Error("Pi bridge socket changed while binding");
				this.ownedSocketIdentity = socketIdentity(metadata);
				this.ownsSocket = true;
			} catch {
				this.ownsSocket = false;
				this.ownedSocketIdentity = undefined;
				this.active = false;
				server.close();
			}
		});
		server.unref();
	}

	setContext(ctx: ExtensionContext): void {
		this.latestContext = ctx;
	}

	emit(type: string, payload: unknown, replaceKey?: string): void {
		const ctx = this.latestContext;
		if (!ctx) return;
		const projected = projectEvent(type, payload);
		if (projected === undefined) return;
		const record: WireRecord = {
			protocol: PROTOCOL,
			pane_id: this.paneId,
			instance_id: this.instanceId,
			sequence: ++this.sequence,
			kind: "event",
			session_id: ctx.sessionManager.getSessionId(),
			event: { ...projected, type },
			generated_at: new Date().toISOString(),
		};
		this.enqueue(record, replaceKey);
	}

	snapshot(ctx: ExtensionContext): WireRecord {
		const projection = projectedEntries(ctx);
		return {
			protocol: PROTOCOL,
			pane_id: this.paneId,
			instance_id: this.instanceId,
			sequence: this.sequence,
			kind: "snapshot",
			session_id: ctx.sessionManager.getSessionId(),
			snapshot: {
				protocol: PROTOCOL,
				session: session(ctx),
				state: {
					idle: ctx.isIdle(),
					working: !ctx.isIdle(),
					isStreaming: !ctx.isIdle(),
					pendingMessages: ctx.hasPendingMessages(),
					model: modelIdentity(ctx.model),
					thinkingLevel: ctx.thinkingLevel,
					mode: ctx.mode,
				},
				entries: projection.entries,
				pending_interactions: [],
				truncated: projection.truncated,
				generated_at: new Date().toISOString(),
			},
			generated_at: new Date().toISOString(),
		};
	}

	private hello(ctx: ExtensionContext): WireRecord {
		return {
			protocol: PROTOCOL,
			pane_id: this.paneId,
			instance_id: this.instanceId,
			sequence: this.sequence,
			kind: "hello",
			session_id: ctx.sessionManager.getSessionId(),
			capabilities: {
				prompt: true,
				steer: true,
				followUp: true,
				abort: true,
				interactionResponse: false,
			},
			generated_at: new Date().toISOString(),
		};
	}

	private enqueue(record: WireRecord, replaceKey?: string): void {
		let bytes = encoded(record);
		if (bytes.length > MAX_LINE_BYTES) {
			const eventType = (record.event as JsonObject | undefined)?.type;
			record = {
				...record,
				event: { type: "bridge.payload_omitted", originalType: eventType, payloadBytes: bytes.length },
			};
			bytes = encoded(record);
		}
		if (replaceKey) {
			const index = this.queue.findIndex((item) => item.replaceKey === replaceKey);
			if (index >= 0) {
				this.queueBytes -= this.queue[index].bytes.length;
				this.queue.splice(index, 1);
			}
		}
		let dropped = false;
		while (this.queue.length >= MAX_QUEUE_RECORDS || this.queueBytes + bytes.length > MAX_QUEUE_BYTES) {
			const replaceable = this.queue.findIndex((item) => item.replaceKey !== undefined);
			if (replaceable < 0) break;
			this.queueBytes -= this.queue[replaceable].bytes.length;
			this.queue.splice(replaceable, 1);
			dropped = true;
		}
		if (this.queue.length >= MAX_QUEUE_RECORDS || this.queueBytes + bytes.length > MAX_QUEUE_BYTES) {
			// Losing a semantic delta without telling the client would corrupt its
			// reducer. Replace pending records with an authoritative snapshot followed
			// by a reset, so an HTTP reload can never adopt stale transcript entries.
			this.queueRecovery("extension_queue_overflow", true);
			return;
		} else if (dropped) {
			// Coalesced cumulative updates are safe, so no reset is required.
		}
		this.queue.push({ record, bytes, replaceKey });
		this.queueBytes += bytes.length;
		queueMicrotask(() => this.flush());
	}

	recover(reason: string): void {
		this.queueRecovery(reason, false);
	}

	checkpoint(): void {
		const ctx = this.latestContext;
		if (!ctx) return;
		const record = this.snapshot(ctx);
		const bytes = encoded(record);
		if (bytes.length > MAX_LINE_BYTES) return;
		if (this.queue.length >= MAX_QUEUE_RECORDS || this.queueBytes + bytes.length > MAX_QUEUE_BYTES) {
			this.flush();
		}
		this.queue.push({ record, bytes });
		this.queueBytes += bytes.length;
		queueMicrotask(() => this.flush());
	}

	private queueRecovery(reason: string, clear: boolean): void {
		const ctx = this.latestContext;
		if (!ctx) return;
		if (clear) {
			this.queue = [];
			this.queueBytes = 0;
		}
		const reset: WireRecord = {
			protocol: PROTOCOL,
			pane_id: this.paneId,
			instance_id: this.instanceId,
			sequence: ++this.sequence,
			kind: "reset",
			session_id: ctx.sessionManager.getSessionId(),
			event: { type: "stream.reset", reason },
			generated_at: new Date().toISOString(),
		};
		const snapshot = this.snapshot(ctx);
		reset.snapshot = snapshot.snapshot;
		const bytes = encoded(reset);
		if (bytes.length > MAX_LINE_BYTES) return;
		this.queue.push({ record: reset, bytes });
		this.queueBytes += bytes.length;
		queueMicrotask(() => this.flush());
	}

	private flush(): void {
		while (this.queue.length > 0) {
			const item = this.queue.shift()!;
			this.queueBytes -= item.bytes.length;
			this.replay.push({ record: item.record, bytes: item.bytes });
			this.replayBytes += item.bytes.length;
			while (this.replay.length > MAX_REPLAY_RECORDS || this.replayBytes > MAX_REPLAY_BYTES) {
				this.replayBytes -= this.replay.shift()!.bytes.length;
			}
			for (const socket of this.subscribers) this.write(socket, item.bytes);
		}
	}

	private write(socket: Socket, bytes: Buffer): void {
		if (socket.destroyed) return;
		if (this.blocked.has(socket)) {
			socket.destroy();
			return;
		}
		if (!socket.write(bytes) && this.subscribers.has(socket)) {
			// A subscriber can recover from the bounded replay on reconnect. Keeping
			// an unbounded per-client buffer here would threaten Pi's TUI process.
			this.blocked.add(socket);
		}
	}

	private accept(socket: Socket): void {
		socket.setNoDelay(true);
		socket.unref();
		let buffer = Buffer.alloc(0);
		socket.on("drain", () => this.blocked.delete(socket));
		socket.on("close", () => {
			this.subscribers.delete(socket);
			this.blocked.delete(socket);
		});
		socket.on("data", (chunk: Buffer) => {
			buffer = Buffer.concat([buffer, chunk]);
			if (buffer.length > MAX_LINE_BYTES) {
				socket.destroy();
				return;
			}
			let newline = buffer.indexOf(0x0a);
			while (newline >= 0) {
				const raw = buffer.subarray(0, newline);
				buffer = buffer.subarray(newline + 1);
				if (raw.length > 0) this.handleLine(socket, raw);
				newline = buffer.indexOf(0x0a);
			}
		});
	}

	private handleLine(socket: Socket, raw: Buffer): void {
		let request: JsonObject;
		try {
			request = JSON.parse(raw.toString("utf8")) as JsonObject;
		} catch {
			socket.destroy();
			return;
		}
		const protocol = request.protocol as JsonObject | undefined;
		if (protocol?.name !== PROTOCOL.name || protocol.version !== PROTOCOL.version || request.pane_id !== this.paneId) {
			this.respond(socket, request, false, undefined, "protocol_error", "Incompatible Pi semantic request");
			return;
		}
		if (request.type === "subscribe") {
			const ctx = this.latestContext;
			if (!ctx) return;
			const frames: Buffer[] = [encoded(this.hello(ctx))];
			const requestedInstance = typeof request.instance_id === "string" ? request.instance_id : undefined;
			const after = typeof request.after === "number" ? request.after : 0;
			if (requestedInstance && requestedInstance === this.instanceId) {
				const oldest = this.replay.at(0)?.record.sequence ?? this.sequence + 1;
				const pending = this.replay.filter((item) => item.record.sequence > after);
				const pendingBytes = pending.reduce((total, item) => total + item.bytes.length, 0);
				if ((after && after < oldest - 1) || pendingBytes > MAX_SUBSCRIBE_REPLAY_BYTES) {
					const currentSnapshot = this.snapshot(ctx);
					frames.push(encoded({
						protocol: PROTOCOL,
						pane_id: this.paneId,
						instance_id: this.instanceId,
						sequence: ++this.sequence,
						kind: "reset",
						session_id: ctx.sessionManager.getSessionId(),
						event: {
							type: "stream.reset",
							reason: pendingBytes > MAX_SUBSCRIBE_REPLAY_BYTES ? "replay_too_large" : "replay_gap",
							resumeAfter: oldest - 1,
						},
						snapshot: currentSnapshot.snapshot,
						generated_at: new Date().toISOString(),
					}));
				} else {
					for (const item of pending) frames.push(item.bytes);
				}
			}
			// The checkpoint comes after replay/reset. Its snapshot_cursor therefore
			// covers every preceding frame and a new HTTP client cannot double-apply it.
			frames.push(encoded(this.snapshot(ctx)));
			const batch = Buffer.concat(frames);
			this.subscribers.add(socket);
			if (!socket.write(batch)) this.blocked.add(socket);
			return;
		}
		if (request.type === "command") {
			this.command(socket, request);
			return;
		}
		this.respond(socket, request, false, undefined, "unsupported", "Unsupported Pi semantic request");
	}

	private command(socket: Socket, request: JsonObject): void {
		const ctx = this.latestContext;
		if (!ctx) {
			this.respond(socket, request, false, undefined, "bridge_unavailable", "Pi bridge is not ready");
			return;
		}
		const command = String(request.command ?? "");
		const payload = request.payload as JsonObject | undefined;
		const text = typeof payload?.text === "string" ? payload.text.trim() : "";
		try {
			switch (command) {
				case "prompt":
					if (!text) throw new Error("Prompt text is required");
					if (!ctx.isIdle()) throw new Error("Pi is busy; use steer or follow-up");
					this.pi.sendUserMessage(text);
					break;
				case "steer":
					if (!text) throw new Error("Steering text is required");
					this.pi.sendUserMessage(text, ctx.isIdle() ? undefined : { deliverAs: "steer" });
					break;
				case "follow_up":
					if (!text) throw new Error("Follow-up text is required");
					this.pi.sendUserMessage(text, ctx.isIdle() ? undefined : { deliverAs: "followUp" });
					break;
				case "abort":
					if (ctx.isIdle()) throw new Error("Pi is already idle");
					ctx.abort();
					break;
				case "interaction_response":
					this.respond(socket, request, false, undefined, "unsupported", "Stock TUI extension dialogs stay in the terminal");
					return;
				default:
					this.respond(socket, request, false, undefined, "unsupported", "Unsupported Pi command");
					return;
			}
			this.respond(socket, request, true, { accepted: true, command });
		} catch (error) {
			this.respond(socket, request, false, undefined, "command_rejected", String((error as Error).message || error));
		}
	}

	private respond(
		socket: Socket,
		request: JsonObject,
		success: boolean,
		result?: unknown,
		code?: string,
		message?: string,
	): void {
		this.write(socket, encoded({
			protocol: PROTOCOL,
			pane_id: this.paneId,
			type: "response",
			request_id: request.id,
			success,
			result: jsonSafe(result),
			error: success ? undefined : { code, message },
			generated_at: new Date().toISOString(),
		}));
	}

	shutdown(): void {
		this.flush();
		this.active = false;
		for (const socket of this.subscribers) socket.end();
		this.subscribers.clear();
		this.blocked.clear();
		this.server?.close();
		this.server = undefined;
		if (this.ownsSocket && this.ownedSocketIdentity) {
			try {
				const metadata = lstatSync(this.path);
				if (sameSocket(metadata, this.ownedSocketIdentity)) unlinkSync(this.path);
			} catch { /* already removed */ }
		}
		this.ownsSocket = false;
		this.ownedSocketIdentity = undefined;
	}
}

function replaceKeyFor(type: string, event: unknown): string | undefined {
	if (!event || typeof event !== "object") return undefined;
	const value = event as JsonObject;
	// message_update text/thinking/tool-call updates are true deltas in current
	// Pi, so they must never be coalesced. Tool execution partialResult is
	// cumulative and can safely replace an unsent earlier update for that call.
	if (type === "tool_execution_update") return `tool:${String(value.toolCallId ?? "unknown")}`;
	return undefined;
}

export default function piSemanticBridge(pi: ExtensionAPI): void {
	const herdrPath = process.env.HERDR_SOCKET_PATH;
	const paneId = process.env.HERDR_PANE_ID;
	if (!herdrPath || !isAbsolute(herdrPath) || !paneId) return;
	const runtime = new BridgeRuntime(pi, herdrPath, paneId);

	const events = [
		"session_info_changed", "session_before_switch", "session_before_fork", "session_before_compact",
		"session_compact", "session_before_tree", "session_tree", "before_agent_start", "agent_start",
		"agent_end", "agent_settled", "turn_start", "turn_end", "message_start", "message_update",
		"message_end", "tool_execution_start", "tool_execution_update", "tool_execution_end", "model_select",
		"thinking_level_select", "input", "tool_call", "tool_result",
	] as const;

	pi.on("session_start", (event, ctx) => {
		runtime.start(ctx);
		runtime.emit("session_start", event);
		runtime.recover("session_started");
	});
	for (const type of events) {
		// ExtensionAPI's overloads cannot express a dynamic, statically known
		// event tuple. Runtime registration still retains each native event raw.
		(pi.on as unknown as (name: string, handler: (event: unknown, ctx: ExtensionContext) => void) => void)(
			type,
			(event, ctx) => {
				runtime.setContext(ctx);
				runtime.emit(type, event, replaceKeyFor(type, event));
				if (type === "agent_settled") runtime.checkpoint();
				if (type === "session_tree" || type === "session_compact") {
					runtime.recover(type === "session_tree" ? "session_tree_changed" : "session_compacted");
				}
			},
		);
	}
	pi.on("session_shutdown", (event, ctx) => {
		runtime.setContext(ctx);
		runtime.emit("session_shutdown", event);
		runtime.checkpoint();
		runtime.shutdown();
	});
}
