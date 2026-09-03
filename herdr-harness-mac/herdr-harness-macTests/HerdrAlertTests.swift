import Foundation
import Testing
@testable import herdr_harness_mac

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

    @Test("Auto-clear leaves alerts unchanged when there is no matching unread alert")
    func autoClearLeavesPanesWithoutMatchingUnreadAlertsUnchanged() throws {
        let suiteName = "HerdrAlertTests.autoClearSkips.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: "m1") }
        model.alerts = DemoData.alerts.map { $0.stamped(machineID: "m1") }

        let unreadPaneIDs = Set(
            model.alerts.lazy.filter { !$0.isRead }.map(\.scopedPaneID)
        )
        let pane = try #require(model.workspaces.flatMap(\.panes).first { !unreadPaneIDs.contains($0.id) })
        let alerts = model.alerts

        model.openPane(id: pane.id)

        #expect(model.alerts == alerts)
    }

    @Test("Opening a pane marks its alerts read immediately, before any network round trip")
    func openingPaneOptimisticallyMarksAlertsRead() throws {
        let suiteName = "HerdrAlertTests.optimisticAutoClear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: "m1") }
        model.alerts = DemoData.alerts.map { $0.stamped(machineID: "m1") }

        let alert = try #require(model.alerts.first { !$0.isRead })
        let pane = try #require(model.pane(id: alert.scopedPaneID))

        model.openPane(id: pane.id)

        #expect(model.alerts.first(where: { $0.id == alert.id })?.isRead == true)
    }

    @Test("Opening a pane without unread alerts still acknowledges it")
    func openingPaneWithoutUnreadAlertsAcknowledgesPane() async throws {
        await AlertReadOnOpenRequestRecorder.shared.reset()
        let suiteName = "HerdrAlertTests.acknowledgesNoUnread.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AlertReadOnOpenURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live

        let rawPane = HerdrPane(
            paneID: "w1:p1", terminalID: "w1:p1", workspaceID: "w1", tabID: "",
            focused: true, agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil,
            label: nil, title: nil, agent: nil, displayAgent: nil, terminalTitle: nil,
            terminalTitleStripped: nil
        )
        model.workspaces = [HerdrWorkspace(
            workspaceID: "w1", number: 1, label: "Workspace", focused: true,
            paneCount: 1, tabCount: 0, activeTabID: "", agentStatus: .idle, panes: [rawPane]
        ).stamped(machineID: machine.id)]
        model.alerts = []

        model.openPane(id: "m1|w1:p1")
        for _ in 0..<20 {
            if !(await AlertReadOnOpenRequestRecorder.shared.requests()).isEmpty { break }
            await Task.yield()
        }

        #expect(await AlertReadOnOpenRequestRecorder.shared.requests() == [
            .init(method: "POST", path: "/api/v1/panes/w1:p1/alerts/read"),
        ])
    }

    @Test("Stale done panes acknowledge once per episode; new activity re-arms the ack")
    func activeSessionEngagementDedupesStaleDoneByEpisode() async throws {
        await AlertReadOnOpenRequestRecorder.shared.reset()
        let suiteName = "HerdrAlertTests.activeEngagement.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AlertReadOnOpenURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live

        let rawPane = HerdrPane(
            paneID: "w1:p1", terminalID: "w1:p1", workspaceID: "w1", tabID: "",
            focused: true, agentStatus: .done, revision: 1, cwd: nil, foregroundCWD: nil,
            label: nil, title: nil, agent: nil, displayAgent: nil, terminalTitle: nil,
            terminalTitleStripped: nil
        )
        model.workspaces = [HerdrWorkspace(
            workspaceID: "w1", number: 1, label: "Workspace", focused: true,
            paneCount: 1, tabCount: 0, activeTabID: "", agentStatus: .done, panes: [rawPane]
        ).stamped(machineID: machine.id)]
        let pane = try #require(model.pane(id: "m1|w1:p1"))
        model.selectedPaneID = pane.id

        // This deliberately flips the old behavior: a stale done pane with no
        // locally unread alert self-heals with one acknowledgement.
        model.alerts = []
        model.acknowledgeUnreadAlerts(for: pane)
        for _ in 0..<20 {
            if !(await AlertReadOnOpenRequestRecorder.shared.requests()).isEmpty { break }
            await Task.yield()
        }
        #expect(await AlertReadOnOpenRequestRecorder.shared.requests() == [
            .init(method: "POST", path: "/api/v1/panes/w1:p1/alerts/read"),
        ])

        model.alerts = [HerdrAlert(
            id: "alert-1",
            workspaceID: "w1",
            paneID: pane.paneID,
            status: .done,
            title: "Ready",
            message: "",
            createdAt: "2026-08-26T12:00:00Z",
            isRead: false
        ).stamped(machineID: machine.id)]
        #expect(model.unreadPaneIDs == [pane.id])

        model.acknowledgeUnreadAlerts(for: pane)
        #expect(model.alerts[0].isRead)
        #expect(model.unreadPaneIDs.isEmpty)
        for _ in 0..<20 {
            if await AlertReadOnOpenRequestRecorder.shared.requests().count == 2 { break }
            await Task.yield()
        }
        #expect(await AlertReadOnOpenRequestRecorder.shared.requests().count == 2)

        // Repeated taps in the same done episode must not create more POSTs.
        model.acknowledgeUnreadAlerts(for: pane)
        for _ in 0..<5 { await Task.yield() }
        #expect(await AlertReadOnOpenRequestRecorder.shared.requests().count == 2)

        // A fresh done episode re-arms the dedupe instead of leaving it
        // permanently open or permanently closed.
        let updatedRawPane = HerdrPane(
            paneID: "w1:p1", terminalID: "w1:p1", workspaceID: "w1", tabID: "",
            focused: true, agentStatus: .done, revision: 1, cwd: nil, foregroundCWD: nil,
            label: nil, title: nil, agent: nil, displayAgent: nil, terminalTitle: nil,
            terminalTitleStripped: nil,
            lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        model.workspaces = [HerdrWorkspace(
            workspaceID: "w1", number: 1, label: "Workspace", focused: true,
            paneCount: 1, tabCount: 0, activeTabID: "", agentStatus: .done, panes: [updatedRawPane]
        ).stamped(machineID: machine.id)]
        let updatedPane = try #require(model.pane(id: "m1|w1:p1"))
        model.alerts = []
        model.acknowledgeUnreadAlerts(for: updatedPane)
        for _ in 0..<20 {
            if await AlertReadOnOpenRequestRecorder.shared.requests().count == 3 { break }
            await Task.yield()
        }
        #expect(await AlertReadOnOpenRequestRecorder.shared.requests().count == 3)
    }
}

private actor AlertReadOnOpenRequestRecorder {
    struct Request: Equatable {
        let method: String
        let path: String
    }

    static let shared = AlertReadOnOpenRequestRecorder()
    private var recordedRequests: [Request] = []

    func reset() { recordedRequests = [] }
    func record(_ request: URLRequest) {
        recordedRequests.append(.init(method: request.httpMethod ?? "", path: request.url?.path ?? ""))
    }
    func requests() -> [Request] { recordedRequests }
}

private final class AlertReadOnOpenURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Task { await AlertReadOnOpenRequestRecorder.shared.record(request) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
