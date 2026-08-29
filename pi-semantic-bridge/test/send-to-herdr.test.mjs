import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

const jitiCandidates = [
	"/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti.mjs",
	"/Users/ronnierocha/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti.mjs",
	join(homedir(), "node_modules/jiti/lib/jiti.mjs"),
];
const jitiPath = jitiCandidates.find((candidate) => existsSync(candidate));
if (!jitiPath) throw new Error(`jiti not found; tried:\n${jitiCandidates.join("\n")}`);
const { createJiti } = await import(pathToFileURL(jitiPath).href);
const jiti = createJiti(import.meta.url);
const extension = await jiti.import("../extensions/send-to-herdr.ts");

function response(status, body) {
	return {
		ok: status >= 200 && status < 300,
		status,
		async text() { return JSON.stringify(body); },
	};
}

function harness(overrides = {}) {
	let registered;
	const pi = {
		registerCommand(name, options) { registered = { name, options }; },
	};
	const fetchCalls = [];
	const fetchResponses = [...(overrides.fetchResponses ?? [response(200, {
		ok: true,
		workspace_id: "w-random",
		tab_id: "w-random:t1",
		pane_id: "w-random:p2",
		session_id: overrides.sessionId ?? "01912345-test-session",
		pi_semantic_ready: true,
	})])];
	const fetch = async (url, init) => {
		fetchCalls.push({ url, init });
		const next = fetchResponses.shift();
		if (next instanceof Error) throw next;
		if (!next) throw new Error("No test response queued");
		return next;
	};
	const openCalls = [];
	const cleanupCalls = [];
	const dependencies = {
		environment: overrides.environment ?? {},
		fetch,
		readToken: () => overrides.token ?? "private-test-token",
		requestId: () => "request-123",
		retryDelay: async () => {},
		openPane: async (paneId) => {
			openCalls.push(paneId);
			if (overrides.openError) throw overrides.openError;
			return overrides.openResult ?? true;
		},
		cleanupPlaceholder: (path, sessionId, afterProcessExit) => {
			cleanupCalls.push({ path, sessionId, afterProcessExit });
			if (overrides.cleanupError) throw overrides.cleanupError;
		},
	};
	extension.createSendToHerdrExtension(dependencies)(pi);
	assert.equal(registered?.name, "send-to-herdr");

	const notifications = [];
	let waited = 0;
	let shutdowns = 0;
	let newSessions = 0;
	const switchCalls = [];
	const originalSessionManager = {
			getSessionFile: () => Object.prototype.hasOwnProperty.call(overrides, "sessionFile")
				? overrides.sessionFile
				: "/tmp/pi-session.jsonl",
			getSessionId: () => overrides.sessionId ?? "01912345-test-session",
			getCwd: () => overrides.cwd ?? "/tmp/project",
			getSessionName: () => overrides.sessionName === undefined ? "Fix the frobnicator" : overrides.sessionName,
	};
	const replacementSessionManager = {
		getSessionFile: () => "/tmp/replacement-session.jsonl",
		getSessionId: () => "replacement-session",
		getCwd: () => overrides.cwd ?? "/tmp/project",
		getSessionName: () => undefined,
	};
	function makeContext(sessionManager) {
		return {
			ui: { notify(message, type) { notifications.push({ message, type }); } },
			async waitForIdle() { waited += 1; },
			isIdle: () => overrides.isIdle ?? true,
			hasPendingMessages: () => overrides.hasPendingMessages ?? false,
			shutdown() {
				shutdowns += 1;
				if (overrides.shutdownError) throw overrides.shutdownError;
			},
			sessionManager,
			async newSession(options) {
				newSessions += 1;
				if (overrides.newSessionCancelled) return { cancelled: true };
				await options?.withSession?.(makeContext(replacementSessionManager));
				return { cancelled: false };
			},
			async switchSession(path, options) {
				switchCalls.push(path);
				if (overrides.switchSessionCancelled) return { cancelled: true };
				await options?.withSession?.(makeContext(originalSessionManager));
				return { cancelled: false };
			},
		};
	}
	const context = makeContext(originalSessionManager);
	return {
		command: registered.options,
		context,
		openCalls,
		cleanupCalls,
		fetchCalls,
		notifications,
		get waited() { return waited; },
		get shutdowns() { return shutdowns; },
		get newSessions() { return newSessions; },
		switchCalls,
	};
}

test("registers static destination flag completions", () => {
	const run = harness();
	assert.match(run.command.description, /Random \/ One-off Tasks/);
	assert.deepEqual(
		run.command.getArgumentCompletions("").map((item) => item.label),
		["--workspace-id <id>", "--tab-id <id>", "--help"],
	);
	assert.deepEqual(
		run.command.getArgumentCompletions("--workspace-id w1 ").map((item) => item.label),
		["--tab-id <id>"],
	);
});

test("sends the exact persisted session, opens its pane, and shuts down", async () => {
	const run = harness();
	await run.command.handler("", run.context);

	assert.equal(run.waited, 1);
	assert.equal(run.fetchCalls.length, 1);
	assert.equal(run.fetchCalls[0].url, "http://127.0.0.1:9092/api/v1/quick-sessions/pi");
	assert.equal(run.fetchCalls[0].init.redirect, "error");
	assert.equal(run.fetchCalls[0].init.headers.Authorization, "Bearer private-test-token");
	assert.deepEqual(JSON.parse(run.fetchCalls[0].init.body), {
		label: "Fix the frobnicator",
		cwd: "/tmp/project",
		sessionFile: "/tmp/pi-session.jsonl",
		sessionId: "01912345-test-session",
		requestId: "request-123",
	});
	assert.equal(run.newSessions, 1);
	assert.deepEqual(run.openCalls, ["w-random:p2"]);
	assert.deepEqual(run.cleanupCalls, [{
		path: "/tmp/replacement-session.jsonl",
		sessionId: "replacement-session",
		afterProcessExit: true,
	}]);
	assert.equal(run.shutdowns, 1);
	assert.deepEqual(run.notifications.at(-1), { message: "Session sent to Herdr", type: "info" });
});

test("accepts explicit workspace and tab IDs in either order", async () => {
	const run = harness();
	await run.command.handler("--tab-id w2:t7 --workspace-id w2", run.context);
	assert.deepEqual(JSON.parse(run.fetchCalls[0].init.body), {
		label: "Fix the frobnicator",
		cwd: "/tmp/project",
		sessionFile: "/tmp/pi-session.jsonl",
		sessionId: "01912345-test-session",
		requestId: "request-123",
		workspaceId: "w2",
		tabId: "w2:t7",
	});
	assert.equal(run.shutdowns, 1);

	assert.deepEqual(extension.parseSendToHerdrArguments("--workspace-id=w3 --tab-id=w3:t4"), {
		help: false,
		workspaceId: "w3",
		tabId: "w3:t4",
	});
});

test("retries one transient failure with the same request ID", async () => {
	const run = harness({
		fetchResponses: [
			response(503, { ok: false, error: { code: "herdr_unavailable", message: "Try again" } }),
			response(200, {
				ok: true,
				workspace_id: "w-random",
				tab_id: "w-random:t1",
				pane_id: "w-random:p2",
				session_id: "01912345-test-session",
				pi_semantic_ready: true,
			}),
		],
	});
	await run.command.handler("", run.context);
	assert.equal(run.fetchCalls.length, 2);
	assert.equal(JSON.parse(run.fetchCalls[0].init.body).requestId, "request-123");
	assert.equal(JSON.parse(run.fetchCalls[1].init.body).requestId, "request-123");
	assert.equal(run.shutdowns, 1);
});

test("shuts down after handoff even when the Herdr deep link cannot open", async () => {
	const run = harness({ openResult: false });
	await run.command.handler("", run.context);
	assert.equal(run.fetchCalls.length, 1);
	assert.equal(run.openCalls.length, 1);
	assert.equal(run.shutdowns, 1);
	assert.deepEqual(run.notifications.at(-1), {
		message: "Session is in Herdr at pane w-random:p2, but the app did not open",
		type: "warning",
	});
});

test("never restores the source after Herdr commits ownership even if local follow-up work throws", async () => {
	const run = harness({
		openError: new Error("open failed"),
		cleanupError: new Error("cleanup failed"),
		shutdownError: new Error("shutdown failed"),
	});
	await run.command.handler("", run.context);

	assert.deepEqual(run.switchCalls, []);
	assert.deepEqual(run.openCalls, ["w-random:p2"]);
	assert.equal(run.cleanupCalls.length, 1);
	assert.equal(run.shutdowns, 1);
	assert.match(run.notifications.at(-1).message, /placeholder Pi process/);
});

test("shows help and rejects bad arguments without contacting Herdr", async () => {
	const help = harness();
	await help.command.handler("--help", help.context);
	assert.equal(help.fetchCalls.length, 0);
	assert.equal(help.waited, 0);
	assert.match(help.notifications[0].message, /Usage:/);

	for (const args of ["--workspace-id", "--workspace-id bad/value", "--unknown w1", "--tab-id t1 --tab-id t2"]) {
		const run = harness();
		await run.command.handler(args, run.context);
		assert.equal(run.fetchCalls.length, 0, args);
		assert.equal(run.shutdowns, 0, args);
		assert.equal(run.notifications[0].type, "error", args);
	}
});

test("does not hand off an ephemeral or already Herdr-managed session", async () => {
	const ephemeral = harness({ sessionFile: undefined });
	await ephemeral.command.handler("", ephemeral.context);
	assert.equal(ephemeral.fetchCalls.length, 0);
	assert.equal(ephemeral.shutdowns, 0);
	assert.match(ephemeral.notifications[0].message, /not persisted/);

	const managed = harness({
		environment: { HERDR_PANE_ID: "w1:p1", HERDR_SOCKET_PATH: "/tmp/herdr.sock" },
	});
	await managed.command.handler("", managed.context);
	assert.equal(managed.waited, 0);
	assert.equal(managed.fetchCalls.length, 0);
	assert.equal(managed.openCalls.length, 0);
	assert.equal(managed.shutdowns, 0);
	assert.deepEqual(managed.notifications, [{
		message: "This Pi session is already running in Herdr",
		type: "info",
	}]);
});

test("reports server errors without leaking the token or shutting down", async () => {
	const token = "never-print-this-token";
	const run = harness({
		token,
		fetchResponses: [response(400, {
			ok: false,
			error: { code: "invalid_request", message: `bad request ${token}` },
		})],
	});
	await run.command.handler("", run.context);
	assert.equal(run.shutdowns, 0);
	assert.equal(run.openCalls.length, 0);
	assert.deepEqual(run.switchCalls, ["/tmp/pi-session.jsonl"]);
	assert.deepEqual(run.cleanupCalls, [{
		path: "/tmp/replacement-session.jsonl",
		sessionId: "replacement-session",
		afterProcessExit: false,
	}]);
	assert.equal(run.notifications.at(-1).type, "error");
	assert.equal(run.notifications.at(-1).message.includes(token), false);
	assert.match(run.notifications.at(-1).message, /\[redacted\]/);
});

test("keeps the source closed when a success response cannot prove readiness", async () => {
	const run = harness({
		fetchResponses: [response(200, {
			ok: true,
			workspace_id: "w-random",
			tab_id: "w-random:t1",
			pane_id: "w-random:p2",
			session_id: "different-session",
			pi_semantic_ready: true,
		})],
	});
	await run.command.handler("", run.context);

	assert.equal(run.shutdowns, 0);
	assert.deepEqual(run.openCalls, []);
	assert.deepEqual(run.switchCalls, []);
	assert.deepEqual(run.cleanupCalls, []);
	assert.match(run.notifications.at(-1).message, /original session is closed/i);
});

test("does not reopen the source session when a transport failure leaves the outcome unknown", async () => {
	const run = harness({
		fetchResponses: [new Error("connection reset"), new Error("connection reset")],
	});
	await run.command.handler("", run.context);

	assert.equal(run.fetchCalls.length, 2);
	assert.equal(run.shutdowns, 0);
	assert.deepEqual(run.switchCalls, []);
	assert.deepEqual(run.cleanupCalls, []);
	assert.match(run.notifications.at(-1).message, /avoid two writers/);
});

test("does not reopen the source when Herdr cannot confirm rollback", async () => {
	const run = harness({
		fetchResponses: [response(502, {
			ok: false,
			error: {
				code: "quick_session_outcome_unknown",
				message: "The new pane could not be confirmed closed",
			},
		})],
	});
	await run.command.handler("", run.context);

	assert.equal(run.fetchCalls.length, 1);
	assert.deepEqual(run.switchCalls, []);
	assert.deepEqual(run.cleanupCalls, []);
	assert.match(run.notifications.at(-1).message, /avoid two writers/);
});

test("does not switch sessions while Pi still has queued work", async () => {
	const run = harness({ hasPendingMessages: true });
	await run.command.handler("", run.context);

	assert.equal(run.fetchCalls.length, 0);
	assert.equal(run.newSessions, 0);
	assert.match(run.notifications.at(-1).message, /queued Pi work/);
});

test("placeholder cleanup removes only the exact empty replacement session", () => {
	const root = mkdtempSync(join(tmpdir(), "send-to-herdr-placeholder-"));
	try {
		const valid = join(root, "valid.jsonl");
		writeFileSync(valid, `${JSON.stringify({ type: "session", id: "replacement-session" })}\n`);
		assert.equal(extension.removePlaceholderSessionFile(valid, "replacement-session"), true);
		assert.equal(existsSync(valid), false);

		const wrong = join(root, "wrong.jsonl");
		writeFileSync(wrong, `${JSON.stringify({ type: "session", id: "real-session" })}\n`);
		assert.equal(extension.removePlaceholderSessionFile(wrong, "replacement-session"), false);
		assert.equal(existsSync(wrong), true);

		const populated = join(root, "populated.jsonl");
		writeFileSync(
			populated,
			`${JSON.stringify({ type: "session", id: "replacement-session" })}\n${JSON.stringify({ type: "message" })}\n`,
		);
		assert.equal(extension.removePlaceholderSessionFile(populated, "replacement-session"), false);
		assert.equal(existsSync(populated), true);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

test("reads only a private regular token file and rejects unsafe URLs", () => {
	const root = mkdtempSync(join(tmpdir(), "send-to-herdr-token-"));
	try {
		const directory = join(root, ".config", "herdr-harness");
		mkdirSync(directory, { recursive: true });
		const token = join(directory, "api-token");
		writeFileSync(token, "secret-token\n", { mode: 0o600 });
		assert.equal(extension.readPrivateToken({ HOME: root }), "secret-token");
		chmodSync(token, 0o644);
		assert.throws(() => extension.readPrivateToken({ HOME: root }), /must not be accessible/);
		chmodSync(token, 0o600);
		const linkRoot = join(root, "linked-home");
		mkdirSync(join(linkRoot, ".config", "herdr-harness"), { recursive: true });
		symlinkSync(token, join(linkRoot, ".config", "herdr-harness", "api-token"));
		assert.throws(() => extension.readPrivateToken({ HOME: linkRoot }), /regular file/);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}

	assert.equal(extension.herdrBaseURL({ HERDR_SEND_TO_HERDR_URL: "http://localhost:9192/" }), "http://localhost:9192");
	assert.throws(
		() => extension.herdrBaseURL({ HERDR_SEND_TO_HERDR_URL: "https://example.com" }),
		/localhost/,
	);
	assert.throws(
		() => extension.herdrBaseURL({ HERDR_SEND_TO_HERDR_URL: "http://127.0.0.1:9092/api" }),
		/without credentials or a path/,
	);
});
