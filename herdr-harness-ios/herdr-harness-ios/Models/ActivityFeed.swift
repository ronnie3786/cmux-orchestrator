import Foundation

enum ActivityFeedFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case needsYou
    case completed

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .needsYou: "Needs you"
        case .completed: "Completed"
        }
    }

    func includes(_ alert: HerdrAlert) -> Bool {
        switch self {
        case .all: true
        case .needsYou: alert.status == .blocked
        case .completed: alert.status == .done
        }
    }
}

struct ActivityFeedDay: Equatable, Identifiable, Sendable {
    let date: Date
    let alerts: [HerdrAlert]

    var id: Date { date }
}

enum ActivityFeed {
    static func merged(current: [HerdrAlert], history: [HerdrAlert]) -> [HerdrAlert] {
        var byID: [String: HerdrAlert] = [:]
        for alert in history {
            byID[alert.id] = alert
        }
        // Current fleet state wins because a just-acknowledged alert can be
        // newer than the last explicit history fetch.
        for alert in current {
            byID[alert.id] = alert
        }
        return byID.values.sorted(by: newestFirst)
    }

    static func days(
        alerts: [HerdrAlert],
        filter: ActivityFeedFilter,
        machineID: String? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ActivityFeedDay] {
        let filtered = alerts.filter { alert in
            filter.includes(alert) && (machineID == nil || alert.machineID == machineID)
        }
        let grouped = Dictionary(grouping: filtered) { alert in
            calendar.startOfDay(for: alert.createdDate ?? .distantPast)
        }
        return grouped
            .map { date, alerts in
                ActivityFeedDay(date: date, alerts: alerts.sorted(by: newestFirst))
            }
            .sorted { $0.date > $1.date }
    }

    private static func newestFirst(_ lhs: HerdrAlert, _ rhs: HerdrAlert) -> Bool {
        switch (lhs.createdDate, rhs.createdDate) {
        case let (left?, right?):
            if left != right { return left > right }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return lhs.id > rhs.id
    }
}
