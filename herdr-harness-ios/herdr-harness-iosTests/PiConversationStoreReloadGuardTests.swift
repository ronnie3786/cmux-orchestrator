import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Pi conversation reload guard")
@MainActor
struct PiConversationStoreReloadGuardTests {
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

    @Test("URL-session cancellation does not become a persistent connection error")
    func urlCancellationDoesNotSurfaceAsAnError() async throws {
        let store = PiConversationStore()
        let pane = testPane()
        store.snapshotProvider = { _ in try self.snapshot() }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorCancelled
                ))
            }
        }

        await store.follow(model: HerdrAppModel(arguments: []), pane: pane)

        #expect(store.connection == .connected)
        #expect(store.lastError == nil)
    }

    @Test("Snapshot cancellation does not become a persistent connection error")
    func snapshotCancellationDoesNotSurfaceAsAnError() async {
        let store = PiConversationStore()
        store.snapshotProvider = { _ in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        }

        await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())

        #expect(store.connection == .loading)
        #expect(store.lastError == nil)
    }

    private func testPane() -> HerdrPane {
        HerdrPane(
            paneID: "w1:p1", terminalID: "w1:p1", workspaceID: "w1", tabID: "",
            focused: true, agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil,
            label: nil, title: nil, agent: nil, displayAgent: nil, terminalTitle: nil,
            terminalTitleStripped: nil
        )
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
