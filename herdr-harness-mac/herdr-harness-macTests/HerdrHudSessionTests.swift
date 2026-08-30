import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD session")
@MainActor
struct HerdrHudSessionTests {
    @Test("Submitting appends a completed exchange and clears running state")
    func submitAppendsCompletedExchangeAndClearsRunningState() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "What needs attention?"

        await session.submit(model: model)

        #expect(session.exchanges.count == 1)
        let exchange = try #require(session.exchanges.first)
        #expect(exchange.status == .completed)
        #expect(exchange.response?.isEmpty == false)
        #expect(model.machines.map(\.id).contains(exchange.machineID))
        #expect(!session.isRunning)
        #expect(session.draft.isEmpty)
        #expect(session.validationError == nil)
    }

    @Test("Failed submission marks the pending exchange failed and restores the draft")
    func failedSubmissionMarksPendingExchangeFailedAndRestoresDraft() async throws {
        let defaults = makeDefaults(prefix: "failed-submission")
        let model = HerdrAppModel(arguments: ["HerdrTests"], userDefaults: defaults)
        #expect(model.addMachine(name: "Unavailable", urlString: "http://localhost:65534", token: "test"))
        let machine = try #require(model.machines.first)
        model.machineStates[machine.id] = .live

        let session = makeSession()
        session.selectedMachineID = machine.id
        session.draft = "Keep this prompt"

        await session.submit(model: model)

        #expect(session.exchanges.count == 1)
        let exchange = try #require(session.exchanges.first)
        #expect(exchange.status == .failed)
        #expect(exchange.error != nil)
        #expect(session.draft == "Keep this prompt")
    }

    @Test("Submitting image attachments records names and uses vision routing")
    func submitImageAttachmentsRecordsNamesAndUsesVisionRouting() async throws {
        let url = temporaryURL(named: "hud-image.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)

        let model = makeDemoModel()
        let session = makeSession()
        session.addImageAttachments([url])
        session.draft = "Describe this image"

        await session.submit(model: model)

        #expect(session.exchanges.last?.attachmentFilenames == [url.lastPathComponent])
        let demoRun = try await model.startHeadlessAgent(
            prompt: "Describe this image",
            machineID: "demo1",
            mode: .act,
            model: HerdrHudModelRouting.visionModel,
            thinkingLevel: HerdrHudModelRouting.thinkingLevel,
            attachments: [HeadlessAgentAttachment(filename: "hud-image.png", dataBase64: "Zm9v")]
        )
        #expect(demoRun.model == HerdrHudModelRouting.visionModel)
        #expect(demoRun.thinkingLevel == HerdrHudModelRouting.thinkingLevel)
        #expect(demoRun.attachments == ["hud-image.png"])
    }

    @Test("Text-only submissions use maximum thinking without a model override")
    func textOnlySubmissionsUseMaximumThinkingWithoutAModelOverride() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "What needs attention?"

        await session.submit(model: model)

        let demoRun = try await model.startHeadlessAgent(
            prompt: "What needs attention?",
            machineID: "demo1",
            mode: .act,
            model: nil,
            thinkingLevel: HerdrHudModelRouting.thinkingLevel
        )
        #expect(demoRun.model == nil)
        #expect(demoRun.thinkingLevel == HerdrHudModelRouting.thinkingLevel)
    }

    @Test("Model routing only selects vision for attachments")
    func modelRoutingOnlySelectsVisionForAttachments() {
        #expect(HerdrHudModelRouting.model(hasAttachments: false) == nil)
        #expect(HerdrHudModelRouting.model(hasAttachments: true) == HerdrHudModelRouting.visionModel)
    }

    @Test("Image attachments enforce count and file-size limits")
    func imageAttachmentsEnforceCountAndFileSizeLimits() throws {
        let regularURL = temporaryURL(named: "attachment.png")
        let oversizedURL = temporaryURL(named: "oversized.png")
        defer {
            try? FileManager.default.removeItem(at: regularURL)
            try? FileManager.default.removeItem(at: oversizedURL)
        }
        try Data([1]).write(to: regularURL)
        try Data(repeating: 0, count: 21 * 1024 * 1024).write(to: oversizedURL)

        let countSession = makeSession()
        countSession.addImageAttachments(Array(repeating: regularURL, count: 5))
        #expect(countSession.imageAttachments.count == 4)
        #expect(countSession.validationError != nil)

        let sizeSession = makeSession()
        sizeSession.addImageAttachments([oversizedURL])
        #expect(sizeSession.imageAttachments.isEmpty)
        #expect(sizeSession.validationError != nil)
    }

    @Test("Image attachments enforce the combined message-size limit")
    func imageAttachmentsEnforceCombinedMessageSizeLimit() throws {
        let firstURL = temporaryURL(named: "first.png")
        let secondURL = temporaryURL(named: "second.png")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try Data(repeating: 0, count: 11 * 1024 * 1024).write(to: firstURL)
        try Data(repeating: 0, count: 11 * 1024 * 1024).write(to: secondURL)

        let session = makeSession()
        session.addImageAttachments([firstURL, secondURL])

        #expect(session.imageAttachments.map(\.filename) == [firstURL.lastPathComponent])
        #expect(session.validationError == "Attachments can total up to 21 MB per message.")
    }

    @Test("Image attachments reject unsupported file extensions")
    func imageAttachmentsRejectUnsupportedFileExtensions() throws {
        let url = temporaryURL(named: "unsupported.tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)

        let session = makeSession()
        session.addImageAttachments([url])

        #expect(session.imageAttachments.isEmpty)
        #expect(session.validationError?.contains("isn't a supported image type") == true)
    }

    @Test("The exchange history retains the newest twenty entries")
    func exchangeHistoryCapsAtTwenty() async throws {
        let model = makeDemoModel()
        let session = makeSession()

        for index in 0...20 {
            session.draft = "prompt \(index)"
            await session.submit(model: model)
        }

        #expect(session.exchanges.count == 20)
        #expect(!session.exchanges.contains(where: { $0.prompt == "prompt 0" }))
        let newest = try #require(session.exchanges.last)
        #expect(newest.prompt == "prompt 20")
    }

    @Test("Cap eviction retains an in-flight exchange")
    func capEvictionRetainsInFlightExchange() {
        let session = makeSession()
        let exchanges = (0..<20).map { index in
            exchange(id: "seed-\(index)", status: index == 10 ? .running : .completed)
        }
        session.seedExchangesForTesting(exchanges)

        session.appendExchangeForTesting(exchange(id: "new", status: .completed))

        #expect(session.exchanges.count == 20)
        #expect(session.exchanges.contains(where: { $0.id == "seed-10" }))
        #expect(!session.exchanges.contains(where: { $0.id == "seed-0" }))
    }

    @Test("Clearing removes all submitted exchanges")
    func clearEmptiesExchanges() async {
        let model = makeDemoModel()
        let session = makeSession()

        for prompt in ["first", "second", "third"] {
            session.draft = prompt
            await session.submit(model: model)
        }
        #expect(!session.exchanges.isEmpty)

        await session.clear(model: model)

        #expect(session.exchanges.isEmpty)
    }

    @Test("Unseen answer state follows collapsed and expanded submission")
    func unseenAnswerLifecycleFollowsCollapsedState() async {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "Answer while collapsed"

        await session.submit(model: model)

        #expect(session.hasUnseenAnswer)
        session.markSeen()
        #expect(!session.hasUnseenAnswer)

        session.isCollapsed = false
        session.draft = "Answer while expanded"
        await session.submit(model: model)

        #expect(!session.hasUnseenAnswer)
    }

    @Test("Retry preserves the active composer state and resends the original prompt")
    func retryPreservesComposerStateAndUsesStoredRequest() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        let original = exchange(
            id: "failed-run",
            status: .failed,
            prompt: "Display prompt",
            sentPrompt: "Stored request",
            error: "Failed",
            attachmentFilenames: ["original.png"],
            attachments: [HeadlessAgentAttachment(filename: "original.png", dataBase64: "b3JpZ2luYWw=")]
        )
        session.seedExchangesForTesting([original])
        session.draft = "New draft"
        session.selectedMachineID = "current-composer-machine"

        await session.retry(original, model: model)

        #expect(session.draft == "New draft")
        #expect(session.selectedMachineID == "current-composer-machine")
        #expect(session.exchanges.count == 2)
        let retried = try #require(session.exchanges.last)
        #expect(retried.machineID == original.machineID)
        #expect(retried.sentPrompt == original.sentPrompt)
        #expect(retried.attachmentFilenames == original.attachmentFilenames)
        #expect(retried.attachments.isEmpty)

        let demoRun = try await model.startHeadlessAgent(
            prompt: original.sentPrompt,
            machineID: original.machineID,
            mode: .act,
            model: HerdrHudModelRouting.visionModel,
            thinkingLevel: HerdrHudModelRouting.thinkingLevel,
            attachments: original.attachments
        )
        #expect(demoRun.model == HerdrHudModelRouting.visionModel)
        #expect(demoRun.thinkingLevel == HerdrHudModelRouting.thinkingLevel)
    }

    private func exchange(
        id: String,
        status: HeadlessAgentRunStatus,
        prompt: String? = nil,
        sentPrompt: String? = nil,
        error: String? = nil,
        attachmentFilenames: [String] = [],
        attachments: [HeadlessAgentAttachment] = []
    ) -> HerdrHudExchange {
        HerdrHudExchange(
            id: id,
            machineID: "demo1",
            prompt: prompt ?? id,
            sentPrompt: sentPrompt ?? id,
            response: status == .completed ? "Done" : nil,
            error: error,
            status: status,
            costUSD: nil,
            createdAt: .now,
            promotedPaneID: nil,
            attachmentFilenames: attachmentFilenames,
            attachments: attachments
        )
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func makeDemoModel() -> HerdrAppModel {
        HerdrAppModel(
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: makeDefaults(prefix: "model")
        )
    }

    private func makeSession() -> HerdrHudSession {
        HerdrHudSession(userDefaults: makeDefaults(prefix: "session"))
    }

    private func makeDefaults(prefix: String) -> UserDefaults {
        let suiteName = "HerdrHudSessionTests.\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
