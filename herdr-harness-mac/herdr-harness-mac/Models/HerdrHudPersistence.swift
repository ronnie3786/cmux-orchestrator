import Foundation

struct HerdrHudPersistenceSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumExchangeCount = 10
    static let maximumResponseBytes = 64 * 1024
    static let truncatedResponseMarker = "\n\n[Response truncated for HUD persistence]"

    let version: Int
    let thread: HerdrHudSession.HerdrHudThread?
    let exchanges: [PersistedExchange]

    init(
        version: Int = HerdrHudPersistenceSnapshot.currentVersion,
        thread: HerdrHudSession.HerdrHudThread?,
        exchanges: [HerdrHudExchange]
    ) {
        self.version = version
        self.thread = thread
        self.exchanges = exchanges.suffix(Self.maximumExchangeCount).map(PersistedExchange.init)
    }

    static func load(from fileURL: URL) -> HerdrHudPersistenceSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.version == Self.currentVersion
        else {
            return nil
        }
        return snapshot
    }

    func save(to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: fileURL, options: .atomic)
    }

    func restoredValues() -> (thread: HerdrHudSession.HerdrHudThread?, exchanges: [HerdrHudExchange]) {
        (
            thread,
            exchanges.map { persistedExchange in
                var exchange = persistedExchange.exchange
                if !exchange.status.isTerminal {
                    exchange.status = .failed
                    exchange.error = "Interrupted by app restart"
                }
                return exchange
            }
        )
    }

    struct PersistedExchange: Codable, Equatable, Sendable {
        let id: String
        let machineID: String
        let prompt: String
        let sentPrompt: String
        let response: String?
        let error: String?
        let status: HeadlessAgentRunStatus
        let costUSD: Double?
        let createdAt: Date
        let promotedPaneID: String?
        let attachmentFilenames: [String]
        let localAttachments: [HerdrHudAttachment]?
        let modelLabel: String
        let steps: [HerdrHudStep]
        let stepsTruncated: Bool

        init(_ exchange: HerdrHudExchange) {
            id = exchange.id
            machineID = exchange.machineID
            prompt = exchange.prompt
            sentPrompt = exchange.sentPrompt
            response = exchange.response.map(Self.cappedResponse)
            error = exchange.error
            status = exchange.status
            costUSD = exchange.costUSD
            createdAt = exchange.createdAt
            promotedPaneID = exchange.promotedPaneID
            attachmentFilenames = exchange.attachmentFilenames
            localAttachments = exchange.localAttachments.isEmpty ? nil : exchange.localAttachments
            modelLabel = exchange.modelLabel
            steps = exchange.steps
            stepsTruncated = exchange.stepsTruncated
        }

        var exchange: HerdrHudExchange {
            HerdrHudExchange(
                id: id,
                machineID: machineID,
                prompt: prompt,
                sentPrompt: sentPrompt,
                response: response,
                error: error,
                status: status,
                costUSD: costUSD,
                createdAt: createdAt,
                promotedPaneID: promotedPaneID,
                attachmentFilenames: attachmentFilenames,
                attachments: [],
                localAttachments: localAttachments ?? [],
                modelLabel: modelLabel,
                steps: steps,
                stepsTruncated: stepsTruncated
            )
        }

        private static func cappedResponse(_ response: String) -> String {
            let data = Data(response.utf8)
            guard data.count > HerdrHudPersistenceSnapshot.maximumResponseBytes else { return response }

            let marker = HerdrHudPersistenceSnapshot.truncatedResponseMarker
            let byteLimit = HerdrHudPersistenceSnapshot.maximumResponseBytes - marker.utf8.count
            var prefix = Data(data.prefix(byteLimit))
            while String(data: prefix, encoding: .utf8) == nil {
                prefix.removeLast()
            }
            return String(decoding: prefix, as: UTF8.self) + marker
        }
    }
}

actor HerdrHudPersistenceStore {
    let fileURL: URL
    private var pendingSnapshot: HerdrHudPersistenceSnapshot?
    private var isSaveScheduled = false

    init(fileURL: URL = HerdrHudPersistenceStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "herdr-harness-mac"
        return applicationSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("hud-thread.json", isDirectory: false)
    }

    func load() -> HerdrHudPersistenceSnapshot? {
        HerdrHudPersistenceSnapshot.load(from: fileURL)
    }

    func scheduleSave(_ snapshot: HerdrHudPersistenceSnapshot) {
        pendingSnapshot = snapshot
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.writePendingSnapshots()
        }
    }

    func remove() {
        pendingSnapshot = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func writePendingSnapshots() {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            try? snapshot.save(to: fileURL)
        }
        isSaveScheduled = false
    }
}
