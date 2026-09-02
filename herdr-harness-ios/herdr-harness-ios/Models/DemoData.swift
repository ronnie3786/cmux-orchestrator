import Foundation

enum DemoData {
    static let workspaces: [HerdrWorkspace] = [
        workspace(
            id: "w1",
            number: 1,
            label: "iOS Doximity",
            path: "/Users/ronnie/Work/iOS-Doximity",
            panes: [
                pane(id: "w1:p1", tabID: "w1:t1", status: .working, title: "Refine member profile", agent: "Codex", revision: 184, firstSeenAt: Date().addingTimeInterval(-3_600), lastActivityAt: Date(), workingSince: Date().addingTimeInterval(-47 * 60)),
                pane(id: "w1:p2", tabID: "w1:t1", status: .blocked, title: "Auth reducer review", agent: "Claude", revision: 97, firstSeenAt: Date().addingTimeInterval(-7_200), lastActivityAt: Date().addingTimeInterval(-22 * 60)),
                pane(id: "w1:p3", tabID: "w1:t2", status: .unknown, title: "Unit tests", agent: nil, revision: 52, firstSeenAt: Date().addingTimeInterval(-3 * 86_400), lastActivityAt: Date().addingTimeInterval(-2 * 86_400)),
            ],
            layouts: [layout(workspaceID: "w1", tabID: "w1:t1", paneIDs: ["w1:p1", "w1:p2"])]
        ),
        workspace(
            id: "w2",
            number: 2,
            label: "Member API",
            path: "/Users/ronnie/Work/member-api",
            panes: [
                pane(id: "w2:p1", tabID: "w2:t1", status: .done, title: "Pagination contract", agent: "Codex", revision: 311, firstSeenAt: Date(), lastActivityAt: Date()),
                pane(id: "w2:p2", tabID: "w2:t1", status: .working, title: "GraphQL smoke test", agent: "Claude", revision: 118, firstSeenAt: Date().addingTimeInterval(-5_400), lastActivityAt: Date(), workingSince: Date().addingTimeInterval(-35 * 60)),
            ],
            layouts: [layout(workspaceID: "w2", tabID: "w2:t1", paneIDs: ["w2:p1", "w2:p2"])]
        ),
        workspace(
            id: "w3",
            number: 3,
            label: "Release Train",
            path: "/Users/ronnie/Work/release",
            panes: [
                pane(id: "w3:p1", tabID: "w3:t1", status: .idle, title: "Release notes", agent: "Codex", revision: 44, firstSeenAt: Date().addingTimeInterval(-10 * 86_400), lastActivityAt: Date().addingTimeInterval(-8 * 86_400)),
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

    static let workspacesForWorkMBP: [HerdrWorkspace] = [
        workspace(
            id: "w1",
            number: 1,
            label: "Herdr Mac",
            path: "/Users/ronnie/Work/herdr-harness",
            panes: [
                pane(id: "w1:p1", tabID: "w1:t1", status: .working, title: "Connection runtime", agent: "Codex", revision: 28),
                pane(id: "w1:p2", tabID: "w1:t1", status: .idle, title: "Release checklist", agent: "Claude", revision: 12),
            ],
            layouts: [layout(workspaceID: "w1", tabID: "w1:t1", paneIDs: ["w1:p1", "w1:p2"])]
        ),
        workspace(
            id: "w2",
            number: 2,
            label: "Infra Notes",
            path: "/Users/ronnie/Work/infra",
            panes: [
                pane(id: "w2:p1", tabID: "w2:t1", status: .done, title: "Tailscale check", agent: "Codex", revision: 7),
            ],
            layouts: [layout(workspaceID: "w2", tabID: "w2:t1", paneIDs: ["w2:p1"])]
        ),
    ]

    static func terminalText(for paneID: String) -> String {
        switch paneID {
        case "demo1|w1:p2":
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
        case "demo1|w2:p1":
            """
            ✓ Added cursor pagination to MemberConnection
            ✓ Preserved legacy page-number compatibility
            ✓ 42 contract tests passed

            Summary
            The API now emits stable cursors and rejects stale page tokens.
            No schema-breaking changes were introduced.

            Ready for review.
            """
        case "demo2|w1:p2":
            """
            Release checklist

            ✓ Tagged the candidate build
            ✓ Confirmed the migration notes
            ◐ Waiting on App Store review wording

            Next: send the release summary to the team.
            """
        case "demo2|w2:p1":
            """
            ✓ Tailscale Serve is reachable
            ✓ DNS name resolves inside the tailnet
            ✓ Health probe returned 200

            Connection runtime is ready for the next deploy.
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

    static func gitStatus(for workspace: HerdrWorkspace) -> WorkspaceGitStatus {
        WorkspaceGitStatus(
            ok: true,
            workspaceID: workspace.id,
            branch: workspace.tokens["branch"] ?? "feature/member-profile",
            cwd: workspace.displayPath,
            staged: [
                WorkspaceGitFile(status: "M", file: "herdr-harness-ios/Views/Pane/PaneSessionView.swift"),
            ],
            unstaged: [
                WorkspaceGitFile(status: "M", file: "herdr-harness-ios/Views/Pane/PromptComposerView.swift"),
                WorkspaceGitFile(status: "M", file: "herdr_harness/server.py"),
            ],
            untracked: [
                "herdr-harness-ios/Views/Pane/WorkspaceSkillsView.swift",
            ],
            commits: [
                WorkspaceGitCommit(hash: "8d3b96a", message: "Keep terminal frames live while a pane stays open"),
                WorkspaceGitCommit(hash: "a18fe2c", message: "Match the workspace picker to the Herdr TUI"),
                WorkspaceGitCommit(hash: "5f29d10", message: "Add iOS pane controls"),
            ],
            error: nil
        )
    }

    static func gitDiff(file: String, section: GitFileSection) -> WorkspaceGitDiffResponse {
        WorkspaceGitDiffResponse(
            ok: true,
            file: file,
            section: section,
            diff: """
            diff --git a/\(file) b/\(file)
            index 17f4c31..92ab840 100644
            --- a/\(file)
            +++ b/\(file)
            @@ -42,6 +42,9 @@ struct PaneSessionView: View {
                 PaneTerminalView(
                     pane: currentPane,
            +        source: terminalSource,
            +        isFollowing: $isFollowing,
            +        refresh: manualRefresh,
                     output: output
                 )
            """,
            error: nil
        )
    }

    static func skills(for workspace: HerdrWorkspace) -> SkillsResponse {
        let projectSkills = [
            ProjectSkill(
                name: "swiftui-pro",
                skillFilePath: "./.claude/skills/swiftui-pro/SKILL.md",
                scope: "project"
            ),
            ProjectSkill(
                name: "self-qa",
                skillFilePath: "./.claude/skills/self-qa/SKILL.md",
                scope: "project"
            ),
            ProjectSkill(
                name: "release-ios",
                skillFilePath: "./.claude/skills/release-ios/SKILL.md",
                scope: "project"
            ),
        ]
        let userSkills = [
            ProjectSkill(
                name: "handoff",
                skillFilePath: "~/.codex/skills/handoff/SKILL.md",
                scope: "user"
            ),
            ProjectSkill(
                name: "message-me",
                skillFilePath: "~/.codex/skills/message-me/SKILL.md",
                scope: "user"
            ),
        ]
        return SkillsResponse(
            ok: true,
            workspaceID: workspace.id,
            rootPath: workspace.displayPath,
            skillsDirectory: "\(workspace.displayPath)/.claude/skills",
            userSkillsDirectory: "~/.codex/skills",
            projectSkills: projectSkills,
            userSkills: userSkills,
            skills: projectSkills + userSkills,
            error: nil
        )
    }

    static func fileSearch(query: String, workspace: HerdrWorkspace) -> FileSearchResponse {
        FileSearchResponse(
            ok: true,
            workspaceID: workspace.id,
            rootPath: workspace.displayPath,
            query: query,
            files: [
                ProjectFileMatch(path: "herdr-harness-ios/Views/Pane/PaneSessionView.swift"),
                ProjectFileMatch(path: "herdr-harness-ios/Views/Pane/PromptComposerView.swift"),
                ProjectFileMatch(path: "tests/test_herdr_service.py"),
            ].filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) },
            truncated: false,
            limit: 50,
            error: nil
        )
    }

    static let jiraTickets = JiraTicketsResponse(
        ok: true,
        project: "MOB",
        projects: ["MOB", "IOS"],
        site: "example.atlassian.net",
        tickets: [
            JiraTicket(
                key: "MOB-1842",
                projectKey: "MOB",
                title: "Keep the remote terminal live on iOS",
                status: "In Progress",
                priority: "High",
                issueType: "Story",
                url: "https://example.atlassian.net/browse/MOB-1842"
            ),
            JiraTicket(
                key: "IOS-927",
                projectKey: "IOS",
                title: "Polish the Herdr pane command deck",
                status: "Ready for QA",
                priority: "Medium",
                issueType: "Task",
                url: "https://example.atlassian.net/browse/IOS-927"
            ),
        ],
        error: nil
    )

    static let workInbox = WorkInboxResponse(
        ok: true,
        reviewRequests: WorkInboxProviderSection(
            ok: true,
            items: [
                GitHubReviewRequest(
                    number: 11856,
                    title: "Add calculator access to the drawer",
                    url: "https://github.com/doximity/iOS-Doximity/pull/11856",
                    isDraft: false,
                    state: "open",
                    author: "Chandlerdea",
                    repository: "doximity/iOS-Doximity"
                ),
                GitHubReviewRequest(
                    number: 520,
                    title: "Register managed MCP runtime with standalone clients",
                    url: "https://github.com/doximity/agentic-dev/pull/520",
                    isDraft: false,
                    state: "open",
                    author: "TheMetalCode",
                    repository: "doximity/agentic-dev"
                ),
            ],
            error: nil
        ),
        jiraTickets: WorkInboxProviderSection(
            ok: true,
            items: jiraTickets.tickets + [
                JiraTicket(
                    key: "IOS-901",
                    projectKey: "IOS",
                    title: "Review remote build distribution",
                    status: "In Code Review",
                    priority: "Medium",
                    issueType: "Story",
                    url: "https://example.atlassian.net/browse/IOS-901"
                )
            ],
            error: nil
        )
    )

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
        revision: Int,
        firstSeenAt: Date? = nil,
        lastActivityAt: Date? = nil,
        workingSince: Date? = nil
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
            terminalTitleStripped: title,
            firstSeenAt: firstSeenAt,
            lastActivityAt: lastActivityAt,
            workingSince: workingSince
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
