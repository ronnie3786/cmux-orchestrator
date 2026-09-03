import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Herdr focus handoff", .serialized)
struct HerdrFocusActivationTests {
    @Test("Pane focus activates cmux after the remote focus succeeds")
    func focusActivatesCmuxAfterRemoteSuccess() async throws {
        FocusHandoffURLProtocol.recorder.reset()
        let fixture = try makeFixture()
        var requestsSeenAtActivation: [String] = []
        fixture.model.activateCmuxApplication = {
            requestsSeenAtActivation = FocusHandoffURLProtocol.recorder.paths()
        }

        await fixture.model.focus(fixture.pane)

        #expect(requestsSeenAtActivation == ["/api/v1/panes/w1:p1/focus"])
        let refreshPaths = FocusHandoffURLProtocol.recorder.paths()
        #expect(refreshPaths.contains("/api/v1/workspaces"))
        #expect(refreshPaths.contains("/api/v1/result-artifacts"))
        #expect(fixture.model.toastMessage == "Focused on Mac")
    }

    @Test("Focus and zoom completes both remote actions before activating cmux")
    func focusAndZoomActivatesAfterBothRemoteActions() async throws {
        FocusHandoffURLProtocol.recorder.reset()
        let fixture = try makeFixture()
        var requestsSeenAtActivation: [String] = []
        fixture.model.activateCmuxApplication = {
            requestsSeenAtActivation = FocusHandoffURLProtocol.recorder.paths()
        }

        await fixture.model.focusAndZoom(fixture.pane)

        #expect(requestsSeenAtActivation == [
            "/api/v1/panes/w1:p1/focus",
            "/api/v1/panes/w1:p1/zoom",
        ])
        #expect(fixture.model.toastMessage == "Focused + zoomed on Mac")
    }

    private func makeFixture() throws -> (model: HerdrAppModel, pane: HerdrPane) {
        let suiteName = "HerdrFocusActivationTests.\(UUID().uuidString)"
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
        sessionConfiguration.protocolClasses = [FocusHandoffURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live

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
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil
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

private final class FocusHandoffURLProtocol: URLProtocol {
    static let recorder = FocusHandoffRequestRecorder()

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
        let body = switch url.path {
        case "/api/v1/workspaces":
            #"{"ok":true,"workspaces":[],"alerts":[]}"#
        case "/api/v1/result-artifacts":
            #"{"ok":true,"artifacts":[]}"#
        default:
            #"{"ok":true}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FocusHandoffRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedPaths = []
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recordedPaths.append(request.url?.path ?? "")
    }

    func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }
}
