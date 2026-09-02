import Foundation

struct GitHubReviewRequest: Codable, Equatable, Hashable, Identifiable, Sendable {
    var number: Int
    var title: String
    var url: String
    var isDraft: Bool
    var state: String
    var author: String
    var repository: String

    var id: String { url.isEmpty ? "\(repository)#\(number)" : url }
    var browserURL: URL? {
        guard let candidate = URL(string: url),
              let scheme = candidate.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return candidate
    }

    enum CodingKeys: String, CodingKey {
        case number
        case title
        case url
        case isDraft = "is_draft"
        case state
        case author
        case repository
    }
}
