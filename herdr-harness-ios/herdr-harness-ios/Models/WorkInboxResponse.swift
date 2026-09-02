import Foundation

struct WorkInboxResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var reviewRequests: WorkInboxProviderSection<GitHubReviewRequest>
    var jiraTickets: WorkInboxProviderSection<JiraTicket>

    static let empty = WorkInboxResponse(
        ok: true,
        reviewRequests: .empty,
        jiraTickets: .empty
    )

    func prioritizingActiveJiraStatuses() -> Self {
        var prioritized = self
        prioritized.jiraTickets.items = jiraTickets.items
            .enumerated()
            .sorted { left, right in
                let leftRank = left.element.workInboxStatus.rawValue
                let rightRank = right.element.workInboxStatus.rawValue
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }
            .map(\.element)
        return prioritized
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case reviewRequests = "review_requests"
        case jiraTickets = "jira_tickets"
    }
}
