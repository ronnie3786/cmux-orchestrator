import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Activity feed projection")
struct ActivityFeedTests {
    @Test("Current alert state overrides duplicate history and newest sorts first")
    func mergesCurrentStateOverHistory() throws {
        let historical = alert(
            id: "same",
            machineID: "m1",
            status: .blocked,
            createdAt: "2026-08-25T10:00:00Z",
            isRead: false
        )
        let current = alert(
            id: "same",
            machineID: "m1",
            status: .blocked,
            createdAt: "2026-08-25T10:00:00Z",
            isRead: true
        )
        let newer = alert(
            id: "newer",
            machineID: "m2",
            status: .done,
            createdAt: "2026-08-25T11:00:00Z",
            isRead: false
        )

        let merged = ActivityFeed.merged(current: [current], history: [historical, newer])

        #expect(merged.map(\.id) == [newer.id, current.id])
        #expect(try #require(merged.first(where: { $0.id == current.id })).isRead)
    }

    @Test("Days apply status and machine filters before grouping")
    func groupsFilteredDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let alerts = [
            alert(id: "m1-blocked", machineID: "m1", status: .blocked, createdAt: "2026-08-25T12:00:00Z"),
            alert(id: "m1-done", machineID: "m1", status: .done, createdAt: "2026-08-24T12:00:00Z"),
            alert(id: "m2-blocked", machineID: "m2", status: .blocked, createdAt: "2026-08-24T13:00:00Z"),
        ]

        let days = ActivityFeed.days(
            alerts: alerts,
            filter: .needsYou,
            machineID: "m1",
            calendar: calendar
        )

        #expect(days.count == 1)
        #expect(days.first?.alerts.map(\.rawID) == ["m1-blocked"])
    }

    private func alert(
        id: String,
        machineID: String,
        status: AgentStatus,
        createdAt: String,
        isRead: Bool = false
    ) -> HerdrAlert {
        HerdrAlert(
            id: id,
            workspaceID: "workspace",
            paneID: "workspace:\(id)",
            status: status,
            title: status.title,
            message: "",
            createdAt: createdAt,
            isRead: isRead
        )
        .stamped(machineID: machineID)
    }
}
