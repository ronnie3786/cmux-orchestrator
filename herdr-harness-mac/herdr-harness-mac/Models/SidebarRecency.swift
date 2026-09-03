import Foundation

enum SidebarRecency: String, CaseIterable, Identifiable, Sendable {
    case today
    case last3Days
    case thisWeek
    case all
    case recents

    static let recentsLimit = 20

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .last3Days: "Last 3 days"
        case .thisWeek: "This week"
        case .all: "All"
        case .recents: "Recents"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.max"
        case .last3Days: "calendar.day.timeline.left"
        case .thisWeek: "calendar"
        case .all: "clock"
        case .recents: "clock.arrow.circlepath"
        }
    }

    func includes(_ pane: HerdrPane, now: Date, calendar: Calendar) -> Bool {
        // Recents is a ranking, not a predicate. Callers needing its top N use
        // `SidebarTree.recentChats`; this keeps the common filter API total.
        guard self != .all && self != .recents else { return true }
        guard let activity = pane.lastActivityAt ?? pane.firstSeenAt else { return false }
        switch self {
        case .today:
            return calendar.isDate(activity, inSameDayAs: now)
        case .last3Days:
            // Whole days, not a rolling 72 hours: "last 3 days" should mean
            // today plus the two days before it, so a chat does not drop out of
            // the list part-way through an afternoon.
            guard let startOfToday = calendar.dateInterval(of: .day, for: now)?.start,
                  let cutoff = calendar.date(byAdding: .day, value: -2, to: startOfToday)
            else { return false }
            return activity >= cutoff
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.contains(activity) == true
        case .all:
            return true
        case .recents:
            return true
        }
    }
}
