import Foundation
import Observation

struct HerdrHudImageAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let byteCount: Int
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
}

@MainActor
@Observable
final class HerdrHudSession {
    private enum DefaultsKey {
        static let machineID = "herdr.hud.machineID"
    }

    static let maxImageAttachments = 4
    static let maxCombinedImageBytes: Int64 = 21 * 1024 * 1024
    static let allowedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    private let controller = HeadlessAgentController()
    private let userDefaults: UserDefaults
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?

    let responseAudioPlayer = ResponseAudioPlayer()
    private(set) var exchanges: [HerdrHudExchange] = []
    var draft = ""
    var imageAttachments: [HerdrHudImageAttachment] = []
    var selectedMachineID: String? {
        didSet { userDefaults.set(selectedMachineID, forKey: DefaultsKey.machineID) }
    }
    var isCollapsed = true {
        didSet {
            if isCollapsed {
                responseAudioPlayer.stop()
            }
        }
    }
    private(set) var hasUnseenAnswer = false
    private(set) var elapsedSeconds = 0
    private(set) var validationError: String?
    private(set) var promoteErrorMessage: String?
    private(set) var audioErrorMessage: String?
    private(set) var promotingExchangeIDs: Set<String> = []

    var isRunning: Bool { controller.isRunning }
    var errorMessage: String? { controller.errorMessage }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.selectedMachineID = userDefaults.string(forKey: DefaultsKey.machineID)
    }

    deinit {
        elapsedTask?.cancel()
    }

    func markSeen() {
        hasUnseenAnswer = false
    }

    func addImageAttachments(_ urls: [URL]) {
        for url in urls {
            guard imageAttachments.count < Self.maxImageAttachments else {
                validationError = "You can attach up to 4 images."
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
                guard Self.allowedImageExtensions.contains(url.pathExtension.lowercased()) else {
                    validationError = "\(url.lastPathComponent) isn't a supported image type. Use PNG, JPEG, GIF, WebP, or HEIC."
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
                let currentTotal = imageAttachments.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
                guard currentTotal + Int64(fileSize) <= Self.maxCombinedImageBytes else {
                    validationError = "Attachments can total up to 21 MB per message."
                    continue
                }
                imageAttachments.append(
                    HerdrHudImageAttachment(
                        id: UUID(),
                        url: url,
                        filename: url.lastPathComponent,
                        byteCount: fileSize
                    )
                )
            } catch {
                validationError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func removeImageAttachment(_ id: UUID) {
        imageAttachments.removeAll { $0.id == id }
    }

    func reportAttachmentError(_ message: String) {
        validationError = message
    }

    #if DEBUG
    func seedExchangesForTesting(_ exchanges: [HerdrHudExchange]) {
        self.exchanges = exchanges
    }

    func appendExchangeForTesting(_ exchange: HerdrHudExchange) {
        append(exchange)
    }
    #endif

    func submit(model: HerdrAppModel) async {
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

        let pendingImageAttachments = imageAttachments
        guard pendingImageAttachments.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= Self.maxCombinedImageBytes else {
            validationError = "Attachments can total up to 21 MB per message."
            return
        }

        let attachmentFilenames = pendingImageAttachments.map(\.filename)
        let pendingID = "hud-pending-\(UUID().uuidString)"
        let submittedAt = Date.now
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
                attachmentFilenames: attachmentFilenames
            )
        )
        draft = ""
        imageAttachments = []

        let wireAttachments: [HeadlessAgentAttachment]
        do {
            wireAttachments = pendingImageAttachments.isEmpty ? [] : try await Task.detached(priority: .userInitiated) {
                try pendingImageAttachments.map { attachment in
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
            exchanges[index].error = "Couldn't read \(pendingImageAttachments.first?.filename ?? "attachment"): \(error.localizedDescription)"
            if draft.isEmpty { draft = prompt }
            if imageAttachments.isEmpty { imageAttachments = pendingImageAttachments }
            controller.reset()
            return
        }

        let hasAttachments = !wireAttachments.isEmpty
        let agentModel = HerdrHudModelRouting.model(hasAttachments: hasAttachments)
        let thinkingLevel = HerdrHudModelRouting.thinkingLevel
        let run = await submitAndWait(
            prompt: prompt,
            machineID: machineID,
            agentModel: agentModel,
            thinkingLevel: thinkingLevel,
            attachments: hasAttachments ? wireAttachments : nil,
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
                attachments: wireAttachments
            )
            if draft.isEmpty { draft = prompt }
            if imageAttachments.isEmpty { imageAttachments = pendingImageAttachments }
            controller.reset()
            return
        }

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
            attachments: retainedAttachments
        )
        if run.status.isTerminal, isCollapsed {
            hasUnseenAnswer = true
        }
        controller.reset()
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

    func activateResponseAudio(
        _ action: ResponseAudioAction,
        text: String,
        model: HerdrAppModel
    ) {
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

    func promote(exchange: HerdrHudExchange, model: HerdrAppModel) async -> HerdrPane? {
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
            }
            return result.pane
        } catch {
            promoteErrorMessage = error.localizedDescription
            return nil
        }
    }

    func retry(_ exchange: HerdrHudExchange, model: HerdrAppModel) async {
        guard !controller.isRunning else { return }
        validationError = nil
        promoteErrorMessage = nil
        audioErrorMessage = nil
        let hasAttachments = !exchange.attachments.isEmpty
        guard let run = await submitAndWait(
            prompt: exchange.sentPrompt,
            machineID: exchange.machineID,
            agentModel: HerdrHudModelRouting.model(hasAttachments: hasAttachments),
            thinkingLevel: HerdrHudModelRouting.thinkingLevel,
            attachments: hasAttachments ? exchange.attachments : nil,
            model: model
        ) else {
            validationError = controller.errorMessage
            controller.reset()
            return
        }
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
                attachments: retainedAttachments
            )
        )
        if run.status.isTerminal, isCollapsed {
            hasUnseenAnswer = true
        }
        controller.reset()
    }

    func clear(model: HerdrAppModel) async {
        for exchange in exchanges where exchange.promotedPaneID == nil && exchange.status.isTerminal {
            try? await model.deleteHeadlessAgent(runID: exchange.id, machineID: exchange.machineID)
        }
        exchanges = []
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

    private func append(_ exchange: HerdrHudExchange) {
        exchanges.append(exchange)
        trimExceedingCap()
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

    private func submitAndWait(
        prompt: String,
        machineID: String,
        agentModel: String?,
        thinkingLevel: String?,
        attachments: [HeadlessAgentAttachment]?,
        model: HerdrAppModel
    ) async -> HeadlessAgentRun? {
        elapsedSeconds = 0
        await controller.submit(
            prompt: prompt,
            machineID: machineID,
            mode: .act,
            agentModel: agentModel,
            thinkingLevel: thinkingLevel,
            attachments: attachments,
            model: model
        )
        beginElapsedTimer()
        while controller.isRunning {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return nil
            }
        }
        endElapsedTimer()
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
    }
}
