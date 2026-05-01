import Foundation

struct GitStatus: Decodable, Equatable, Sendable {
    var ok: Bool?
    var branch: String?
    var cwd: String?
    var staged: [GitFile]
    var unstaged: [GitFile]
    var untracked: [String]
    var commits: [GitCommit]
    var error: String?

    var hasChanges: Bool {
        !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty
    }
}

struct GitFile: Decodable, Equatable, Identifiable, Sendable {
    var status: String
    var file: String

    var id: String { "\(status)|\(file)" }
}

struct GitCommit: Decodable, Equatable, Identifiable, Sendable {
    var hash: String
    var message: String

    var id: String { "\(hash)|\(message)" }
}
