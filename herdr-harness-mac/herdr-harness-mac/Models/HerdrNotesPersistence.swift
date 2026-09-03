import Foundation

struct HerdrNotesSnapshot: Codable, Sendable {
    static let currentVersion = 1
    static let maximumNoteCount = 100
    static let maximumBodyLength = 20_000

    let version: Int
    let notes: [HerdrNote]

    init(version: Int = HerdrNotesSnapshot.currentVersion, notes: [HerdrNote]) {
        self.version = version
        var trimmed = notes
        if trimmed.count > Self.maximumNoteCount {
            let idsToKeep = Set(trimmed.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maximumNoteCount).map(\.id))
            trimmed = trimmed.filter { idsToKeep.contains($0.id) }
        }
        self.notes = trimmed.map { note in
            guard note.richBody.characters.count > Self.maximumBodyLength else { return note }
            var copy = note
            copy.richBody = HerdrNoteRichText.truncated(note.richBody, to: Self.maximumBodyLength)
            return copy
        }
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
    private var flushTask: Task<Void, Never>?

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

    func scheduleSave(_ snapshot: HerdrNotesSnapshot, delay: Duration = .milliseconds(500)) {
        pendingSnapshot = snapshot
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        try? snapshot.save(to: fileURL)
    }

    #if DEBUG
    func waitForPendingFlushForTesting() async { await flushTask?.value }
    #endif

    func remove() {
        pendingSnapshot = nil
        flushTask?.cancel()
        flushTask = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
