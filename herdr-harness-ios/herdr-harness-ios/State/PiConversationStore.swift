import Foundation
import Observation
import os

enum PiStreamTransport: Equatable, Sendable {
    case liveStream
    case polling
}

private let piStreamLog = OSLog(subsystem: "dev.ronnierocha.herdr-harness", category: "pi-stream")

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
    private(set) var sessionCost: PiSessionCost?
    private(set) var currentModel: PiModelIdentity?
    private(set) var availableModels: [PiAvailableModel] = []
    private(set) var isLoadingModels = false
    private(set) var isSettingModel = false
    private(set) var thinkingLevel: String?
    private(set) var isSettingThinkingLevel = false
    private(set) var modelCatalogError: String?
    private(set) var isModelSwitchingUnsupported = false
    private(set) var isSubmitting = false
    private(set) var isAborting = false
    private(set) var lastError: String?
    private(set) var commandNotice: String?
    private(set) var transport: PiStreamTransport = .liveStream

    @ObservationIgnored private var reducer = PiConversationReducer()
    @ObservationIgnored private var coalescer = PiStreamCoalescer()
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    var hasContent: Bool {
        turns.contains(where: \.hasVisibleContent)
    }

    var latestCompletedAssistantResponse: String? {
        for turn in turns.reversed() {
            for item in turn.items.reversed() {
                guard case let .assistant(block) = item,
                      block.status == .complete
                else { continue }
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
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
                schedulePublish(.streamReset)
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

                if pane.piSemantic?.capabilities.listModels == true, availableModels.isEmpty {
                    Task { await loadModels(model: model, pane: pane) }
                }

                transport = .liveStream
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

    func setModel(_ candidate: PiAvailableModel, model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard canSendCommands, !isSettingModel else { return false }
        isSettingModel = true
        commandNotice = nil
        defer { isSettingModel = false }
        do {
            try await model.setPiModel(provider: candidate.provider, modelID: candidate.modelID, for: pane)
            lastError = nil
            commandNotice = "Model set to \(candidate.displayName)"
            return true
        } catch let APIError.server(status, _) where status == 501 {
            lastError = "Model switching isn't supported by this Pi session"
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setThinkingLevel(_ level: PiThinkingLevel, model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard canSendCommands, !isSettingThinkingLevel else { return false }
        isSettingThinkingLevel = true
        commandNotice = nil
        defer { isSettingThinkingLevel = false }
        do {
            let effective = try await model.setPiThinkingLevel(level: level.rawValue, for: pane)
            lastError = nil
            let effectiveDisplay = effective.flatMap { PiThinkingLevel(rawValue: $0)?.displayName ?? $0 }
                ?? level.displayName
            commandNotice = "Thinking set to \(effectiveDisplay)"
            return true
        } catch let APIError.server(status, _) where status == 501 {
            lastError = "Thinking control isn't supported by this Pi session"
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func retryLoadModels(model: HerdrAppModel, pane: HerdrPane) async {
        modelCatalogError = nil
        isModelSwitchingUnsupported = false
        await loadModels(model: model, pane: pane)
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
            schedulePublish(.pendingInteraction)
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
                let previousPhase = reducer.phase
                let previousTurnCount = reducer.turns.count
                let previousPendingInteractions = reducer.pendingInteractions
                let previousBridgeConnected = reducer.bridgeConnected
                os_signpost(.begin, log: piStreamLog, name: "reducer.apply")
                let effect = reducer.apply(envelope)
                os_signpost(.end, log: piStreamLog, name: "reducer.apply")
                schedulePublish(
                    trigger(
                        for: effect,
                        previousPhase: previousPhase,
                        previousTurnCount: previousTurnCount,
                        previousPendingInteractions: previousPendingInteractions,
                        previousBridgeConnected: previousBridgeConnected
                    )
                )
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
        flushTask?.cancel()
        flushTask = nil
        coalescer = PiStreamCoalescer()
        reducer = PiConversationReducer()
        turns = []
        pendingInteractions = []
        phase = .idle
        connection = .loading
        revision &+= 1
        isTruncated = false
        bridgeConnected = false
        contextUsage = nil
        sessionCost = nil
        currentModel = nil
        availableModels = []
        isLoadingModels = false
        isSettingModel = false
        thinkingLevel = nil
        isSettingThinkingLevel = false
        modelCatalogError = nil
        isModelSwitchingUnsupported = false
        isSubmitting = false
        isAborting = false
        lastError = nil
        commandNotice = nil
        transport = .liveStream
    }

    /// Legacy bridges can provide a durable snapshot without a compatible
    /// live context/event stream. Keep that transcript usable with a gentle
    /// snapshot poll instead of retrying a long-lived SSE connection forever.
    private func followSnapshotPolling(
        model: HerdrAppModel,
        pane: HerdrPane,
        initialSnapshot: PiConversationSnapshot
    ) async -> Bool {
        transport = .polling
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
                    schedulePublish(.streamReset)
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
        os_signpost(.event, log: piStreamLog, name: "publish")
        turns = reducer.turns
        pendingInteractions = reducer.pendingInteractions
        phase = reducer.phase
        isTruncated = reducer.isTruncated
        bridgeConnected = reducer.bridgeConnected
        contextUsage = reducer.contextUsage
        sessionCost = reducer.sessionCost
        currentModel = reducer.currentModel
        thinkingLevel = reducer.thinkingLevel
        revision &+= 1
    }

    private func trigger(
        for effect: PiConversationReducer.Effect,
        previousPhase: PiConversationPhase,
        previousTurnCount: Int,
        previousPendingInteractions: [PiPendingInteraction],
        previousBridgeConnected: Bool
    ) -> PiStreamCoalescer.Trigger {
        switch effect {
        case .needsSnapshot:
            .streamReset
        case .completed:
            .turnCompletion
        case .interactionRequested:
            .pendingInteraction
        case .failed:
            .phaseTransition
        case .none:
            if reducer.bridgeConnected != previousBridgeConnected {
                .connectionChange
            } else if reducer.phase != previousPhase {
                .phaseTransition
            } else if reducer.pendingInteractions != previousPendingInteractions {
                .pendingInteraction
            } else if reducer.turns.count > previousTurnCount {
                .turnBoundary
            } else {
                .delta
            }
        }
    }

    private func schedulePublish(_ trigger: PiStreamCoalescer.Trigger) {
        let clock = ContinuousClock()
        switch coalescer.register(trigger, now: clock.now) {
        case .flushNow:
            flushTask?.cancel()
            flushTask = nil
            publishReducerState()
            coalescer.markFlushed()
        case let .coalesce(deadline):
            guard flushTask == nil else { return }
            flushTask = Task { [weak self] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.publishReducerState()
                self.coalescer.markFlushed()
                self.flushTask = nil
            }
        }
    }

    private func loadModels(model: HerdrAppModel, pane: HerdrPane) async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let response = try await model.fetchPiModels(for: pane)
            availableModels = response.models
            if currentModel == nil { currentModel = response.current }
            modelCatalogError = nil
        } catch let APIError.server(status, _) where status == 501 {
            isModelSwitchingUnsupported = true
        } catch {
            modelCatalogError = "Couldn't load models"
        }
    }
}
