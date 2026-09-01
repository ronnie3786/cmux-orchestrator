import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD session mute", .serialized)
struct HerdrHudMuteTests {
    @MainActor
    @Test("Muting a HUD session round-trips through local defaults")
    func muteRoundTripsThroughDefaults() throws {
        let suiteName = "HerdrHudMuteTests.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let paneID = "machine-a|w1:p1"

        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        model.toggleMutedHudSession(paneID)

        #expect(model.mutedHudSessionIDs.contains(paneID))
        #expect(defaults.stringArray(forKey: "herdr.hud.mutedSessions")?.contains(paneID) == true)
        #expect(HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults).mutedHudSessionIDs.contains(paneID))
    }

    @MainActor
    @Test("Muting a HUD session makes no network request")
    func muteMakesNoNetworkRequest() async throws {
        await HudMuteRequestRecorder.shared.reset()
        let suiteName = "HerdrHudMuteTests.network.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HudMuteURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)

        model.toggleMutedHudSession("m1|w1:p1")
        for _ in 0..<3 { await Task.yield() }

        #expect(await HudMuteRequestRecorder.shared.requests().isEmpty)
    }

    @MainActor
    @Test("Removing a machine purges only its muted and dismissed session state")
    func removingMachinePurgesOnlyMatchingSessionState() {
        let defaults = makeDefaults()
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        let demoOne = "demo1|w1:p1"
        let demoTwo = "demo2|w2:p1"
        model.toggleMutedHudSession(demoOne)
        model.toggleMutedHudSession(demoTwo)
        model.dismissHudChip(demoOne)
        model.dismissHudChip(demoTwo)

        model.removeMachine(id: "demo1")

        #expect(!model.mutedHudSessionIDs.contains(demoOne))
        #expect(model.mutedHudSessionIDs.contains(demoTwo))
        #expect(model.dismissedHudChipStatuses[demoOne] == nil)
        #expect(model.dismissedHudChipStatuses[demoTwo] == .done)
    }

    @MainActor
    @Test("Dismissal records the current status and ignores unknown panes")
    func dismissalRecordsCurrentStatusAndIgnoresUnknownPane() {
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: makeDefaults())
        let paneID = "demo1|w1:p1"

        model.dismissHudChip(paneID)
        model.dismissHudChip("demo1|missing")

        #expect(model.dismissedHudChipStatuses[paneID] == .working)
        #expect(model.dismissedHudChipStatuses["demo1|missing"] == nil)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HerdrHudMuteTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor HudMuteRequestRecorder {
    static let shared = HudMuteRequestRecorder()
    private var recordedRequests: [URLRequest] = []

    func reset() { recordedRequests = [] }
    func record(_ request: URLRequest) { recordedRequests.append(request) }
    func requests() -> [URLRequest] { recordedRequests }
}

private final class HudMuteURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        Task { await HudMuteRequestRecorder.shared.record(request) }
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}
