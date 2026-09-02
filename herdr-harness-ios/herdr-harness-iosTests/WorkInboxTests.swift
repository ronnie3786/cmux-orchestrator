import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Work inbox")
struct WorkInboxTests {
    @Test("Decodes provider sections and prioritizes active Jira statuses")
    func decodesAndPrioritizes() throws {
        let response = try JSONDecoder().decode(
            WorkInboxResponse.self,
            from: Data(
                """
                {
                  "ok": true,
                  "review_requests": {
                    "ok": true,
                    "items": [{
                      "number": 11856,
                      "title": "Add calculator drawer",
                      "url": "https://github.com/doximity/iOS-Doximity/pull/11856",
                      "is_draft": false,
                      "state": "open",
                      "author": "Chandlerdea",
                      "repository": "doximity/iOS-Doximity"
                    }]
                  },
                  "jira_tickets": {
                    "ok": true,
                    "items": [
                      {"key":"APP-1","title":"Backlog","status":"Backlog","priority":"","issue_type":"Story","url":"https://jira.example/APP-1"},
                      {"key":"APP-2","title":"Review","status":"In Code Review","priority":"","issue_type":"Story","url":"https://jira.example/APP-2"},
                      {"key":"APP-3","title":"Other","status":"Ready for QA","priority":"","issue_type":"Story","url":"https://jira.example/APP-3"},
                      {"key":"APP-4","title":"Active","status":"In Progress","priority":"","issue_type":"Story","url":"https://jira.example/APP-4"},
                      {"key":"APP-5","title":"Blocked","status":"Blocked","priority":"","issue_type":"Story","url":"https://jira.example/APP-5"}
                    ]
                  }
                }
                """.utf8
            )
        )

        let prioritized = response.prioritizingActiveJiraStatuses()

        #expect(prioritized.reviewRequests.items.first?.number == 11856)
        #expect(prioritized.reviewRequests.items.first?.repository == "doximity/iOS-Doximity")
        #expect(prioritized.jiraTickets.items.map(\.key) == ["APP-4", "APP-2", "APP-5", "APP-1", "APP-3"])
    }

    @Test("Rejects non-web work item links")
    func validatesBrowserLinks() {
        let review = GitHubReviewRequest(
            number: 1,
            title: "Unsafe",
            url: "file:///tmp/private",
            isDraft: false,
            state: "open",
            author: "author",
            repository: "owner/repo"
        )
        let ticket = JiraTicket(
            key: "APP-1",
            projectKey: "APP",
            title: "Unsafe",
            status: "In Progress",
            priority: "High",
            issueType: "Story",
            url: "herdr://pane/private"
        )

        #expect(review.browserURL == nil)
        #expect(ticket.workInboxURL == nil)
    }

    @Test("Store keeps provider results and reports transport failures")
    @MainActor
    func storeRefreshState() async {
        let store = WorkInboxStore()
        var response = WorkInboxResponse.empty
        response.reviewRequests.items = [
            GitHubReviewRequest(
                number: 7,
                title: "Review me",
                url: "https://github.com/owner/repo/pull/7",
                isDraft: false,
                state: "open",
                author: "author",
                repository: "owner/repo"
            )
        ]

        await store.refresh { response }

        #expect(store.hasLoaded)
        #expect(store.totalCount == 1)
        #expect(store.transportError == nil)

        await store.refresh { throw APIError.invalidResponse }

        #expect(store.totalCount == 1)
        #expect(store.transportError == "The Herdr server returned an invalid response.")
    }

    @Test("Freshness window keeps drawer reopens off the network")
    @MainActor
    func freshnessWindowSuppressesRedundantRefreshes() async {
        let store = WorkInboxStore()
        #expect(store.isStale(olderThan: 120))

        await store.refresh { .empty }

        #expect(!store.isStale(olderThan: 120))
        #expect(store.isStale(olderThan: 0))
    }

    /// The drawer cancels the in-flight refresh on dismiss. URLSession reports
    /// that as `URLError.cancelled`, not `CancellationError`, and treating it as
    /// a transport failure would paint a warning triangle over a healthy inbox
    /// the next time the drawer opens.
    @Test("A cancelled refresh does not become a transport error")
    @MainActor
    func cancelledRefreshIsNotAnError() async {
        let store = WorkInboxStore()

        await store.refresh { throw URLError(.cancelled) }

        #expect(!store.hasLoaded)
        #expect(!store.hasError)
        #expect(store.transportError == nil)
    }
}
