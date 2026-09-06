import Foundation
import Observation

/// A local archive of submitted prompts. Keys are fleet-wide pane IDs, so two
/// machines with the same terminal pane ID never share history. Transcript
/// imports only add or reconcile entries, and compaction cannot erase history.
@MainActor
@Observable
final class PromptHistoryStore {
    static let defaultsKey = "herdr.prompts.history.v1"
    private(set) var entriesByPane: [String: [PromptHistoryEntry]]
    @ObservationIgnored private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        entriesByPane = userDefaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: [PromptHistoryEntry]].self, from: $0) } ?? [:]
    }

    func entries(for paneID: String) -> [PromptHistoryEntry] {
        entriesByPane[paneID] ?? []
    }

    func record(_ text: String, paneID: String, submittedAt: Date = .now) {
        guard !paneID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var entries = entries(for: paneID)
        // A stream echo can arrive before the HTTP submission finishes. Claim
        // that echo instead of recording the same submission a second time.
        if let index = entries.lastIndex(where: {
            !$0.wasSubmittedLocally && $0.text == text
                && $0.submittedAt.map { abs($0.timeIntervalSince(submittedAt)) < 5 } == true
        }) {
            let echoed = entries[index]
            entries[index] = PromptHistoryEntry(
                id: echoed.id, text: text, submittedAt: submittedAt,
                transcriptIDs: echoed.transcriptIDs
            )
        } else {
            entries.append(PromptHistoryEntry(text: text, submittedAt: submittedAt))
        }
        save(entries, paneID: paneID)
    }

    func merge(_ messages: [PiUserMessage], paneID: String) {
        guard !paneID.isEmpty else { return }
        let previous = entries(for: paneID)
        var entries = previous
        for message in messages where !message.text.isEmpty {
            if let index = entries.firstIndex(where: { $0.transcriptIDs.contains(message.id) }) {
                entries[index].text = message.text
                continue
            }
            let index = entries.firstIndex { entry in
                guard entry.text == message.text else { return false }
                // Queued follow-ups may echo much later. Consume one unmatched
                // local submission at a time to preserve repeated prompts.
                if entry.wasSubmittedLocally && entry.transcriptIDs.isEmpty {
                    // Loading an older transcript must not consume a newly
                    // submitted identical prompt as though it were its echo.
                    if let timestamp = message.timestamp, let submittedAt = entry.submittedAt {
                        return timestamp >= submittedAt.addingTimeInterval(-5)
                    }
                    return true
                }
                guard let timestamp = message.timestamp, let submittedAt = entry.submittedAt else { return false }
                return abs(timestamp.timeIntervalSince(submittedAt)) < 0.001
            }
            if let index {
                entries[index].transcriptIDs.insert(message.id)
            } else {
                entries.append(PromptHistoryEntry(
                    text: message.text, submittedAt: message.timestamp,
                    transcriptIDs: [message.id], wasSubmittedLocally: false
                ))
            }
        }
        // Stable sorting leaves undated transcript entries in their original
        // order and uses import order to break equal timestamps.
        entries = entries.enumerated().sorted { lhs, rhs in
            let left = lhs.element.submittedAt ?? .distantPast
            let right = rhs.element.submittedAt ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        if entries != previous { save(entries, paneID: paneID) }
    }

    private func save(_ entries: [PromptHistoryEntry], paneID: String) {
        entriesByPane[paneID] = entries
        if let data = try? JSONEncoder().encode(entriesByPane) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
