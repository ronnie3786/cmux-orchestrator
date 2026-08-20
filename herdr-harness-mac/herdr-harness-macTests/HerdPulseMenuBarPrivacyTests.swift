import Foundation
import Testing
@testable import herdr_harness_mac

/// The menu bar is visible in screen shares, recordings, and screenshots — the
/// Mac equivalent of the iOS lock screen. Herd Pulse may export counts and
/// phases, never workspace labels, pane titles, cwds, or session IDs.
@Suite("Herd Pulse menu bar exports aggregates only")
struct HerdPulseMenuBarPrivacyTests {
    @Test("Aggregate counts every state without exporting session identity")
    func aggregateCountsStates() throws {
        let aggregate = HerdPulseAggregate(
            workspaces: [secretWorkspace],
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
        let json = String(decoding: data, as: UTF8.self)
        for secret in Self.secrets {
            #expect(!json.contains(secret))
        }
    }

    @Test("Every string the menu bar renders is built from counts, never labels")
    func menuBarStringsExcludeIdentity() {
        for connectionState in [ConnectionState.live, .connecting, .demo, .disconnected, .failed] {
            let state = HerdPulseAggregate(
                workspaces: [secretWorkspace],
                connectionState: connectionState
            ).contentState(at: Date(timeIntervalSince1970: 123))

            var rendered = [
                HerdPulseMenuBarPresentation.title(for: state, isStale: false),
                HerdPulseMenuBarPresentation.title(for: state, isStale: true),
                HerdPulseMenuBarPresentation.detail(for: state),
                HerdPulseMenuBarPresentation.labelAccessibility(for: state),
                HerdPulseMenuBarPresentation.connectionTitle(for: state.connection),
                HerdPulseMenuBarPresentation.workspaceSummary(for: state),
                "\(HerdPulseMenuBarPresentation.badgeCount(for: state) ?? 0)",
            ]
            rendered.append(contentsOf: [
                HerdPulseMenuBarPresentation.title(for: nil, isStale: true),
                HerdPulseMenuBarPresentation.detail(for: nil),
                HerdPulseMenuBarPresentation.labelAccessibility(for: nil),
                HerdPulseMenuBarPresentation.connectionTitle(for: nil),
                HerdPulseMenuBarPresentation.workspaceSummary(for: nil),
            ])

            for text in rendered {
                for secret in Self.secrets {
                    #expect(!text.localizedCaseInsensitiveContains(secret), "\(text) leaked \(secret)")
                }
            }
        }
    }

    @Test("Menu bar badge shows the attention-first count and hides a bare zero")
    func badgeCountPriority() {
        #expect(HerdPulseMenuBarPresentation.badgeCount(for: state(attention: 3, ready: 2, working: 4)) == 3)
        #expect(HerdPulseMenuBarPresentation.badgeCount(for: state(attention: 0, ready: 2, working: 4)) == 2)
        #expect(HerdPulseMenuBarPresentation.badgeCount(for: state(attention: 0, ready: 0, working: 4)) == 4)
        #expect(HerdPulseMenuBarPresentation.badgeCount(for: state(attention: 0, ready: 0, working: 0)) == nil)
        #expect(HerdPulseMenuBarPresentation.badgeCount(for: nil) == nil)
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

    // MARK: - Fixtures

    private static let secrets = [
        "Confidential",
        "secret-work",
        "confidential/path",
        "Implement unannounced feature",
        "Secret pane",
        "codex",
    ]

    private var secretWorkspace: HerdrWorkspace {
        workspace(
            label: "Confidential Project",
            panes: [
                pane(id: "secret-work:p1", status: .working),
                pane(id: "secret-work:p2", status: .working),
                pane(id: "secret-work:p3", status: .blocked),
                pane(id: "secret-work:p4", status: .done),
                pane(id: "secret-work:p5", status: .idle),
            ]
        )
    }

    private func state(attention: Int, ready: Int, working: Int) -> HerdPulseContentState {
        HerdPulseContentState(
            workspaceCount: 1,
            paneCount: attention + ready + working,
            workingCount: working,
            attentionCount: attention,
            readyCount: ready,
            connection: .live,
            phase: .resting,
            updatedAt: 123
        )
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
