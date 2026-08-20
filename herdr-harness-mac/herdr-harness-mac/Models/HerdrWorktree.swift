import Foundation

struct HerdrWorktree: Codable, Equatable, Hashable, Sendable {
    let repoKey: String
    let repoName: String
    let repoRoot: String
    let checkoutPath: String
    let isLinkedWorktree: Bool

    enum CodingKeys: String, CodingKey {
        case repoKey = "repo_key"
        case repoName = "repo_name"
        case repoRoot = "repo_root"
        case checkoutPath = "checkout_path"
        case isLinkedWorktree = "is_linked_worktree"
    }
}
