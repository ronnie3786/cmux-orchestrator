/**
 * Port of `herdr-harness-iosTests/PiConversationReducerTests.swift`
 * (13 cases, 1:1). The Swift suite is the acceptance spec: same event
 * sequences, same expectations. The only adaptations:
 *  - Swift `#expect(a == .case)` → `expect(a).toBe("case")` (Effect union).
 *  - Swift enum-tagged `PiConversationItem` pattern matching → `kind` checks.
 *  - `PiJSONValue?.stringValue` → `piStringValue(...)`.
 *  - Test 1 (`resetInterruptsLiveStream`): the Swift `PiConversationStore`
 *    is not yet ported; the test drives the port of its `consume(_:)` core
 *    (`consumePiConversationStream`) instead — same contract: returns true
 *    exactly when the reducer requests a snapshot while the stream is open.
 */
import { describe, expect, it } from "vitest";
import {
  consumePiConversationStream,
  PiConversationReducer,
} from "./reducer";
import {
  decodePiConversationSnapshot,
  piContextUsageFraction,
  piStringValue,
  piValue,
} from "./types";
import type {
  PiConversationEnvelope,
  PiConversationItem,
  PiConversationSnapshot,
  PiConversationStreamEvent,
  PiJSONValue,
} from "./types";

function decodeSnapshot(
  entries: string,
  state = '{"isStreaming":false}',
): PiConversationSnapshot {
  return decodePiConversationSnapshot(`{
    "protocol":{"name":"herdr.pi.semantic","version":1},
    "paneId":"p1","available":true,"connected":true,
    "session":{"id":"s1"},"state":${state},"entries":${entries},
    "pendingInteractions":[],"cursor":"0","oldestCursor":"0","truncated":false
  }`);
}

function envelope(cursor: number, eventJSON: string): PiConversationEnvelope {
  return {
    protocolInfo: { name: "herdr.pi.semantic", version: 1 },
    paneID: "p1",
    sessionID: "s1",
    cursor: String(cursor),
    connected: null,
    event: JSON.parse(eventJSON) as PiJSONValue,
    generatedAt: null,
  };
}

type ItemValueOf<K extends PiConversationItem["kind"]> = Extract<
  PiConversationItem,
  { kind: K }
>["value"];

function valuesOfKind<K extends PiConversationItem["kind"]>(
  items: PiConversationItem[],
  kind: K,
): ItemValueOf<K>[] {
  return items.flatMap(
    (item): ItemValueOf<K>[] =>
      item.kind === kind ? [item.value as ItemValueOf<K>] : [],
  );
}

describe("Pi conversation reducer", () => {
  it("A reset exits a still-open stream so follow can reload its snapshot", async () => {
    const reset = envelope(
      1,
      '{"type":"stream.reset","reason":"session_tree_changed"}',
    );
    const stream = (async function* (): AsyncGenerator<PiConversationStreamEvent> {
      yield { kind: "activity" };
      yield { kind: "envelope", envelope: reset };
      // Deliberately keep the stream open. A production SSE connection
      // will not end just because it delivered a reset record. (Bounded so
      // the test cannot hang if the consumer fails to exit.)
      for (let i = 0; i < 40; i++) {
        await new Promise((resolve) => setTimeout(resolve, 10));
        yield { kind: "activity" };
      }
    })();
    const reducer = new PiConversationReducer();
    const exited = await consumePiConversationStream(stream, reducer);
    expect(exited).toBe(true);
  });

  it("Pi turn start waits for the user message before creating a visible turn", () => {
    const reducer = new PiConversationReducer();
    const start: PiConversationEnvelope = {
      protocolInfo: { name: "herdr.pi.semantic", version: 1 },
      paneID: "w1:p1",
      sessionID: "session-a",
      cursor: "1",
      connected: null,
      event: { type: "turn_start" },
      generatedAt: null,
    };

    expect(reducer.apply(start)).toBe("none");

    expect(reducer.phase).toBe("working");
    expect(reducer.turns).toHaveLength(0);
  });

  it("Tree and compaction lifecycle events reload same-session context", () => {
    for (const eventType of ["session_tree", "session_compact"]) {
      const reducer = new PiConversationReducer();
      const env: PiConversationEnvelope = {
        protocolInfo: { name: "herdr.pi.semantic", version: 1 },
        paneID: "w1:p1",
        sessionID: "session-a",
        cursor: "1",
        connected: null,
        event: { type: eventType },
        generatedAt: null,
      };

      expect(reducer.apply(env)).toBe("needsSnapshot");
    }
  });

  it("Snapshot groups persisted entries into stable user turns", () => {
    const snapshot = decodeSnapshot(`[
      {
        "type":"message","id":"u1","parentId":null,"timestamp":"2026-08-12T12:00:00Z",
        "message":{"role":"user","content":"Inspect the API","timestamp":1786536000000}
      },
      {
        "type":"message","id":"a1","parentId":"u1","timestamp":"2026-08-12T12:00:01Z",
        "message":{
          "role":"assistant","timestamp":1786536001000,"stopReason":"toolUse",
          "content":[
            {"type":"thinking","thinking":"I should inspect the file."},
            {"type":"text","text":"I’ll inspect it."},
            {"type":"toolCall","id":"call-1","name":"read","arguments":{"path":"API.swift"}}
          ]
        }
      },
      {
        "type":"message","id":"r1","parentId":"a1","timestamp":"2026-08-12T12:00:02Z",
        "message":{
          "role":"toolResult","toolCallId":"call-1","toolName":"read","isError":false,
          "timestamp":1786536002000,"content":[{"type":"text","text":"contents"}]
        }
      },
      {
        "type":"message","id":"a2","parentId":"r1","timestamp":"2026-08-12T12:00:03Z",
        "message":{
          "role":"assistant","timestamp":1786536003000,"stopReason":"stop",
          "content":[{"type":"text","text":"The API looks good."}]
        }
      },
      {
        "type":"message","id":"u2","parentId":"a2","timestamp":"2026-08-12T12:01:00Z",
        "message":{"role":"user","content":"Thanks","timestamp":1786536060000}
      }
    ]`);
    const reducer = new PiConversationReducer();
    reducer.replace(snapshot);

    expect(reducer.turns).toHaveLength(2);
    expect(reducer.turns[0].id).toBe("turn:u1");
    expect(reducer.turns[0].user?.text).toBe("Inspect the API");
    expect(reducer.turns[0].items).toHaveLength(4);
    expect(reducer.turns[1].user?.text).toBe("Thanks");
    expect(reducer.phase).toBe("idle");

    const tool = valuesOfKind(reducer.turns[0].items, "tool")[0];
    expect(tool?.status).toBe("succeeded");
    expect(piStringValue(piValue(tool?.arguments, "path"))).toBe("API.swift");
  });

  it("Direct stripped deltas stream text, thinking, and tools without duplication", () => {
    const reducer = new PiConversationReducer();
    reducer.replace(decodeSnapshot("[]", '{"isStreaming":true}'));

    expect(reducer.apply(envelope(1, '{"type":"agent_start"}'))).toBe("none");
    expect(
      reducer.apply(
        envelope(
          2,
          '{"type":"message_start","message":{"role":"assistant","timestamp":1786536000000,"content":[]}}',
        ),
      ),
    ).toBe("none");
    expect(
      reducer.apply(
        envelope(
          3,
          '{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}',
        ),
      ),
    ).toBe("none");
    const delta = envelope(
      4,
      '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello"}}',
    );
    expect(reducer.apply(delta)).toBe("none");
    expect(reducer.apply(delta)).toBe("none");
    reducer.apply(
      envelope(
        5,
        '{"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":1}}',
      ),
    );
    reducer.apply(
      envelope(
        6,
        '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":1,"delta":"Checking"}}',
      ),
    );
    reducer.apply(
      envelope(
        7,
        '{"type":"message_update","assistantMessageEvent":{"type":"thinking_end","contentIndex":1,"content":"Checking carefully"}}',
      ),
    );
    reducer.apply(
      envelope(
        8,
        '{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":2}}',
      ),
    );
    reducer.apply(
      envelope(
        9,
        '{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":2,"toolCall":{"type":"toolCall","id":"call-2","name":"bash","arguments":{"command":"pwd"}}}}',
      ),
    );
    reducer.apply(
      envelope(
        10,
        '{"type":"tool_execution_start","toolCallId":"call-2","toolName":"bash","args":{"command":"pwd"}}',
      ),
    );
    reducer.apply(
      envelope(
        11,
        '{"type":"tool_execution_end","toolCallId":"call-2","toolName":"bash","result":{"content":"/repo"},"isError":false}',
      ),
    );
    reducer.apply(
      envelope(
        12,
        `{
          "type":"message_end",
          "message":{"role":"assistant","timestamp":1786536000000,"stopReason":"stop","content":[
            {"type":"text","text":"Hello!"},
            {"type":"thinking","thinking":"Checking carefully"},
            {"type":"toolCall","id":"call-2","name":"bash","arguments":{"command":"pwd"}}
          ]}
        }`,
      ),
    );
    const settledEffect = reducer.apply(envelope(13, '{"type":"agent_settled"}'));

    expect(settledEffect).toBe("completed");
    expect(reducer.phase).toBe("idle");
    expect(reducer.turns).toHaveLength(1);
    const items = reducer.turns[0].items;
    const text = valuesOfKind(items, "assistant")[0];
    const thinking = valuesOfKind(items, "thinking")[0];
    const tool = valuesOfKind(items, "tool")[0];
    expect(text?.text).toBe("Hello!");
    expect(thinking?.text).toBe("Checking carefully");
    expect(thinking?.isStreaming).toBe(false);
    expect(tool?.callID).toBe("call-2");
    expect(tool?.status).toBe("succeeded");
    expect(piStringValue(piValue(tool?.result, "content"))).toBe("/repo");
  });

  it("Replay gaps request an authoritative snapshot", () => {
    const reducer = new PiConversationReducer();
    reducer.replace(decodeSnapshot("[]"));
    expect(
      reducer.apply(envelope(9, '{"type":"ready","connected":true}')),
    ).toBe("none");
    const effect = reducer.apply(
      envelope(9, '{"type":"stream.reset","reason":"replay_gap"}'),
    );
    expect(effect).toBe("needsSnapshot");
  });

  it("Only bridge state events change command connectivity", () => {
    const reducer = new PiConversationReducer();
    const offlineSnapshot = decodePiConversationSnapshot(`{
      "protocol":{"name":"herdr.pi.semantic","version":1},
      "paneId":"p1","available":true,"connected":false,
      "entries":[],"pendingInteractions":[],"cursor":"0","truncated":false
    }`);
    reducer.replace(offlineSnapshot);
    expect(reducer.bridgeConnected).toBe(false);

    reducer.apply(envelope(1, '{"type":"agent_start"}'));
    expect(reducer.bridgeConnected).toBe(false);

    reducer.apply(envelope(2, '{"type":"bridge.connection","connected":true}'));
    expect(reducer.bridgeConnected).toBe(true);

    reducer.apply(envelope(3, '{"type":"bridge.connection","connected":false}'));
    expect(reducer.bridgeConnected).toBe(false);
    expect(reducer.turns).toHaveLength(0);
  });

  it("Snapshots and model selection events update the current model", () => {
    const reducer = new PiConversationReducer();
    reducer.replace(
      decodeSnapshot(
        "[]",
        '{"isStreaming":false,"model":{"provider":"anthropic","id":"claude-3","name":"Claude 3"}}',
      ),
    );

    expect(reducer.currentModel?.provider).toBe("anthropic");
    expect(reducer.currentModel?.id).toBe("claude-3");

    const effect = reducer.apply(
      envelope(
        1,
        '{"type":"pi.model_select","model":{"provider":"openai","id":"gpt-5"},"previousModel":{"provider":"anthropic","id":"claude-3"},"source":"set"}',
      ),
    );

    expect(effect).toBe("none");
    expect(reducer.currentModel?.provider).toBe("openai");
    expect(reducer.currentModel?.id).toBe("gpt-5");

    reducer.apply(envelope(2, '{"type":"turn_start"}'));
    expect(reducer.currentModel?.provider).toBe("openai");
    expect(reducer.currentModel?.id).toBe("gpt-5");
  });

  it("Snapshots and thinking level selection events update the thinking level", () => {
    const reducer = new PiConversationReducer();
    reducer.replace(
      decodeSnapshot("[]", '{"isStreaming":false,"thinkingLevel":"high"}'),
    );

    expect(reducer.thinkingLevel).toBe("high");

    const effect = reducer.apply(
      envelope(1, '{"type":"pi.thinking_level_select","level":"max"}'),
    );

    expect(effect).toBe("none");
    expect(reducer.thinkingLevel).toBe("max");

    reducer.apply(envelope(2, '{"type":"turn_start"}'));
    expect(reducer.thinkingLevel).toBe("max");
  });

  it("An empty failed assistant message remains visible", () => {
    const reducer = new PiConversationReducer();
    reducer.replace(decodeSnapshot("[]"));

    const effect = reducer.apply(
      envelope(
        1,
        `{
          "type":"message_end",
          "message":{
            "role":"assistant",
            "id":"a-error",
            "content":[],
            "stopReason":"error",
            "errorMessage":"Provider unavailable"
          }
        }`,
      ),
    );

    expect(effect).toBe("failed");
    const lastTurn = reducer.turns[reducer.turns.length - 1];
    expect(
      valuesOfKind(lastTurn?.items ?? [], "notice").some(
        (notice) => notice.detail === "Provider unavailable" && notice.tone === "error",
      ),
    ).toBe(true);
  });

  it("Pending extension interactions are correlated and removed", () => {
    const reducer = new PiConversationReducer();
    reducer.replace(decodeSnapshot("[]"));
    const requested = reducer.apply(
      envelope(
        1,
        `{
          "type":"extension_ui_request",
          "id":"question-1",
          "method":"select",
          "title":"Choose a target",
          "options":["iOS","Server"]
        }`,
      ),
    );

    expect(requested).toBe("interactionRequested");
    expect(reducer.pendingInteractions[0]?.options).toEqual(["iOS", "Server"]);
    reducer.removeInteraction("question-1");
    expect(reducer.pendingInteractions).toHaveLength(0);
  });

  it("Context usage projects from snapshots and updates on turn end", () => {
    const reducer = new PiConversationReducer();

    const snapshot = decodeSnapshot(
      "[]",
      '{"isStreaming":false,"context":{"tokens":12345,"contextWindow":192000,"percent":6.43}}',
    );
    reducer.replace(snapshot);
    expect(reducer.contextUsage?.tokens).toBe(12345);
    expect(reducer.contextUsage?.contextWindow).toBe(192000);
    expect(piContextUsageFraction(reducer.contextUsage!)).toBe(
      12345.0 / 192000,
    );

    const turnEnd = envelope(
      1,
      '{"type":"turn_end","turnIndex":1,"context":{"tokens":20000,"contextWindow":192000,"percent":10.4}}',
    );
    reducer.apply(turnEnd);
    expect(reducer.contextUsage?.tokens).toBe(20000);

    // A null post-compaction reading keeps the last known value.
    const compactedTurnEnd = envelope(
      2,
      '{"type":"turn_end","turnIndex":2,"context":{"tokens":null,"contextWindow":null,"percent":null}}',
    );
    reducer.apply(compactedTurnEnd);
    expect(reducer.contextUsage?.tokens).toBe(20000);

    // An authoritative snapshot still wins, including "unknown".
    const compactedSnapshot = decodeSnapshot(
      "[]",
      '{"isStreaming":false,"context":{"tokens":null,"contextWindow":null,"percent":null}}',
    );
    reducer.replace(compactedSnapshot);
    expect(reducer.contextUsage).toBeNull();
  });

  it("Older snapshots without context reporting leave usage unknown", () => {
    const reducer = new PiConversationReducer();
    const snapshot = decodeSnapshot("[]");
    reducer.replace(snapshot);
    expect(reducer.contextUsage).toBeNull();
  });
});
