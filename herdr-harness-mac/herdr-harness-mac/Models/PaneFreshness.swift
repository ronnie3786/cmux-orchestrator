import Foundation

enum PaneFreshness {
    static let staleDayThreshold = 7

    static func isStale(
        _ pane: HerdrPane,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard pane.agentStatus != .working, pane.agentStatus != .blocked else { return false }
        guard let firstSeenAt = pane.firstSeenAt, let lastActivityAt = pane.lastActivityAt else { return false }
        guard let cutoff = calendar.date(byAdding: .day, value: -staleDayThreshold, to: now) else { return false }
        return firstSeenAt <= cutoff && lastActivityAt <= cutoff
    }
}
