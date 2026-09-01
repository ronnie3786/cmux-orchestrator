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
    var body: String
    var replacedAt: Date
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
    var body: String
    var color: HerdrNoteColor
    let createdAt: Date
    var updatedAt: Date
    var previousVersion: HerdrNoteVersion?
    var aiSummary: String?
    var actions: [HerdrNoteAction]
    var links: [HerdrNoteLink]
    var lastCleanedAt: Date?

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
        self.body = body
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.previousVersion = previousVersion
        self.aiSummary = aiSummary
        self.actions = actions
        self.links = links
        self.lastCleanedAt = lastCleanedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, color, createdAt, updatedAt, previousVersion, aiSummary, actions, links, lastCleanedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
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
