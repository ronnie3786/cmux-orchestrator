import Foundation
import Observation

struct HerdrHudAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let byteCount: Int
    let isImage: Bool
}

struct HerdrHudStep: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let isFailure: Bool
    let isRunning: Bool
}

struct HerdrHudExchange: Identifiable, Equatable, Sendable {
    let id: String
    let machineID: String
    let prompt: String
    let sentPrompt: String
    var response: String?
    var error: String?
    var status: HeadlessAgentRunStatus
    var costUSD: Double?
    let createdAt: Date
    var promotedPaneID: String?
    let attachmentFilenames: [String]
    var attachments: [HeadlessAgentAttachment] = []
    var modelLabel: String = "default"
    var steps: [HerdrHudStep] = []
    var stepsTruncated = false
}

@MainActor
@Observable
final class HerdrHudSession {
    /// The live HUD thread. A follow-up continues it; Trash ends it.
    struct HerdrHudThread: Codable, Equatable, Sendable {
        var machineID: String
        var rootRunID: String
        var lastRunID: String
        var turnCount: Int
    }

    static let machineIDDefaultsKey = "herdr.hud.machineID"
    static let maxAttachments = 4
    static let maxCombinedAttachmentBytes: Int64 = 21 * 1024 * 1024

    private let controller = HeadlessAgentController()
    private let userDefaults: UserDefaults
    @ObservationIgnored private let agentSettings: AgentModelSettingsStore
    @ObservationIgnored private let promptSettings: HerdrPromptSettingsStore
    @ObservationIgnored private let persistence: HerdrHudPersistenceStore
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var hasStartedSessionActivity = false

    let responseAudioPlayer = ResponseAudioPlayer()
    private(set) var exchanges: [HerdrHudExchange] = []
    private(set) var exchangesRevision = 0
    private(set) var latestPromotableExchangeID: String?
    private(set) var thread: HerdrHudThread?
    var draft = ""
    var pendingAttachments: [HerdrHudAttachment] = []
    var selectedMachineID: String? {
        didSet { userDefaults.set(selectedMachineID, forKey: Self.machineIDDefaultsKey) }
    }
    /// The HUD chip and Settings edit the same preference; @Observable
    /// propagation through the store keeps both surfaces honest.
    var selectedModel: String? {
        get { agentSettings.hudModel.isEmpty ? nil : agentSettings.hudModel }
        set { agentSettings.hudModel = newValue ?? "" }
    }
    var isCollapsed = true {
        didSet {
            if isCollapsed {
                responseAudioPlayer.stop()
            }
        }
    }
    private(set) var hasUnseenAnswer = false
    /// Bumped once per submission that clears validation and actually starts.
    private(set) var runStartedRevision = 0
    private(set) var elapsedSeconds = 0
    private(set) var liveStepCount = 0
    private(set) var validationError: String?
    private(set) var promoteErrorMessage: String?
    private(set) var audioErrorMessage: String?
    /// The session chip whose last answer is being spoken, and the transcript
    /// it is reading. Cached so pause/resume does not refetch.
    private(set) var sessionAudioPaneID: String?
    private(set) var loadingSessionAudioPaneID: String?
    @ObservationIgnored private var sessionAudioText: String?
    /// Which exchange the transcript-row player is speaking, so a completed
    /// playback resolves back to *that* exchange rather than whichever one
    /// happened to be promoted last.
    @ObservationIgnored private var speakingExchangeID: String?
    private(set) var voiceReplyTarget: String?
    /// The activity stamp of the answer that was read aloud. The reply offer
    /// belongs to *that* answer, so when the pane moves on the offer is stale —
    /// keying it on status alone would not notice, because a pane is `.done`
    /// both before and after it produces a new response.
    private(set) var voiceReplyTargetActivityAt: Date?
    @ObservationIgnored private var sessionAudioActivityAt: Date?
    private(set) var promotingExchangeIDs: Set<String> = []
    private(set) var availableModels: [PiAvailableModel] = []
    private(set) var defaultModel: PiModelIdentity?
    private(set) var isLoadingModels = false
    private(set) var modelsError: String?
    private(set) var didLoadCatalog = false

    #if DEBUG
    private(set) var lastHeadlessRunForTesting: HeadlessAgentRun?
    #endif

    var isRunning: Bool { controller.isRunning }
    var errorMessage: String? { controller.errorMessage }

    init(
        userDefaults: UserDefaults = .standard,
        agentSettings: AgentModelSettingsStore? = nil,
        persistenceURL: URL? = nil,
        promptSettings: HerdrPromptSettingsStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.agentSettings = agentSettings ?? AgentModelSettingsStore(defaults: userDefaults)
        self.promptSettings = promptSettings ?? HerdrPromptSettingsStore(defaults: userDefaults)
        self.persistence = HerdrHudPersistenceStore(
            fileURL: persistenceURL ?? HerdrHudPersistenceStore.defaultFileURL()
        )
        self.selectedMachineID = userDefaults.string(forKey: Self.machineIDDefaultsKey)
        responseAudioPlayer.onPlaybackCompleted = { [weak self] in
            self?.captureVoiceReplyTarget()
        }
        let persistence = self.persistence
        restoreTask = Task { [weak self, persistence] in
            guard let snapshot = await persistence.load(), !Task.isCancelled else { return }
            self?.restore(snapshot)
        }
    }

    deinit {
        elapsedTask?.cancel()
        restoreTask?.cancel()
    }

    func markSeen() {
        hasUnseenAnswer = false
    }

    func addAttachments(_ urls: [URL]) {
        for url in urls {
            guard pendingAttachments.count < Self.maxAttachments else {
                validationError = "You can attach up to 4 files."
                return
            }

            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let fileSize = values.fileSize else {
                    validationError = "\(url.lastPathComponent) is not a readable file."
                    continue
                }
                guard HerdrAttachmentTypes.isAllowed(url) else {
                    validationError = "\(url.lastPathComponent) isn't a supported file type."
                    continue
                }
                guard fileSize > 0 else {
                    validationError = "\(url.lastPathComponent) is empty."
                    continue
                }
                guard Int64(fileSize) <= AttachmentPolicy.maximumFileBytes else {
                    validationError = "\(url.lastPathComponent) is larger than 20 MB."
                    continue
                }
                let currentTotal = pendingAttachments.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
                guard currentTotal + Int64(fileSize) <= Self.maxCombinedAttachmentBytes else {
                    validationError = "Attachments can total up to 21 MB per message."
                    continue
                }
                pendingAttachments.append(
                    HerdrHudAttachment(
                        id: UUID(),
                        url: url,
                        filename: url.lastPathComponent,
                        byteCount: fileSize,
                        isImage: HerdrAttachmentTypes.isImage(url)
                    )
                )
            } catch {
                validationError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func reportAttachmentError(_ message: String) {
        validationError = message
    }

    #if DEBUG
    func seedExchangesForTesting(_ exchanges: [HerdrHudExchange]) {
        self.exchanges = exchanges
        markExchangesChanged()
    }

    func appendExchangeForTesting(_ exchange: HerdrHudExchange) {
        append(exchange)
    }

    func seedThreadForTesting(_ thread: HerdrHudThread?) {
        self.thread = thread
    }

    func waitForPersistenceRestoreForTesting() async {
        await restoreTask?.value
    }

    func seedModelsForTesting(_ models: [PiAvailableModel], default defaultModel: PiModelIdentity?) {
        availableModels = models
        self.defaultModel = defaultModel
    }
    #endif

    func submit(model: HerdrAppModel) async {
        beginSessionActivity()
        validationError = nil
        promoteErrorMessage = nil
        audioErrorMessage = nil

        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !controller.isRunning else { return }
        guard let machineID = resolvedMachineID(in: model) else {
            validationError = "No machine is available for the HUD."
            return
        }
        guard model.canControl(machineID: machineID) else {
            validationError = "This machine is not connected."
            return
        }

        let attachmentsToSend = pendingAttachments
        guard attachmentsToSend.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= Self.maxCombinedAttachmentBytes else {
            validationError = "Attachments can total up to 21 MB per message."
            return
        }

        let attachmentFilenames = attachmentsToSend.map(\.filename)
        let hasAttachments = !attachmentsToSend.isEmpty
        let hasImageAttachments = attachmentsToSend.contains(where: \.isImage)
        let resolution = AgentModelResolver.resolve(
            preference: selectedModel,
            catalog: availableModels,
            isCatalogAuthoritative: didLoadCatalog
        )
        let agentModel = HerdrHudModelRouting.model(
            selection: resolution.modelID,
            selectionSupportsImages: selectedModelSupportsImages,
            hasImageAttachments: hasImageAttachments,
            visionModel: agentSettings.effectiveVisionModel
        )
        let thinkingLevel = agentSettings.hudThinkingLevel.rawValue
        if resolution.preferenceIsUnavailable {
            validationError = "\(selectedModel ?? "") isn't offered by this machine — using its default model."
        }
        let label = modelLabel(for: agentModel)
        let pendingID = "hud-pending-\(UUID().uuidString)"
        let submittedAt = Date.now
        let continueFromRunId = thread?.machineID == machineID ? thread?.lastRunID : nil
        append(
            HerdrHudExchange(
                id: pendingID,
                machineID: machineID,
                prompt: prompt,
                sentPrompt: prompt,
                response: nil,
                error: nil,
                status: .running,
                costUSD: nil,
                createdAt: submittedAt,
                promotedPaneID: nil,
                attachmentFilenames: attachmentFilenames,
                modelLabel: label
            )
        )
        draft = ""
        pendingAttachments = []
        // Past every validation guard, so a run is genuinely in flight. The
        // composer waits for this before auto-collapsing the HUD — collapsing
        // on a validation failure would hide the error it needs to show.
        runStartedRevision &+= 1

        let wireAttachments: [HeadlessAgentAttachment]
        do {
            wireAttachments = attachmentsToSend.isEmpty ? [] : try await Task.detached(priority: .userInitiated) {
                try attachmentsToSend.map { attachment in
                    let accessed = attachment.url.startAccessingSecurityScopedResource()
                    defer { if accessed { attachment.url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: attachment.url)
                    return HeadlessAgentAttachment(
                        filename: attachment.filename,
                        dataBase64: data.base64EncodedString()
                    )
                }
            }.value
        } catch {
            guard let index = exchanges.firstIndex(where: { $0.id == pendingID }) else {
                controller.reset()
                return
            }
            exchanges[index].status = .failed
            exchanges[index].error = "Couldn't read \(attachmentsToSend.first?.filename ?? "attachment"): \(error.localizedDescription)"
            markExchangesChanged()
            if draft.isEmpty { draft = prompt }
            if pendingAttachments.isEmpty { pendingAttachments = attachmentsToSend }
            controller.reset()
            await schedulePersistenceSave()
            return
        }

        let run = await submitAndWait(
            prompt: prompt,
            machineID: machineID,
            agentModel: agentModel,
            thinkingLevel: thinkingLevel,
            attachments: hasAttachments ? wireAttachments : nil,
            continueFromRunId: continueFromRunId,
            model: model
        )
        guard let index = exchanges.firstIndex(where: { $0.id == pendingID }) else {
            controller.reset()
            return
        }
        guard let run else {
            exchanges[index] = HerdrHudExchange(
                id: pendingID,
                machineID: machineID,
                prompt: prompt,
                sentPrompt: prompt,
                response: nil,
                error: controller.errorMessage ?? "The run failed to start.",
                status: .failed,
                costUSD: nil,
                createdAt: submittedAt,
                promotedPaneID: nil,
                attachmentFilenames: attachmentFilenames,
                attachments: wireAttachments,
                modelLabel: label
            )
            markExchangesChanged()
            if draft.isEmpty { draft = prompt }
            if pendingAttachments.isEmpty { pendingAttachments = attachmentsToSend }
            controller.reset()
            await schedulePersistenceSave()
            return
        }

        #if DEBUG
        lastHeadlessRunForTesting = run
        #endif

        let isSuccess = run.status == .completed || run.status == .promoted
        let retainedAttachments = isSuccess ? [] : wireAttachments
        exchanges[index] = HerdrHudExchange(
            id: run.id,
            machineID: machineID,
            prompt: prompt,
            sentPrompt: prompt,
            response: run.response,
            error: run.error,
            status: run.status,
            costUSD: run.costUSD,
            createdAt: submittedAt,
            promotedPaneID: run.promotedPaneID,
            attachmentFilenames: attachmentFilenames,
            attachments: retainedAttachments,
            modelLabel: label,
            steps: Self.hudSteps(from: run.steps ?? []),
            stepsTruncated: run.stepsTruncated == true
        )
        markExchangesChanged()
        if run.status == .completed {
            let rootRunID = run.threadRootRunId ?? run.id
            let turnCount: Int
            if let thread,
               thread.machineID == machineID,
               thread.rootRunID == rootRunID {
                turnCount = thread.turnCount + 1
            } else {
                turnCount = 1
            }
            thread = HerdrHudThread(
                machineID: machineID,
                rootRunID: rootRunID,
                lastRunID: run.id,
                turnCount: turnCount
            )
        }
        if run.status.isTerminal, isCollapsed {
            hasUnseenAnswer = true
        }
        controller.reset()
        await schedulePersistenceSave()
    }

    func stop(model: HerdrAppModel) async {
        await controller.cancel(model: model)
    }

    func loadAudioCapabilities(model: HerdrAppModel) async {
        audioErrorMessage = nil
        guard let machineID = resolvedMachineIDReadOnly(in: model) else { return }
        await responseAudioPlayer.loadCapabilities {
            try await model.fetchResponseAudioCapabilities(forMachine: machineID)
        }
    }

    func loadModels(model: HerdrAppModel) async {
        modelsError = nil
        guard let machineID = resolvedMachineIDReadOnly(in: model) else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let response = try await model.fetchAgentModels(machineID: machineID)
            availableModels = response.models
            defaultModel = response.defaultModel
            didLoadCatalog = true
        } catch {
            modelsError = error.localizedDescription
        }
    }

    func setSelectedModel(_ candidate: PiAvailableModel?) {
        selectedModel = candidate?.id
    }

    func isSpeakingSession(_ paneID: String) -> Bool {
        sessionAudioPaneID == paneID && responseAudioPlayer.phase.activeAction != nil
    }

    func isPreparingSessionAudio(_ paneID: String) -> Bool {
        guard sessionAudioPaneID == paneID else { return false }
        if loadingSessionAudioPaneID == paneID { return true }
        return responseAudioPlayer.phase == .preparing(.tldr)
    }

    /// Speak a finished session's last answer from its HUD chip.
    ///
    /// The chip has no conversation store behind it — that only exists while a
    /// pane's session view is on screen — so the transcript is fetched on
    /// demand and cached for the length of this playback. Playback itself is
    /// the same `.tldr` path the chat composer uses, so a second press
    /// pauses/resumes exactly like the in-chat control.
    func toggleSessionAudio(paneID: String, model: HerdrAppModel) async {
        audioErrorMessage = nil
        guard let pane = model.pane(id: paneID) else { return }

        if sessionAudioPaneID == paneID,
           let text = sessionAudioText,
           responseAudioPlayer.phase.activeAction != nil {
            activateSessionAudio(text: text, pane: pane, model: model)
            return
        }

        responseAudioPlayer.stop()
        sessionAudioPaneID = paneID
        sessionAudioText = nil
        sessionAudioActivityAt = pane.lastActivityAt
        speakingExchangeID = nil
        loadingSessionAudioPaneID = paneID
        defer {
            if loadingSessionAudioPaneID == paneID { loadingSessionAudioPaneID = nil }
        }

        if !responseAudioPlayer.capabilities.available {
            await responseAudioPlayer.loadCapabilities {
                try await model.fetchResponseAudioCapabilities(for: pane)
            }
        }
        guard responseAudioPlayer.capabilities.supports(.tldr) else {
            audioErrorMessage = "This machine can't read responses aloud."
            sessionAudioPaneID = nil
            return
        }

        do {
            guard let text = try await model.latestCompletedAssistantResponse(for: pane) else {
                audioErrorMessage = "\(pane.displayTitle) hasn't answered yet."
                sessionAudioPaneID = nil
                return
            }
            guard sessionAudioPaneID == paneID else { return }
            sessionAudioText = text
            activateSessionAudio(text: text, pane: pane, model: model)
        } catch {
            audioErrorMessage = error.localizedDescription
            sessionAudioPaneID = nil
        }
    }

    private func activateSessionAudio(text: String, pane: HerdrPane, model: HerdrAppModel) {
        responseAudioPlayer.activate(
            .tldr,
            text: text,
            prepare: { action, text in
                try await model.prepareResponseAudio(action: action, text: text, for: pane)
            },
            synthesize: { text in
                try await model.synthesizeResponseAudio(text: text, for: pane)
            },
            failure: { [weak self] message in
                self?.audioErrorMessage = message
                self?.sessionAudioPaneID = nil
            }
        )
    }

    func activateResponseAudio(
        _ action: ResponseAudioAction,
        text: String,
        exchangeID: String? = nil,
        model: HerdrAppModel
    ) {
        sessionAudioPaneID = nil
        sessionAudioText = nil
        speakingExchangeID = exchangeID
        audioErrorMessage = nil
        guard let machineID = resolvedMachineIDReadOnly(in: model) else { return }
        responseAudioPlayer.activate(
            action,
            text: text,
            prepare: { action, text in
                try await model.prepareResponseAudio(action: action, text: text, forMachine: machineID)
            },
            synthesize: { text in
                try await model.synthesizeResponseAudio(text: text, forMachine: machineID)
            },
            failure: { [weak self] message in
                self?.audioErrorMessage = message
            }
        )
    }

    /// Runs when playback reaches its natural end. The target is captured here
    /// rather than read later because collapsing the HUD, switching machines and
    /// appending a run all call `stop()`, which tears the audio state down.
    private func captureVoiceReplyTarget() {
        if let sessionAudioPaneID {
            voiceReplyTarget = sessionAudioPaneID
            voiceReplyTargetActivityAt = sessionAudioActivityAt
            return
        }
        // A headless HUD exchange only has a pi session once it was promoted.
        // `promotedPaneID` is a raw id while panes are addressed machine-scoped.
        if let speakingExchangeID,
           let exchange = exchanges.first(where: { $0.id == speakingExchangeID }),
           let promotedPaneID = exchange.promotedPaneID {
            voiceReplyTarget = MachineScopedID.compose(
                machineID: exchange.machineID,
                rawID: promotedPaneID
            )
            return
        }
        voiceReplyTarget = nil
        voiceReplyTargetActivityAt = nil
    }

    func clearVoiceReplyTarget() {
        voiceReplyTarget = nil
        voiceReplyTargetActivityAt = nil
    }

    /// Retires a reply offer whose answer has been superseded, so the chip goes
    /// back to offering the speaker for the newer response.
    ///
    /// Skipped while a reply is actually being spoken or edited: the pane can
    /// tick its activity underneath the user, and pulling the composer out from
    /// under them mid-sentence would be worse than a stale offer.
    func expireVoiceReplyTargetIfStale(pane: HerdrPane?, isReplyInFlight: Bool) {
        guard !isReplyInFlight, voiceReplyTarget != nil else { return }
        guard let pane, pane.id == voiceReplyTarget else {
            clearVoiceReplyTarget()
            return
        }
        guard pane.lastActivityAt == voiceReplyTargetActivityAt else {
            clearVoiceReplyTarget()
            return
        }
    }

    #if DEBUG
    func setVoiceReplyTargetForTesting(_ paneID: String?, activityAt: Date? = nil) {
        voiceReplyTarget = paneID
        voiceReplyTargetActivityAt = activityAt
    }
    #endif

    func promote(exchange: HerdrHudExchange, model: HerdrAppModel) async -> HerdrPane? {
        beginSessionActivity()
        promoteErrorMessage = nil
        promotingExchangeIDs.insert(exchange.id)
        defer { promotingExchangeIDs.remove(exchange.id) }
        do {
            let result = try await model.promoteHeadlessAgent(
                runID: exchange.id,
                machineID: exchange.machineID,
                workspaceID: nil
            )
            if let index = exchanges.firstIndex(where: { $0.id == exchange.id }) {
                exchanges[index].promotedPaneID = result.pane.paneID
                exchanges[index].status = result.run.status
                markExchangesChanged()
            }
            thread = nil
            await schedulePersistenceSave()
            return result.pane
        } catch {
            promoteErrorMessage = error.localizedDescription
            return nil
        }
    }

    func retry(_ exchange: HerdrHudExchange, model: HerdrAppModel) async {
        beginSessionActivity()
        // Retry stays a fresh single-turn run: re-appending it would double a turn in the
        // session file, and doing it properly needs a harness-side fork.
        guard !controller.isRunning else { return }
        validationError = nil
        promoteErrorMessage = nil
        audioErrorMessage = nil
        let hasAttachments = !exchange.attachments.isEmpty
        let hasImageAttachments = exchange.attachments.contains {
            HerdrAttachmentTypes.isImage(URL(fileURLWithPath: $0.filename))
        }
        let resolution = AgentModelResolver.resolve(
            preference: selectedModel,
            catalog: availableModels,
            isCatalogAuthoritative: didLoadCatalog
        )
        let agentModel = HerdrHudModelRouting.model(
            selection: resolution.modelID,
            selectionSupportsImages: selectedModelSupportsImages,
            hasImageAttachments: hasImageAttachments,
            visionModel: agentSettings.effectiveVisionModel
        )
        let thinkingLevel = agentSettings.hudThinkingLevel.rawValue
        if resolution.preferenceIsUnavailable {
            validationError = "\(selectedModel ?? "") isn't offered by this machine — using its default model."
        }
        let label = modelLabel(for: agentModel)
        guard let run = await submitAndWait(
            prompt: exchange.sentPrompt,
            machineID: exchange.machineID,
            agentModel: agentModel,
            thinkingLevel: thinkingLevel,
            attachments: hasAttachments ? exchange.attachments : nil,
            model: model
        ) else {
            validationError = controller.errorMessage
            controller.reset()
            return
        }
        #if DEBUG
        lastHeadlessRunForTesting = run
        #endif
        let isSuccess = run.status == .completed || run.status == .promoted
        let retainedAttachments = isSuccess ? [] : exchange.attachments
        append(
            HerdrHudExchange(
                id: run.id,
                machineID: exchange.machineID,
                prompt: exchange.prompt,
                sentPrompt: exchange.sentPrompt,
                response: run.response,
                error: run.error,
                status: run.status,
                costUSD: run.costUSD,
                createdAt: .now,
                promotedPaneID: run.promotedPaneID,
                attachmentFilenames: exchange.attachmentFilenames,
                attachments: retainedAttachments,
                modelLabel: label,
                steps: Self.hudSteps(from: run.steps ?? []),
                stepsTruncated: run.stepsTruncated == true
            )
        )
        if run.status.isTerminal, isCollapsed {
            hasUnseenAnswer = true
        }
        controller.reset()
        await schedulePersistenceSave()
    }

    func clear(model: HerdrAppModel) async {
        beginSessionActivity()
        if let thread {
            try? await model.deleteHeadlessAgent(runID: thread.rootRunID, machineID: thread.machineID)
        }
        for exchange in exchanges where exchange.promotedPaneID == nil && exchange.status.isTerminal {
            guard exchange.id != thread?.rootRunID else { continue }
            try? await model.deleteHeadlessAgent(runID: exchange.id, machineID: exchange.machineID)
        }
        exchanges = []
        markExchangesChanged()
        thread = nil
        await persistence.remove()
    }

    private func resolvedMachineID(in model: HerdrAppModel) -> String? {
        if let selectedMachineID,
           model.machines.contains(where: { $0.id == selectedMachineID }) {
            return selectedMachineID
        }
        let fallback = model.machines.first?.id
        selectedMachineID = fallback
        return fallback
    }

    private func resolvedMachineIDReadOnly(in model: HerdrAppModel) -> String? {
        if let selectedMachineID,
           model.machines.contains(where: { $0.id == selectedMachineID }) {
            return selectedMachineID
        }
        return model.machines.first?.id
    }

    private var selectedModelSupportsImages: Bool {
        guard let selectedModel else { return false }
        return availableModels.first(where: { $0.id == selectedModel })?.supportsImages ?? false
    }

    private func modelLabel(for requestedModel: String?) -> String {
        guard let requestedModel else { return defaultModel?.displayName ?? "default" }
        return availableModels.first(where: { $0.id == requestedModel })?.displayName ?? requestedModel
    }

    private func append(_ exchange: HerdrHudExchange) {
        exchanges.append(exchange)
        trimExceedingCap()
        markExchangesChanged()
    }

    private func trimExceedingCap() {
        guard exchanges.count > 20 else { return }
        var overflow = exchanges.count - 20
        var index = 0
        while overflow > 0, index < exchanges.count {
            if !exchanges[index].status.isTerminal {
                index += 1
                continue
            }
            exchanges.remove(at: index)
            overflow -= 1
        }
    }

    private func markExchangesChanged() {
        let latestPromotableExchangeID = exchanges.last(where: { $0.status == .completed })?.id
        if latestPromotableExchangeID != self.latestPromotableExchangeID {
            self.latestPromotableExchangeID = latestPromotableExchangeID
        }
        exchangesRevision += 1
    }

    private func restore(_ snapshot: HerdrHudPersistenceSnapshot) {
        guard !hasStartedSessionActivity, exchanges.isEmpty, thread == nil else { return }
        let restored = snapshot.restoredValues()
        exchanges = restored.exchanges
        thread = restored.thread
        markExchangesChanged()
    }

    /// Startup restoration is allowed only until the user initiates real HUD work.
    private func beginSessionActivity() {
        hasStartedSessionActivity = true
        restoreTask?.cancel()
    }

    private func schedulePersistenceSave() async {
        let snapshot = HerdrHudPersistenceSnapshot(thread: thread, exchanges: exchanges)
        await persistence.scheduleSave(snapshot)
    }

    private func submitAndWait(
        prompt: String,
        machineID: String,
        agentModel: String?,
        thinkingLevel: String?,
        attachments: [HeadlessAgentAttachment]?,
        continueFromRunId: String? = nil,
        model: HerdrAppModel
    ) async -> HeadlessAgentRun? {
        elapsedSeconds = 0
        liveStepCount = 0
        var systemPrompt: String?
        if let override = promptSettings.override(for: .hudActCharter) {
            if await model.supportsPromptOverrides(machineID: machineID) {
                systemPrompt = override
            } else if validationError == nil {
                validationError = "Custom instructions skipped — this machine's harness doesn't support them yet."
            }
        }
        await controller.submit(
            prompt: prompt,
            machineID: machineID,
            mode: .act,
            agentModel: agentModel,
            thinkingLevel: thinkingLevel,
            attachments: attachments,
            continueFromRunId: continueFromRunId,
            systemPrompt: systemPrompt,
            model: model
        )
        beginElapsedTimer()
        defer { endElapsedTimer() }
        while controller.isRunning {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return nil
            }
            let count = controller.run?.steps?.count ?? 0
            if count != liveStepCount {
                liveStepCount = count
            }
        }
        return controller.run
    }

    private func beginElapsedTimer() {
        elapsedTask?.cancel()
        guard controller.isRunning else { return }
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.controller.isRunning {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.controller.isRunning else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    private func endElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
        elapsedSeconds = 0
        liveStepCount = 0
    }

    static func hudSteps(from steps: [HeadlessAgentStep]) -> [HerdrHudStep] {
        steps.enumerated().map { index, step in
            let toolName = step.toolName.flatMap { $0.isEmpty ? nil : $0 } ?? "Tool"
            let presentation = PiToolPresentation.details(forToolName: toolName)
            let identifier = step.toolCallId.flatMap { $0.isEmpty ? nil : $0 } ?? "hud-step-\(index)"
            return HerdrHudStep(
                id: identifier,
                title: presentation.title,
                detail: Self.hudStepDetail(for: step, isCommand: presentation.title == "Command"),
                symbol: presentation.symbol,
                isFailure: step.isError == true,
                isRunning: step.finishedAt == nil
            )
        }
    }

    private static func hudStepDetail(
        for step: HeadlessAgentStep,
        isCommand: Bool
    ) -> String {
        let preview: String?
        if isCommand {
            preview = commandPreview(from: step.argsPreview) ?? step.argsPreview ?? step.resultPreview
        } else {
            preview = step.argsPreview ?? step.resultPreview
        }
        return singleLinePreview(preview ?? "")
    }

    private static func commandPreview(from preview: String?) -> String? {
        guard let preview,
              let data = preview.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return ["command", "cmd", "script"].lazy.compactMap { object[$0] as? String }.first
    }

    private static func singleLinePreview(_ preview: String) -> String {
        let singleLine = preview.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let limit = 120
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}
