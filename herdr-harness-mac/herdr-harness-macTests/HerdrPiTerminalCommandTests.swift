import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Herdr Pi terminal commands", .serialized)
struct HerdrPiTerminalCommandTests {
    @Test("Pane session mutations are disabled while Pi is compacting")
    func paneMenuCompactionPolicy() {
        #expect(PaneActionsMenu.piSessionMutationsEnabled(canControl: true, isCompacting: false))
        #expect(!PaneActionsMenu.piSessionMutationsEnabled(canControl: true, isCompacting: true))
        #expect(!PaneActionsMenu.piSessionMutationsEnabled(canControl: false, isCompacting: false))
    }

    @Test("Semantic Pi compaction uses the native command endpoint")
    func compactUsesSemanticCommand() async throws {
        PiTerminalCommandURLProtocol.recorder.reset()
        let fixture = try makeFixture(supportsSemanticCompaction: true)

        await fixture.model.compactPiChat(in: fixture.pane)

        let requests = PiTerminalCommandURLProtocol.recorder.requests()
        #expect(requests.map(\.path) == ["/api/v1/panes/w1:p1/pi/compact"])
        #expect(fixture.model.toastMessage == "compaction started")
    }

    @Test("Legacy Pi panes retain the terminal slash-command fallback")
    func compactSendsSlashCommandForLegacyPane() async throws {
        PiTerminalCommandURLProtocol.recorder.reset()
        let fixture = try makeFixture(supportsSemanticCompaction: false)

        await fixture.model.compactPiChat(in: fixture.pane)

        let requests = PiTerminalCommandURLProtocol.recorder.requests()
        #expect(requests.map(\.path) == [
            "/api/v1/panes/w1:p1/send-text",
            "/api/v1/panes/w1:p1/send-keys",
        ])
        #expect(requests.first?.body["text"] as? String == "/compact")
        #expect(requests.last?.body["keys"] as? [String] == ["enter"])
        #expect(fixture.model.toastMessage == "compaction started")
    }

    private func makeFixture(
        supportsSemanticCompaction: Bool
    ) throws -> (model: HerdrAppModel, pane: HerdrPane) {
        let suiteName = "HerdrPiTerminalCommandTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let machine = HerdrMachine(
            id: "m1",
            name: "Work Mac",
            urlString: "http://localhost:9092"
        )
        let configuration = try #require(
            ServerConfiguration(urlString: machine.urlString, token: "test")
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PiTerminalCommandURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live

        let piSemantic: PiSemanticCapability? = if supportsSemanticCompaction {
            try JSONDecoder().decode(
                PiSemanticCapability.self,
                from: Data(
                    """
                    {
                      "available":true,"connected":true,"protocolVersion":1,
                      "capabilities":{"compact":true}
                    }
                    """.utf8
                )
            )
        } else {
            nil
        }

        let rawPane = HerdrPane(
            paneID: "w1:p1",
            terminalID: "w1:p1",
            workspaceID: "w1",
            tabID: "",
            focused: true,
            agentStatus: .idle,
            revision: 1,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: nil,
            agent: "pi",
            displayAgent: "Pi",
            terminalTitle: nil,
            terminalTitleStripped: nil,
            piSemantic: piSemantic
        )
        model.workspaces = [HerdrWorkspace(
            workspaceID: "w1",
            number: 1,
            label: "Workspace",
            focused: true,
            paneCount: 1,
            tabCount: 0,
            activeTabID: "",
            agentStatus: .idle,
            panes: [rawPane]
        ).stamped(machineID: machine.id)]
        return (model, try #require(model.pane(id: "m1|w1:p1")))
    }
}

private final class PiTerminalCommandURLProtocol: URLProtocol {
    static let recorder = PiTerminalCommandRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct PiTerminalCommandRequest {
    let path: String
    let body: [String: Any]
}

private final class PiTerminalCommandRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [PiTerminalCommandRequest] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests = []
    }

    func record(_ request: URLRequest) {
        let body = Self.bodyData(from: request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(PiTerminalCommandRequest(
            path: request.url?.path ?? "",
            body: body
        ))
    }

    func requests() -> [PiTerminalCommandRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
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
