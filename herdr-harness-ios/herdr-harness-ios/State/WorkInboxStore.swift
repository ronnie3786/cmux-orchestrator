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

    /// The navigator drawer is torn down on dismiss, so the inbox's `.task`
    /// runs again on every open. Without a freshness window that would put a
    /// work-inbox round trip behind a very cheap gesture.
    func isStale(olderThan maxAge: TimeInterval) -> Bool {
        guard let lastUpdated else { return true }
        return Date.now.timeIntervalSince(lastUpdated) >= maxAge
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
        } catch let error as URLError where error.code == .cancelled {
            // Closing the drawer cancels the in-flight refresh. URLSession
            // reports that as URLError.cancelled rather than CancellationError,
            // and surfacing it would paint a warning triangle over a perfectly
            // healthy inbox the next time the drawer opens.
            return
        } catch {
            transportError = error.localizedDescription
            hasLoaded = true
        }
    }
}
