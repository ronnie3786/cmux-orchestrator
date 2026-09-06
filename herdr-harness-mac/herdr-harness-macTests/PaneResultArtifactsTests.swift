import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Pane result attachments")
struct PaneResultArtifactsTests {
    @Test("A chat only shows its own machine and pane results in chronological order")
    func scopesResults() throws {
        let pane = try JSONDecoder().decode(HerdrPane.self, from: Data("""
        {"pane_id":"p1","workspace_id":"w1","tab_id":"t1","agent_status":"idle","revision":1}
        """.utf8)).stamped(machineID: "work")
        let first = artifact("first", machineID: "work", createdAt: "2026-09-06T12:00:00Z")
        let last = artifact("last", machineID: "work", createdAt: "2026-09-06T13:00:00Z")
        let otherMachine = artifact("other-machine", machineID: "home")
        let otherPane = artifact("other-pane", machineID: "work", originID: "p2")
        let headlessRun = artifact("headless", machineID: "work", originType: .agentRun)
        #expect(PaneResultArtifacts.matching([last, otherMachine, otherPane, headlessRun, first], pane: pane).map(\.rawID) == ["first", "last"])
    }

    private func artifact(
        _ id: String,
        machineID: String,
        originID: String = "p1",
        originType: AgentResultArtifact.OriginType = .pane,
        createdAt: String = "2026-09-06T12:00:00Z"
    ) -> AgentResultArtifact {
        AgentResultArtifact(
            id: id, originType: originType, originID: originID,
            kind: .link, title: id, createdAt: createdAt,
            url: URL(string: "https://example.com/result")
        ).stamped(machineID: machineID)
    }
}
