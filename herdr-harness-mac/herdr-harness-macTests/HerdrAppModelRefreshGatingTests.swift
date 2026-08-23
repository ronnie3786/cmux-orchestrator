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
}
