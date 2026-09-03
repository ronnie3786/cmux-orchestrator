import Foundation
import SwiftUI

enum HerdrNoteColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow, peach, pink, green, blue, lavender

    var id: String { rawValue }

    var fill: Color {
        switch self {
        case .yellow: Color(red: 0.9765, green: 0.8863, blue: 0.6863)
        case .peach: Color(red: 0.9804, green: 0.7020, blue: 0.5294)
        case .pink: Color(red: 0.9608, green: 0.7608, blue: 0.9059)
        case .green: Color(red: 0.6510, green: 0.8902, blue: 0.6314)
        case .blue: Color(red: 0.5373, green: 0.7059, blue: 0.9804)
        case .lavender: Color(red: 0.7059, green: 0.7451, blue: 0.9961)
        }
    }

    var ink: Color { HerdrTheme.crust }

    var label: String {
        switch self {
        case .yellow: "Yellow"
        case .peach: "Peach"
        case .pink: "Pink"
        case .green: "Green"
        case .blue: "Blue"
        case .lavender: "Lavender"
        }
    }
}

struct HerdrNoteVersion: Codable, Equatable, Sendable {
    var title: String
    /// The rich snapshot. Tidy rewrites a note from a plain-text model reply,
    /// so this is what makes the undo button give the user their formatting
    /// back rather than a flattened copy of their own words.
    var richBody: AttributedString
    var replacedAt: Date

    var body: String { String(richBody.characters) }

    init(title: String, body: String, replacedAt: Date) {
        self.init(title: title, richBody: AttributedString(body), replacedAt: replacedAt)
    }

    init(title: String, richBody: AttributedString, replacedAt: Date) {
        self.title = title
        self.richBody = richBody
        self.replacedAt = replacedAt
    }
}

extension HerdrNoteVersion {
    private enum CodingKeys: String, CodingKey { case title, body, richBody, replacedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        replacedAt = try container.decode(Date.self, forKey: .replacedAt)
        richBody = try HerdrNoteRichText.decode(from: container, richKey: .richBody, plainKey: .body)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(replacedAt, forKey: .replacedAt)
        try HerdrNoteRichText.encode(richBody, into: &container, richKey: .richBody, plainKey: .body)
    }
}

/// Shared rich-text coding. Notes keep writing a plain `body` alongside the
/// attributed one so an older build (or a hand-edited file) still reads them,
/// and so the snapshot version can stay pinned at 1 — bumping it makes
/// `HerdrNotesSnapshot.load` discard every existing note.
enum HerdrNoteRichText {
    static func decode<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        richKey: K,
        plainKey: K
    ) throws -> AttributedString {
        if let rich = try container.decodeIfPresent(
            AttributedString.self,
            forKey: richKey,
            configuration: AttributeScopes.SwiftUIAttributes.self
        ) {
            return rich
        }
        return AttributedString(try container.decodeIfPresent(String.self, forKey: plainKey) ?? "")
    }

    static func encode<K: CodingKey>(
        _ value: AttributedString,
        into container: inout KeyedEncodingContainer<K>,
        richKey: K,
        plainKey: K
    ) throws {
        try container.encode(String(value.characters), forKey: plainKey)
        try container.encode(
            value,
            forKey: richKey,
            configuration: AttributeScopes.SwiftUIAttributes.self
        )
    }

    /// Character-based truncation that keeps attributes, replacing the plain
    /// `String.prefix` the size caps used to use.
    static func truncated(_ value: AttributedString, to limit: Int) -> AttributedString {
        let characters = value.characters
        guard characters.count > limit else { return value }
        let end = characters.index(characters.startIndex, offsetBy: limit)
        return AttributedString(value[..<end])
    }
}

struct HerdrNoteLink: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let paneID: String
    let machineID: String
    var title: String
    let createdAt: Date
    var actionTitle: String?
}

struct HerdrNoteAction: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case ready, starting, started, failed }

    let id: UUID
    var title: String
    var prompt: String
    var status: Status = .ready
    var linkID: UUID?
    var error: String?
    var startedAt: Date?
}

struct HerdrNote: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    /// Canonical body. `body` stays available as a read-only plain projection
    /// so every consumer that only wants characters — the AI prompts, the row
    /// titles, the emptiness checks — is unchanged.
    var richBody: AttributedString
    var color: HerdrNoteColor
    let createdAt: Date
    var updatedAt: Date
    var previousVersion: HerdrNoteVersion?
    var aiSummary: String?
    var actions: [HerdrNoteAction]
    var links: [HerdrNoteLink]
    var lastCleanedAt: Date?

    var body: String { String(richBody.characters) }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let firstNonBlankLine = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let firstNonBlankLine {
            return firstNonBlankLine.count > 60 ? String(firstNonBlankLine.prefix(60)) : firstNonBlankLine
        }
        return "Untitled note"
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        color: HerdrNoteColor = .yellow,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        previousVersion: HerdrNoteVersion? = nil,
        aiSummary: String? = nil,
        actions: [HerdrNoteAction] = [],
        links: [HerdrNoteLink] = [],
        lastCleanedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.richBody = AttributedString(body)
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.previousVersion = previousVersion
        self.aiSummary = aiSummary
        self.actions = actions
        self.links = links
        self.lastCleanedAt = lastCleanedAt
    }

}

extension HerdrNote {
    private enum CodingKeys: String, CodingKey {
        case id, title, body, richBody, color, createdAt, updatedAt, previousVersion, aiSummary, actions, links, lastCleanedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try HerdrNoteRichText.encode(richBody, into: &container, richKey: .richBody, plainKey: .body)
        try container.encode(color, forKey: .color)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(previousVersion, forKey: .previousVersion)
        try container.encodeIfPresent(aiSummary, forKey: .aiSummary)
        try container.encode(actions, forKey: .actions)
        try container.encode(links, forKey: .links)
        try container.encodeIfPresent(lastCleanedAt, forKey: .lastCleanedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        richBody = try HerdrNoteRichText.decode(from: container, richKey: .richBody, plainKey: .body)
        color = try container.decodeIfPresent(HerdrNoteColor.self, forKey: .color) ?? .yellow
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        previousVersion = try container.decodeIfPresent(HerdrNoteVersion.self, forKey: .previousVersion)
        aiSummary = try container.decodeIfPresent(String.self, forKey: .aiSummary)
        actions = try container.decodeIfPresent([HerdrNoteAction].self, forKey: .actions) ?? []
        links = try container.decodeIfPresent([HerdrNoteLink].self, forKey: .links) ?? []
        lastCleanedAt = try container.decodeIfPresent(Date.self, forKey: .lastCleanedAt)
    }
}

extension HerdrNoteAction {
    private enum CodingKeys: String, CodingKey {
        case id, title, prompt, status, linkID, error, startedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .ready
        linkID = try container.decodeIfPresent(UUID.self, forKey: .linkID)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
    }
}
