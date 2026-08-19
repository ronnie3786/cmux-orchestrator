/**
 * Render-driven tests for the Pi chat timeline (P8-run-A). Fixtures are
 * built through the real PiConversationReducer (snapshot `replace` + live
 * `apply` envelopes, same style as reducer.test.ts); rendering uses
 * react-dom/server's `renderToStaticMarkup` (no jsdom in this repo) and
 * asserts on the produced HTML.
 */
import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { PiConversationReducer } from "../../pi/reducer";
import {
  decodePiConversationSnapshot,
  type PiConversationEnvelope,
  type PiJSONValue,
} from "../../pi/types";
import { PiChatView, type PiChatViewProps } from "./PiChatView";

function snapshot(
  entries: string,
  state = '{"isStreaming":false}',
  truncated = false,
): ReturnType<typeof decodePiConversationSnapshot> {
  return decodePiConversationSnapshot(`{
    "protocol":{"name":"herdr.pi.semantic","version":1},
    "paneId":"p1","available":true,"connected":true,
    "session":{"id":"s1"},"state":${state},"entries":${entries},
    "pendingInteractions":[],"cursor":"0","oldestCursor":"0","truncated":${truncated}
  }`);
}

function env(cursor: number, event: Record<string, unknown>): PiConversationEnvelope {
  return {
    protocolInfo: { name: "herdr.pi.semantic", version: 1 },
    paneID: "p1",
    sessionID: "s1",
    cursor: String(cursor),
    connected: null,
    event: event as PiJSONValue,
    generatedAt: null,
  };
}

function chatProps(
  reducer: PiConversationReducer,
  overrides: Partial<PiChatViewProps> = {},
): PiChatViewProps {
  return {
    connection: { state: "connected" },
    lastError: null,
    turns: reducer.turns,
    phase: reducer.phase,
    isTruncated: reducer.isTruncated,
    contextUsage: reducer.contextUsage,
    ...overrides,
  };
}

function render(props: PiChatViewProps): string {
  return renderToStaticMarkup(createElement(PiChatView, props));
}

const USER_ENTRY = `{
  "type":"message","id":"e1","timestamp":1700000000000,
  "message":{"role":"user","content":"go","timestamp":1700000000000}
}`;

describe("PiChatView", () => {
  it("renders the byte-exact banner for every non-connected store state", () => {
    const base = {
      lastError: null,
      turns: [],
      phase: "idle" as const,
      isTruncated: false,
      contextUsage: null,
    };
    expect(render({ ...base, connection: { state: "loading" } })).toContain(
      "Loading native transcript…",
    );
    expect(render({ ...base, connection: { state: "bridgeOffline" } })).toContain(
      "Pi is offline. Transcript preserved.",
    );
    expect(
      render({ ...base, connection: { state: "reconnecting", attempt: 2 } }),
    ).toContain("Reconnecting to Pi…");
    expect(render({ ...base, connection: { state: "unavailable" } })).toContain(
      "Native transcript unavailable",
    );
    expect(render({ ...base, connection: { state: "connected" } })).not.toContain(
      "hz-pi-banner",
    );
  });

  it("shows the store's lastError detail under the banner, suppressing the generic offline detail", () => {
    const base = {
      turns: [],
      phase: "idle" as const,
      isTruncated: false,
      contextUsage: null,
    };
    const withDetail = render({
      ...base,
      connection: { state: "bridgeOffline" },
      lastError: "connection refused",
    });
    expect(withDetail).toContain("Pi is offline. Transcript preserved.");
    expect(withDetail).toContain("connection refused");
    // The store's own generic offline detail duplicates the banner text.
    const generic = render({
      ...base,
      connection: { state: "bridgeOffline" },
      lastError: "Pi is offline. The saved transcript is still available.",
    });
    expect(generic.split("Pi is offline. The saved transcript")).toHaveLength(1);
  });

  it("renders the truncation header when the reducer reports truncation", () => {
    const reducer = new PiConversationReducer();
    reducer.replace(
      snapshot(`[${USER_ENTRY}]`, '{"isStreaming":false}', true),
    );
    expect(render(chatProps(reducer))).toContain("Older context was omitted by Pi");

    const notTruncated = new PiConversationReducer();
    notTruncated.replace(snapshot(`[${USER_ENTRY}]`));
    expect(render(chatProps(notTruncated))).not.toContain(
      "Older context was omitted by Pi",
    );
  });

  it("renders assistant markdown through MarkdownBlocks (code as pre/code, raw HTML never in the DOM)", () => {
    const assistant = `{
      "type":"message","id":"e2","timestamp":1700000001000,
      "message":{"role":"assistant","content":[{"type":"text","text":"Run the build:\\n\\n\`\`\`sh\\nmake build\\n\`\`\`\\n\\n<script>alert('x')</script> See the [docs](https://example.com)."}]}
    }`;
    const reducer = new PiConversationReducer();
    reducer.replace(snapshot(`[${USER_ENTRY},${assistant}]`));
    const html = render(chatProps(reducer));

    expect(html).toContain("<pre");
    expect(html).toContain("<code");
    expect(html).toContain("make build");
    expect(html).toContain('href="https://example.com"');
    expect(html).not.toContain("<script");
    expect(html).not.toContain("alert('x')</script");
  });

  it("collapses thinking: 'Thinking' while streaming (with timer), 'Thought process' when settled", () => {
    // Streaming turn via live envelopes.
    const reducer = new PiConversationReducer();
    reducer.replace(snapshot(`[${USER_ENTRY}]`));
    reducer.apply(env(1, { type: "turn_start" }));
    reducer.apply(
      env(2, {
        type: "message_update",
        message: { id: "m1" },
        assistantMessageEvent: { type: "thinking_start", contentIndex: 0 },
      }),
    );
    reducer.apply(
      env(3, {
        type: "message_update",
        message: { id: "m1" },
        assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: "weighing options" },
      }),
    );
    reducer.apply(
      env(4, {
        type: "message_update",
        message: { id: "m1" },
        assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "hello" },
      }),
    );
    expect(reducer.phase).toBe("working");
    const streaming = render(chatProps(reducer));
    expect(streaming).toContain("Thinking");
    expect(streaming).toContain("hz-pi-thinking-timer");
    expect(streaming).not.toContain("Thought process");

    // Settled turn via a persisted thinking part.
    const thinkingEntry = `{
      "type":"message","id":"e2",
      "message":{"role":"assistant","content":[{"type":"thinking","thinking":"deep thoughts"},{"type":"text","text":"done"}]}
    }`;
    const settled = new PiConversationReducer();
    settled.replace(snapshot(`[${USER_ENTRY},${thinkingEntry}]`));
    const html = render(chatProps(settled));
    expect(html).toContain("Thought process");
    expect(html).not.toContain("hz-pi-thinking-timer");
  });

  it("uses the byte-exact reasoning fallbacks", () => {
    // Streaming, no text yet.
    const streaming = new PiConversationReducer();
    streaming.replace(snapshot(`[${USER_ENTRY}]`));
    streaming.apply(
      env(1, {
        type: "message_update",
        message: { id: "m1" },
        assistantMessageEvent: { type: "thinking_start", contentIndex: 0 },
      }),
    );
    expect(render(chatProps(streaming))).toContain("Pi is working through the request…");

    // Settled, empty.
    const empty = `{
      "type":"message","id":"e2",
      "message":{"role":"assistant","content":[{"type":"thinking","thinking":""}]}
    }`;
    const settledEmpty = new PiConversationReducer();
    settledEmpty.replace(snapshot(`[${USER_ENTRY},${empty}]`));
    expect(render(chatProps(settledEmpty))).toContain("No reasoning text was provided.");

    // Redacted.
    const redacted = `{
      "type":"message","id":"e2",
      "message":{"role":"assistant","content":[{"type":"thinking","thinking":"","redacted":true}]}
    }`;
    const redactedReducer = new PiConversationReducer();
    redactedReducer.replace(snapshot(`[${USER_ENTRY},${redacted}]`));
    expect(render(chatProps(redactedReducer))).toContain(
      "Reasoning details are unavailable for this response.",
    );
  });

  it("renders tool cards with status pills, a failed turn rail, and ERROR disclosure", () => {
    const toolCall = `{
      "type":"message","id":"e2",
      "message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"bash","arguments":{"command":"make test"}}]}
    }`;
    const toolResult = `{
      "type":"message","id":"e3","timestamp":1700000002000,
      "message":{"role":"toolResult","toolCallId":"call-1","toolName":"bash","isError":true,"content":"boom","timestamp":1700000002000}
    }`;
    const reducer = new PiConversationReducer();
    reducer.replace(snapshot(`[${USER_ENTRY},${toolCall},${toolResult}]`));
    const html = render(chatProps(reducer));
    expect(html).toContain("FAILED");
    expect(html).toContain("Command");
    expect(html).toContain("make test");
    expect(html).toContain("ERROR");
    expect(html).toContain("hz-pi-turn-failed");
    expect(html).toContain("hz-pi-rail-failed");
  });

  it("renders a QUEUED 'Preparing tool' card with the waiting placeholder", () => {
    const reducer = new PiConversationReducer();
    reducer.replace(snapshot(`[${USER_ENTRY}]`));
    reducer.apply(
      env(1, {
        type: "message_update",
        message: { id: "m1" },
        assistantMessageEvent: { type: "toolcall_start", contentIndex: 0 },
      }),
    );
    const html = render(chatProps(reducer));
    expect(html).toContain("QUEUED");
    // The placeholder name "Preparing tool" is humanized by the presentation
    // mapping (Swift PiToolPresentation does the same) → "Preparing Tool".
    expect(html).toContain("Preparing Tool");
    expect(html).toContain("Waiting for tool details…");
  });

  it("renders in-transcript notice rows", () => {
    const compaction = `{
      "type":"compaction","id":"e3","summary":"Old context was summarized"
    }`;
    const reducer = new PiConversationReducer();
    reducer.replace(snapshot(`[${USER_ENTRY},${compaction}]`));
    const html = render(chatProps(reducer));
    expect(html).toContain("Context compacted");
    expect(html).toContain("hz-pi-notice");
  });

  it("renders the context meter text and color bands (0.4 / 0.7 / 0.9)", () => {
    const cases: Array<[number, number, string, string]> = [
      [64_000, 160_000, "64.0k / 160k · 40%", "hz-pi-meter-ok"],
      [112_000, 160_000, "112k / 160k · 70%", "hz-pi-meter-warn"],
      [144_000, 160_000, "144k / 160k · 90%", "hz-pi-meter-danger"],
    ];
    for (const [tokens, window, text, band] of cases) {
      const state = `{"isStreaming":false,"context":{"tokens":${tokens},"contextWindow":${window}}}`;
      const reducer = new PiConversationReducer();
      reducer.replace(snapshot(`[${USER_ENTRY}]`, state));
      const html = render(chatProps(reducer));
      expect(html).toContain(text);
      expect(html).toContain(band);
    }
  });

  it("renders the empty state (and 'Pi is starting…' while working)", () => {
    const empty = new PiConversationReducer();
    empty.replace(snapshot("[]"));
    const html = render(chatProps(empty));
    expect(html).toContain("Start a conversation");
    expect(html).toContain(
      "Messages, thinking, and tool activity will appear here. The terminal remains available from the pane menu.",
    );
    expect(html).toContain('data-pi-composer-mount');

    const working = new PiConversationReducer();
    working.replace(snapshot("[]", '{"isStreaming":true}'));
    expect(working.phase).toBe("working");
    expect(render(chatProps(working))).toContain("Pi is starting…");
  });
});
