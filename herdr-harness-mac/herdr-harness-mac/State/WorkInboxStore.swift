import Foundation
import Observation

@MainActor
@Observable
final class WorkInboxStore {
    private(set) var response = WorkInboxResponse.empty
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var lastUpdated: Date?
    private(set) var transportError: String?

    var totalCount: Int {
        response.reviewRequests.items.count + response.jiraTickets.items.count
    }

    var hasError: Bool {
        transportError != nil || response.reviewRequests.error != nil || response.jiraTickets.error != nil
    }

    func error(for provider: WorkInboxProvider) -> String? {
        let providerError = switch provider {
        case .github: response.reviewRequests.error
        case .jira: response.jiraTickets.error
        }
        return providerError ?? transportError
    }

    func refresh(
        using load: () async throws -> WorkInboxResponse
    ) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            response = try await load().prioritizingActiveJiraStatuses()
            transportError = nil
            lastUpdated = .now
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            transportError = error.localizedDescription
            hasLoaded = true
        }
    }
}
