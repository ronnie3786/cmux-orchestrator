import Foundation

enum DemoData {
    static let workspaces: [HerdrWorkspace] = [
        workspace(
            id: "w1",
            number: 1,
            label: "iOS Doximity",
            path: "/Users/ronnie/Work/iOS-Doximity",
            panes: [
                pane(id: "w1:p1", tabID: "w1:t1", status: .working, title: "Refine member profile", agent: "Codex", revision: 184),
                pane(id: "w1:p2", tabID: "w1:t1", status: .blocked, title: "Auth reducer review", agent: "Claude", revision: 97),
                pane(id: "w1:p3", tabID: "w1:t2", status: .unknown, title: "Unit tests", agent: nil, revision: 52),
            ],
            layouts: [layout(workspaceID: "w1", tabID: "w1:t1", paneIDs: ["w1:p1", "w1:p2"])]
        ),
        workspace(
            id: "w2",
            number: 2,
            label: "Member API",
            path: "/Users/ronnie/Work/member-api",
            panes: [
                pane(id: "w2:p1", tabID: "w2:t1", status: .done, title: "Pagination contract", agent: "Codex", revision: 311),
                pane(id: "w2:p2", tabID: "w2:t1", status: .working, title: "GraphQL smoke test", agent: "Claude", revision: 118),
            ],
            layouts: [layout(workspaceID: "w2", tabID: "w2:t1", paneIDs: ["w2:p1", "w2:p2"])]
        ),
        workspace(
            id: "w3",
            number: 3,
            label: "Release Train",
            path: "/Users/ronnie/Work/release",
            panes: [
                pane(id: "w3:p1", tabID: "w3:t1", status: .idle, title: "Release notes", agent: "Codex", revision: 44),
            ],
            layouts: [layout(workspaceID: "w3", tabID: "w3:t1", paneIDs: ["w3:p1"])]
        ),
    ]

    static let alerts: [HerdrAlert] = [
        HerdrAlert(
            id: "demo-blocked",
            workspaceID: "w1",
            paneID: "w1:p2",
            status: .blocked,
            title: "Auth reducer needs you",
            message: "Claude is waiting for approval to update the sign-in dependency.",
            createdAt: "2026-08-11T14:42:00Z",
            isRead: false
        ),
        HerdrAlert(
            id: "demo-done",
            workspaceID: "w2",
            paneID: "w2:p1",
            status: .done,
            title: "Pagination contract is ready",
            message: "Codex finished in the background. Review the final response when ready.",
            createdAt: "2026-08-11T14:38:00Z",
            isRead: false
        ),
    ]

    static func terminalText(for paneID: String) -> String {
        switch paneID {
        case "w1:p2":
            """
            ╭─ Claude · Auth reducer review ─────────────────────────────╮
            │ I can update the authentication dependency and regenerate │
            │ the package graph. This changes Package.resolved.         │
            ╰────────────────────────────────────────────────────────────╯

            Do you want me to proceed?

              1. Yes, update and verify
              2. No, keep the current version

            ❯ Waiting for your response
            """
        case "w2:p1":
            """
            ✓ Added cursor pagination to MemberConnection
            ✓ Preserved legacy page-number compatibility
            ✓ 42 contract tests passed

            Summary
            The API now emits stable cursors and rejects stale page tokens.
            No schema-breaking changes were introduced.

            Ready for review.
            """
        default:
            """
            $ git status --short
             M Sources/Profile/ProfileFeature.swift
             M Tests/ProfileFeatureTests.swift

            ◐ Running focused tests…
            Test Suite 'ProfileFeatureTests' started
            ✓ loads cached member before refreshing
            ✓ refresh preserves optimistic specialty edit
            """
        }
    }

    private static func workspace(
        id: String,
        number: Int,
        label: String,
        path: String,
        panes: [HerdrPane],
        layouts: [HerdrLayout]
    ) -> HerdrWorkspace {
        let status = panes.min(by: { $0.agentStatus.attentionRank < $1.agentStatus.attentionRank })?.agentStatus ?? .unknown
        return HerdrWorkspace(
            workspaceID: id,
            number: number,
            label: label,
            focused: number == 1,
            paneCount: panes.count,
            tabCount: Set(panes.map(\.tabID)).count,
            activeTabID: panes.first?.tabID ?? "",
            agentStatus: status,
            tokens: ["branch": number == 1 ? "feature/member-profile" : "main"],
            worktree: HerdrWorktree(
                repoKey: label.lowercased().replacing(" ", with: "-"),
                repoName: label,
                repoRoot: path,
                checkoutPath: path,
                isLinkedWorktree: number == 1
            ),
            tabs: Array(Set(panes.map(\.tabID))).sorted().enumerated().map { index, tabID in
                HerdrTab(
                    tabID: tabID,
                    workspaceID: id,
                    number: index + 1,
                    label: index == 0 ? "Agents" : "Tests",
                    focused: index == 0,
                    paneCount: panes.count(where: { $0.tabID == tabID }),
                    agentStatus: status
                )
            },
            panes: panes,
            layouts: layouts
        )
    }

    private static func pane(
        id: String,
        tabID: String,
        status: AgentStatus,
        title: String,
        agent: String?,
        revision: Int
    ) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: "term_\(id.replacing(":", with: "_"))",
            workspaceID: String(id.split(separator: ":").first ?? "w1"),
            tabID: tabID,
            focused: id == "w1:p1",
            agentStatus: status,
            revision: revision,
            cwd: "/Users/ronnie/Work",
            foregroundCWD: nil,
            label: nil,
            title: title,
            agent: agent?.lowercased(),
            displayAgent: agent,
            terminalTitle: title,
            terminalTitleStripped: title
        )
    }

    private static func layout(workspaceID: String, tabID: String, paneIDs: [String]) -> HerdrLayout {
        let width = 120
        let paneWidth = width / max(paneIDs.count, 1)
        return HerdrLayout(
            workspaceID: workspaceID,
            tabID: tabID,
            focusedPaneID: paneIDs.first,
            zoomed: false,
            area: HerdrLayoutRect(x: 0, y: 0, width: width, height: 36),
            panes: paneIDs.enumerated().map { index, id in
                HerdrLayoutPane(
                    paneID: id,
                    focused: index == 0,
                    rect: HerdrLayoutRect(x: index * paneWidth, y: 0, width: paneWidth, height: 36)
                )
            },
            splits: []
        )
    }
}
