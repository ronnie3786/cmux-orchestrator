import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Quick Pi session routing", .serialized)
@MainActor
struct QuickPiSessionTests {
    @Test("Sends an explicit workspace and opens the machine-scoped pane")
    func routesCreatedPaneToTargetMachine() async throws {
        QuickPiURLProtocol.recorder.reset()
        let suiteName = "QuickPiSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machine = HerdrMachine(id: "machine-2", name: "Work Mac", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [QuickPiURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live

        await model.createQuickPiSession(machineID: machine.id, workspaceID: "w1")

        #expect(model.selectedPaneID == "machine-2|w1:p1")
        let request = try #require(QuickPiURLProtocol.recorder.requests().first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/quick-sessions/pi")
        #expect(request.body.contains(#""workspaceId":"w1""#))
        #expect(request.body.contains(#""requestId":""#))
        #expect(model.quickPiSessionMachineIDs.isEmpty)
        #expect(model.toastMessage == "pi session ready")
    }

    @Test("Retries one transient transport failure with the same request ID and suppresses another tap")
    func retriesIdempotentlyAndSuppressesDuplicateTap() async throws {
        QuickPiURLProtocol.recorder.reset(transientFailures: 1)
        let suiteName = "QuickPiSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machine = HerdrMachine(id: "machine-2", name: "Work Mac", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [QuickPiURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live

        let first = Task { @MainActor in
            await model.createQuickPiSession(machineID: machine.id)
        }
        while !model.isCreatingQuickPiSession(machineID: machine.id) {
            await Task.yield()
        }
        await model.createQuickPiSession(machineID: machine.id)
        await first.value

        let posts = QuickPiURLProtocol.recorder.requests().filter {
            $0.method == "POST" && $0.path == "/api/v1/quick-sessions/pi"
        }
        #expect(posts.count == 2)
        let requestIDs = try posts.map { request in
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
            )
            return try #require(object["requestId"] as? String)
        }
        #expect(Set(requestIDs).count == 1)
        #expect(!posts[0].body.contains("workspaceId"))
        #expect(model.selectedPaneID == "machine-2|w1:p1")
    }

    @Test("Concurrent machines retain delayed routes and select the newest request")
    func concurrentMachinesResolveDelayedTopologyDeterministically() async throws {
        let firstPort = 9_101
        let secondPort = 9_102
        QuickPiURLProtocol.recorder.reset(fixtures: [
            firstPort: QuickPiMachineFixture(
                workspaceID: "w-first",
                tabID: "w-first:t1",
                paneID: "w-first:p1",
                postDelay: 0.15,
                topologyAvailable: false
            ),
            secondPort: QuickPiMachineFixture(
                workspaceID: "w-second",
                tabID: "w-second:t1",
                paneID: "w-second:p1",
                topologyAvailable: false
            ),
        ])
        let suiteName = "QuickPiSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstMachine = HerdrMachine(
            id: "machine-first",
            name: "First Mac",
            urlString: "http://localhost:\(firstPort)"
        )
        let secondMachine = HerdrMachine(
            id: "machine-second",
            name: "Second Mac",
            urlString: "http://localhost:\(secondPort)"
        )
        let firstConfiguration = try #require(
            ServerConfiguration(urlString: firstMachine.urlString, token: "test")
        )
        let secondConfiguration = try #require(
            ServerConfiguration(urlString: secondMachine.urlString, token: "test")
        )
        let firstClient = makeQuickPiClient(configuration: firstConfiguration)
        let secondClient = makeQuickPiClient(configuration: secondConfiguration)
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [firstMachine, secondMachine]
        model.clientFactory = { configuration in
            configuration.baseURL.port == firstPort ? firstClient : secondClient
        }
        for machine in model.machines {
            model.prepareRuntime(for: machine, generation: model.connectionGeneration)
            model.machineStates[machine.id] = .live
        }

        let firstRequest = Task { @MainActor in
            await model.createQuickPiSession(machineID: firstMachine.id)
        }
        while !model.isCreatingQuickPiSession(machineID: firstMachine.id) {
            await Task.yield()
        }
        let secondRequest = Task { @MainActor in
            await model.createQuickPiSession(machineID: secondMachine.id)
        }
        await firstRequest.value
        await secondRequest.value

        // Both POSTs have returned, but neither pane exists in the fetched
        // topology yet. The first response deliberately arrives last.
        #expect(model.selectedPaneID == nil)

        QuickPiURLProtocol.recorder.setTopologyAvailable(port: firstPort)
        try await model.refresh(
            machineID: firstMachine.id,
            using: firstClient,
            showSpinner: false,
            expectedGeneration: model.connectionGeneration
        )
        // The older request must not steal selection just because its machine
        // reports topology first.
        #expect(model.selectedPaneID == nil)

        QuickPiURLProtocol.recorder.setTopologyAvailable(port: secondPort)
        try await model.refresh(
            machineID: secondMachine.id,
            using: secondClient,
            showSpinner: false,
            expectedGeneration: model.connectionGeneration
        )
        #expect(model.selectedPaneID == "machine-second|w-second:p1")
        #expect(model.selectedWorkspaceID == "machine-second|w-second")
    }
}

private func makeQuickPiClient(configuration: ServerConfiguration) -> HerdrAPIClient {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [QuickPiURLProtocol.self]
    return HerdrAPIClient(
        configuration: configuration,
        session: URLSession(configuration: sessionConfiguration)
    )
}

private struct QuickPiMachineFixture: Sendable {
    let workspaceID: String
    let tabID: String
    let paneID: String
    let postDelay: TimeInterval
    var topologyAvailable: Bool

    init(
        workspaceID: String,
        tabID: String,
        paneID: String,
        postDelay: TimeInterval = 0,
        topologyAvailable: Bool
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.postDelay = postDelay
        self.topologyAvailable = topologyAvailable
    }
}

private final class QuickPiURLProtocol: URLProtocol {
    static let recorder = QuickPiRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Self.recorder.record(request)
        if recorded.method == "POST",
           recorded.path == "/api/v1/quick-sessions/pi",
           Self.recorder.consumeTransientFailure() {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let fixture = url.port.flatMap(Self.recorder.fixture(port:))

        let body: String
        switch (request.httpMethod, url.path) {
        case ("POST", "/api/v1/quick-sessions/pi"):
            if let delay = fixture?.postDelay, delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(recorded.body.utf8))) as? [String: Any]
            let requestID = object?["requestId"] as? String ?? ""
            let payload: [String: Any] = [
                "ok": true,
                "workspace_id": fixture?.workspaceID ?? "w1",
                "tab_id": fixture?.tabID ?? "w1:t1",
                "pane_id": fixture?.paneID ?? "w1:p1",
                "created_workspace": false,
                "created_tab": false,
                "created_pane": true,
                "pi_extension_attached": true,
                "request_id": requestID,
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload)
            body = data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"ok":false}"#
        case ("GET", "/api/v1/workspaces"):
            if let fixture {
                body = fixture.topologyAvailable
                    ? Self.workspaceBody(fixture: fixture)
                    : #"{"ok":true,"workspaces":[],"alerts":[]}"#
            } else {
                body = #"{"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Random","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"working","tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"One-off Tasks","focused":true,"pane_count":1,"agent_status":"working"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"working","revision":1}]}],"alerts":[]}"#
            }
        default:
            body = #"{"ok":true}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func workspaceBody(fixture: QuickPiMachineFixture) -> String {
        let payload: [String: Any] = [
            "ok": true,
            "workspaces": [[
                "workspace_id": fixture.workspaceID,
                "number": 1,
                "label": "Random",
                "focused": true,
                "pane_count": 1,
                "tab_count": 1,
                "active_tab_id": fixture.tabID,
                "agent_status": "working",
                "tabs": [[
                    "tab_id": fixture.tabID,
                    "workspace_id": fixture.workspaceID,
                    "number": 1,
                    "label": "One-off Tasks",
                    "focused": true,
                    "pane_count": 1,
                    "agent_status": "working",
                ]],
                "panes": [[
                    "pane_id": fixture.paneID,
                    "workspace_id": fixture.workspaceID,
                    "tab_id": fixture.tabID,
                    "focused": true,
                    "agent_status": "working",
                    "revision": 1,
                ]],
            ]],
            "alerts": [],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return #"{"ok":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class QuickPiRequestRecorder: @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let path: String
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var transientFailuresRemaining = 0
    private var fixtures: [Int: QuickPiMachineFixture] = [:]

    func reset(
        transientFailures: Int = 0,
        fixtures: [Int: QuickPiMachineFixture] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        recorded = []
        transientFailuresRemaining = transientFailures
        self.fixtures = fixtures
    }

    func record(_ request: URLRequest) -> Request {
        let body = Self.bodyData(from: request)
        let value = Request(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            body: body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        )
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
        return value
    }

    func consumeTransientFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard transientFailuresRemaining > 0 else { return false }
        transientFailuresRemaining -= 1
        return true
    }

    func requests() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func fixture(port: Int) -> QuickPiMachineFixture? {
        lock.lock()
        defer { lock.unlock() }
        return fixtures[port]
    }

    func setTopologyAvailable(port: Int) {
        lock.lock()
        defer { lock.unlock() }
        fixtures[port]?.topologyAvailable = true
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
