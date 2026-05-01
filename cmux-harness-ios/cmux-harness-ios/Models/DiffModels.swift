import Foundation

struct DiffSheet: Equatable, Identifiable, Sendable {
    var id = UUID()
    var file: String
    var section: GitFileSection
    var diff: String
    var isLoading: Bool
    var error: String?
}

enum DiffLineCommentSide: String, Equatable, Sendable {
    case old
    case new
    case context

    var promptLabel: String {
        switch self {
        case .old:
            return "old"
        case .new:
            return "new"
        case .context:
            return "context"
        }
    }
}

struct DiffLineReviewComment: Equatable, Sendable {
    var file: String
    var lineNumber: Int?
    var side: DiffLineCommentSide
    var code: String
    var comment: String
}
