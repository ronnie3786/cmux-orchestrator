/**
 * Hand a persisted, non-Herdr Pi session to the local Herdr Harness.
 *
 * The harness resumes the exact session in its durable Random / One-off Tasks
 * destination (or explicit workspace/tab IDs). Only after Herdr confirms the
 * new pane and the app deep link is attempted does this process shut down,
 * keeping the session file under a single active writer.
 */

import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { lstatSync, readFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";

const DEFAULT_BASE_URL = "http://127.0.0.1:9092";
const QUICK_SESSION_PATH = "/api/v1/quick-sessions/pi";
const MAX_TOKEN_BYTES = 4096;
const MAX_RESPONSE_BYTES = 64 * 1024;
const REQUEST_TIMEOUT_MS = 45_000;
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$/;
const TRANSIENT_STATUSES = new Set([408, 425, 429, 500, 502, 503, 504]);

const HELP = [
	"Send this persisted Pi session to Herdr.",
	"",
	"Usage:",
	"  /send-to-herdr",
	"  /send-to-herdr --workspace-id <id>",
	"  /send-to-herdr --tab-id <id>",
	"  /send-to-herdr --workspace-id <id> --tab-id <id>",
	"",
	"Without IDs, Herdr uses workspace Random and tab One-off Tasks.",
].join("\n");

type FetchResponse = {
	ok: boolean;
	status: number;
	text(): Promise<string>;
};

type FetchLike = (
	url: string,
	init: {
		method: string;
		headers: Record<string, string>;
		body: string;
		redirect: "error";
		signal: AbortSignal;
	},
) => Promise<FetchResponse>;

type ParsedArguments = {
	help: boolean;
	workspaceId?: string;
	tabId?: string;
};

type QuickSessionPayload = {
	label: string;
	cwd: string;
	sessionFile: string;
	sessionId: string;
	requestId: string;
	workspaceId?: string;
	tabId?: string;
};

type QuickSessionResponse = {
	workspace_id: string;
	tab_id: string;
	pane_id: string;
	session_id: string;
};

export type SendToHerdrDependencies = {
	environment: NodeJS.ProcessEnv;
	fetch: FetchLike;
	readToken: () => string;
	requestId: () => string;
	retryDelay: () => Promise<void>;
	openPane: (paneId: string) => Promise<boolean>;
	cleanupPlaceholder: (path: string, sessionId: string, afterProcessExit: boolean) => void;
};

class SendToHerdrError extends Error {
	constructor(
		message: string,
		readonly transient = false,
		readonly outcomeUnknown = false,
	) {
		super(message);
		this.name = "SendToHerdrError";
	}
}

function openHerdrPane(paneId: string): Promise<boolean> {
	const link = `herdr://pane/${encodeURIComponent(paneId)}`;
	return new Promise((resolve) => {
		execFile("/usr/bin/open", [link], { timeout: 5_000 }, (error) => resolve(error === null));
	});
}

export function removePlaceholderSessionFile(path: string, expectedSessionId: string): boolean {
	let metadata;
	try {
		metadata = lstatSync(path);
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "ENOENT";
	}
	if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > 64 * 1024) return false;
	if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) return false;
	try {
		const lines = readFileSync(path, "utf8").split("\n").filter((line) => line.trim());
		if (lines.length !== 1) return false;
		const header = JSON.parse(lines[0]) as Record<string, unknown>;
		if (header.type !== "session" || header.id !== expectedSessionId) return false;
		unlinkSync(path);
		return true;
	} catch {
		return false;
	}
}

const PLACEHOLDER_CLEANUP_SCRIPT = String.raw`
const fs = require("node:fs");
const [parentRaw, path, expectedId] = process.argv.slice(1);
const parent = Number(parentRaw);
const finish = () => {
  let metadata;
  try { metadata = fs.lstatSync(path); } catch (error) { process.exit(error && error.code === "ENOENT" ? 0 : 1); }
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > 65536) process.exit(1);
  if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) process.exit(1);
  try {
    const lines = fs.readFileSync(path, "utf8").split("\n").filter((line) => line.trim());
    const header = lines.length === 1 ? JSON.parse(lines[0]) : null;
    if (!header || header.type !== "session" || header.id !== expectedId) process.exit(1);
    fs.unlinkSync(path);
    process.exit(0);
  } catch { process.exit(1); }
};
let checks = 0;
const timer = setInterval(() => {
  checks += 1;
  if (process.ppid !== parent) { clearInterval(timer); finish(); }
  else if (checks >= 1200) { clearInterval(timer); process.exit(1); }
}, 50);
`;

function cleanupPlaceholder(path: string, sessionId: string, afterProcessExit: boolean): void {
	if (!afterProcessExit) {
		removePlaceholderSessionFile(path, sessionId);
		return;
	}
	const child = spawn(
		process.execPath,
		["-e", PLACEHOLDER_CLEANUP_SCRIPT, String(process.pid), path, sessionId],
		{ detached: true, stdio: "ignore" },
	);
	child.on("error", () => {});
	child.unref();
}

function requiredIdentifier(value: string | undefined, flag: string): string {
	if (!value || !IDENTIFIER.test(value)) {
		throw new SendToHerdrError(`${flag} requires a valid Herdr ID`);
	}
	return value;
}

export function parseSendToHerdrArguments(raw: string): ParsedArguments {
	const tokens = raw.trim() ? raw.trim().split(/\s+/) : [];
	const result: ParsedArguments = { help: false };

	for (let index = 0; index < tokens.length; index += 1) {
		const token = tokens[index];
		if (token === "--help" || token === "-h") {
			result.help = true;
			continue;
		}

		let flag: "--workspace-id" | "--tab-id";
		let value: string | undefined;
		if (token === "--workspace-id" || token === "--tab-id") {
			flag = token;
			value = tokens[++index];
		} else if (token.startsWith("--workspace-id=")) {
			flag = "--workspace-id";
			value = token.slice("--workspace-id=".length);
		} else if (token.startsWith("--tab-id=")) {
			flag = "--tab-id";
			value = token.slice("--tab-id=".length);
		} else {
			throw new SendToHerdrError(`Unknown argument: ${token}. Use /send-to-herdr --help`);
		}

		const identifier = requiredIdentifier(value, flag);
		if (flag === "--workspace-id") {
			if (result.workspaceId !== undefined) throw new SendToHerdrError("--workspace-id was supplied more than once");
			result.workspaceId = identifier;
		} else {
			if (result.tabId !== undefined) throw new SendToHerdrError("--tab-id was supplied more than once");
			result.tabId = identifier;
		}
	}

	if (result.help && tokens.length > 1) {
		throw new SendToHerdrError("--help cannot be combined with destination arguments");
	}
	return result;
}

type Completion = { value: string; label: string; description: string };

export function sendToHerdrArgumentCompletions(argumentPrefix: string): Completion[] | null {
	const definitions = [
		{ flag: "--workspace-id", label: "--workspace-id <id>", description: "Target a Herdr workspace by ID" },
		{ flag: "--tab-id", label: "--tab-id <id>", description: "Target a Herdr tab by ID" },
		{ flag: "--help", label: "--help", description: "Show command usage" },
	] as const;
	const endsWithWhitespace = /\s$/.test(argumentPrefix);
	const tokens = argumentPrefix.trim() ? argumentPrefix.trim().split(/\s+/) : [];
	const fragment = endsWithWhitespace ? "" : (tokens.at(-1) ?? "");
	const base = endsWithWhitespace
		? argumentPrefix
		: argumentPrefix.slice(0, Math.max(0, argumentPrefix.length - fragment.length));
	const used = new Set(tokens.flatMap((token) => {
		const flag = token.split("=", 1)[0];
		return definitions.some((item) => item.flag === flag) ? [flag] : [];
	}));
	const hasEarlierArguments = tokens.length > (fragment ? 1 : 0);
	const matches = definitions
		.filter((item) => (!used.has(item.flag) || fragment.startsWith(item.flag)))
		.filter((item) => !(item.flag === "--help" && hasEarlierArguments))
		.filter((item) => item.flag.startsWith(fragment))
		.map((item) => ({
			value: `${base}${item.flag}${item.flag === "--help" ? "" : " "}`,
			label: item.label,
			description: item.description,
		}));
	return matches.length > 0 ? matches : null;
}

function tokenPath(environment: NodeJS.ProcessEnv): string {
	const home = environment.HOME?.trim() || homedir();
	return join(home, ".config", "herdr-harness", "api-token");
}

export function readPrivateToken(environment: NodeJS.ProcessEnv = process.env): string {
	const path = tokenPath(environment);
	let metadata;
	try {
		metadata = lstatSync(path);
	} catch {
		throw new SendToHerdrError(`Herdr API token is unavailable at ${path}`);
	}
	if (!metadata.isFile() || metadata.isSymbolicLink()) {
		throw new SendToHerdrError("Herdr API token path must be a regular file");
	}
	if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) {
		throw new SendToHerdrError("Herdr API token file belongs to another user");
	}
	if ((metadata.mode & 0o077) !== 0) {
		throw new SendToHerdrError("Herdr API token file must not be accessible to other users");
	}
	if (metadata.size < 1 || metadata.size > MAX_TOKEN_BYTES) {
		throw new SendToHerdrError("Herdr API token file has an invalid size");
	}
	const token = readFileSync(path, "utf8").trim();
	if (!token || token.length > MAX_TOKEN_BYTES || [...token].some((character) => {
		const code = character.charCodeAt(0);
		return code < 0x21 || code > 0x7e;
	})) {
		throw new SendToHerdrError("Herdr API token has an invalid format");
	}
	return token;
}

export function herdrBaseURL(environment: NodeJS.ProcessEnv = process.env): string {
	const raw = environment.HERDR_SEND_TO_HERDR_URL?.trim()
		|| environment.HERDR_HARNESS_URL?.trim()
		|| DEFAULT_BASE_URL;
	let url: URL;
	try {
		url = new URL(raw);
	} catch {
		throw new SendToHerdrError("Herdr URL is invalid");
	}
	const loopbackHosts = new Set(["localhost", "127.0.0.1", "::1", "[::1]"]);
	if (!loopbackHosts.has(url.hostname.toLowerCase()) || !["http:", "https:"].includes(url.protocol)) {
		throw new SendToHerdrError("Herdr URL must use HTTP or HTTPS on localhost");
	}
	if (url.username || url.password || url.search || url.hash || !["", "/"].includes(url.pathname)) {
		throw new SendToHerdrError("Herdr URL must be a localhost origin without credentials or a path");
	}
	return url.origin;
}

function safeMessage(error: unknown, token: string): string {
	const raw = error instanceof Error ? error.message : "Herdr did not accept the session";
	return (token ? raw.split(token).join("[redacted]") : raw).slice(0, 500);
}

function decodedResponse(raw: string): Record<string, unknown> {
	if (Buffer.byteLength(raw) > MAX_RESPONSE_BYTES) {
		throw new SendToHerdrError("Herdr returned an oversized response");
	}
	try {
		const value = JSON.parse(raw) as unknown;
		if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not an object");
		return value as Record<string, unknown>;
	} catch {
		throw new SendToHerdrError("Herdr returned an invalid response");
	}
}

async function postQuickSession(
	baseURL: string,
	token: string,
	payload: QuickSessionPayload,
	fetchImpl: FetchLike,
): Promise<QuickSessionResponse> {
	const controller = new AbortController();
	const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
	try {
		let response: FetchResponse;
		let rawBody: string;
		try {
			response = await fetchImpl(`${baseURL}${QUICK_SESSION_PATH}`, {
				method: "POST",
				headers: {
					Accept: "application/json",
					Authorization: `Bearer ${token}`,
					"Content-Type": "application/json",
					"User-Agent": "herdr-pi-extension/1",
				},
				body: JSON.stringify(payload),
				redirect: "error",
				signal: controller.signal,
			});
			rawBody = await response.text();
		} catch {
			throw new SendToHerdrError("Could not reach the local Herdr Harness", true, true);
		}
		let body: Record<string, unknown>;
		try {
			body = decodedResponse(rawBody);
		} catch (error) {
			if (!response.ok && TRANSIENT_STATUSES.has(response.status)) {
				throw new SendToHerdrError(`Herdr is temporarily unavailable (HTTP ${response.status})`, true);
			}
			if (response.ok) {
				throw new SendToHerdrError("Herdr returned an invalid success response", false, true);
			}
			throw error;
		}
		if (!response.ok) {
			const error = body.error;
			const errorCode = error && typeof error === "object" && !Array.isArray(error)
				&& typeof (error as Record<string, unknown>).code === "string"
				? String((error as Record<string, unknown>).code)
				: "";
			const message = error && typeof error === "object" && !Array.isArray(error)
				&& typeof (error as Record<string, unknown>).message === "string"
				? String((error as Record<string, unknown>).message)
				: `Herdr rejected the session (HTTP ${response.status})`;
			throw new SendToHerdrError(
				message,
				TRANSIENT_STATUSES.has(response.status)
					&& errorCode !== "quick_session_outcome_unknown",
				errorCode === "quick_session_outcome_unknown",
			);
		}
		const paneId = body.pane_id;
		const workspaceId = body.workspace_id;
		const tabId = body.tab_id;
		const sessionId = body.session_id;
		const semanticReady = body.pi_semantic_ready;
		if (typeof paneId !== "string" || !IDENTIFIER.test(paneId)
			|| typeof workspaceId !== "string" || !IDENTIFIER.test(workspaceId)
			|| typeof tabId !== "string" || !IDENTIFIER.test(tabId)
			|| sessionId !== payload.sessionId
			|| semanticReady !== true) {
			throw new SendToHerdrError(
				"Herdr did not prove that the requested Pi session is ready",
				false,
				true,
			);
		}
		return { pane_id: paneId, workspace_id: workspaceId, tab_id: tabId, session_id: sessionId };
	} finally {
		clearTimeout(timeout);
	}
}

async function requestQuickSession(
	baseURL: string,
	token: string,
	payload: QuickSessionPayload,
	dependencies: SendToHerdrDependencies,
): Promise<QuickSessionResponse> {
	for (let attempt = 0; attempt < 2; attempt += 1) {
		try {
			return await postQuickSession(baseURL, token, payload, dependencies.fetch);
		} catch (error) {
			if (!(error instanceof SendToHerdrError) || !error.transient || attempt === 1) throw error;
			await dependencies.retryDelay();
		}
	}
	throw new SendToHerdrError("Herdr did not accept the session");
}

function sessionLabel(ctx: ExtensionCommandContext, sessionId: string): string {
	const name = ctx.sessionManager.getSessionName()?.trim();
	return (name || `Pi ${sessionId.slice(0, 8)}`).slice(0, 120);
}

function alreadyManaged(environment: NodeJS.ProcessEnv): boolean {
	return Boolean(environment.HERDR_PANE_ID?.trim() && environment.HERDR_SOCKET_PATH?.trim());
}

export function createSendToHerdrExtension(
	overrides: Partial<SendToHerdrDependencies> = {},
): (pi: ExtensionAPI) => void {
	const environment = overrides.environment ?? process.env;
	const dependencies: SendToHerdrDependencies = {
		environment,
		fetch: overrides.fetch ?? ((url, init) => globalThis.fetch(url, init) as Promise<FetchResponse>),
		readToken: overrides.readToken ?? (() => readPrivateToken(environment)),
		requestId: overrides.requestId ?? randomUUID,
		retryDelay: overrides.retryDelay ?? (() => new Promise((resolve) => setTimeout(resolve, 200))),
		openPane: overrides.openPane ?? openHerdrPane,
		cleanupPlaceholder: overrides.cleanupPlaceholder ?? cleanupPlaceholder,
	};

	return (pi: ExtensionAPI): void => {
		pi.registerCommand("send-to-herdr", {
			description: "Open this Pi session in Herdr (defaults to Random / One-off Tasks)",
			getArgumentCompletions: sendToHerdrArgumentCompletions,
			handler: async (rawArguments, ctx) => {
				let parsed: ParsedArguments;
				try {
					parsed = parseSendToHerdrArguments(rawArguments);
				} catch (error) {
					ctx.ui.notify(error instanceof Error ? error.message : "Invalid /send-to-herdr arguments", "error");
					return;
				}
				if (parsed.help) {
					ctx.ui.notify(HELP, "info");
					return;
				}
				if (alreadyManaged(dependencies.environment)) {
					ctx.ui.notify("This Pi session is already running in Herdr", "info");
					return;
				}

				let token = "";
				try {
					await ctx.waitForIdle();
					if (!ctx.isIdle() || ctx.hasPendingMessages()) {
						ctx.ui.notify("Wait for queued Pi work to finish, then run /send-to-herdr again", "error");
						return;
					}
					const sessionFile = ctx.sessionManager.getSessionFile();
					if (!sessionFile) {
						ctx.ui.notify("This Pi session is not persisted, so Herdr cannot resume it", "error");
						return;
					}
					const sessionId = ctx.sessionManager.getSessionId();
					const payload: QuickSessionPayload = {
						label: sessionLabel(ctx, sessionId),
						cwd: ctx.sessionManager.getCwd(),
						sessionFile,
						sessionId,
						requestId: dependencies.requestId(),
						...(parsed.workspaceId ? { workspaceId: parsed.workspaceId } : {}),
						...(parsed.tabId ? { tabId: parsed.tabId } : {}),
					};

					token = dependencies.readToken();
					const baseURL = herdrBaseURL(dependencies.environment);
					ctx.ui.notify("Handing this session to Herdr…", "info");
					const replacement = await ctx.newSession({
						withSession: async (handoffCtx) => {
							const placeholderFile = handoffCtx.sessionManager.getSessionFile();
							const placeholderId = handoffCtx.sessionManager.getSessionId();
							const canCleanPlaceholder = Boolean(
								placeholderFile && placeholderFile !== sessionFile && placeholderId,
							);
							let response: QuickSessionResponse;
							try {
								response = await requestQuickSession(
									baseURL,
									token,
									payload,
									dependencies,
								);
							} catch (error) {
								const message = safeMessage(error, token);
								if (error instanceof SendToHerdrError && error.outcomeUnknown) {
									handoffCtx.ui.notify(
										`${message}. The original session is closed to avoid two writers; check Herdr before resuming it manually.`,
										"warning",
									);
									return;
								}
								const restored = await handoffCtx.switchSession(sessionFile, {
									withSession: async (restoredCtx) => {
										if (canCleanPlaceholder) {
											dependencies.cleanupPlaceholder(placeholderFile!, placeholderId, false);
										}
										restoredCtx.ui.notify(`${message}. This session was restored locally.`, "error");
									},
								});
								if (restored.cancelled) {
									handoffCtx.ui.notify(
										`${message}. Automatic session restore was cancelled.`,
										"error",
									);
								}
								return;
							}

							// Herdr has now proved that it owns the exact original session.
							// Nothing after this commit point may restore that session locally.
							try {
								handoffCtx.ui.notify("Session sent to Herdr", "info");
							} catch { /* the handoff is already committed */ }
							let opened = false;
							try {
								opened = await dependencies.openPane(response.pane_id);
							} catch { /* warn below without changing session ownership */ }
							if (!opened) {
								try {
									handoffCtx.ui.notify(
										`Session is in Herdr at pane ${response.pane_id}, but the app did not open`,
										"warning",
									);
								} catch { /* the handoff is already committed */ }
							}
							if (canCleanPlaceholder) {
								try {
									dependencies.cleanupPlaceholder(placeholderFile!, placeholderId, true);
								} catch { /* a validated empty file is safe to leave behind */ }
							}
							try {
								handoffCtx.shutdown();
							} catch {
								try {
									handoffCtx.ui.notify(
										"Session is in Herdr. Close this placeholder Pi process when convenient.",
										"warning",
									);
								} catch { /* the handoff remains committed */ }
							}
						},
					});
					if (replacement.cancelled) {
						ctx.ui.notify("Session handoff was cancelled before the local session closed", "info");
					}
				} catch (error) {
					try {
						ctx.ui.notify(safeMessage(error, token), "error");
					} catch {
						// A failed runtime replacement can invalidate the original UI context.
					}
				}
			},
		});
	};
}

export default createSendToHerdrExtension();
