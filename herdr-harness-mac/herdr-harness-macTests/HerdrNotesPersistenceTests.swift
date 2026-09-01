import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr notes persistence")
struct HerdrNotesPersistenceTests {
    @Test("Notes round-trip through the persistence file")
    func roundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-notes.json")
        let notes = [note(id: UUID(), body: "First", updatedAt: 1), note(id: UUID(), body: "Second", updatedAt: 2)]
        try HerdrNotesSnapshot(notes: notes).save(to: fileURL)

        let restored = try #require(HerdrNotesSnapshot.load(from: fileURL))
        #expect(restored.version == HerdrNotesSnapshot.currentVersion)
        #expect(restored.notes == notes)
    }

    @Test("Legacy partial notes decode with safe defaults")
    func decodesPartialNote() throws {
        let id = UUID()
        let data = Data(#"""
        {
          "id": "\#(id.uuidString)",
          "title": "Title",
          "body": "Body",
          "createdAt": 1,
          "updatedAt": 2
        }
        """#.utf8)
        let note = try JSONDecoder().decode(HerdrNote.self, from: data)
        #expect(note.color == .yellow)
        #expect(note.actions.isEmpty)
        #expect(note.links.isEmpty)
        #expect(note.previousVersion == nil)
    }

    @Test("Missing corrupt and unsupported persistence files do not load")
    func invalidFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-notes.json")
        #expect(HerdrNotesSnapshot.load(from: fileURL) == nil)
        try Data("not json".utf8).write(to: fileURL)
        #expect(HerdrNotesSnapshot.load(from: fileURL) == nil)
        try HerdrNotesSnapshot(version: 999, notes: []).save(to: fileURL)
        #expect(HerdrNotesSnapshot.load(from: fileURL) == nil)
    }

    @Test("Snapshots keep the newest hundred notes")
    func capsNoteCount() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-notes.json")
        let notes = (0..<105).map { index in note(id: UUID(), body: "\(index)", updatedAt: TimeInterval(index)) }
        try HerdrNotesSnapshot(notes: notes).save(to: fileURL)

        let restored = try #require(HerdrNotesSnapshot.load(from: fileURL))
        #expect(restored.notes.count == 100)
        #expect(restored.notes.first?.body == "5")
        #expect(restored.notes.last?.body == "104")
    }

    @Test("Snapshots cap a note body at twenty thousand characters")
    func capsBodyLength() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-notes.json")
        try HerdrNotesSnapshot(notes: [note(id: UUID(), body: String(repeating: "x", count: 20_100), updatedAt: 1)]).save(to: fileURL)
        let restored = try #require(HerdrNotesSnapshot.load(from: fileURL))
        #expect(restored.notes[0].body.count == HerdrNotesSnapshot.maximumBodyLength)
    }

    @Test("Snapshots keep original relative order among survivors even when unsorted")
    func preservesRelativeOrderAmongSurvivors() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-notes.json")
        let notes = (0..<105).map { index in
            note(id: UUID(), body: "\(index)", updatedAt: TimeInterval((index * 37) % 105))
        }
        try HerdrNotesSnapshot(notes: notes).save(to: fileURL)
        let restored = try #require(HerdrNotesSnapshot.load(from: fileURL))
        let ids = Set(notes.sorted { $0.updatedAt > $1.updatedAt }.prefix(100).map(\.id))
        let expected = notes.filter { ids.contains($0.id) }.map(\.id)
        #expect(restored.notes.count == 100)
        #expect(restored.notes.map(\.id) == expected)
        #expect(restored.notes.map(\.updatedAt) != restored.notes.map(\.updatedAt).sorted(by: >))
    }

    @Test("Store debounce keeps the latest scheduled snapshot")
    func storeDebouncesLatestSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-notes.json")
        let store = HerdrNotesStore(fileURL: fileURL)
        let first = HerdrNotesSnapshot(notes: [note(id: UUID(), body: "first", updatedAt: 1)])
        let second = HerdrNotesSnapshot(notes: [note(id: UUID(), body: "second", updatedAt: 2)])
        await store.scheduleSave(first, delay: .seconds(30))
        await store.scheduleSave(second, delay: .zero)
        await store.waitForPendingFlushForTesting()
        #expect(HerdrNotesSnapshot.load(from: fileURL)?.notes == second.notes)
    }

    @Test("Store flush writes immediately")
    func storeFlushWritesImmediately() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-notes.json")
        let store = HerdrNotesStore(fileURL: fileURL)
        let snapshot = HerdrNotesSnapshot(notes: [note(id: UUID(), body: "now", updatedAt: 1)])
        await store.scheduleSave(snapshot, delay: .seconds(30))
        await store.flush()
        #expect(HerdrNotesSnapshot.load(from: fileURL)?.notes == snapshot.notes)
    }

    @Test("A legacy note action without a status decodes as ready")
    func decodesActionWithoutStatus() throws {
        let id = UUID()
        let data = Data(#"""
        {"id": "\#(id.uuidString)", "title": "Do the thing", "prompt": "Do the thing please"}
        """#.utf8)
        let action = try JSONDecoder().decode(HerdrNoteAction.self, from: data)
        #expect(action.status == .ready)
        #expect(action.linkID == nil)
        #expect(HerdrNoteAction(id: UUID(), title: "t", prompt: "p").status == .ready)
    }

    @Test("Store removal deletes its persistence file")
    func storeRemoval() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-notes.json")
        try HerdrNotesSnapshot(notes: [note(id: UUID(), body: "body", updatedAt: 1)]).save(to: fileURL)
        let store = HerdrNotesStore(fileURL: fileURL)
        await store.remove()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrNotesPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func note(id: UUID, body: String, updatedAt: TimeInterval) -> HerdrNote {
        HerdrNote(
            id: id,
            title: "Title",
            body: body,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
