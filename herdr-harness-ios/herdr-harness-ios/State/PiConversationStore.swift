import Foundation
import Observation

@MainActor
@Observable
final class PiConversationStore {
    private(set) var turns: [PiConversationTurn] = []
    private(set) var pendingInteractions: [PiPendingInteraction] = []
    private(set) var phase: PiConversationPhase = .idle
    private(set) var connection: PiConversationConnection = .loading
    private(set) var revision = 0
    private(set) var isTruncated = false
    private(set) var bridgeConnected = false
    private(set) var contextUsage: PiContextUsage?
    private(set) var isSubmitting = false
    private(set) var isAborting = false
    private(set) var lastError: String?
    private(set) var commandNotice: String?

    @ObservationIgnored private var reducer = PiConversationReducer()

    var hasContent: Bool {
        turns.contains(where: \.hasVisibleContent)
    }

    var canSendCommands: Bool {
        bridgeConnected && connection.isConnected
    }

    func follow(model: HerdrAppModel, pane: HerdrPane) async {
        connection = .loading
        lastError = nil
        var retryDelay = 0.65
        var retryAttempt = 0

        followLoop: while !Task.isCancelled {
            do {
                let snapshot = try await model.fetchPiConversationSnapshot(for: pane)
                try Task.checkCancellation()
                guard snapshot.protocolInfo.name == "herdr.pi.semantic",
                      snapshot.protocolInfo.version == 1,
                      snapshot.available
                else {
                    connection = .unavailable
                    lastError = "This Pi session does not expose a compatible native transcript."
                    return
                }

                reducer.replace(with: snapshot)
                publishReducerState()
                guard !Task.isCancelled else { return }
                connection = snapshot.connected ? .connected : .bridgeOffline
                lastError = snapshot.connected
                    ? nil
                    : "Pi is offline. The saved transcript is still available."

                // A transcript from an older bridge is still useful, but its
                // event stream may not have the newer semantic contract. Do
                // not block the chat on an SSE stream that cannot provide the
                // optional context telemetry. Polling keeps legacy chats
                // readable and automatically upgrades when a new bridge is
                // available.
                if !snapshot.reportsContextUsage || !snapshot.connected {
                    if await followSnapshotPolling(
                        model: model,
                        pane: pane,
                        initialSnapshot: snapshot
                    ) {
                        retryAttempt = 0
                        retryDelay = 0.65
                        continue followLoop
                    }
                    return
                }

                guard let events = await model.piConversationEvents(for: pane, after: reducer.cursor) else {
                    throw APIError.streamEnded
                }
                if try await consume(events) {
                    retryAttempt = 0
                    retryDelay = 0.65
                    continue followLoop
                }
                throw APIError.streamEnded
            } catch is CancellationError {
                return
            } catch {
                retryAttempt += 1
                connection = .reconnecting(attempt: retryAttempt)
                lastError = hasContent
                    ? "Live updates paused. Reconnecting…"
                    : error.localizedDescription
            }

            do {
                try await Task.sleep(for: .seconds(retryDelay))
            } catch {
                return
            }
            retryDelay = min(retryDelay * 1.7, 6)
        }
    }

    func submit(
        text: String,
        disposition: PiPromptDisposition,
        model: HerdrAppModel,
        pane: HerdrPane
    ) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSubmitting else { return false }
        guard canSendCommands else {
            lastError = "Pi is offline. Reconnect before sending a message."
            return false
        }
        isSubmitting = true
        commandNotice = nil
        defer { isSubmitting = false }
        do {
            try await model.sendPiConversationPrompt(prompt, disposition: disposition, to: pane)
            lastError = nil
            commandNotice = disposition == .followUp ? "Follow-up queued" : nil
            return true
        } catch {
            commandNotice = nil
            lastError = error.localizedDescription
            return false
        }
    }

    func abort(model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard !isAborting, canSendCommands else { return false }
        isAborting = true
        commandNotice = nil
        defer { isAborting = false }
        do {
            try await model.abortPiConversation(for: pane)
            lastError = nil
            commandNotice = "Stop requested"
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func respond(
        to interaction: PiPendingInteraction,
        response: PiInteractionResponseBody,
        model: HerdrAppModel,
        pane: HerdrPane
    ) async -> Bool {
        guard canSendCommands else {
            lastError = "Pi is offline. Reconnect before responding."
            return false
        }
        do {
            try await model.respondToPiInteraction(
                id: interaction.id,
                response: response,
                in: pane
            )
            reducer.removeInteraction(id: interaction.id)
            publishReducerState()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func clearCommandNotice() {
        commandNotice = nil
    }

    /// Consumes one live stream until it ends or the reducer requests an
    /// authoritative snapshot. Returning immediately on reset is important:
    /// healthy SSE connections are intentionally long-lived, so merely setting
    /// a flag would leave stale transcript state in place forever.
    func consume(
        _ events: AsyncThrowingStream<PiConversationStreamEvent, any Error>
    ) async throws -> Bool {
        for try await streamEvent in events {
            try Task.checkCancellation()
            switch streamEvent {
            case .activity:
                // An SSE heartbeat proves only that the harness is alive.
                // It says nothing about the extension socket behind it.
                continue
            case let .envelope(envelope):
                let effect = reducer.apply(envelope)
                publishReducerState()
                connection = reducer.bridgeConnected ? .connected : .bridgeOffline
                lastError = reducer.bridgeConnected ? nil : "Pi is offline. The saved transcript is still available."
                if effect == .needsSnapshot {
                    return true
                }
            }
        }
        return false
    }

    func reset() {
        reducer = PiConversationReducer()
        turns = []
        pendingInteractions = []
        phase = .idle
        connection = .loading
        revision &+= 1
        isTruncated = false
        bridgeConnected = false
        contextUsage = nil
        isSubmitting = false
        isAborting = false
        lastError = nil
        commandNotice = nil
    }

    /// Legacy bridges can provide a durable snapshot without a compatible
    /// live context/event stream. Keep that transcript usable with a gentle
    /// snapshot poll instead of retrying a long-lived SSE connection forever.
    private func followSnapshotPolling(
        model: HerdrAppModel,
        pane: HerdrPane,
        initialSnapshot: PiConversationSnapshot
    ) async -> Bool {
        var previousSnapshot = initialSnapshot
        var retryDelay = 2.0

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
                let snapshot = try await model.fetchPiConversationSnapshot(for: pane)
                try Task.checkCancellation()
                guard snapshot.protocolInfo.name == "herdr.pi.semantic",
                      snapshot.protocolInfo.version == 1,
                      snapshot.available
                else {
                    connection = .unavailable
                    lastError = "This Pi session does not expose a compatible native transcript."
                    return false
                }

                if snapshotContentChanged(from: previousSnapshot, to: snapshot) {
                    reducer.replace(with: snapshot)
                    publishReducerState()
                    guard !Task.isCancelled else { return false }
                    previousSnapshot = snapshot
                }
                connection = snapshot.connected ? .connected : .bridgeOffline
                lastError = snapshot.connected
                    ? nil
                    : "Pi is offline. The saved transcript is still available."
                retryDelay = 2

                if snapshot.reportsContextUsage && snapshot.connected {
                    return true
                }
            } catch is CancellationError {
                return false
            } catch {
                retryDelay = min(retryDelay * 1.7, 8)
                connection = .reconnecting(attempt: 1)
                lastError = hasContent
                    ? "Live updates paused. Reconnecting…"
                    : error.localizedDescription
                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private func snapshotContentChanged(
        from previous: PiConversationSnapshot,
        to current: PiConversationSnapshot
    ) -> Bool {
        previous.ok != current.ok
            || previous.protocolInfo != current.protocolInfo
            || previous.paneID != current.paneID
            || previous.available != current.available
            || previous.connected != current.connected
            || previous.session != current.session
            || previous.state != current.state
            || previous.entries != current.entries
            || previous.pendingInteractions != current.pendingInteractions
            || previous.cursor != current.cursor
            || previous.oldestCursor != current.oldestCursor
            || previous.truncated != current.truncated
    }

    private func publishReducerState() {
        turns = reducer.turns
        pendingInteractions = reducer.pendingInteractions
        phase = reducer.phase
        isTruncated = reducer.isTruncated
        bridgeConnected = reducer.bridgeConnected
        contextUsage = reducer.contextUsage
        revision &+= 1
    }
}
