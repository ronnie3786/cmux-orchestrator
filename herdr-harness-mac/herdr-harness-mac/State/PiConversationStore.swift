import Foundation
import Observation
import os

enum PiStreamTransport: Equatable, Sendable {
    case liveStream
    case polling
}

private let piStreamLog = OSLog(subsystem: "dev.ronnierocha.herdr-harness", category: "pi-stream")
private let piReloadLog = Logger(subsystem: "dev.ronnierocha.herdr-harness", category: "pi-stream")

@MainActor
@Observable
final class PiConversationStore {
    private(set) var turns: [PiConversationTurn] = []
    private(set) var pendingInteractions: [PiPendingInteraction] = []
    private(set) var phase: PiConversationPhase = .idle
    private(set) var compactionActivity: PiCompactionActivity?
    private(set) var connection: PiConversationConnection = .loading
    private(set) var revision = 0
    private(set) var structureRevision = 0
    private(set) var lastUserMessage: PiUserMessage?
    private(set) var userMessages: [PiUserMessage] = []
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
    @ObservationIgnored private var streamingBlockIDs: Set<String> = []
    @ObservationIgnored private var lastReloadCursor: String?
    @ObservationIgnored private var lastReloadAt: ContinuousClock.Instant?
    @ObservationIgnored private(set) var noProgressReloads = 0
    /// Internal test seams for deterministic snapshot and stream sequences.
    @ObservationIgnored var reloadBackoffBase: Duration = .milliseconds(250)
    @ObservationIgnored var reloadDecayWindow: Duration = .seconds(60)
    @ObservationIgnored var stuckCursorPollingHold: Duration = .seconds(60)
    @ObservationIgnored var overflowRetryDelay: Duration = .milliseconds(250)
    @ObservationIgnored var snapshotProvider: (@MainActor (HerdrPane) async throws -> PiConversationSnapshot)?
    @ObservationIgnored var eventsProvider: (@MainActor (HerdrPane, String?) async -> AsyncThrowingStream<PiConversationStreamEvent, any Error>?)?

    var hasContent: Bool {
        turns.contains(where: \.hasVisibleContent)
    }

    var isCompacting: Bool {
        compactionActivity != nil
    }

    var latestCompletedAssistantResponse: String? {
        turns.latestCompletedAssistantText
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
                let snapshot = try await fetchSnapshot(model: model, pane: pane)
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

                if try await consumeLiveStreamResumingAfterOverflow(model: model, pane: pane) {
                    let cursor = reducer.cursor
                    let now = ContinuousClock().now
                    if let lastReloadAt, lastReloadAt.duration(to: now) > reloadDecayWindow {
                        noProgressReloads = 0
                    }
                    if cursor == lastReloadCursor {
                        noProgressReloads += 1
                    } else {
                        noProgressReloads = 0
                    }
                    lastReloadCursor = cursor
                    lastReloadAt = now
                    let reloadNumber = noProgressReloads + 1
                    let reloadBackoff = min(
                        reloadBackoffBase * (1 << noProgressReloads),
                        .milliseconds(6_000)
                    )
                    piReloadLog.notice(
                        "pi needsSnapshot reload #\(reloadNumber) pane=\(pane.paneID, privacy: .public) cursor=\(cursor ?? "nil", privacy: .public) noProgress=\(self.noProgressReloads)"
                    )
                    try await Task.sleep(for: reloadBackoff)
                    if noProgressReloads >= 2 {
                        piReloadLog.error(
                            "pi needsSnapshot polling fallback pane=\(pane.paneID, privacy: .public) cursor=\(cursor ?? "nil", privacy: .public)"
                        )
                        if await followSnapshotPolling(
                            model: model,
                            pane: pane,
                            initialSnapshot: snapshot,
                            stuckCursor: cursor
                        ) {
                            retryAttempt = 0
                            retryDelay = 0.65
                            lastReloadCursor = nil
                            lastReloadAt = nil
                            noProgressReloads = 0
                            continue followLoop
                        }
                        return
                    }
                    retryAttempt = 0
                    retryDelay = 0.65
                    continue followLoop
                }
                throw APIError.streamEnded
            } catch is CancellationError {
                return
            } catch {
                guard !HerdrCancellation.isCancellation(error) else { return }
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
        guard !prompt.isEmpty, !isSubmitting, compactionActivity == nil else { return false }
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
            guard !HerdrCancellation.isCancellation(error) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func abort(model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard !isAborting, canSendCommands, compactionActivity == nil else { return false }
        isAborting = true
        commandNotice = nil
        defer { isAborting = false }
        do {
            try await model.abortPiConversation(for: pane)
            lastError = nil
            commandNotice = "Stop requested"
            return true
        } catch {
            guard !HerdrCancellation.isCancellation(error) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func setModel(_ candidate: PiAvailableModel, model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard canSendCommands, !isSettingModel, compactionActivity == nil else { return false }
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
            guard !HerdrCancellation.isCancellation(error) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func setThinkingLevel(_ level: PiThinkingLevel, model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard canSendCommands, !isSettingThinkingLevel, compactionActivity == nil else { return false }
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
            guard !HerdrCancellation.isCancellation(error) else { return false }
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
            guard !HerdrCancellation.isCancellation(error) else { return false }
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
        defer { HerdrPerfDiagnostics.streamBacklog.reset(.pi) }
        for try await streamEvent in events {
            try Task.checkCancellation()
            HerdrPerfDiagnostics.streamBacklog.noteConsumed(.pi)
            switch streamEvent {
            case .activity:
                // An SSE heartbeat proves only that the harness is alive.
                // It says nothing about the extension socket behind it.
                continue
            case let .envelope(envelope):
                HerdrPerfDiagnostics.checkpoint("pi.envelope")
                let previousPhase = reducer.phase
                let previousCompactionActivity = reducer.compactionActivity
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
                        previousCompactionActivity: previousCompactionActivity,
                        previousTurnCount: previousTurnCount,
                        previousPendingInteractions: previousPendingInteractions,
                        previousBridgeConnected: previousBridgeConnected
                    )
                )
                let newConnection: PiConversationConnection = reducer.bridgeConnected ? .connected : .bridgeOffline
                let newError = reducer.bridgeConnected ? nil : "Pi is offline. The saved transcript is still available."
                if connection != newConnection { connection = newConnection }
                if lastError != newError { lastError = newError }
                if effect == .needsSnapshot {
                    return true
                }
            }
        }
        return false
    }

    /// A bounded oldest-first stream buffer preserves a contiguous prefix when
    /// it overflows. The reducer cursor therefore identifies an exact replay
    /// boundary in the durable journal. Resume from that cursor instead of
    /// replacing the live transcript with an older active-turn checkpoint.
    private func consumeLiveStreamResumingAfterOverflow(
        model: HerdrAppModel,
        pane: HerdrPane
    ) async throws -> Bool {
        var isRetryingOverflow = false

        while !Task.isCancelled {
            if isRetryingOverflow {
                try await Task.sleep(for: overflowRetryDelay)
                await Task.yield()
            }

            transport = .liveStream
            guard let events = await fetchEvents(model: model, pane: pane, after: reducer.cursor) else {
                throw APIError.streamEnded
            }

            do {
                return try await consume(events)
            } catch APIError.streamBacklogOverflow {
                isRetryingOverflow = true
            }
        }

        throw CancellationError()
    }

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        for id in streamingBlockIDs {
            PiMarkdownDocumentCache.shared.evictStreaming(id: id)
            PiMarkdownInlineCache.shared.evictStreaming(id: id)
        }
        streamingBlockIDs = []
        coalescer = PiStreamCoalescer()
        reducer = PiConversationReducer()
        turns = []
        pendingInteractions = []
        phase = .idle
        compactionActivity = nil
        connection = .loading
        revision &+= 1
        structureRevision = 0
        lastUserMessage = nil
        userMessages = []
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
        lastReloadCursor = nil
        lastReloadAt = nil
        noProgressReloads = 0
    }

    /// Legacy bridges can provide a durable snapshot without a compatible
    /// live context/event stream. Keep that transcript usable with a gentle
    /// snapshot poll instead of retrying a long-lived SSE connection forever.
    private func followSnapshotPolling(
        model: HerdrAppModel,
        pane: HerdrPane,
        initialSnapshot: PiConversationSnapshot,
        stuckCursor: String? = nil
    ) async -> Bool {
        transport = .polling
        var previousSnapshot = initialSnapshot
        var retryDelay = 2.0
        let pollingStartedAt = ContinuousClock().now

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(previousSnapshot.connected ? 2 : 5))
                let snapshot = try await fetchSnapshot(model: model, pane: pane)
                try Task.checkCancellation()
                guard snapshot.protocolInfo.name == "herdr.pi.semantic",
                      snapshot.protocolInfo.version == 1,
                      snapshot.available
                else {
                    if connection != .unavailable { connection = .unavailable }
                    let message = "This Pi session does not expose a compatible native transcript."
                    if lastError != message { lastError = message }
                    return false
                }

                if snapshotContentChanged(from: previousSnapshot, to: snapshot) {
                    reducer.replace(with: snapshot)
                    schedulePublish(.streamReset)
                    guard !Task.isCancelled else { return false }
                    previousSnapshot = snapshot
                }
                let newConnection: PiConversationConnection = snapshot.connected ? .connected : .bridgeOffline
                let newError = snapshot.connected
                    ? nil
                    : "Pi is offline. The saved transcript is still available."
                if connection != newConnection { connection = newConnection }
                if lastError != newError { lastError = newError }
                retryDelay = 2

                let heldStuckCursorLongEnough = pollingStartedAt.duration(to: ContinuousClock().now) >= stuckCursorPollingHold
                if snapshot.reportsContextUsage && snapshot.connected && (
                    stuckCursor == nil || snapshot.cursor != stuckCursor || heldStuckCursorLongEnough
                ) {
                    return true
                }
            } catch is CancellationError {
                return false
            } catch {
                guard !HerdrCancellation.isCancellation(error) else { return false }
                retryDelay = min(retryDelay * 1.7, 8)
                let newConnection: PiConversationConnection = .reconnecting(attempt: 1)
                let newError = hasContent
                    ? "Live updates paused. Reconnecting…"
                    : error.localizedDescription
                if connection != newConnection { connection = newConnection }
                if lastError != newError { lastError = newError }
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
        previous.cursor != current.cursor
            || previous.latestCursor != current.latestCursor
            || previous.connected != current.connected
            || previous.available != current.available
            || previous.session != current.session
            || previous.state != current.state
            || previous.entries.count != current.entries.count
            || previous.pendingInteractions.count != current.pendingInteractions.count
            || previous.oldestCursor != current.oldestCursor
            || previous.truncated != current.truncated
    }

    private func fetchSnapshot(model: HerdrAppModel, pane: HerdrPane) async throws -> PiConversationSnapshot {
        if let snapshotProvider { return try await snapshotProvider(pane) }
        return try await model.fetchPiConversationSnapshot(for: pane)
    }

    private func fetchEvents(
        model: HerdrAppModel,
        pane: HerdrPane,
        after cursor: String?
    ) async -> AsyncThrowingStream<PiConversationStreamEvent, any Error>? {
        if let eventsProvider { return await eventsProvider(pane, cursor) }
        return await model.piConversationEvents(for: pane, after: cursor)
    }

    private func publishReducerState() {
        HerdrPerfDiagnostics.checkpoint("pi.publish")
        os_signpost(.event, log: piStreamLog, name: "publish")
        let previousStructureRevision = structureRevision
        reconcileStreamingCaches(with: reducer.turns)
        turns = reducer.turns
        pendingInteractions = reducer.pendingInteractions
        structureRevision = reducer.structureRevision
        if structureRevision != previousStructureRevision {
            lastUserMessage = PiLastPrompt.lastUserMessage(in: turns)
            let messages = turns.compactMap(\.user)
            if messages != userMessages { userMessages = messages }
        }
        phase = reducer.phase
        compactionActivity = reducer.compactionActivity
        isTruncated = reducer.isTruncated
        bridgeConnected = reducer.bridgeConnected
        contextUsage = reducer.contextUsage
        sessionCost = reducer.sessionCost
        currentModel = reducer.currentModel
        thinkingLevel = reducer.thinkingLevel
        revision &+= 1
    }

    private func reconcileStreamingCaches(with newTurns: [PiConversationTurn]) {
        var newlyStreamingIDs: Set<String> = []
        for turn in newTurns {
            for item in turn.items {
                switch item {
                case let .assistant(block):
                    if case .streaming = block.status { newlyStreamingIDs.insert(block.id) }
                case let .thinking(block):
                    if block.isStreaming { newlyStreamingIDs.insert(block.id) }
                case .tool, .notice:
                    break
                }
            }
        }
        for id in streamingBlockIDs where !newlyStreamingIDs.contains(id) {
            PiMarkdownDocumentCache.shared.evictStreaming(id: id)
            PiMarkdownInlineCache.shared.evictStreaming(id: id)
        }
        streamingBlockIDs = newlyStreamingIDs
    }

    private func trigger(
        for effect: PiConversationReducer.Effect,
        previousPhase: PiConversationPhase,
        previousCompactionActivity: PiCompactionActivity?,
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
        case .compactionChanged:
            .compactionChange
        case .failed:
            .phaseTransition
        case .none:
            if reducer.bridgeConnected != previousBridgeConnected {
                .connectionChange
            } else if reducer.phase != previousPhase {
                .phaseTransition
            } else if reducer.compactionActivity != previousCompactionActivity {
                .compactionChange
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
                // How late this task ran is a direct read of main-actor
                // congestion: the sleep ended on time, but the main thread was
                // still inside a layout pass. Widen the window accordingly.
                self.coalescer.noteFlushLateness(deadline.duration(to: clock.now))
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
            guard !HerdrCancellation.isCancellation(error) else { return }
            modelCatalogError = "Couldn't load models"
        }
    }
}
