import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Herd Pulse session projection")
struct HerdPulseSessionsTests {
    @Test("Only blocked, done, and working panes become rows")
    func includesSupportedStatesOnly() {
        let projection = HerdPulseSessions.sessions(
            panes: [
                pane(id: "blocked", status: .blocked),
                pane(id: "done", status: .done),
                pane(id: "working", status: .working),
                pane(id: "idle", status: .idle),
                pane(id: "unknown", status: .unknown),
            ],
            alerts: [],
            revealTitles: true
        )

        #expect(projection.sessions.map(\.state) == [.blocked, .done, .working])
    }

    @Test("Sessions sort by urgency, then longest-running working session")
    func ordersSessionsDeterministically() {
        let projection = HerdPulseSessions.sessions(
            panes: [
                pane(id: "working-new", status: .working, revision: 5, workingSince: 400),
                pane(id: "done", status: .done, revision: 2),
                pane(id: "blocked", status: .blocked, revision: 1),
                pane(id: "working-old", status: .working, revision: 1, workingSince: 100),
            ],
            alerts: [],
            revealTitles: true
        )

        #expect(projection.sessions.map(\.id) == ["blocked", "done", "working-old", "working-new"])
    }

    @Test("Limit caps rows and reports the remainder")
    func limitsAndReportsOverflow() {
        let projection = HerdPulseSessions.sessions(
            panes: [
                pane(id: "blocked", status: .blocked),
                pane(id: "done", status: .done),
                pane(id: "working", status: .working),
            ],
            alerts: [],
            revealTitles: true,
            limit: 2
        )

        #expect(projection.sessions.count == 2)
        #expect(projection.overflow == 1)
    }

    @Test("Pending reads suppress only done rows")
    func pendingReadSuppressesDoneOnly() {
        let done = pane(id: "done", status: .done)
        let working = pane(id: "working", status: .working)
        let projection = HerdPulseSessions.sessions(
            panes: [done, working],
            alerts: [],
            pendingReadPaneIDs: [done.id, working.id],
            revealTitles: true
        )

        #expect(projection.sessions.map(\.id) == [working.id])
    }

    @Test("Redacted rows never export pane identity or title")
    func redactsSessionIdentity() throws {
        let secret = pane(
            id: "secret-pane-id",
            status: .working,
            title: "Top Secret Project"
        )
        let projection = HerdPulseSessions.sessions(
            panes: [secret],
            alerts: [],
            revealTitles: false
        )

        let session = try #require(projection.sessions.first)
        #expect(session.id == "s1")
        #expect(session.title == "session 1")
        #expect(session.agent == "")
        let payload = try JSONEncoder().encode(projection.sessions)
        let text = String(decoding: payload, as: UTF8.self)
        #expect(!text.contains("Top Secret Project"))
        #expect(!text.contains("secret-pane-id"))
    }

    @Test("Titles and agents are capped")
    func truncatesTitlesAndAgents() {
        let title = String(repeating: "t", count: 41)
        let agent = String(repeating: "a", count: 17)
        let projection = HerdPulseSessions.sessions(
            panes: [pane(id: "pane", status: .working, title: title, agent: agent)],
            alerts: [],
            revealTitles: true
        )

        let session = projection.sessions[0]
        #expect(session.title == String(repeating: "t", count: 40))
        #expect(session.agent == String(repeating: "a", count: 16))
    }

    @Test("Content state round-trips with sessions")
    func contentStateRoundTrips() throws {
        let state = HerdPulseAttributes.ContentState(
            workspaceCount: 1,
            paneCount: 2,
            workingCount: 1,
            attentionCount: 1,
            readyCount: 0,
            connection: .live,
            phase: .attention,
            updatedAt: 123,
            sessions: [
                .init(id: "pane", title: "Review", agent: "Codex", state: .blocked, since: 100),
            ],
            sessionOverflow: 3
        )

        #expect(try JSONDecoder().decode(HerdPulseAttributes.ContentState.self, from: JSONEncoder().encode(state)) == state)
    }

    @Test("Content state decodes legacy eight-key payloads")
    func contentStateDecodesLegacyPayload() throws {
        let data = Data("""
        {"workspaceCount":1,"paneCount":2,"workingCount":1,"attentionCount":0,"readyCount":1,"connection":"live","phase":"ready","updatedAt":123}
        """.utf8)

        let state = try JSONDecoder().decode(HerdPulseAttributes.ContentState.self, from: data)
        #expect(state.sessions == [])
        #expect(state.sessionOverflow == 0)
    }

    private func pane(
        id: String,
        status: AgentStatus,
        revision: Int = 1,
        title: String? = nil,
        agent: String? = nil,
        workingSince: TimeInterval? = nil
    ) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: "workspace",
            tabID: "tab",
            focused: false,
            agentStatus: status,
            revision: revision,
            cwd: nil,
            foregroundCWD: nil,
            label: title,
            title: nil,
            agent: agent,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil,
            workingSince: workingSince.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
