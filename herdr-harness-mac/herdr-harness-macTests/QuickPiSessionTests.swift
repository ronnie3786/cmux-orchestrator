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
    }
}

private final class QuickPiURLProtocol: URLProtocol {
    static let recorder = QuickPiRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body: String
        switch (request.httpMethod, url.path) {
        case ("POST", "/api/v1/quick-sessions/pi"):
            body = #"{"ok":true,"workspace_id":"w1","pane_id":"w1:p1","created_workspace":false,"pi_extension_attached":true}"#
        case ("GET", "/api/v1/workspaces"):
            body = #"{"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"working","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"working","revision":1}]}],"alerts":[]}"#
        default:
            body = #"{"ok":true}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class QuickPiRequestRecorder: @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let path: String
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded = []
    }

    func record(_ request: URLRequest) {
        let body = Self.bodyData(from: request)
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Request(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            body: body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        ))
    }

    func requests() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
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
