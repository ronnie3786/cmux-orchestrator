import Foundation
import Testing
@testable import herdr_harness_mac

/// The HUD chip's speaker reads a finished session's last answer without a
/// conversation store behind it: it projects a fetched snapshot through the
/// same reducer the chat uses. This pins that the two agree.
@Suite("Latest assistant text")
struct PiLatestAssistantTextTests {
    @Test("A snapshot yields the last finished assistant answer")
    func projectsLastCompletedAnswer() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: """
        [
          {
            "type":"message","id":"u1","parentId":null,"timestamp":"2026-08-12T12:00:00Z",
            "message":{"role":"user","content":"Inspect the API","timestamp":1786536000000}
          },
          {
            "type":"message","id":"a1","parentId":"u1","timestamp":"2026-08-12T12:00:01Z",
            "message":{
              "role":"assistant","timestamp":1786536001000,"stopReason":"stop",
              "content":[{"type":"text","text":"An earlier answer."}]
            }
          },
          {
            "type":"message","id":"u2","parentId":"a1","timestamp":"2026-08-12T12:01:00Z",
            "message":{"role":"user","content":"And now?","timestamp":1786536060000}
          },
          {
            "type":"message","id":"a2","parentId":"u2","timestamp":"2026-08-12T12:01:01Z",
            "message":{
              "role":"assistant","timestamp":1786536061000,"stopReason":"stop",
              "content":[{"type":"text","text":"The API looks good."}]
            }
          }
        ]
        """))

        #expect(reducer.turns.latestCompletedAssistantText == "The API looks good.")
    }

    @Test("A session that has not answered yet has nothing to read")
    func emptyTranscriptHasNoText() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: """
        [
          {
            "type":"message","id":"u1","parentId":null,"timestamp":"2026-08-12T12:00:00Z",
            "message":{"role":"user","content":"Inspect the API","timestamp":1786536000000}
          }
        ]
        """))

        #expect(reducer.turns.latestCompletedAssistantText == nil)
    }

    private func snapshot(entries: String) throws -> PiConversationSnapshot {
        try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                """
                {
                  "protocol":{"name":"herdr.pi.semantic","version":1},
                  "paneId":"p1","available":true,"connected":true,
                  "session":{"id":"s1"},"state":{"isStreaming":false},"entries":\(entries),
                  "pendingInteractions":[],"cursor":"0","oldestCursor":"0","truncated":false
                }
                """.utf8
            )
        )
    }
}
