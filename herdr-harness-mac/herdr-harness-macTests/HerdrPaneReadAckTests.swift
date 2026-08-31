import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr pane read acknowledgements", .serialized)
@MainActor
struct HerdrPaneReadAckTests {
    @Test("A refresh during an in-flight acknowledgement keeps the pane read")
    func refreshDuringInFlightAcknowledgementKeepsPaneRead() async throws {
        let suiteName = "HerdrPaneReadAckTests.inFlight.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [InFlightPaneReadAcknowledgementURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        let paneID = MachineScopedID.compose(machineID: machine.id, rawID: "w1:p1")

        try await model.refresh(machineID: machine.id, using: client, expectedGeneration: model.connectionGeneration)
        #expect(model.unreadPaneIDs == [paneID])

        model.openPane(id: paneID)
        #expect(model.unreadPaneIDs.isEmpty)

        try await model.refresh(machineID: machine.id, using: client, expectedGeneration: model.connectionGeneration)
        #expect(model.unreadPaneIDs.isEmpty)

        for _ in 0..<5 { await Task.yield() }
    }

    @Test("A failed acknowledgement is retried before giving up")
    func failedAcknowledgementIsRetriedBeforeGivingUp() async throws {
        await PaneReadAcknowledgementRequestRecorder.shared.reset()
        RetryingPaneReadAcknowledgementURLProtocol.reset()
        let suiteName = "HerdrPaneReadAckTests.retries.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RetryingPaneReadAcknowledgementURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        let paneID = MachineScopedID.compose(machineID: machine.id, rawID: "w1:p1")

        try await model.refresh(machineID: machine.id, using: client, expectedGeneration: model.connectionGeneration)
        #expect(model.unreadPaneIDs == [paneID])

        model.openPane(id: paneID)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while await PaneReadAcknowledgementRequestRecorder.shared.requests().count < 3,
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await PaneReadAcknowledgementRequestRecorder.shared.requests().count == 3)
        let alertID = MachineScopedID.compose(machineID: machine.id, rawID: "a1")
        #expect(model.alerts.first(where: { $0.id == alertID })?.isRead == true)
    }
}

private actor PaneReadAcknowledgementRequestRecorder {
    struct Request: Equatable {
        let method: String
        let path: String
    }

    static let shared = PaneReadAcknowledgementRequestRecorder()
    private var recordedRequests: [Request] = []

    func reset() { recordedRequests = [] }
    func record(_ request: URLRequest) -> Int {
        recordedRequests.append(.init(method: request.httpMethod ?? "", path: request.url?.path ?? ""))
        return recordedRequests.count
    }
    func requests() -> [Request] { recordedRequests }
}

private class PaneReadAcknowledgementURLProtocol: URLProtocol, @unchecked Sendable {
    class var fleetResponseData: Data {
        Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"done","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"done","revision":1}]}],"alerts":[{"id":"a1","workspace_id":"w1","pane_id":"w1:p1","status":"done","title":"Ready","message":"","created_at":"2026-08-25T12:00:00Z","is_read":false}]}
            """.utf8
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    func respondWithFleet() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.fleetResponseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    func respondWithReadSuccess() {
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

private final class InFlightPaneReadAcknowledgementURLProtocol: PaneReadAcknowledgementURLProtocol, @unchecked Sendable {
    override func startLoading() {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/workspaces"):
            respondWithFleet()
        case ("POST", "/api/v1/panes/w1:p1/alerts/read"):
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.respondWithReadSuccess()
            }
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
}

private final class RetryingPaneReadAcknowledgementURLProtocol: PaneReadAcknowledgementURLProtocol, @unchecked Sendable {
    private static let attempts = PaneReadAcknowledgementAttemptCounter()

    static func reset() {
        attempts.reset()
    }

    override func startLoading() {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/workspaces"):
            respondWithFleet()
        case ("POST", "/api/v1/panes/w1:p1/alerts/read"):
            let request = self.request
            Task { await PaneReadAcknowledgementRequestRecorder.shared.record(request) }
            if Self.attempts.recordAttempt() < 3 {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                respondWithReadSuccess()
            }
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
}

private final class PaneReadAcknowledgementAttemptCounter: @unchecked Sendable {
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
