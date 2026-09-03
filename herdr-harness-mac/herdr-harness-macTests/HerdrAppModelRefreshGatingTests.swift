import Foundation
import Observation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr app model refresh gating", .serialized)
@MainActor
struct HerdrAppModelRefreshGatingTests {
    @Test("Only changed fleet snapshots replace observed workspaces")
    func equalSnapshotsDoNotInvalidateWorkspaces() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests") }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let unchangedClient = HerdrAPIClient(configuration: configuration, session: session(StableFleetURLProtocol.self))
        let changedClient = HerdrAPIClient(configuration: configuration, session: session(ChangedFleetURLProtocol.self))

        let firstRefresh = ObservationRecorder()
        withObservationTracking { _ = model.workspaces } onChange: {
            Task { await firstRefresh.recordChange() }
        }
        try await model.refresh(machineID: "m1", using: unchangedClient, expectedGeneration: model.connectionGeneration)
        #expect(await changed(firstRefresh))

        let equalRefresh = ObservationRecorder()
        withObservationTracking { _ = model.workspaces } onChange: {
            Task { await equalRefresh.recordChange() }
        }
        try await model.refresh(machineID: "m1", using: unchangedClient, expectedGeneration: model.connectionGeneration)
        await Task.yield()
        #expect(!(await equalRefresh.changed()))

        let changedRefresh = ObservationRecorder()
        withObservationTracking { _ = model.workspaces } onChange: {
            Task { await changedRefresh.recordChange() }
        }
        try await model.refresh(machineID: "m1", using: changedClient, expectedGeneration: model.connectionGeneration)
        #expect(await changed(changedRefresh))
    }

    @Test("Alternating fleet refreshes preserve workspace order and gate equal snapshots")
    func alternatingFleetRefreshesPreserveWorkspaceOrder() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests.order"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.order")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.order") }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let clientA = HerdrAPIClient(configuration: configuration, session: session(MachineAFleetURLProtocol.self))
        let clientB = HerdrAPIClient(configuration: configuration, session: session(MachineBFleetURLProtocol.self))

        try await model.refresh(machineID: "a", using: clientA, expectedGeneration: model.connectionGeneration)
        try await model.refresh(machineID: "b", using: clientB, expectedGeneration: model.connectionGeneration)
        let expectedOrder = ["a|a1", "a|a2", "b|b1"]
        #expect(model.workspaces.map(\.id) == expectedOrder)

        let recorder = ObservationRecorder()
        withObservationTracking { _ = model.workspaces } onChange: {
            Task { await recorder.recordChange() }
        }
        try await model.refresh(machineID: "a", using: clientA, expectedGeneration: model.connectionGeneration)
        await Task.yield()

        #expect(model.workspaces.map(\.id) == expectedOrder)
        #expect(!(await recorder.changed()))
    }

    @Test("Equal fleet snapshots keep last updated stable but tick completed refreshes")
    func equalSnapshotsGateLastUpdatedButAdvanceRefreshTick() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests.lastUpdated"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.lastUpdated")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.lastUpdated") }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let client = HerdrAPIClient(configuration: configuration, session: session(StableFleetURLProtocol.self))

        try await model.refresh(machineID: "m1", using: client, expectedGeneration: model.connectionGeneration)
        let lastUpdated = try #require(model.lastUpdated)
        let refreshTick = model.refreshTick
        try await model.refresh(machineID: "m1", using: client, expectedGeneration: model.connectionGeneration)

        #expect(model.lastUpdated == lastUpdated)
        #expect(model.refreshTick == refreshTick + 1)
    }

    @Test("Unchanged fleet refresh clears a stale error message")
    func unchangedRefreshClearsStaleErrorMessage() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests.staleError"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.staleError")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.staleError") }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let client = HerdrAPIClient(configuration: configuration, session: session(StableFleetURLProtocol.self))

        try await model.refresh(machineID: "m1", using: client, expectedGeneration: model.connectionGeneration)
        model.errorMessage = "some stale error"
        try await model.refresh(machineID: "m1", using: client, expectedGeneration: model.connectionGeneration)

        #expect(model.errorMessage == nil)
    }

    @Test("Fleet refresh adopts the server workspace order")
    func refreshAdoptsFreshWorkspaceOrder() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests.workspaceOrder"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.workspaceOrder")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.workspaceOrder") }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let firstClient = HerdrAPIClient(
            configuration: configuration,
            session: session(WorkspaceOrderFirstFleetURLProtocol.self)
        )
        let secondClient = HerdrAPIClient(
            configuration: configuration,
            session: session(WorkspaceOrderSecondFleetURLProtocol.self)
        )

        try await model.refresh(machineID: "m1", using: firstClient, expectedGeneration: model.connectionGeneration)
        try await model.refresh(machineID: "m1", using: secondClient, expectedGeneration: model.connectionGeneration)

        #expect(model.workspaces.filter { $0.machineID == "m1" }.map(\.workspaceID) == ["w2", "w1"])
    }

    @Test("Fleet refresh adopts newest-first server alert order")
    func refreshAdoptsFreshAlertOrder() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests.alertOrder"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.alertOrder")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.alertOrder") }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let firstClient = HerdrAPIClient(
            configuration: configuration,
            session: session(AlertOrderFirstFleetURLProtocol.self)
        )
        let secondClient = HerdrAPIClient(
            configuration: configuration,
            session: session(AlertOrderSecondFleetURLProtocol.self)
        )

        try await model.refresh(machineID: "m1", using: firstClient, expectedGeneration: model.connectionGeneration)
        try await model.refresh(machineID: "m1", using: secondClient, expectedGeneration: model.connectionGeneration)

        #expect(model.alerts.filter { $0.machineID == "m1" }.map(\.rawID) == ["a2", "a1"])
    }

    @Test("Fleet refresh backoff widens for boring streams and resets for fresh activity")
    func fleetRefreshBackoffResetsForInteractionChangesAndQuietBursts() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests.backoff"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.backoff")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.backoff") }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let stableClient = HerdrAPIClient(configuration: configuration, session: session(StableFleetURLProtocol.self))
        let changedClient = HerdrAPIClient(configuration: configuration, session: session(ChangedFleetURLProtocol.self))
        model.fleetRefreshBaseWindow = .milliseconds(1)
        model.fleetRefreshBackoffWindow = .milliseconds(10)

        for _ in 0..<6 {
            try await model.refresh(machineID: "m1", using: stableClient, expectedGeneration: model.connectionGeneration)
        }
        #expect(model.currentFleetRefreshWindow(forMachine: "m1") == .milliseconds(10))

        model.noteUserInteraction(machineID: "m1")
        #expect(model.currentFleetRefreshWindow(forMachine: "m1") == .milliseconds(1))

        for _ in 0..<5 {
            try await model.refresh(machineID: "m1", using: stableClient, expectedGeneration: model.connectionGeneration)
        }
        #expect(model.currentFleetRefreshWindow(forMachine: "m1") == .milliseconds(10))
        try await model.refresh(machineID: "m1", using: changedClient, expectedGeneration: model.connectionGeneration)
        #expect(model.currentFleetRefreshWindow(forMachine: "m1") == .milliseconds(1))

        for _ in 0..<5 {
            try await model.refresh(machineID: "m1", using: changedClient, expectedGeneration: model.connectionGeneration)
        }
        #expect(model.currentFleetRefreshWindow(forMachine: "m1") == .milliseconds(10))
        model.fleetRefreshQuietWindow = .milliseconds(1)
        model.setLastRelevantEventAt(ContinuousClock.now.advanced(by: .seconds(-5)), for: "m1")
        model.noteFleetRefreshNeeded(
            machineID: "m1",
            client: changedClient,
            expectedGeneration: model.connectionGeneration
        )
        #expect(model.currentFleetRefreshWindow(forMachine: "m1") == .milliseconds(1))
    }

    @Test("Pane index follows added, removed, and machine-removed panes")
    func paneIndexFollowsFleetChanges() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests.paneIndex"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.paneIndex")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.paneIndex") }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let initialClient = HerdrAPIClient(configuration: configuration, session: session(StableFleetURLProtocol.self))
        let addedClient = HerdrAPIClient(configuration: configuration, session: session(AddedPaneFleetURLProtocol.self))
        let removedClient = HerdrAPIClient(configuration: configuration, session: session(RemovedPaneFleetURLProtocol.self))
        let otherMachineClient = HerdrAPIClient(configuration: configuration, session: session(MachineBFleetURLProtocol.self))

        try await model.refresh(machineID: "m1", using: initialClient, expectedGeneration: model.connectionGeneration)
        try await model.refresh(machineID: "m1", using: addedClient, expectedGeneration: model.connectionGeneration)
        #expect(model.pane(id: "m1|w1:p2")?.revision == 2)

        try await model.refresh(machineID: "m1", using: removedClient, expectedGeneration: model.connectionGeneration)
        #expect(model.pane(id: "m1|w1:p2") == nil)
        #expect(model.pane(id: "m1|w1:p1")?.revision == 3)

        try await model.refresh(machineID: "m2", using: otherMachineClient, expectedGeneration: model.connectionGeneration)
        #expect(model.pane(id: "m2|b1:p1") != nil)
        model.removeMachine(id: "m1")
        #expect(model.pane(id: "m1|w1:p1") == nil)
        #expect(model.pane(id: "m2|b1:p1") != nil)
    }

    @Test("Fleet refresh retries after a transient failure and recovers to live")
    func fleetRefreshRetriesAfterTransientFailure() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrAppModelRefreshGatingTests.retry"))
        defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.retry")
        defer { defaults.removePersistentDomain(forName: "HerdrAppModelRefreshGatingTests.retry") }

        FlakyFleetURLProtocol.reset()
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let client = HerdrAPIClient(configuration: configuration, session: session(FlakyFleetURLProtocol.self))
        model.fleetRefreshRetryBase = .milliseconds(10)

        model.noteFleetRefreshNeeded(
            machineID: "m1",
            client: client,
            expectedGeneration: model.connectionGeneration
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while model.connectionState(forMachine: "m1") != .live, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.connectionState(forMachine: "m1") == .live)
        #expect(model.workspaces.contains { $0.workspaceID == "w1" })
        let workspace = try #require(model.workspaces.first { $0.workspaceID == "w1" })
        #expect(workspace.machineID == "m1")
    }

    @Test("Post-ready result refresh closes the initial list-to-stream gap")
    func postReadyResultRefreshRecoversGapArtifact() async throws {
        let suiteName = "HerdrAppModelRefreshGatingTests.resultGap"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ResultArtifactGapURLProtocol.reset()
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let configuration = try #require(
            ServerConfiguration(urlString: "http://localhost:9092", token: "test")
        )
        let client = HerdrAPIClient(
            configuration: configuration,
            session: session(ResultArtifactGapURLProtocol.self)
        )

        // The canonical list taken before SSE subscription is empty.
        try await model.refresh(
            machineID: "m1",
            using: client,
            expectedGeneration: model.connectionGeneration
        )
        #expect(model.resultArtifacts.isEmpty)

        // A result commits in the gap and the cursorless stream starts after
        // its event. The mandatory list taken on `ready` recovers it.
        try await model.refreshResultArtifactsAfterEventStreamReady(
            machineID: "m1",
            using: client,
            expectedGeneration: model.connectionGeneration
        )

        #expect(ResultArtifactGapURLProtocol.resultListRequestCount == 2)
        #expect(model.resultArtifacts.map(\.rawID) == ["art_0123456789abcdef01234567"])
    }

    private func session(_ protocolClass: URLProtocol.Type) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }

    private func changed(_ recorder: ObservationRecorder) async -> Bool {
        for _ in 0..<20 {
            if await recorder.changed() { return true }
            await Task.yield()
        }
        return false
    }

}

private actor ObservationRecorder {
    private var didChange = false

    func recordChange() { didChange = true }
    func changed() -> Bool { didChange }
}

private class FleetURLProtocol: URLProtocol {
    class var responseData: Data { Data() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: type(of: self).responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class StableFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"idle","revision":1}]}],"alerts":[]}
            """.utf8
        )
    }
}

private final class ChangedFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"working","revision":2}]}],"alerts":[]}
            """.utf8
        )
    }
}

private final class WorkspaceOrderFirstFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace one","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"idle","revision":1}]},{"workspace_id":"w2","number":2,"label":"Workspace two","focused":false,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"","focused":false,"agent_status":"idle","revision":1}]}],"alerts":[]}
            """.utf8
        )
    }
}

private final class WorkspaceOrderSecondFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w2","number":2,"label":"Workspace two","focused":false,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"","focused":false,"agent_status":"idle","revision":2}]},{"workspace_id":"w1","number":1,"label":"Workspace one","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"idle","revision":2}]}],"alerts":[]}
            """.utf8
        )
    }
}

private final class AlertOrderFirstFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[],"alerts":[{"id":"a1","workspace_id":"w1","pane_id":"w1:p1","status":"blocked","title":"First alert","message":"Older alert","created_at":"2026-08-25T12:00:00Z","is_read":false}]}
            """.utf8
        )
    }
}

private final class AlertOrderSecondFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[],"alerts":[{"id":"a2","workspace_id":"w1","pane_id":"w1:p2","status":"blocked","title":"Second alert","message":"Newer alert","created_at":"2026-08-25T12:01:00Z","is_read":false},{"id":"a1","workspace_id":"w1","pane_id":"w1:p1","status":"blocked","title":"First alert","message":"Older alert","created_at":"2026-08-25T12:00:00Z","is_read":false}]}
            """.utf8
        )
    }
}

private final class MachineAFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"a1","number":1,"label":"A one","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"a1:p1","workspace_id":"a1","tab_id":"","focused":true,"agent_status":"idle","revision":1}]},{"workspace_id":"a2","number":2,"label":"A two","focused":false,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"a2:p1","workspace_id":"a2","tab_id":"","focused":false,"agent_status":"idle","revision":1}]}],"alerts":[]}
            """.utf8
        )
    }
}

private final class MachineBFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"b1","number":1,"label":"B one","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"b1:p1","workspace_id":"b1","tab_id":"","focused":true,"agent_status":"idle","revision":1}]}],"alerts":[]}
            """.utf8
        )
    }
}

private final class AddedPaneFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":2,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"idle","revision":1},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"","focused":false,"agent_status":"idle","revision":2}]}],"alerts":[]}
            """.utf8
        )
    }
}

private final class RemovedPaneFleetURLProtocol: FleetURLProtocol {
    override class var responseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"idle","revision":3}]}],"alerts":[]}
            """.utf8
        )
    }
}

private final class ResultArtifactGapURLProtocol: FleetURLProtocol {
    private static let listRequests = FlakyFleetAttemptCounter()

    static var resultListRequestCount: Int { listRequests.currentCount() }

    static func reset() {
        listRequests.reset()
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let data: Data
        if url.path == "/api/v1/result-artifacts" {
            let attempt = Self.listRequests.recordAttempt()
            data = Data(
                (attempt == 1
                    ? #"{"ok":true,"artifacts":[]}"#
                    : #"{"ok":true,"artifacts":[{"id":"art_0123456789abcdef01234567","originType":"agent_run","originId":"agr_012345abcdef","sessionId":"session-gap","kind":"link","title":"Recovered result","filename":null,"contentType":null,"byteSize":null,"createdAt":"2026-09-02T20:00:00.000Z","url":"https://example.com/result"}]}"#
                ).utf8
            )
        } else {
            data = StableFleetURLProtocol.responseData
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class FlakyFleetURLProtocol: FleetURLProtocol {
    private static let attempts = FlakyFleetAttemptCounter()

    override class var responseData: Data {
        StableFleetURLProtocol.responseData
    }

    static func reset() {
        Self.attempts.reset()
    }

    override func startLoading() {
        if Self.attempts.recordAttempt() == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        super.startLoading()
    }
}

private final class FlakyFleetAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
    }

    func recordAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    func currentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
