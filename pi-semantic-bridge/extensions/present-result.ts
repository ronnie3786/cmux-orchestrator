/**
 * Register a user-facing result with the local Herdr Harness.
 *
 * The tool is intentionally absent outside Herdr-managed Pi sessions. Files
 * are resolved against the agent's working directory before registration so
 * the harness can safely copy them into its artifact store.
 */

import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { herdrBaseURL, readPrivateToken } from "./send-to-herdr.ts";

const RESULT_ARTIFACT_PATH = "/api/v1/result-artifacts";
const MAX_LOCATION_CHARS = 8_192;
const MAX_TITLE_CHARS = 240;
const MAX_RESPONSE_BYTES = 64 * 1024;
const REQUEST_TIMEOUT_MS = 45_000;
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$/;
const AGENT_RUN_ID = /^agr_[0-9a-f]{12}$/;

type ResultKind = "file" | "link";
type HerdrOrigin = {
	originType: "pane" | "agent_run";
	originId: string;
};
type PresentResultParameters = {
	kind: ResultKind;
	location: string;
	title?: string;
};
type PresentResultPayload = PresentResultParameters & HerdrOrigin & {
	idempotencyKey: string;
	sessionId?: string;
};
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

export type PresentResultDependencies = {
	environment: NodeJS.ProcessEnv;
	fetch: FetchLike;
	readToken: () => string;
};

class PresentResultError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "PresentResultError";
	}
}

/// The server may already have committed these requests even though the caller
/// did not receive a usable response. Retrying once with the same idempotency
/// key is therefore both safe and materially more reliable than surfacing the
/// ambiguity to the model as a new tool call.
class AmbiguousPresentResultError extends PresentResultError {}

export function resolveHerdrOrigin(environment: NodeJS.ProcessEnv): HerdrOrigin | undefined {
	const paneId = environment.HERDR_PANE_ID?.trim();
	const agentRunId = environment.HERDR_AGENT_RUN_ID?.trim();
	if (paneId && agentRunId) return undefined;
	if (paneId && IDENTIFIER.test(paneId)) return { originType: "pane", originId: paneId };
	if (agentRunId && AGENT_RUN_ID.test(agentRunId)) {
		return { originType: "agent_run", originId: agentRunId };
	}
	return undefined;
}

export function presentResultBaseURL(environment: NodeJS.ProcessEnv): string {
	return herdrBaseURL(environment);
}

export function resultIdempotencyKey(
	toolCallId: string,
	origin: HerdrOrigin,
	sessionId: string | undefined,
): string {
	const identity = JSON.stringify({
		version: 1,
		toolCallId,
		originType: origin.originType,
		originId: origin.originId,
		sessionId: sessionId ?? null,
	});
	return `pr_${createHash("sha256").update(identity).digest("hex")}`;
}

function normalizedTitle(value: unknown): string | undefined {
	if (value === undefined) return undefined;
	if (typeof value !== "string") throw new PresentResultError("Result title must be text");
	const title = value.trim();
	if (!title) return undefined;
	if (title.length > MAX_TITLE_CHARS) {
		throw new PresentResultError(`Result title must be at most ${MAX_TITLE_CHARS} characters`);
	}
	return title;
}

function normalizedKind(value: unknown): ResultKind {
	if (value !== "file" && value !== "link") {
		throw new PresentResultError("Result kind must be file or link");
	}
	return value;
}

function normalizedLocation(kind: ResultKind, value: unknown, cwd: string): string {
	if (typeof value !== "string") throw new PresentResultError("Result location must be text");
	const location = value.trim();
	if (!location || location.length > MAX_LOCATION_CHARS || location.includes("\0")) {
		throw new PresentResultError("Result location is invalid");
	}
	if (kind === "file") return resolve(cwd, location);

	let url: URL;
	try {
		url = new URL(location);
	} catch {
		throw new PresentResultError("Result link must be a valid HTTP or HTTPS URL");
	}
	if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
		throw new PresentResultError("Result link must be a valid HTTP or HTTPS URL without credentials");
	}
	return location;
}

function decodedResponse(raw: string): Record<string, unknown> {
	if (Buffer.byteLength(raw) > MAX_RESPONSE_BYTES) {
		throw new PresentResultError("Herdr returned an oversized response");
	}
	try {
		const value = JSON.parse(raw) as unknown;
		if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not an object");
		return value as Record<string, unknown>;
	} catch {
		throw new PresentResultError("Herdr returned an invalid response");
	}
}

function responseError(body: Record<string, unknown>, status: number): string {
	const error = body.error;
	if (error && typeof error === "object" && !Array.isArray(error)) {
		const message = (error as Record<string, unknown>).message;
		if (typeof message === "string" && message.trim()) return message.trim();
	}
	return `Herdr rejected the result (HTTP ${status})`;
}

function safeMessage(error: unknown, token: string): string {
	const raw = error instanceof Error ? error.message : "Herdr could not register the result";
	return (token ? raw.split(token).join("[redacted]") : raw).slice(0, 500);
}

async function postResult(
	baseURL: string,
	token: string,
	payload: PresentResultPayload,
	fetchImpl: FetchLike,
	signal: AbortSignal | undefined,
): Promise<Record<string, unknown>> {
	for (let attempt = 0; attempt < 2; attempt += 1) {
		try {
			return await postResultAttempt(baseURL, token, payload, fetchImpl, signal);
		} catch (error) {
			const canRetry = attempt === 0
				&& error instanceof AmbiguousPresentResultError
				&& signal?.aborted !== true;
			if (!canRetry) throw error;
		}
	}
	throw new PresentResultError("Herdr could not register the result");
}

async function postResultAttempt(
	baseURL: string,
	token: string,
	payload: PresentResultPayload,
	fetchImpl: FetchLike,
	signal: AbortSignal | undefined,
): Promise<Record<string, unknown>> {
	const controller = new AbortController();
	const abort = () => controller.abort();
	if (signal?.aborted) controller.abort();
	else signal?.addEventListener("abort", abort, { once: true });
	const timeout = setTimeout(abort, REQUEST_TIMEOUT_MS);
	try {
		let response: FetchResponse;
		let rawBody: string;
		try {
			response = await fetchImpl(`${baseURL}${RESULT_ARTIFACT_PATH}`, {
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
			if (signal?.aborted) {
				throw new PresentResultError("Result registration was cancelled");
			}
			throw new AmbiguousPresentResultError(
				controller.signal.aborted
					? "Result registration timed out"
					: "Could not reach the local Herdr Harness",
			);
		}
		let body: Record<string, unknown>;
		try {
			body = decodedResponse(rawBody);
		} catch (error) {
			if (response.ok) {
				throw new AmbiguousPresentResultError(
					error instanceof Error ? error.message : "Herdr returned an invalid response",
				);
			}
			throw error;
		}
		if (!response.ok) throw new PresentResultError(responseError(body, response.status));
		if (body.ok !== true || !body.artifact || typeof body.artifact !== "object" || Array.isArray(body.artifact)) {
			throw new AmbiguousPresentResultError("Herdr returned an invalid success response");
		}
		return body.artifact as Record<string, unknown>;
	} finally {
		clearTimeout(timeout);
		signal?.removeEventListener("abort", abort);
	}
}

function currentSessionId(ctx: ExtensionContext): string | undefined {
	try {
		const value = ctx.sessionManager.getSessionId()?.trim();
		return value && value.length <= 256 ? value : undefined;
	} catch {
		return undefined;
	}
}

export function createPresentResultExtension(
	overrides: Partial<PresentResultDependencies> = {},
): (pi: ExtensionAPI) => void {
	const environment = overrides.environment ?? process.env;
	const dependencies: PresentResultDependencies = {
		environment,
		fetch: overrides.fetch ?? ((url, init) => globalThis.fetch(url, init) as Promise<FetchResponse>),
		readToken: overrides.readToken ?? (() => readPrivateToken(environment)),
	};

	return (pi: ExtensionAPI): void => {
		const origin = resolveHerdrOrigin(dependencies.environment);
		if (!origin) return;
		const isAskAgentRun = dependencies.environment.HERDR_AGENT_RUN_MODE?.trim().toLowerCase() === "ask";

		pi.registerTool({
			name: "present_result",
			label: "Present Result",
			description: "Register a finished file or web link for the user to open from the Herdr HUD.",
			promptSnippet: "Register a user-facing local file or HTTP(S) link with the Herdr HUD.",
			promptGuidelines: [
				"When you create or return a document, HTML page, image, audio file, video, or web link that the user should open, call present_result once for each finished artifact.",
				"Use kind=file for a local file and kind=link for an HTTP(S) URL. Give each result a short, useful title when possible.",
				"Do not call present_result for ordinary source-code edits, intermediate files, logs, or incidental build products that were not intended as deliverables.",
				...(isAskAgentRun
					? ["ASK mode may present finished HTTP(S) links only. Never register a local file in ASK mode."]
					: []),
			],
			parameters: Type.Object({
				kind: Type.Union([Type.Literal("file"), Type.Literal("link")], {
					description: "Whether location identifies a local file or a web link.",
				}),
				location: Type.String({
					description: "Local path (absolute or relative to the working directory), or an HTTP(S) URL.",
				}),
				title: Type.Optional(Type.String({
					description: "Short user-facing label for the result.",
				})),
			}),
			async execute(toolCallId, params, signal, _onUpdate, ctx) {
				let token = "";
				try {
					// Validate the destination before reading the bearer token. This
					// ordering ensures credentials can never be sent to a non-loopback URL.
					const baseURL = presentResultBaseURL(dependencies.environment);
					const kind = normalizedKind(params.kind);
					if (isAskAgentRun && kind === "file") {
						throw new PresentResultError("ASK mode can present HTTP(S) links, not local files");
					}
					const sessionId = currentSessionId(ctx);
					const payload: PresentResultPayload = {
						kind,
						location: normalizedLocation(kind, params.location, ctx.cwd),
						...origin,
						idempotencyKey: resultIdempotencyKey(toolCallId, origin, sessionId),
					};
					const title = normalizedTitle(params.title);
					if (title) payload.title = title;
					if (sessionId) payload.sessionId = sessionId;
					token = dependencies.readToken();
					const artifact = await postResult(baseURL, token, payload, dependencies.fetch, signal);
					const displayTitle = title || (kind === "file" ? "File" : "Link");
					return {
						content: [{ type: "text" as const, text: `${displayTitle} is ready in the Herdr HUD.` }],
						details: { artifact },
					};
				} catch (error) {
					throw new PresentResultError(safeMessage(error, token));
				}
			},
		});
	};
}

export default createPresentResultExtension();
