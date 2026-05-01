import Foundation

struct SkillsResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var rootPath: String?
    var skillsDirectory: String?
    var userSkillsDirectory: String? = nil
    var projectSkills: [ProjectSkill]? = nil
    var userSkills: [ProjectSkill]? = nil
    var skills: [ProjectSkill]? = nil
    var error: String?

    var resolvedProjectSkills: [ProjectSkill] {
        projectSkills ?? skills?.filter { $0.scope == "project" } ?? []
    }

    var resolvedUserSkills: [ProjectSkill] {
        userSkills ?? skills?.filter { $0.scope == "user" } ?? []
    }
}

struct ProjectSkill: Decodable, Equatable, Identifiable, Sendable {
    var name: String
    var skillFilePath: String
    var scope: String? = nil

    var id: String { "\(scope ?? "project")|\(name)" }
}

struct FileSearchResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var rootPath: String?
    var query: String
    var files: [ProjectFileMatch]
    var truncated: Bool?
    var limit: Int?
    var error: String?
}

struct ProjectFileMatch: Decodable, Equatable, Identifiable, Sendable {
    var path: String

    var id: String { path }
}

struct JiraTicketsResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var project: String?
    var projects: [String]? = nil
    var site: String?
    var tickets: [JiraTicket]
    var error: String?
}

struct JiraTicketResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var site: String?
    var ticket: JiraTicket?
    var error: String?
}

struct JiraTicket: Decodable, Equatable, Identifiable, Sendable {
    var key: String
    var projectKey: String? = nil
    var title: String
    var status: String
    var priority: String
    var issueType: String
    var url: String

    var id: String { key }
}

struct AttachmentUploadResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var attachment: UploadedAttachment?
    var error: String?
}

struct UploadedAttachment: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var filename: String
    var originalFilename: String
    var contentType: String
    var size: Int
    var path: String
    var workspaceKey: String
    var createdAt: String
}

struct TerminalAttachment: Equatable, Identifiable, Sendable {
    var id: UUID
    var filename: String
    var sourceURL: URL
    var status: TerminalAttachmentStatus
    var uploaded: UploadedAttachment?
    var error: String?

    var displayName: String {
        let original = uploaded?.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return original.isEmpty ? filename : original
    }

    var uploadedPath: String? {
        let value = uploaded?.path.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum TerminalAttachmentStatus: String, Equatable, Sendable {
    case uploading
    case uploaded
    case failed
}
