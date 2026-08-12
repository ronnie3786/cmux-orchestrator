import Foundation

struct WorkspaceGitStatus: Codable, Equatable, Sendable {
    var ok: Bool
    var workspaceID: String?
    var branch: String?
    var cwd: String?
    var staged: [WorkspaceGitFile]
    var unstaged: [WorkspaceGitFile]
    var untracked: [String]
    var commits: [WorkspaceGitCommit]
    var error: String?

    var hasChanges: Bool {
        !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty
    }

    var changeCount: Int {
        staged.count + unstaged.count + untracked.count
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case workspaceID = "workspace_id"
        case branch
        case cwd = "root_path"
        case staged
        case unstaged
        case untracked
        case commits
        case error
    }
}

struct WorkspaceGitFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var status: String
    var file: String

    var id: String { "\(status)|\(file)" }
}

struct WorkspaceGitCommit: Codable, Equatable, Hashable, Identifiable, Sendable {
    var hash: String
    var message: String

    var id: String { "\(hash)|\(message)" }
}

struct WorkspaceGitDiffResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var file: String?
    var section: GitFileSection?
    var diff: String?
    var error: String?
}

enum GitFileSection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case staged
    case unstaged
    case untracked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .untracked: "Untracked"
        }
    }
}

struct SkillsResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var workspaceID: String?
    var rootPath: String?
    var skillsDirectory: String?
    var userSkillsDirectory: String?
    var projectSkills: [ProjectSkill]?
    var userSkills: [ProjectSkill]?
    var skills: [ProjectSkill]?
    var error: String?

    var resolvedProjectSkills: [ProjectSkill] {
        projectSkills ?? skills?.filter { $0.scope == "project" } ?? []
    }

    var resolvedUserSkills: [ProjectSkill] {
        userSkills ?? skills?.filter { $0.scope == "user" } ?? []
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case workspaceID = "workspace_id"
        case rootPath = "root_path"
        case skillsDirectory = "skills_directory"
        case userSkillsDirectory = "user_skills_directory"
        case projectSkills = "project_skills"
        case userSkills = "user_skills"
        case skills
        case error
    }
}

struct ProjectSkill: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var skillFilePath: String
    var scope: String?

    var id: String { "\(scope ?? "project")|\(name)|\(skillFilePath)" }

    enum CodingKeys: String, CodingKey {
        case name
        case skillFilePath = "skill_file_path"
        case scope
    }
}

enum SkillInsertionStyle: String, CaseIterable, Hashable, Identifiable, Sendable {
    case claudeCode
    case codexCLI
    case filePath

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codexCLI: "Codex CLI"
        case .filePath: "Skill file path"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "terminal"
        case .codexCLI: "dollarsign.circle"
        case .filePath: "doc.text"
        }
    }

    func token(for skill: ProjectSkill) -> String {
        switch self {
        case .claudeCode: "/\(skill.name)"
        case .codexCLI: "$\(skill.name)"
        case .filePath: "`\(skill.skillFilePath)`"
        }
    }
}

struct FileSearchResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var workspaceID: String?
    var rootPath: String?
    var query: String
    var files: [ProjectFileMatch]
    var truncated: Bool?
    var limit: Int?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case workspaceID = "workspace_id"
        case rootPath = "root_path"
        case query
        case files
        case truncated
        case limit
        case error
    }
}

struct ProjectFileMatch: Codable, Equatable, Hashable, Identifiable, Sendable {
    var path: String

    var id: String { path }
}

struct JiraTicketsResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var project: String?
    var projects: [String]?
    var site: String?
    var tickets: [JiraTicket]
    var error: String?
}

struct JiraTicketResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var site: String?
    var ticket: JiraTicket?
    var error: String?
}

struct JiraTicket: Codable, Equatable, Hashable, Identifiable, Sendable {
    var key: String
    var projectKey: String?
    var title: String
    var status: String
    var priority: String
    var issueType: String
    var url: String

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case projectKey = "project_key"
        case title
        case status
        case priority
        case issueType = "issue_type"
        case url
    }
}

struct AttachmentUploadResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var attachment: UploadedAttachment?
    var error: String?
}

struct WorkspaceGitFileBody: Codable, Sendable {
    let file: String
}

struct WorkspaceAttachmentBody: Codable, Sendable {
    let filename: String
    let contentType: String
    let dataBase64: String

    enum CodingKeys: String, CodingKey {
        case filename
        case contentType = "content_type"
        case dataBase64 = "data_base64"
    }
}

struct UploadedAttachment: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var filename: String
    var originalFilename: String
    var contentType: String
    var size: Int
    var path: String
    var workspaceID: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case originalFilename = "original_filename"
        case contentType = "content_type"
        case size
        case path
        case workspaceID = "workspace_id"
        case createdAt = "created_at"
    }
}

struct TerminalAttachment: Equatable, Identifiable, Sendable {
    var id: UUID
    var filename: String
    var sourceURL: URL
    var byteCount: Int64
    var sourceOwnership: AttachmentSourceOwnership
    var status: TerminalAttachmentStatus
    var uploaded: UploadedAttachment?
    var error: String?

    var displayName: String {
        let originalName = uploaded?.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return originalName.isEmpty ? filename : originalName
    }

    var uploadedPath: String? {
        let path = uploaded?.path.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    func removeSourceFileIfOwned(fileManager: FileManager = .default) {
        guard sourceOwnership == .appTemporary else { return }
        try? fileManager.removeItem(at: sourceURL)
    }
}

enum AttachmentSourceOwnership: String, Codable, Equatable, Sendable {
    case userSelected
    case appTemporary
}

enum TerminalAttachmentStatus: String, Codable, Equatable, Sendable {
    case uploading
    case uploaded
    case failed
}
