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
                connection = snapshot.connected ? .connected : .bridgeOffline
                lastError = snapshot.connected
                    ? nil
                    : "Pi is offline. The saved transcript is still available."

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
        isSubmitting = false
        isAborting = false
        lastError = nil
        commandNotice = nil
    }

    private func publishReducerState() {
        turns = reducer.turns
        pendingInteractions = reducer.pendingInteractions
        phase = reducer.phase
        isTruncated = reducer.isTruncated
        bridgeConnected = reducer.bridgeConnected
        revision &+= 1
    }
}
