import Foundation

struct PromptHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var text: String
    var submittedAt: Date?
    var transcriptIDs: Set<String>
    let wasSubmittedLocally: Bool

    init(
        id: String = UUID().uuidString,
        text: String,
        submittedAt: Date? = .now,
        transcriptIDs: Set<String> = [],
        wasSubmittedLocally: Bool = true
    ) {
        self.id = id
        self.text = text
        self.submittedAt = submittedAt
        self.transcriptIDs = transcriptIDs
        self.wasSubmittedLocally = wasSubmittedLocally
    }
}
