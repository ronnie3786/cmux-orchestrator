/**
 * Ports of `herdr-harness-iosTests/PiConversationDecodingTests.swift`
 * (8 cases, 1:1) and `PiContextUsageTests.swift` (3 cases, 1:1), plus
 * envelope-normalization cases for the `PiConversationSSEParser` rules
 * ported into `envelope.ts`. The Swift tests are the fixtures; the live
 * server is deliberately not used as a test input source.
 */
import { describe, expect, it } from "vitest";
import {
  decodePiCommandResponse,
  decodePiConversationSnapshot,
  decodePiSemanticCapability,
  decodePiSemanticCapabilities,
  PI_SEMANTIC_CAPABILITIES_UNAVAILABLE,
  piContextUsageFraction,
  piContextUsageFrom,
  piContextUsagePercentText,
  piContextUsageSummary,
  piEnvelopeEventType,
  piKey,
  piSnapshotReportsContextUsage,
  piString,
} from "./types";
import type { PiJSONValue } from "./types";
import {
  PiConversationSSEParser,
  PiInvalidResponseError,
  PiStreamEndedError,
} from "./envelope";

describe("Pi semantic protocol decoding", () => {
  it("decodes the v1 pane capability contract", () => {
    // Swift: JSONDecoder().decode(HerdrPane.self, ...) then asserts on
    // pane.supportsPiSemanticChat / pane.piSemantic — the pane wrapper is
    // HerdrPane territory (P6-run-B); the Pi contract decoded here is the
    // same `pi_semantic` object.
    const pane = JSON.parse(`{
      "pane_id": "w1:p1",
      "workspace_id": "w1",
      "tab_id": "w1:t1",
      "agent_status": "working",
      "pi_semantic": {
        "available": true,
        "connected": true,
        "protocolVersion": 1,
        "sessionId": "session-1",
        "cursor": 42,
        "oldestCursor": "8",
        "capabilities": {
          "prompt": true,
          "steer": true,
          "followUp": true,
          "abort": true,
          "interactionResponse": true
        }
      }
    }`) as { pi_semantic: unknown };

    const piSemantic = decodePiSemanticCapability(pane.pi_semantic as PiJSONValue);

    // Swift: `supportsPiSemanticChat == piSemantic?.available == true && piSemantic?.protocolVersion == 1`
    expect(piSemantic.available).toBe(true);
    expect(piSemantic.protocolVersion).toBe(1);
    expect(piSemantic.sessionID).toBe("session-1");
    expect(piSemantic.cursor).toBe("42");
    expect(piSemantic.capabilities.followUp).toBe(true);
  });

  it("accepts model capabilities in snake case, camel case, and absent fields", () => {
    const snakeCase = decodePiSemanticCapabilities(
      '{"prompt":true,"list_models":true,"set_model":true,"set_thinking_level":true}',
    );
    const camelCase = decodePiSemanticCapabilities(
      '{"prompt":true,"listModels":true,"setModel":true,"setThinkingLevel":true}',
    );
    const absent = decodePiSemanticCapabilities('{"prompt":true}');

    expect(snakeCase.listModels).toBe(true);
    expect(snakeCase.setModel).toBe(true);
    expect(snakeCase.setThinkingLevel).toBe(true);
    expect(camelCase.listModels).toBe(true);
    expect(camelCase.setModel).toBe(true);
    expect(camelCase.setThinkingLevel).toBe(true);
    expect(absent.listModels).toBe(false);
    expect(absent.setModel).toBe(false);
    expect(absent.setThinkingLevel).toBe(false);
    expect(PI_SEMANTIC_CAPABILITIES_UNAVAILABLE.listModels).toBe(false);
    expect(PI_SEMANTIC_CAPABILITIES_UNAVAILABLE.setModel).toBe(false);
    expect(PI_SEMANTIC_CAPABILITIES_UNAVAILABLE.setThinkingLevel).toBe(false);
  });

  it("retains unknown snapshot entries and accepts snake case aliases", () => {
    const snapshot = decodePiConversationSnapshot(`{
      "protocol": {"name":"herdr.pi.semantic","version":1},
      "pane_id":"w1:p1",
      "available":true,
      "connected":true,
      "session":{"id":"s1","future":"kept"},
      "entries":[{"type":"future_entry","id":"e1","payload":{"x":1}}],
      "pending_interactions":[],
      "cursor":17,
      "oldest_cursor":"3",
      "truncated":true
    }`);

    expect(snapshot.paneID).toBe("w1:p1");
    expect(snapshot.cursor).toBe("17");
    expect(snapshot.oldestCursor).toBe("3");
    expect(snapshot.truncated).toBe(true);
    expect(piString(piKey(snapshot.entries[0], "payload"), "x")).toBe("1");
    expect(piSnapshotReportsContextUsage(snapshot)).toBe(false);
  });

  it("distinguishes legacy snapshots by context telemetry presence", () => {
    const snapshot = decodePiConversationSnapshot(`{
      "protocol":{"name":"herdr.pi.semantic","version":1},
      "paneId":"p1","available":true,"connected":true,
      "state":{"isStreaming":false,"context":{"tokens":null,"contextWindow":192000,"percent":null}},
      "entries":[],"pendingInteractions":[],"cursor":"1","truncated":false
    }`);

    // The field exists even when individual values are temporarily null.
    // This is how the app distinguishes a new bridge from a legacy one.
    expect(piSnapshotReportsContextUsage(snapshot)).toBe(true);
  });

  it("SSE parser preserves durable id and multiline payload", () => {
    const parser = new PiConversationSSEParser();
    expect(parser.consume("id: 82")).toBeNull();
    expect(parser.consume("event: pi.agent_start")).toBeNull();
    expect(
      parser.consume('data: {"protocol":{"name":"herdr.pi.semantic","version":1},'),
    ).toBeNull();
    const output = parser.consume(
      'data: "paneId":"p1","sessionId":"s1","event":{"type":"agent_start"}}',
    );

    expect(output?.kind).toBe("envelope");
    if (output?.kind !== "envelope") return;
    expect(output.envelope.cursor).toBe("82");
    expect(piEnvelopeEventType(output.envelope)).toBe("agent_start");
    expect(output.envelope.sessionID).toBe("s1");
  });

  it("SSE comments and heartbeat frames count as activity", () => {
    const parser = new PiConversationSSEParser();
    expect(parser.consume(": keepalive")).toEqual({ kind: "activity" });
    expect(parser.consume("event: heartbeat")).toBeNull();
    expect(parser.consume("data: {}")).toEqual({ kind: "activity" });
    expect(parser.consume("")).toBeNull();
  });

  it("SSE accepts the server's namespaced ready event", () => {
    const parser = new PiConversationSSEParser();
    expect(parser.consume("event: pi.ready")).toBeNull();
    expect(
      parser.consume('data: {"cursor":"42","latest_cursor":"47"}'),
    ).toEqual({ kind: "activity" });
    expect(parser.consume("")).toBeNull();
  });

  it("command acknowledgement accepts bridge success responses", () => {
    const response = decodePiCommandResponse('{"type":"response","success":true}');
    expect(response.accepted).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// PiContextUsageTests.swift (3 cases, 1:1)
// ---------------------------------------------------------------------------

describe("Pi context usage", () => {
  it("summary compacts token counts", () => {
    const usage = piContextUsageFrom({
      tokens: 12_345,
      contextWindow: 192_000,
      percent: 6.43,
    } as PiJSONValue);

    expect(usage).not.toBeNull();
    const value = usage!;
    expect(piContextUsageSummary(value)).toBe("12.3k / 192k");
    expect(piContextUsagePercentText(value)).toBe("6%");
    expect(piContextUsageFraction(value)).toBe(12_345.0 / 192_000);
  });

  it("all-null usage decodes as unknown", () => {
    const usage = piContextUsageFrom({
      tokens: null,
      contextWindow: null,
      percent: null,
    } as PiJSONValue);

    expect(usage).toBeNull();
  });

  it("percent-only usage still yields a fraction", () => {
    const usage = piContextUsageFrom({ percent: 87 } as PiJSONValue);

    expect(usage).not.toBeNull();
    const value = usage!;
    expect(piContextUsageFraction(value)).toBe(0.87);
    expect(piContextUsagePercentText(value)).toBe("87%");
    expect(piContextUsageSummary(value)).toBeNull();
  });
});

describe("PiConversationSSEParser envelope normalization", () => {
  it("drops events that are neither pi.-prefixed nor the default message name", () => {
    const parser = new PiConversationSSEParser();
    expect(parser.consume("event: terminal.update")).toBeNull();
    expect(
      parser.consume('data: {"paneID":"p1","event":{"type":"frame"}}'),
    ).toBeNull();
    // The blank line force-dispatches: record is reset, nothing emitted.
    expect(parser.consume("")).toBeNull();
    // The next record still decodes cleanly.
    const output = parser.consume(
      'data: {"paneID":"p1","event":{"type":"agent_start"}}',
    );
    expect(output?.kind).toBe("envelope");
  });

  it("the default event name (no `event:` line) still decodes envelopes", () => {
    const parser = new PiConversationSSEParser();
    const output = parser.consume(
      'data: {"paneID":"p1","event":{"type":"message"}}',
    );
    expect(output?.kind).toBe("envelope");
    if (output?.kind !== "envelope") return;
    expect(output.envelope.cursor).toBeNull();
    expect(piEnvelopeEventType(output.envelope)).toBe("message");
  });

  it("un-prefixed ready/heartbeat frames also count as activity", () => {
    const parser = new PiConversationSSEParser();
    expect(parser.consume("event: ready")).toBeNull();
    expect(parser.consume('data: {"connected":true}')).toEqual({ kind: "activity" });
    expect(parser.consume("")).toBeNull();
  });

  it("pi.stream.closed and pi.error throw the stream-ended error", () => {
    for (const eventName of ["pi.stream.closed", "pi.error"]) {
      const parser = new PiConversationSSEParser();
      parser.consume(`event: ${eventName}`);
      expect(() => parser.consume('data: {"event":{"type":"x"}}')).toThrow(
        PiStreamEndedError,
      );
    }
  });

  it("an undecodable payload throws at forced dispatch", () => {
    const parser = new PiConversationSSEParser();
    // Non-forced dispatch buffers the incomplete/invalid payload...
    expect(parser.consume("data: {\"paneID\":\"p1\"")).toBeNull();
    // ...and the blank line force-dispatches it as invalid.
    expect(() => parser.consume("")).toThrow(PiInvalidResponseError);
  });

  it("a payload missing the required event field throws at forced dispatch", () => {
    const parser = new PiConversationSSEParser();
    expect(parser.consume('data: {"paneID":"p1","sessionID":"s1"}')).toBeNull();
    expect(() => parser.consume("")).toThrow(PiInvalidResponseError);
  });
});
