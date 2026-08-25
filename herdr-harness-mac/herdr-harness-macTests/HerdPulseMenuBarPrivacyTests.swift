import Foundation
import Testing
@testable import herdr_harness_mac

/// The menu bar is visible in screen shares, recordings, and screenshots — the
/// Mac equivalent of the iOS lock screen. Its aggregate payload remains
/// counts-only, and its session list must fully redact when titles are hidden.
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

    @Test("Redacted attention rows expose only ordinal labels and status words")
    func redactedAttentionRowsExcludeSessionIdentity() {
        let rows = HerdPulseAttentionRows.attentionRows(
            panes: secretAttentionPanes,
            alerts: [],
            revealTitles: false,
            limit: 5
        ).rows

        for row in rows {
            // `row.id` intentionally remains routable pane identity. This
            // fixture embeds a secret in that ID, so assert the rendered text.
            let rendered = "\(row.title)\n\(row.subtitle)"
            for secret in Self.secrets {
                #expect(!rendered.localizedCaseInsensitiveContains(secret), "\(rendered) leaked \(secret)")
            }
        }
    }

    @Test("Revealed attention rows surface session titles and agent names")
    func revealedAttentionRowsSurfaceSessionIdentity() {
        let rows = HerdPulseAttentionRows.attentionRows(
            panes: secretAttentionPanes,
            alerts: [],
            revealTitles: true,
            limit: 5
        ).rows

        var includesTitle = false
        var includesAgent = false
        for row in rows {
            if row.title.contains("Secret pane") {
                includesTitle = true
            }
            if row.subtitle.localizedCaseInsensitiveContains("codex") {
                includesAgent = true
            }
        }
        #expect(includesTitle)
        #expect(includesAgent)
    }

    @Test("Attention rows prioritize status, newest alert, missing alerts, and revision")
    func attentionRowsSortDeterministically() {
        let blockedNewest = attentionPane(id: "blocked-newest", status: .blocked, revision: 1)
        let blockedOlder = attentionPane(id: "blocked-older", status: .blocked, revision: 99)
        let blockedNoAlertHighRevision = attentionPane(id: "blocked-none-high", status: .blocked, revision: 7)
        let blockedNoAlertLowRevision = attentionPane(id: "blocked-none-low", status: .blocked, revision: 3)
        let doneWithAlert = attentionPane(id: "done-alert", status: .done, revision: 1)
        let doneNoAlert = attentionPane(id: "done-none", status: .done, revision: 20)

        let result = HerdPulseAttentionRows.attentionRows(
            panes: [
                doneNoAlert,
                blockedNoAlertLowRevision,
                blockedOlder,
                doneWithAlert,
                blockedNoAlertHighRevision,
                blockedNewest,
            ],
            alerts: [
                alert(paneID: "blocked-older", createdAt: "2026-08-25T11:00:00Z"),
                alert(paneID: "done-alert", status: .done, createdAt: "2026-08-25T13:00:00Z"),
                alert(
                    paneID: "blocked-newest",
                    createdAt: "2026-08-25T12:00:00Z",
                    isRead: true
                ),
            ],
            revealTitles: false,
            limit: 10
        )

        #expect(result.rows.map(\.id) == [
            blockedNewest.id,
            blockedOlder.id,
            blockedNoAlertHighRevision.id,
            blockedNoAlertLowRevision.id,
            doneWithAlert.id,
            doneNoAlert.id,
        ])
    }

    @Test("Attention rows report entries beyond their display limit")
    func attentionRowsReportOverflow() {
        var panes: [HerdrPane] = []
        for ordinal in 1...6 {
            panes.append(attentionPane(id: "overflow-\(ordinal)", status: .blocked, revision: ordinal))
        }

        let result = HerdPulseAttentionRows.attentionRows(
            panes: panes,
            alerts: [],
            revealTitles: false,
            limit: 3
        )

        #expect(result.rows.count == 3)
        #expect(result.overflow == 3)
    }

    @Test("Attention age follows the current transition, not an older status")
    func attentionAgeMatchesCurrentStatus() throws {
        let pane = attentionPane(id: "transition", status: .blocked, revision: 1)
        let result = HerdPulseAttentionRows.attentionRows(
            panes: [pane],
            alerts: [
                alert(paneID: "transition", status: .done, createdAt: "2026-08-25T13:00:00Z"),
                alert(paneID: "transition", status: .blocked, createdAt: "2026-08-25T12:00:00Z"),
            ],
            revealTitles: true
        )

        let row = try #require(result.rows.first)
        #expect(row.since == HerdrTimestamp.date(from: "2026-08-25T12:00:00Z"))
    }

    @Test("Working rows put the longest running agents first")
    func workingRowsSortByElapsedTime() {
        let oldest = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let result = HerdPulseWorkingRows.workingRows(
            panes: [
                pane(id: "secret-work:idle", status: .idle),
                pane(id: "secret-work:newer", status: .working, workingSince: newer),
                pane(id: "secret-work:oldest", status: .working, workingSince: oldest),
            ],
            revealTitles: true
        )

        #expect(result.rows.map(\.id) == ["secret-work:oldest", "secret-work:newer"])
        #expect(result.rows.map(\.since) == [oldest, newer])
    }

    @Test("Redacted working rows preserve duration without exposing identity")
    func redactedWorkingRowsExcludeSessionIdentity() {
        let result = HerdPulseWorkingRows.workingRows(
            panes: [pane(id: "secret-work:p1", status: .working, workingSince: .now)],
            revealTitles: false
        )

        for row in result.rows {
            let rendered = "\(row.title)\n\(row.subtitle)"
            for secret in Self.secrets {
                #expect(!rendered.localizedCaseInsensitiveContains(secret), "\(rendered) leaked \(secret)")
            }
            #expect(row.since != nil)
        }
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

    private var secretAttentionPanes: [HerdrPane] {
        var panes: [HerdrPane] = []
        for pane in secretWorkspace.panes where pane.agentStatus.needsAttention {
            panes.append(pane)
        }
        return panes
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

    private func pane(
        id: String,
        status: AgentStatus,
        workingSince: Date? = nil
    ) -> HerdrPane {
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
            terminalTitleStripped: "Confidential terminal",
            workingSince: workingSince
        )
    }

    private func attentionPane(id: String, status: AgentStatus, revision: Int) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: "test-workspace",
            tabID: "test-workspace:t1",
            focused: false,
            agentStatus: status,
            revision: revision,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: nil,
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil
        )
        .stamped(machineID: "test-machine")
    }

    private func alert(
        paneID: String,
        status: AgentStatus = .blocked,
        createdAt: String,
        isRead: Bool = false
    ) -> HerdrAlert {
        HerdrAlert(
            id: "alert-\(paneID)-\(createdAt)",
            workspaceID: "test-workspace",
            paneID: paneID,
            status: status,
            title: "",
            message: "",
            createdAt: createdAt,
            isRead: isRead
        )
        .stamped(machineID: "test-machine")
    }
}
