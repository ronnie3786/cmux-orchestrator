import Foundation

enum SidebarRecency: String, CaseIterable, Identifiable, Sendable {
    case today
    case thisWeek
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .thisWeek: "This week"
        case .all: "All"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.max"
        case .thisWeek: "calendar"
        case .all: "clock"
        }
    }

    func includes(_ pane: HerdrPane, now: Date, calendar: Calendar) -> Bool {
        guard self != .all else { return true }
        guard let activity = pane.lastActivityAt ?? pane.firstSeenAt else { return false }
        switch self {
        case .today:
            return calendar.isDate(activity, inSameDayAs: now)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.contains(activity) == true
        case .all:
            return true
        }
    }
}
