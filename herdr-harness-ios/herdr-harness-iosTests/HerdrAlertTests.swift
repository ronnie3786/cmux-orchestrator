import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Herdr alerts", .serialized)
@MainActor
struct HerdrAlertTests {
    @Test("Scoped pane ID resolves its matching demo pane")
    func scopedPaneIDResolvesDemoPane() {
        let alert = HerdrAlert(
            id: "alert-1",
            workspaceID: "workspace-1",
            paneID: "workspace-1:pane-1",
            status: .blocked,
            title: "Needs input",
            message: "",
            createdAt: "2026-08-25T12:00:00Z",
            isRead: false
        ).stamped(machineID: "machine-1")
        #expect(alert.scopedPaneID == MachineScopedID.compose(machineID: "machine-1", rawID: "workspace-1:pane-1"))

        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        let demoAlert = DemoData.alerts[0].stamped(machineID: "demo1")
        #expect(model.pane(id: demoAlert.scopedPaneID) != nil)
    }

    @Test("Auto-clear is skipped when a pane has no matching unread alert")
    func autoClearSkipsPanesWithoutMatchingUnreadAlerts() throws {
        let suiteName = "HerdrAlertTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: "m1") }
        model.alerts = DemoData.alerts.map { $0.stamped(machineID: "m1") }
        let pane = try #require(model.pane(id: "m1|w1:p1"))
        let alerts = model.alerts

        model.openPane(id: pane.id)

        #expect(model.alerts == alerts)
    }

    @Test("Opening a pane marks its alerts read immediately")
    func openingPaneMarksAlertsReadOptimistically() throws {
        let suiteName = "HerdrAlertTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: "m1") }
        model.alerts = DemoData.alerts.map { $0.stamped(machineID: "m1") }
        let alert = try #require(model.alerts.first(where: { !$0.isRead }))
        let pane = try #require(model.pane(id: alert.scopedPaneID))

        model.openPane(id: pane.id)

        #expect(model.alerts.first(where: { $0.id == alert.id })?.isRead == true)
    }
}
