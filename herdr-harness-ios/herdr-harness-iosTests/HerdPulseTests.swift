import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Herd Pulse privacy-safe aggregation", .serialized)
struct HerdPulseTests {
    @Test("Aggregate counts every state without exporting session identity")
    func aggregateCountsStates() throws {
        let panes = [
            pane(id: "secret-work:p1", status: .working),
            pane(id: "secret-work:p2", status: .working),
            pane(id: "secret-work:p3", status: .blocked),
            pane(id: "secret-work:p4", status: .done),
            pane(id: "secret-work:p5", status: .idle),
        ]
        let aggregate = HerdPulseAggregate(
            workspaces: [workspace(label: "Confidential Project", panes: panes)],
            connectionState: .live
        )

        #expect(aggregate.workspaceCount == 1)
        #expect(aggregate.paneCount == 5)
        #expect(aggregate.workingCount == 2)
        #expect(aggregate.attentionCount == 1)
        #expect(aggregate.readyCount == 1)
        #expect(aggregate.phase == .attention)

        let data = try JSONEncoder().encode(aggregate.contentState(at: Date(timeIntervalSince1970: 123)))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(payload.keys) == [
            "workspaceCount", "paneCount", "workingCount", "attentionCount",
            "readyCount", "connection", "phase", "updatedAt",
        ])
        #expect(!String(decoding: data, as: UTF8.self).contains("Confidential"))
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-work"))
    }

    @Test("Connection and attention priority produce deterministic phases")
    func phasePriority() {
        let done = workspace(label: "Done", panes: [pane(id: "w:p1", status: .done)])
        let working = workspace(label: "Working", panes: [pane(id: "w:p2", status: .working)])

        #expect(HerdPulseAggregate(workspaces: [done, working], connectionState: .live).phase == .ready)
        #expect(HerdPulseAggregate(workspaces: [working], connectionState: .live).phase == .working)
        #expect(HerdPulseAggregate(workspaces: [], connectionState: .live).phase == .resting)
        #expect(HerdPulseAggregate(workspaces: [done], connectionState: .failed).phase == .offline)
    }

    @Test("Pulse retains the committed client configuration while Settings drafts change")
    @MainActor
    func pulseUsesCommittedConnection() throws {
        let defaults = UserDefaults.standard
        let previousURL = defaults.object(forKey: "herdr.serverURL")
        let previousDemo = defaults.object(forKey: "herdr.demoMode")
        let previousSetup = defaults.object(forKey: "herdr.completedSetup")
        let previousToken = KeychainStore.value(for: "api-token")
        defer {
            restore(previousURL, key: "herdr.serverURL", defaults: defaults)
            restore(previousDemo, key: "herdr.demoMode", defaults: defaults)
            restore(previousSetup, key: "herdr.completedSetup", defaults: defaults)
            KeychainStore.set(previousToken, for: "api-token")
        }

        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        model.serverURLString = "https://active.tailnet.example"
        model.apiToken = "committed-token"
        model.connect()

        let active = try #require(model.activeServerConnection)
        #expect(active.generation == model.connectionGeneration)
        #expect(active.configuration.baseURL.absoluteString == "https://active.tailnet.example")
        #expect(active.configuration.token == "committed-token")

        model.serverURLString = "https://unsaved.tailnet.example"
        model.apiToken = "unsaved-token"

        #expect(model.activeServerConfiguration == active.configuration)
        model.useDemo()
        #expect(model.activeServerConnection == nil)
        #expect(model.activeServerConfiguration == nil)
    }

    @Test("Registration retry policy backs off and rejects permanent failures")
    func registrationRetryPolicy() {
        let policy = HerdPulseRegistrationRetryPolicy.standard

        #expect(policy.delay(afterFailure: 1) == .seconds(1))
        #expect(policy.delay(afterFailure: 3) == .seconds(4))
        #expect(policy.delay(afterFailure: 99) == .seconds(30))
        #expect(policy.shouldRetry(URLError(.timedOut)))
        #expect(policy.shouldRetry(APIError.server(status: 503, message: "Unavailable")))
        #expect(policy.shouldRetry(APIError.server(status: 429, message: "Slow down")))
        #expect(!policy.shouldRetry(APIError.server(status: 401, message: "Unauthorized")))
        #expect(!policy.shouldRetry(APIError.invalidResponse))
        #expect(!policy.shouldRetry(CancellationError()))
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func workspace(label: String, panes: [HerdrPane]) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceID: "secret-work",
            number: 1,
            label: label,
            focused: true,
            paneCount: panes.count,
            tabCount: 1,
            activeTabID: "secret-work:t1",
            agentStatus: panes.first?.agentStatus ?? .idle,
            panes: panes
        )
    }

    private func pane(id: String, status: AgentStatus) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: "secret-work",
            tabID: "secret-work:t1",
            focused: false,
            agentStatus: status,
            revision: 1,
            cwd: "/private/confidential/path",
            foregroundCWD: "/private/confidential/path",
            label: "Secret pane",
            title: "Implement unannounced feature",
            agent: "codex",
            displayAgent: "Codex",
            terminalTitle: "Confidential terminal",
            terminalTitleStripped: "Confidential terminal"
        )
    }
}
