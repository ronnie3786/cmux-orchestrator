import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr alert notification sweeps", .serialized)
@MainActor
struct HerdrAlertNotificationSweepTests {
    @Test("Local pane reads withdraw exactly their delivered notifications")
    func localReadWithdrawsDeliveredNotifications() async throws {
        let suiteName = "HerdrAlertNotificationSweepTests.localRead.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let client = HerdrAPIClient(configuration: configuration, session: makeSession(UnreadAlertFleetURLProtocol.self))
        let paneID = MachineScopedID.compose(machineID: "m1", rawID: "w1:p1")
        let alertID = MachineScopedID.compose(machineID: "m1", rawID: "a1")

        try await model.refresh(machineID: "m1", using: client, expectedGeneration: model.connectionGeneration)

        let recorder = DeliveredNotificationRemovalRecorder()
        NotificationManager.removeDeliveredOverride = { alertIDs in recorder.record(alertIDs) }
        defer { NotificationManager.removeDeliveredOverride = nil }

        model.openPane(id: paneID)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while recorder.calls.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.calls == [Set([alertID])])
    }

    @Test("Remote-only reads still withdraw delivered notifications on refresh")
    func remoteOnlyReadStillSweepsOnRefresh() async throws {
        let suiteName = "HerdrAlertNotificationSweepTests.remoteRead.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let unreadClient = HerdrAPIClient(configuration: configuration, session: makeSession(UnreadAlertFleetURLProtocol.self))
        let readClient = HerdrAPIClient(configuration: configuration, session: makeSession(RemotelyReadAlertFleetURLProtocol.self))
        let alertID = MachineScopedID.compose(machineID: "m1", rawID: "a1")

        try await model.refresh(machineID: "m1", using: unreadClient, expectedGeneration: model.connectionGeneration)

        let recorder = DeliveredNotificationRemovalRecorder()
        NotificationManager.removeDeliveredOverride = { alertIDs in recorder.record(alertIDs) }
        defer { NotificationManager.removeDeliveredOverride = nil }

        try await model.refresh(machineID: "m1", using: readClient, expectedGeneration: model.connectionGeneration)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while recorder.calls.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.calls.contains { $0.contains(alertID) })
    }

    @Test("Stale done panes acknowledge remotely while idle panes remain a no-op")
    func acknowledgeUnreadAlertsPostsForStaleDone() async throws {
        await PaneReadRequestRecorder.shared.reset()
        let suiteName = "HerdrAlertNotificationSweepTests.staleDone.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let client = HerdrAPIClient(configuration: configuration, session: makeSession(StaleDoneFleetURLProtocol.self))
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        await model.refresh()

        let donePane = try #require(model.pane(id: "m1|w1:done"))
        let idlePane = try #require(model.pane(id: "m1|w1:idle"))
        model.acknowledgeUnreadAlerts(for: donePane)

        let donePath = "/api/v1/panes/w1:done/alerts/read"
        let idlePath = "/api/v1/panes/w1:idle/alerts/read"
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await PaneReadRequestRecorder.shared.paths()).contains(donePath), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        model.acknowledgeUnreadAlerts(for: idlePane)
        try await Task.sleep(for: .milliseconds(50))

        let paths = await PaneReadRequestRecorder.shared.paths()
        #expect(paths.contains(donePath))
        #expect(!paths.contains(idlePath))
    }

    @Test("Read acknowledgements queue until a machine reconnects")
    func remoteAcknowledgementWithoutClientQueuesAndRetriesWhenLive() async throws {
        await PaneReadRequestRecorder.shared.reset()
        let suiteName = "HerdrAlertNotificationSweepTests.queuedAck.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let seedClient = HerdrAPIClient(configuration: configuration, session: makeSession(UnreadAlertFleetURLProtocol.self))
        let recordingClient = HerdrAPIClient(configuration: configuration, session: makeSession(RecordingUnreadAlertFleetURLProtocol.self))
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        let paneID = MachineScopedID.compose(machineID: machine.id, rawID: "w1:p1")

        try await model.refresh(machineID: machine.id, using: seedClient, expectedGeneration: model.connectionGeneration)
        model.openPane(id: paneID)
        try await Task.sleep(for: .milliseconds(50))
        #expect((await PaneReadRequestRecorder.shared.paths()).isEmpty)

        model.clientFactory = { _ in recordingClient }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        await model.refresh()

        let expectedPath = "/api/v1/panes/w1:p1/alerts/read"
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await PaneReadRequestRecorder.shared.paths()).contains(expectedPath), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect((await PaneReadRequestRecorder.shared.paths()).contains(expectedPath))
    }
}

@MainActor
private final class DeliveredNotificationRemovalRecorder {
    private(set) var calls: [Set<String>] = []

    func record(_ alertIDs: Set<String>) {
        calls.append(alertIDs)
    }
}

private actor PaneReadRequestRecorder {
    static let shared = PaneReadRequestRecorder()
    private var recordedPaths: [String] = []

    func reset() { recordedPaths = [] }

    func record(_ request: URLRequest) {
        guard request.httpMethod == "POST" else { return }
        recordedPaths.append(request.url?.path ?? "")
    }

    func paths() -> [String] { recordedPaths }
}

private func makeSession(_ protocolClass: URLProtocol.Type) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return URLSession(configuration: configuration)
}

private class AlertFleetURLProtocol: URLProtocol, @unchecked Sendable {
    class var fleetResponseData: Data { Data() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    func respond(statusCode: Int = 200, data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UnreadAlertFleetURLProtocol: AlertFleetURLProtocol, @unchecked Sendable {
    override class var fleetResponseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"done","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"done","revision":1}]}],"alerts":[{"id":"a1","workspace_id":"w1","pane_id":"w1:p1","status":"done","title":"Ready","message":"","created_at":"2026-08-25T12:00:00Z","is_read":false}]}
            """.utf8
        )
    }

    override func startLoading() {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/workspaces"):
            respond(data: Self.fleetResponseData)
        case ("GET", "/api/v1/result-artifacts"):
            respond(data: Data("{\"ok\":true,\"artifacts\":[]}".utf8))
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
}

private final class RemotelyReadAlertFleetURLProtocol: AlertFleetURLProtocol, @unchecked Sendable {
    override class var fleetResponseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"done","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"done","revision":1}]}],"alerts":[{"id":"a1","workspace_id":"w1","pane_id":"w1:p1","status":"done","title":"Ready","message":"","created_at":"2026-08-25T12:00:00Z","is_read":true}]}
            """.utf8
        )
    }

    override func startLoading() {
        guard request.httpMethod == "GET", request.url?.path == "/api/v1/workspaces" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        respond(data: Self.fleetResponseData)
    }
}

private final class StaleDoneFleetURLProtocol: AlertFleetURLProtocol, @unchecked Sendable {
    override class var fleetResponseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":2,"tab_count":0,"active_tab_id":"","agent_status":"done","panes":[{"pane_id":"w1:done","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"done","revision":1},{"pane_id":"w1:idle","workspace_id":"w1","tab_id":"","focused":false,"agent_status":"idle","revision":1}]}],"alerts":[]}
            """.utf8
        )
    }

    override func startLoading() {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/workspaces"):
            respond(data: Self.fleetResponseData)
        case ("GET", "/api/v1/result-artifacts"):
            respond(data: Data("{\"ok\":true,\"artifacts\":[]}".utf8))
        case ("POST", _):
            let request = self.request
            Task { await PaneReadRequestRecorder.shared.record(request) }
            respond(data: Data("{\"ok\":true}".utf8))
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
}

private final class RecordingUnreadAlertFleetURLProtocol: AlertFleetURLProtocol, @unchecked Sendable {
    override func startLoading() {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/workspaces"):
            respond(data: UnreadAlertFleetURLProtocol.fleetResponseData)
        case ("GET", "/api/v1/result-artifacts"):
            respond(data: Data("{\"ok\":true,\"artifacts\":[]}".utf8))
        case ("POST", "/api/v1/panes/w1:p1/alerts/read"):
            let request = self.request
            Task { await PaneReadRequestRecorder.shared.record(request) }
            respond(data: Data("{\"ok\":true}".utf8))
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
}
