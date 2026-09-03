import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
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
const piAiCandidates = [
	"/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/compat.js",
	"/Users/ronnierocha/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/compat.js",
	join(homedir(), "node_modules/@earendil-works/pi-ai/dist/compat.js"),
];
const piAiPath = piAiCandidates.find((candidate) => existsSync(candidate));
if (!piAiPath) throw new Error(`pi-ai not found; tried:\n${piAiCandidates.join("\n")}`);
const { createJiti } = await import(pathToFileURL(jitiPath).href);
const jiti = createJiti(import.meta.url, { alias: { "@earendil-works/pi-ai": piAiPath } });
const extension = await jiti.import("../extensions/present-result.ts");

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
		registerTool(tool) { registered = tool; },
	};
	const fetchCalls = [];
	const fetch = async (url, init) => {
		fetchCalls.push({ url, init });
		if (overrides.fetch) return overrides.fetch(url, init, fetchCalls.length);
		if (overrides.fetchError) throw overrides.fetchError;
		return overrides.response ?? response(201, {
			ok: true,
			artifact: {
				id: "art_0123456789abcdef01234567",
				kind: "file",
				title: "Launch brief",
			},
		});
	};
	let tokenReads = 0;
	const environment = overrides.environment ?? {
		HERDR_PANE_ID: "workspace:pane-1",
		HERDR_HARNESS_URL: "http://127.0.0.1:9192",
	};
	extension.createPresentResultExtension({
		environment,
		fetch,
		readToken: () => {
			tokenReads += 1;
			return overrides.token ?? "private-test-token";
		},
	})(pi);
	const context = {
		cwd: overrides.cwd ?? "/tmp/project",
		sessionManager: {
			getSessionId: () => overrides.sessionId ?? "session-123",
		},
	};
	return {
		context,
		fetchCalls,
		get tokenReads() { return tokenReads; },
		tool: registered,
	};
}

test("registers an explicit result tool only in Herdr-managed sessions", () => {
	const pane = harness();
	assert.equal(pane.tool.name, "present_result");
	assert.match(pane.tool.promptSnippet, /Herdr HUD/);
	assert.ok(pane.tool.promptGuidelines.some((item) => /ordinary source-code edits/.test(item)));

	const agentRun = harness({
		environment: {
			HERDR_AGENT_RUN_ID: "agr_012345abcdef",
			HERDR_HARNESS_URL: "http://localhost:9192",
		},
	});
	assert.equal(agentRun.tool.name, "present_result");

	assert.equal(harness({ environment: {} }).tool, undefined);
	assert.equal(harness({ environment: { HERDR_PANE_ID: "bad/pane" } }).tool, undefined);
	assert.equal(harness({
		environment: {
			HERDR_PANE_ID: "workspace:pane-1",
			HERDR_AGENT_RUN_ID: "agr_012345abcdef",
		},
	}).tool, undefined);
});

test("posts a pane file result with a resolved path and session ID", async () => {
	const run = harness();
	const result = await run.tool.execute(
		"call-1",
		{ kind: "file", location: "reports/launch.html", title: " Launch brief " },
		undefined,
		undefined,
		run.context,
	);

	assert.equal(run.fetchCalls.length, 1);
	assert.equal(run.fetchCalls[0].url, "http://127.0.0.1:9192/api/v1/result-artifacts");
	assert.equal(run.fetchCalls[0].init.redirect, "error");
	assert.equal(run.fetchCalls[0].init.headers.Authorization, "Bearer private-test-token");
	const payload = JSON.parse(run.fetchCalls[0].init.body);
	assert.match(payload.idempotencyKey, /^pr_[0-9a-f]{64}$/);
	delete payload.idempotencyKey;
	assert.deepEqual(payload, {
		kind: "file",
		location: "/tmp/project/reports/launch.html",
		originType: "pane",
		originId: "workspace:pane-1",
		title: "Launch brief",
		sessionId: "session-123",
	});
	assert.equal(result.content[0].text, "Launch brief is ready in the Herdr HUD.");
	assert.equal(result.details.artifact.id, "art_0123456789abcdef01234567");
});

test("posts a link result for a headless Agent run and omits absent optional values", async () => {
	const run = harness({
		environment: {
			HERDR_AGENT_RUN_ID: "agr_012345abcdef",
			HERDR_HARNESS_URL: "https://[::1]:9443/",
		},
		sessionId: "",
	});
	await run.tool.execute(
		"call-2",
		{ kind: "link", location: "https://example.com/report?q=1" },
		undefined,
		undefined,
		run.context,
	);

	const payload = JSON.parse(run.fetchCalls[0].init.body);
	assert.match(payload.idempotencyKey, /^pr_[0-9a-f]{64}$/);
	delete payload.idempotencyKey;
	assert.deepEqual(payload, {
		kind: "link",
		location: "https://example.com/report?q=1",
		originType: "agent_run",
		originId: "agr_012345abcdef",
	});
});

test("enforces the ASK-mode link-only contract before reading credentials", async () => {
	const askEnvironment = {
		HERDR_AGENT_RUN_ID: "agr_012345abcdef",
		HERDR_AGENT_RUN_MODE: "ask",
		HERDR_HARNESS_URL: "http://127.0.0.1:9192",
	};
	const rejected = harness({ environment: askEnvironment });
	assert.ok(rejected.tool.promptGuidelines.some((item) => /ASK mode.*links only/.test(item)));
	await assert.rejects(
		rejected.tool.execute(
			"call-ask-file",
			{ kind: "file", location: "/tmp/report.pdf" },
			undefined,
			undefined,
			rejected.context,
		),
		/ASK mode can present HTTP\(S\) links, not local files/,
	);
	assert.equal(rejected.tokenReads, 0);
	assert.equal(rejected.fetchCalls.length, 0);

	const allowed = harness({ environment: askEnvironment });
	await allowed.tool.execute(
		"call-ask-link",
		{ kind: "link", location: "https://example.com/final" },
		undefined,
		undefined,
		allowed.context,
	);
	assert.equal(allowed.fetchCalls.length, 1);
});

test("derives a stable idempotency key from the tool call and Herdr context", async () => {
	const run = harness();
	const params = { kind: "file", location: "/tmp/report.pdf", title: "Report" };
	await run.tool.execute("call-stable", params, undefined, undefined, run.context);
	await run.tool.execute("call-stable", params, undefined, undefined, run.context);
	await run.tool.execute("call-different", params, undefined, undefined, run.context);

	const keys = run.fetchCalls.map((call) => JSON.parse(call.init.body).idempotencyKey);
	assert.equal(keys[0], keys[1]);
	assert.notEqual(keys[0], keys[2]);
	assert.match(keys[0], /^pr_[0-9a-f]{64}$/);

	const otherSession = harness({ sessionId: "session-456" });
	await otherSession.tool.execute("call-stable", params, undefined, undefined, otherSession.context);
	const otherKey = JSON.parse(otherSession.fetchCalls[0].init.body).idempotencyKey;
	assert.notEqual(keys[0], otherKey);

	const otherOrigin = harness({
		environment: {
			HERDR_AGENT_RUN_ID: "agr_012345abcdef",
			HERDR_HARNESS_URL: "http://127.0.0.1:9192",
		},
	});
	await otherOrigin.tool.execute("call-stable", params, undefined, undefined, otherOrigin.context);
	const otherOriginKey = JSON.parse(otherOrigin.fetchCalls[0].init.body).idempotencyKey;
	assert.notEqual(keys[0], otherOriginKey);
});

test("retries an ambiguous lost response once with the identical idempotency key", async () => {
	const run = harness({
		fetch: async (_url, _init, attempt) => {
			if (attempt === 1) throw new Error("socket closed after commit");
			return response(201, {
				ok: true,
				artifact: {
					id: "art_0123456789abcdef01234567",
					kind: "file",
					title: "Recovered result",
				},
			});
		},
	});

	const result = await run.tool.execute(
		"call-lost-response",
		{ kind: "file", location: "/tmp/recovered.pdf", title: "Recovered result" },
		undefined,
		undefined,
		run.context,
	);

	assert.equal(run.fetchCalls.length, 2);
	assert.equal(run.fetchCalls[0].init.body, run.fetchCalls[1].init.body);
	assert.equal(result.details.artifact.id, "art_0123456789abcdef01234567");
});

test("validates the harness origin before reading or transmitting the token", async () => {
	for (const url of [
		"https://example.com",
		"http://127.0.0.1:9192/api",
		"file:///tmp/herdr.sock",
	]) {
		const run = harness({
			environment: { HERDR_PANE_ID: "workspace:pane-1", HERDR_HARNESS_URL: url },
		});
		await assert.rejects(
			run.tool.execute(
				"call-3",
				{ kind: "file", location: "/tmp/report.pdf" },
				undefined,
				undefined,
				run.context,
			),
			/localhost|HTTP or HTTPS|without credentials or a path/,
		);
		assert.equal(run.tokenReads, 0, url);
		assert.equal(run.fetchCalls.length, 0, url);
	}
});

test("rejects invalid user-facing links without contacting Herdr", async () => {
	for (const location of ["not a url", "file:///tmp/report.html", "https://user:pass@example.com/report"]) {
		const run = harness();
		await assert.rejects(
			run.tool.execute(
				"call-4",
				{ kind: "link", location },
				undefined,
				undefined,
				run.context,
			),
			/valid HTTP or HTTPS URL/,
		);
		assert.equal(run.fetchCalls.length, 0, location);
		assert.equal(run.tokenReads, 0, location);
	}
});

test("reports server and transport errors without leaking the bearer token", async () => {
	const token = "never-print-this-token";
	const rejected = harness({
		token,
		response: response(400, {
			ok: false,
			error: { code: "invalid_result_artifact", message: `bad path ${token}` },
		}),
	});
	await assert.rejects(
		rejected.tool.execute(
			"call-5",
			{ kind: "file", location: "/tmp/report.pdf" },
			undefined,
			undefined,
			rejected.context,
		),
		(error) => {
			assert.equal(error.message.includes(token), false);
			assert.match(error.message, /bad path \[redacted\]/);
			return true;
		},
	);

	const unreachable = harness({ fetchError: new Error(`connect failed ${token}`), token });
	await assert.rejects(
		unreachable.tool.execute(
			"call-6",
			{ kind: "file", location: "/tmp/report.pdf" },
			undefined,
			undefined,
			unreachable.context,
		),
		/Could not reach the local Herdr Harness/,
	);
});

test("rejects malformed success responses", async () => {
	const run = harness({ response: response(201, { ok: true }) });
	await assert.rejects(
		run.tool.execute(
			"call-7",
			{ kind: "file", location: "/tmp/report.pdf" },
			undefined,
			undefined,
			run.context,
		),
		/invalid success response/,
	);
});
