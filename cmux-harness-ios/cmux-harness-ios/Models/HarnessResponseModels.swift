import Foundation

struct ScreenResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var screen: String
    var lines: Int?
    var error: String?
}

struct BasicResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var enabled: Bool?
    var error: String?
}

struct OpenCodeIntegrationResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var status: String?
    var installed: Bool?
    var cmuxAvailable: Bool?
    var needsInstall: Bool?
    var needsRestart: Bool?
    var summary: String?
    var error: String?
}

struct NewSessionResponse: Decodable, Equatable, Sendable {
    struct CreatedWorkspace: Decodable, Equatable, Sendable {
        var index: Int?
        var uuid: String?
    }

    var ok: Bool
    var workspace: CreatedWorkspace?
    var worktreePath: String?
    var branchName: String?
    var error: String?
}

struct FeedResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var items: [FeedItem]
    var error: String?
}

struct FeedItem: Decodable, Equatable, Identifiable, Sendable {
    struct Option: Decodable, Equatable, Identifiable, Sendable {
        var id: String
        var label: String
        var description: String?
    }

    struct Question: Decodable, Equatable, Identifiable, Sendable {
        var id: String
        var header: String?
        var question: String
        var multiSelect: Bool
        var options: [Option]
    }

    var requestID: String
    var kind: String
    var title: String?
    var message: String?
    var command: String?
    var workspaceID: String?
    var surfaceID: String?
    var agent: String?
    var createdAt: String?
    var options: [String]?
    var permissionType: String? = nil
    var patterns: [String]? = nil
    var questions: [Question]? = nil

    var id: String { requestID }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        switch kind {
        case "permission":
            return "Permission Request"
        case "plan":
            return "Plan Approval"
        case "question":
            return "Question"
        default:
            return "cmux Feed"
        }
    }

    var summary: String {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        let commandText = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return commandText.isEmpty ? displayTitle : commandText
    }

    var supportsNativeReply: Bool {
        kind != "question" || questions?.contains(where: \.multiSelect) != true
    }
}
