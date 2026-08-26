import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Pi conversation reload guard")
@MainActor
struct PiConversationStoreReloadGuardTests {
    @Test("Overflow resumes from the last applied cursor without publishing a stale snapshot")
    func overflowResumesWithoutSnapshotRegression() async throws {
        let store = PiConversationStore()
        let staleSnapshot = try snapshot(
            cursor: "1",
            state: "{\"working\":true,\"isStreaming\":true,\"context\":{\"tokens\":0,\"contextWindow\":1000000,\"percent\":0}}",
            entries: """
            [{"type":"message","id":"u1","message":{"role":"user","content":"Fix it"}}]
            """
        )
        let liveEvents = try [
            streamEvent(2, """
            {"type":"message_start","message":{"role":"assistant","content":[]}}
            """),
            streamEvent(3, """
            {"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}
            """),
            streamEvent(4, """
            {"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Live answer"}}
            """),
            streamEvent(5, """
            {"type":"turn_end","context":{"tokens":36300,"contextWindow":175000,"percent":20.74}}
            """)
        ]
        let pane = testPane()
        var snapshotCalls = 0
        var requestedCursors: [String?] = []
        store.snapshotProvider = { _ in
            snapshotCalls += 1
            return staleSnapshot
        }
        store.eventsProvider = { _, cursor in
            requestedCursors.append(cursor)
            if requestedCursors.count == 1 {
                return AsyncThrowingStream { continuation in
                    for event in liveEvents { continuation.yield(event) }
                    continuation.finish(throwing: APIError.streamBacklogOverflow)
                }
            }
            return AsyncThrowingStream { _ in }
        }
        store.overflowRetryDelay = .milliseconds(5)

        let model = HerdrAppModel(arguments: [])
        let task = Task { @MainActor in
            await store.follow(model: model, pane: pane)
        }
        defer { task.cancel() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while (requestedCursors.count < 2 || store.contextUsage?.tokens != 36_300),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(snapshotCalls == 1)
        #expect(requestedCursors == ["1", "5"])
        #expect(store.contextUsage?.tokens == 36_300)
        #expect(store.contextUsage?.contextWindow == 175_000)
        #expect(store.turns.contains { turn in
            turn.items.contains { item in
                guard case let .assistant(block) = item else { return false }
                return block.text == "Live answer"
            }
        })

        task.cancel()
        await task.value
    }

    @Test("Repeated no-progress reloads back off before polling")
    func repeatedReloadsFallBackToPolling() async throws {
        let store = PiConversationStore()
        let snapshot = try snapshot()
        let pane = testPane()
        store.snapshotProvider = { _ in snapshot }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.envelope(PiConversationEnvelope(
                    paneID: "w1:p1",
                    sessionID: "s1",
                    cursor: "1",
                    event: .object(["type": .string("session_compact")])
                )))
                continuation.finish()
            }
        }
        store.reloadBackoffBase = .milliseconds(5)

        let model = HerdrAppModel(arguments: [])
        let clock = ContinuousClock()
        let task = Task { @MainActor in
            await store.follow(model: model, pane: pane)
        }
        defer { task.cancel() }

        let pollingDeadline = clock.now.advanced(by: .seconds(3))
        while store.transport != .polling, clock.now < pollingDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.transport == .polling)
        #expect(store.noProgressReloads >= 2)
        try await Task.sleep(for: .seconds(2.1))
        #expect(store.transport == .polling)
        task.cancel()
        await task.value
    }

    @Test("Stuck cursor polling holds before returning to live stream")
    func stuckCursorPollingHoldsBeforeReturningToLiveStream() async throws {
        let store = PiConversationStore()
        let snapshot = try snapshot()
        let pane = testPane()
        store.snapshotProvider = { _ in snapshot }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.envelope(PiConversationEnvelope(
                    paneID: "w1:p1",
                    sessionID: "s1",
                    cursor: "1",
                    event: .object(["type": .string("session_compact")])
                )))
                continuation.finish()
            }
        }
        store.reloadBackoffBase = .milliseconds(5)
        store.stuckCursorPollingHold = .milliseconds(300)

        let model = HerdrAppModel(arguments: [])
        let task = Task { @MainActor in await store.follow(model: model, pane: pane) }
        defer { task.cancel() }

        let clock = ContinuousClock()
        let pollingDeadline = clock.now.advanced(by: .seconds(3))
        while store.transport != .polling, clock.now < pollingDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.transport == .polling)

        let pollingEnteredAt = clock.now
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.transport == .polling)

        let liveStreamDeadline = pollingEnteredAt.advanced(by: .seconds(3))
        while store.transport != .liveStream, clock.now < liveStreamDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.transport == .liveStream)
        task.cancel()
        await task.value
    }

    @Test("Reload guard decays after an idle interval")
    func separatedReloadsDoNotTripPollingFallback() async throws {
        let store = PiConversationStore()
        let snapshot = try snapshot()
        let pane = testPane()
        var streamRequest = 0
        store.snapshotProvider = { _ in snapshot }
        store.eventsProvider = { _, _ in
            streamRequest += 1
            let request = streamRequest
            return AsyncThrowingStream { continuation in
                Task { @MainActor in
                    if request <= 2 {
                        if request == 2 { try? await Task.sleep(for: .milliseconds(20)) }
                        continuation.yield(.envelope(PiConversationEnvelope(
                            paneID: "w1:p1",
                            sessionID: "s1",
                            cursor: "1",
                            event: .object(["type": .string("session_compact")])
                        )))
                    }
                }
            }
        }
        store.reloadBackoffBase = .milliseconds(5)
        store.reloadDecayWindow = .milliseconds(10)

        let model = HerdrAppModel(arguments: [])
        let task = Task { @MainActor in await store.follow(model: model, pane: pane) }
        defer { task.cancel() }
        for _ in 0..<100 where streamRequest < 3 { try await Task.sleep(for: .milliseconds(5)) }

        #expect(streamRequest >= 3)
        #expect(store.transport == .liveStream)
        #expect(store.noProgressReloads < 2)
        task.cancel()
        await task.value
    }

    private func testPane() -> HerdrPane {
        HerdrPane(
            paneID: "w1:p1", terminalID: "w1:p1", workspaceID: "w1", tabID: "",
            focused: true, agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil,
            label: nil, title: nil, agent: nil, displayAgent: nil, terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }

    private func streamEvent(_ cursor: Int, _ event: String) throws -> PiConversationStreamEvent {
        let envelope = try JSONDecoder().decode(
            PiConversationEnvelope.self,
            from: Data(
                """
                {"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"w1:p1","session_id":"s1","cursor":"\(cursor)","event":\(event)}
                """.utf8
            )
        )
        return .envelope(envelope)
    }

    private func snapshot(
        cursor: String = "1",
        state: String = "{\"context\":{\"tokens\":1}}",
        entries: String = "[]"
    ) throws -> PiConversationSnapshot {
        try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                """
                {"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"w1:p1","available":true,"connected":true,"session":{"id":"s1"},"state":\(state),"entries":\(entries),"pending_interactions":[],"cursor":"\(cursor)","latest_cursor":"\(cursor)","oldest_cursor":"\(cursor)","truncated":false}
                """.utf8
            )
        )
    }
}
