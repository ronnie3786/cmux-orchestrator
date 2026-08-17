import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createConnection } from "node:net";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const temporary = mkdtempSync(join(tmpdir(), "pi-semantic-extension-test-"));
process.env.HERDR_SOCKET_PATH = join(temporary, "herdr.sock");
process.env.HERDR_PANE_ID = "w1:p1";
process.env.HERDR_PI_SEMANTIC_MAX_QUEUE_RECORDS = "8";
process.env.HERDR_PI_SEMANTIC_MAX_QUEUE_BYTES = String(64 * 1024);

const jitiCandidates = [
	"/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti.mjs",
	"/Users/ronnierocha/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti.mjs",
	join(homedir(), "node_modules/jiti/lib/jiti.mjs"),
];
const jitiPath = jitiCandidates.find((candidate) => existsSync(candidate));
if (!jitiPath) throw new Error(`jiti not found; tried:\n${jitiCandidates.join("\n")}`);
const { createJiti } = await import(pathToFileURL(jitiPath).href);
const jiti = createJiti(import.meta.url);
const bridgeModule = await jiti.import("../extensions/pi-semantic-bridge.ts");
const handlers = new Map();
const sent = [];
let aborted = false;
const setModelCalls = [];
let setModelResult = true;
const setThinkingLevelCalls = [];
let effectiveThinkingLevel = "high";
const availableModels = [
	{ provider: "test", id: "model", name: "Test Model", reasoning: true, contextWindow: 128000 },
	{ provider: "other", id: "other-model", name: "Other Model", reasoning: false, contextWindow: 32000 },
];
const pi = {
	on(type, handler) { handlers.set(type, handler); },
	sendUserMessage(text, options) { sent.push({ text, options }); },
	async setModel(model) {
		setModelCalls.push(model);
		return setModelResult;
	},
	setThinkingLevel(level) {
		setThinkingLevelCalls.push(level);
	},
	getThinkingLevel() {
		return effectiveThinkingLevel;
	},
};

let idle = true;
let contextUsageValue = { tokens: 12_345, contextWindow: 192_000, percent: 6.43 };
const entries = [
	{
		type: "message",
		id: "entry-1",
		parentId: null,
		timestamp: "2026-08-12T00:00:00Z",
		message: { role: "user", content: "hello" },
		future: {
			kept: true,
			thinkingSignature: "secret-thinking",
			thought_signature: "secret-thought",
		},
	},
];
const context = {
	mode: "tui",
	model: { provider: "test", id: "model" },
	thinkingLevel: "high",
	isIdle: () => idle,
	getContextUsage: () => contextUsageValue,
	hasPendingMessages: () => false,
	abort: () => { aborted = true; },
	modelRegistry: {
		getAvailable: () => availableModels,
		find: (provider, id) => availableModels.find((item) => item.provider === provider && item.id === id),
	},
	scopedModels: [],
	sessionManager: {
		getSessionId: () => "session-1",
		getSessionFile: () => "/tmp/session.jsonl",
		getCwd: () => "/tmp/project",
		getLeafId: () => "entry-1",
		getSessionName: () => "Fixture",
		getHeader: () => ({ type: "session", version: 3, id: "session-1" }),
		getEntries: () => entries,
		buildContextEntries: () => entries,
	},
};

function readRecords(socket, until) {
	return new Promise((resolve, reject) => {
		const records = [];
		let buffered = "";
		const timeout = setTimeout(() => reject(new Error("timed out waiting for bridge records")), 3000);
		socket.on("data", (chunk) => {
			buffered += chunk.toString("utf8");
			let newline = buffered.indexOf("\n");
			while (newline >= 0) {
				const raw = buffered.slice(0, newline);
				buffered = buffered.slice(newline + 1);
				if (raw) records.push(JSON.parse(raw));
				if (until(records)) {
					clearTimeout(timeout);
					resolve(records);
					return;
				}
				newline = buffered.indexOf("\n");
			}
		});
		socket.on("error", reject);
	});
}

async function connect(path) {
	for (let attempt = 0; attempt < 60; attempt += 1) {
		try {
			return await new Promise((resolve, reject) => {
				const socket = createConnection(path, () => resolve(socket));
				socket.once("error", reject);
			});
		} catch {
			await delay(20);
		}
	}
	throw new Error("extension socket never appeared");
}

try {
	bridgeModule.default(pi);
	assert.ok(handlers.has("session_start"));
	assert.ok(handlers.has("message_update"));
	assert.ok(handlers.has("session_shutdown"));
	await handlers.get("session_start")({ type: "session_start", reason: "startup" }, context);

	const socketPath = bridgeModule.semanticSocketPath(process.env.HERDR_SOCKET_PATH, process.env.HERDR_PANE_ID);
	const subscription = await connect(socketPath);
	const snapshotPromise = readRecords(subscription, (records) => records.some((item) => item.kind === "snapshot"));
	subscription.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "subscribe-1",
		type: "subscribe",
		pane_id: "w1:p1",
		after: 0,
	})}\n`);
	const initial = await snapshotPromise;
	const snapshot = initial.find((item) => item.kind === "snapshot").snapshot;
	assert.equal(snapshot.entries[0].id, "entry-1");
	assert.equal(snapshot.entries[0].parentId, null);
	assert.equal(snapshot.entries[0].future.kept, true);
	assert.equal(snapshot.entries[0].future.thinkingSignature.reason, "provider_signature");
	assert.equal(snapshot.entries[0].future.thought_signature.reason, "provider_signature");
	assert.equal(snapshot.state.idle, true);
	assert.equal(snapshot.state.working, false);
	assert.equal(snapshot.state.isStreaming, false);
	assert.deepEqual(snapshot.state.context, { tokens: 12_345, contextWindow: 192_000, percent: 6.43 });
	const hello = initial.find((item) => item.kind === "hello");
	assert.equal(hello.capabilities.listModels, true);
	assert.equal(hello.capabilities.setModel, true);
	assert.equal(hello.capabilities.setThinkingLevel, true);

	const deltas = [];
	const privateSentinel = "PRIVATE-SYSTEM-PROMPT-MUST-NOT-CROSS-WIRE";
	handlers.get("before_agent_start")({
		type: "before_agent_start",
		systemPrompt: privateSentinel,
		messages: [{ role: "user", content: privateSentinel }],
	}, context);
	handlers.get("session_before_compact")({
		type: "session_before_compact",
		branchEntries: [{ id: "inactive", content: privateSentinel.repeat(20_000) }],
		customInstructions: privateSentinel,
	}, context);
	handlers.get("session_before_tree")({
		type: "session_before_tree",
		entriesToSummarize: [{ id: "inactive-tree", content: privateSentinel.repeat(20_000) }],
	}, context);
	for (let index = 0; index < 6; index += 1) {
		const delta = String(index);
		deltas.push(delta);
		handlers.get("message_update")({
			type: "message_update",
			assistantMessageEvent: {
				type: "text_delta",
				contentIndex: 0,
				delta,
				partial: { role: "assistant", content: "x".repeat(200_000) },
			},
			message: { role: "assistant", content: "x".repeat(200_000) },
		}, context);
	}
	const deltaRecords = await readRecords(subscription, (records) => records.filter(
		(item) => item.event?.type === "message_update",
	).length === deltas.length);
	assert.deepEqual(
		deltaRecords.filter((item) => item.event?.type === "message_update")
			.map((item) => item.event.assistantMessageEvent.delta),
		deltas,
	);
	assert.equal(JSON.stringify(deltaRecords).includes(privateSentinel), false);
	assert.equal(JSON.stringify(deltaRecords).includes('"partial"'), false);
	assert.equal(JSON.stringify(deltaRecords).includes('"message":{"role":"assistant"'), false);

	handlers.get("turn_end")({ type: "turn_end", turnIndex: 1 }, context);
	const turnEndRecords = await readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "turn_end",
	));
	assert.deepEqual(
		turnEndRecords.find((item) => item.event?.type === "turn_end").event.context,
		{ tokens: 12_345, contextWindow: 192_000, percent: 6.43 },
	);

	entries.push({
		type: "message",
		id: "entry-2",
		parentId: "entry-1",
		timestamp: "2026-08-12T00:01:00Z",
		message: { role: "assistant", content: [{ type: "text", text: "completed answer" }] },
	});
	idle = true;
	contextUsageValue = undefined;
	const settledCheckpoint = readRecords(subscription, (records) => records.some(
		(item) => item.kind === "snapshot" && item.snapshot?.entries?.some((entry) => entry.id === "entry-2"),
	));
	await handlers.get("agent_settled")({ type: "agent_settled" }, context);
	const settled = await settledCheckpoint;
	assert.ok(settled.some((item) => item.kind === "snapshot" && item.snapshot.entries.at(-1).id === "entry-2"));
	assert.deepEqual(settled.find((item) => item.kind === "snapshot").snapshot.state.context,
		{ tokens: null, contextWindow: null, percent: null },
	);

	const prompt = await connect(socketPath);
	const promptResponse = readRecords(prompt, (records) => records.some((item) => item.request_id === "prompt-1"));
	prompt.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "prompt-1",
		type: "command",
		pane_id: "w1:p1",
		command: "prompt",
		payload: { text: "Fix it" },
	})}\n`);
	assert.equal((await promptResponse)[0].success, true);
	assert.deepEqual(sent.at(-1), { text: "Fix it", options: undefined });
	prompt.destroy();

	idle = false;
	const abort = await connect(socketPath);
	const abortResponse = readRecords(abort, (records) => records.some((item) => item.request_id === "abort-1"));
	abort.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "abort-1",
		type: "command",
		pane_id: "w1:p1",
		command: "abort",
		payload: {},
	})}\n`);
	assert.equal((await abortResponse)[0].success, true);
	assert.equal(aborted, true);
	abort.destroy();

	const listModels = await connect(socketPath);
	const listModelsResponse = readRecords(listModels, (records) => records.some((item) => item.request_id === "list-models-1"));
	listModels.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "list-models-1",
		type: "command",
		pane_id: "w1:p1",
		command: "list_models",
		payload: {},
	})}\n`);
	const listedModels = (await listModelsResponse)[0];
	assert.equal(listedModels.success, true);
	assert.equal(listedModels.result.scoped, false);
	assert.equal(listedModels.result.models.length, 2);
	for (const model of listedModels.result.models) {
		assert.equal(typeof model.provider, "string");
		assert.equal(typeof model.id, "string");
		assert.equal(typeof model.name, "string");
		assert.equal(typeof model.reasoning, "boolean");
		assert.equal(typeof model.contextWindow, "number");
	}
	assert.equal(listedModels.result.current.provider, "test");
	assert.equal(listedModels.result.current.id, "model");
	listModels.destroy();

	context.scopedModels = [{ model: availableModels[0] }];
	const scopedModels = await connect(socketPath);
	const scopedModelsResponse = readRecords(scopedModels, (records) => records.some((item) => item.request_id === "list-models-2"));
	scopedModels.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "list-models-2",
		type: "command",
		pane_id: "w1:p1",
		command: "list_models",
		payload: {},
	})}\n`);
	const listedScopedModels = (await scopedModelsResponse)[0];
	assert.equal(listedScopedModels.success, true);
	assert.equal(listedScopedModels.result.scoped, true);
	assert.equal(listedScopedModels.result.models.length, 1);
	assert.equal(listedScopedModels.result.models[0].id, "model");
	scopedModels.destroy();

	const outOfScopeModel = await connect(socketPath);
	const outOfScopeModelResponse = readRecords(outOfScopeModel, (records) => records.some((item) => item.request_id === "set-model-out-of-scope"));
	const scopedSetModelCallCount = setModelCalls.length;
	outOfScopeModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-out-of-scope",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "other", id: "other-model" },
	})}\n`);
	const outOfScopeModelRecord = (await outOfScopeModelResponse)[0];
	assert.equal(outOfScopeModelRecord.success, false);
	assert.equal(outOfScopeModelRecord.error.message, "Model is not in this session's scope");
	assert.equal(setModelCalls.length, scopedSetModelCallCount);
	outOfScopeModel.destroy();

	const inScopeModel = await connect(socketPath);
	const inScopeModelResponse = readRecords(inScopeModel, (records) => records.some((item) => item.request_id === "set-model-in-scope"));
	inScopeModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-in-scope",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "test", id: "model" },
	})}\n`);
	const inScopeModelRecord = (await inScopeModelResponse)[0];
	assert.equal(inScopeModelRecord.success, true);
	assert.equal(inScopeModelRecord.result.accepted, true);
	assert.equal(inScopeModelRecord.result.model.provider, "test");
	assert.equal(inScopeModelRecord.result.model.id, "model");
	assert.equal(setModelCalls.at(-1), availableModels[0]);
	inScopeModel.destroy();

	context.scopedModels = [];

	const setModel = await connect(socketPath);
	const setModelResponse = readRecords(setModel, (records) => records.some((item) => item.request_id === "set-model-1"));
	setModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-1",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "test", id: "model" },
	})}\n`);
	const setModelResultRecord = (await setModelResponse)[0];
	assert.equal(setModelResultRecord.success, true);
	assert.equal(setModelResultRecord.result.accepted, true);
	assert.equal(setModelResultRecord.result.command, "set_model");
	assert.equal(setModelResultRecord.result.model.provider, "test");
	assert.equal(setModelResultRecord.result.model.id, "model");
	assert.equal(setModelCalls.at(-1), availableModels[0]);
	setModel.destroy();

	const unknownModel = await connect(socketPath);
	const unknownModelResponse = readRecords(unknownModel, (records) => records.some((item) => item.request_id === "set-model-unknown"));
	const setModelCallCount = setModelCalls.length;
	unknownModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-unknown",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "nope", id: "nope" },
	})}\n`);
	const unknownModelRecord = (await unknownModelResponse)[0];
	assert.equal(unknownModelRecord.success, false);
	assert.equal(unknownModelRecord.error.message, "Unknown model");
	assert.equal(setModelCalls.length, setModelCallCount);
	unknownModel.destroy();

	setModelResult = false;
	const unavailableModel = await connect(socketPath);
	const unavailableModelResponse = readRecords(unavailableModel, (records) => records.some((item) => item.request_id === "set-model-no-credentials"));
	unavailableModel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "set-model-no-credentials",
		type: "command",
		pane_id: "w1:p1",
		command: "set_model",
		payload: { provider: "test", id: "model" },
	})}\n`);
	const unavailableModelRecord = (await unavailableModelResponse)[0];
	assert.equal(unavailableModelRecord.success, false);
	assert.equal(unavailableModelRecord.error.message, "Model has no configured credentials");
	unavailableModel.destroy();
	setModelResult = true;

	const thinkingLevel = await connect(socketPath);
	const thinkingLevelResponse = readRecords(thinkingLevel, (records) => records.some((item) => item.request_id === "thinking-level-1"));
	thinkingLevel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "thinking-level-1",
		type: "command",
		pane_id: "w1:p1",
		command: "set_thinking_level",
		payload: { level: "high" },
	})}\n`);
	const thinkingLevelRecord = (await thinkingLevelResponse)[0];
	assert.equal(thinkingLevelRecord.success, true);
	assert.equal(thinkingLevelRecord.result.accepted, true);
	assert.equal(thinkingLevelRecord.result.command, "set_thinking_level");
	assert.equal(thinkingLevelRecord.result.level, "high");
	assert.equal(setThinkingLevelCalls.at(-1), "high");
	thinkingLevel.destroy();

	effectiveThinkingLevel = "medium";
	const clampedThinkingLevel = await connect(socketPath);
	const clampedThinkingLevelResponse = readRecords(clampedThinkingLevel, (records) => records.some((item) => item.request_id === "thinking-level-clamped"));
	clampedThinkingLevel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "thinking-level-clamped",
		type: "command",
		pane_id: "w1:p1",
		command: "set_thinking_level",
		payload: { level: "max" },
	})}\n`);
	const clampedThinkingLevelRecord = (await clampedThinkingLevelResponse)[0];
	assert.equal(clampedThinkingLevelRecord.success, true);
	assert.equal(clampedThinkingLevelRecord.result.level, "medium");
	assert.equal(setThinkingLevelCalls.at(-1), "max");
	clampedThinkingLevel.destroy();
	effectiveThinkingLevel = "high";

	const unknownThinkingLevel = await connect(socketPath);
	const unknownThinkingLevelResponse = readRecords(unknownThinkingLevel, (records) => records.some((item) => item.request_id === "thinking-level-unknown"));
	const setThinkingLevelCallCount = setThinkingLevelCalls.length;
	unknownThinkingLevel.write(`${JSON.stringify({
		protocol: { name: "herdr.pi.semantic", version: 1 },
		id: "thinking-level-unknown",
		type: "command",
		pane_id: "w1:p1",
		command: "set_thinking_level",
		payload: { level: "ultra" },
	})}\n`);
	const unknownThinkingLevelRecord = (await unknownThinkingLevelResponse)[0];
	assert.equal(unknownThinkingLevelRecord.success, false);
	assert.equal(unknownThinkingLevelRecord.error.message, "Unknown thinking level");
	assert.equal(setThinkingLevelCalls.length, setThinkingLevelCallCount);
	unknownThinkingLevel.destroy();

	const shutdownRecord = readRecords(subscription, (records) => records.some(
		(item) => item.event?.type === "session_shutdown",
	));
	await handlers.get("session_shutdown")({ type: "session_shutdown", reason: "quit" }, context);
	assert.equal((await shutdownRecord).at(-1).event.type, "session_shutdown");
	assert.equal(existsSync(socketPath), false);
	subscription.destroy();
} finally {
	rmSync(temporary, { recursive: true, force: true });
}

console.log("Pi semantic extension protocol tests passed");
