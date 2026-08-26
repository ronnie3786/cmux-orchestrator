import Foundation

extension JiraTicket {
    var workInboxStatus: WorkInboxJiraStatus {
        WorkInboxJiraStatus(name: status)
    }

    var workInboxURL: URL? {
        guard let candidate = URL(string: url),
              let scheme = candidate.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return candidate
    }
}
