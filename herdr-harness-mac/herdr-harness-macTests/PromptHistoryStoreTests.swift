import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Prompt history", .serialized)
@MainActor
struct PromptHistoryStoreTests {
    @Test("History persists full text and separates panes on different machines")
    func persistenceAndScope() throws {
        let suite = "PromptHistoryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PromptHistoryStore(userDefaults: defaults)
        let fullText = String(repeating: "some detailed prompt\n", count: 100)
        store.record(fullText, paneID: "home|pane:1")
        store.record("work prompt", paneID: "work|pane:1")
        let reloaded = PromptHistoryStore(userDefaults: defaults)
        #expect(reloaded.entries(for: "home|pane:1").map(\.text) == [fullText])
        #expect(reloaded.entries(for: "work|pane:1").map(\.text) == ["work prompt"])
        #expect(reloaded.entries(for: "home|pane:2").isEmpty)
    }

    @Test("Echoes reconcile repeated submissions once and compaction retains history")
    func reconcilesEchoes() throws {
        let suite = "PromptHistoryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PromptHistoryStore(userDefaults: defaults)
        let time = Date(timeIntervalSince1970: 1_000)
        store.record("again", paneID: "machine|pane", submittedAt: time)
        store.record("again", paneID: "machine|pane", submittedAt: time.addingTimeInterval(1))
        let messages = [
            PiUserMessage(id: "1", text: "again", timestamp: time),
            PiUserMessage(id: "2", text: "again", timestamp: time.addingTimeInterval(600))
        ]
        store.merge(messages, paneID: "machine|pane")
        store.merge(messages, paneID: "machine|pane")
        store.merge([], paneID: "machine|pane")
        #expect(store.entries(for: "machine|pane").count == 2)
        #expect(store.entries(for: "machine|pane").map(\.transcriptIDs) == [Set(["1"]), Set(["2"])])
    }

    @Test("Imports older prompts and reconciles a stream echo that wins the submission race")
    func importsAndRace() throws {
        let suite = "PromptHistoryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PromptHistoryStore(userDefaults: defaults)
        let time = Date(timeIntervalSince1970: 1_000)
        store.merge([PiUserMessage(id: "1", text: "hello", timestamp: time)], paneID: "machine|pane")
        store.record("hello", paneID: "machine|pane", submittedAt: time.addingTimeInterval(0.5))
        store.merge([PiUserMessage(id: "older", text: "first", timestamp: time.addingTimeInterval(-10))], paneID: "machine|pane")
        #expect(store.entries(for: "machine|pane").map(\.text) == ["first", "hello"])
        #expect(store.entries(for: "machine|pane").last?.wasSubmittedLocally == true)
    }

    @Test("An older identical prompt cannot consume a new pending submission")
    func oldIdenticalPrompt() throws {
        let suite = "PromptHistoryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PromptHistoryStore(userDefaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000)
        store.record("again", paneID: "machine|pane", submittedAt: now)
        store.merge([PiUserMessage(id: "old", text: "again", timestamp: now.addingTimeInterval(-500))], paneID: "machine|pane")
        store.merge([PiUserMessage(id: "new", text: "again", timestamp: now)], paneID: "machine|pane")
        #expect(store.entries(for: "machine|pane").count == 2)
        #expect(store.entries(for: "machine|pane").map(\.transcriptIDs) == [Set(["old"]), Set(["new"])])
    }
}
