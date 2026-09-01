import Foundation

struct HerdrNotesSnapshot: Codable, Sendable {
    static let currentVersion = 1
    static let maximumNoteCount = 100
    static let maximumBodyLength = 20_000

    let version: Int
    let notes: [HerdrNote]

    init(version: Int = HerdrNotesSnapshot.currentVersion, notes: [HerdrNote]) {
        self.version = version
        let capped = notes
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maximumNoteCount)
            .map { note -> HerdrNote in
                guard note.body.count > Self.maximumBodyLength else { return note }
                var copy = note
                copy.body = String(note.body.prefix(Self.maximumBodyLength))
                return copy
            }
        self.notes = Array(capped)
    }

    static func load(from fileURL: URL) -> HerdrNotesSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.version == Self.currentVersion
        else { return nil }
        return snapshot
    }

    func save(to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: fileURL, options: .atomic)
    }
}

actor HerdrNotesStore {
    let fileURL: URL
    private var pendingSnapshot: HerdrNotesSnapshot?
    private var isSaveScheduled = false

    init(fileURL: URL = HerdrNotesStore.defaultFileURL()) {
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
            .appendingPathComponent("hud-notes.json", isDirectory: false)
    }

    func load() -> HerdrNotesSnapshot? {
        HerdrNotesSnapshot.load(from: fileURL)
    }

    func scheduleSave(_ snapshot: HerdrNotesSnapshot) {
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
