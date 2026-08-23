import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Terminal keyboard router")
@MainActor
struct TerminalKeyboardRouterTests {
    @Test("The router's model handoff sends text to the raw pane ID")
    func sendTextUsesRawPaneID() async throws {
        await KeyboardRequestRecorder.shared.reset()
        let defaults = try #require(UserDefaults(suiteName: "TerminalKeyboardRouterTests"))
        defaults.removePersistentDomain(forName: "TerminalKeyboardRouterTests")
        defer { defaults.removePersistentDomain(forName: "TerminalKeyboardRouterTests") }
        let machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let client = HerdrAPIClient(configuration: configuration, session: session())
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
        let pane = rawPane.stamped(machineID: machine.id)
        model.workspaces = [HerdrWorkspace(
            workspaceID: "w1", number: 1, label: "Workspace", focused: true,
            paneCount: 1, tabCount: 0, activeTabID: "", agentStatus: .idle, panes: [rawPane]
        ).stamped(machineID: machine.id)]

        #expect(pane.id == "m1|w1:p1")
        let router = TerminalKeyboardRouter()
        router.enqueueText("hello", to: pane, model: model)
        for _ in 0..<10 {
            if !(await KeyboardRequestRecorder.shared.paths()).isEmpty { break }
            await Task.yield()
        }
        #expect(await KeyboardRequestRecorder.shared.paths() == ["/api/v1/panes/w1:p1/send-text"])
    }

    @Test("A failed send invalidates only the already queued chain")
    func failedSendDropsRemainingOperationsButAllowsANewEpoch() async {
        let router = TerminalKeyboardRouter()
        let model = HerdrAppModel(arguments: [])
        var invocations: [String] = []

        router.enqueue(model: model) {
            invocations.append("first")
            return false
        }
        router.enqueue(model: model) {
            invocations.append("second")
            return true
        }
        router.enqueue(model: model) {
            invocations.append("third")
            return true
        }
        for _ in 0..<10 where invocations.isEmpty { await Task.yield() }

        router.enqueue(model: model) {
            invocations.append("fourth")
            return true
        }
        for _ in 0..<20 where invocations.count < 2 { await Task.yield() }

        #expect(invocations == ["first", "fourth"])
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyboardURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor KeyboardRequestRecorder {
    static let shared = KeyboardRequestRecorder()
    private var recordedPaths: [String] = []

    func reset() { recordedPaths = [] }
    func record(_ path: String) { recordedPaths.append(path) }
    func paths() -> [String] { recordedPaths }
}

private final class KeyboardURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Task { await KeyboardRequestRecorder.shared.record(path) }
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
