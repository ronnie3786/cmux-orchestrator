import Foundation

struct DemoHarnessStore {
    static func status() -> HarnessStatus {
        HarnessStatus(
            enabled: true,
            workspaces: workspaces(),
            pollInterval: 2,
            socketFound: true,
            connected: true,
            staleData: false,
            model: "local-demo",
            reviewEnabled: true,
            reviewModel: "local-demo",
            reviewBackend: "on-device",
            contractReviewEnabled: false,
            approvalThreshold: 3,
            ollamaAvailable: nil
        )
    }

    static func workspaces() -> [Workspace] {
        [
            Workspace(
                hasClaude: true,
                index: 0,
                name: "Review dashboard polish",
                uuid: "demo-review",
                enabled: true,
                autoMode: .auto,
                starred: true,
                customName: "Review dashboard polish",
                lastCheck: "2026-05-09T14:15:00Z",
                screenTail: terminalScreen,
                screenFull: terminalScreen,
                cwd: "~/Projects/sample-dashboard",
                branch: "feature/native-mac-harness",
                sessionCost: "$0.42",
                surfaceId: "surface-review",
                surfaceLabel: "Review dashboard polish",
                surfaceTitle: "Claude",
                gitDirty: true,
                surfaceAge: 1840
            ),
            Workspace(
                hasClaude: true,
                index: 1,
                name: "Jira import flow",
                uuid: "demo-jira",
                enabled: false,
                autoMode: .off,
                starred: false,
                customName: nil,
                lastCheck: "2026-05-09T14:16:00Z",
                screenTail: "claude\n> Waiting for confirmation before updating Jira links.",
                screenFull: "claude\n> Waiting for confirmation before updating Jira links.",
                cwd: "~/Projects/mobile-app",
                branch: "bugfix/jira-ticket-links",
                sessionCost: "$0.18",
                surfaceId: "surface-jira",
                surfaceLabel: "Jira import flow",
                surfaceTitle: "Claude",
                gitDirty: false,
                surfaceAge: 680
            ),
            Workspace(
                hasClaude: false,
                index: 2,
                name: "Build watcher",
                uuid: "demo-shell",
                enabled: false,
                autoMode: .off,
                starred: false,
                customName: "Build watcher",
                lastCheck: "2026-05-09T14:17:00Z",
                screenTail: "npm run dev\nVITE ready in 312 ms\nLocal: http://localhost:5173/",
                screenFull: "npm run dev\nVITE ready in 312 ms\nLocal: http://localhost:5173/",
                cwd: "~/Projects/sample-dashboard",
                branch: "main",
                sessionCost: nil,
                surfaceId: "surface-shell",
                surfaceLabel: "Build watcher",
                surfaceTitle: "zsh",
                gitDirty: false,
                surfaceAge: 2230
            )
        ]
    }

    static var terminalScreen: String {
        """
        cmux local demo
        Workspace: Review dashboard polish
        Branch: feature/native-mac-harness

        Modified files:
          M Sources/Dashboard/SessionList.swift
          M Sources/Dashboard/GitDiffView.swift
          A Sources/Dashboard/MacServerSupervisor.swift

        Claude is reviewing the native Mac harness shell.
        Approval needed: allow reading git diff and Jira ticket metadata?

        ›
        """
    }

    static func feed() -> [FeedItem] {
        [
            FeedItem(
                requestID: "demo-feed-permission",
                kind: "permission",
                title: "Read repo metadata",
                message: "Allow the agent to inspect git status, current branch, and changed files.",
                command: "git status --short && git diff --stat",
                workspaceID: "demo-review",
                surfaceID: "surface-review",
                agent: "Claude",
                createdAt: "2026-05-09T14:15:30Z",
                options: nil
            ),
            FeedItem(
                requestID: "demo-feed-question",
                kind: "question",
                title: "Choose review target",
                message: "Which PR comment should be handled first?",
                command: nil,
                workspaceID: "demo-jira",
                surfaceID: "surface-jira",
                agent: "Claude",
                createdAt: "2026-05-09T14:16:10Z",
                options: ["Git diff layout", "Jira ticket links", "Attachment uploads"]
            )
        ]
    }

    static func logEntries() -> [LogEntry] {
        [
            LogEntry(timestamp: "2026-05-09T14:15:10Z", workspace: 0, workspaceName: "Review dashboard polish", promptType: "manual", action: "user input", reason: "Requested a native Mac app shell", key: nil, surfaceId: "surface-review"),
            LogEntry(timestamp: "2026-05-09T14:15:35Z", workspace: 0, workspaceName: "Review dashboard polish", promptType: "haiku-auto-policy", action: "human alert", reason: "Permission request includes repo metadata access.", key: nil, surfaceId: "surface-review")
        ]
    }

    static func gitStatus() -> GitStatus {
        GitStatus(
            ok: true,
            branch: "feature/native-mac-harness",
            cwd: "~/Projects/sample-dashboard",
            staged: [
                GitFile(status: "M", file: "Sources/Dashboard/SessionList.swift")
            ],
            unstaged: [
                GitFile(status: "M", file: "Sources/Dashboard/GitDiffView.swift"),
                GitFile(status: "A", file: "Sources/Dashboard/MacServerSupervisor.swift")
            ],
            untracked: [
                "Tests/MacHarnessSmokeTests.swift"
            ],
            commits: [
                GitCommit(hash: "a1b2c3d", message: "Add mac harness shell"),
                GitCommit(hash: "d4e5f6a", message: "Port git detail panes")
            ],
            error: nil
        )
    }

    static func diff(for file: String) -> String {
        """
        diff --git a/\(file) b/\(file)
        index 23c5aa1..98be771 100644
        --- a/\(file)
        +++ b/\(file)
        @@ -18,6 +18,14 @@ struct SessionList: View {
             List(workspaces) { workspace in
                 SessionRow(workspace: workspace)
             }
        +
        +    ServerHealthStrip(
        +        phase: supervisor.phase,
        +        socketFound: status.socketFound,
        +        connected: status.connected
        +    )
        +
             .navigationTitle("cmux Harness")
         }
        """
    }

    static func prThreads() -> [GitHubPRThread] {
        [
            GitHubPRThread(
                id: "demo-pr-thread-1",
                path: "Sources/Dashboard/GitDiffView.swift",
                line: 42,
                isResolved: false,
                isOutdated: false,
                url: "https://github.com/example/sample/pull/42#discussion_r1",
                comments: [
                    GitHubPRComment(
                        id: "demo-pr-comment-1",
                        author: "reviewer",
                        bodyText: "This diff panel should preserve horizontal scrolling for long lines.",
                        createdAt: "2026-05-09T13:00:00Z",
                        url: "https://github.com/example/sample/pull/42#discussion_r1"
                    )
                ]
            )
        ]
    }

    static func jiraTickets() -> [JiraTicket] {
        [
            JiraTicket(key: "CMUX-128", summary: "Expose harness dashboard in native Mac app", status: "In Progress", url: "https://example.atlassian.net/browse/CMUX-128"),
            JiraTicket(key: "CMUX-141", summary: "Add Jira links to session prompts", status: "To Do", url: "https://example.atlassian.net/browse/CMUX-141")
        ]
    }

    static func fileMatches() -> [ProjectFileMatch] {
        [
            ProjectFileMatch(path: "Sources/Dashboard/ServerSupervisor.swift", score: 0.98, line: 12, preview: "final class ServerSupervisor: ObservableObject"),
            ProjectFileMatch(path: "Sources/Dashboard/GitDiffView.swift", score: 0.91, line: 4, preview: "struct GitDiffView: View")
        ]
    }

    static func skills() -> [ProjectSkill] {
        [
            ProjectSkill(name: "ios-parity-review", path: "~/.codex/skills/ios-parity-review/SKILL.md", description: "Check Mac views against the iOS harness behavior."),
            ProjectSkill(name: "release-smoke", path: "~/.codex/skills/release-smoke/SKILL.md", description: "Run local smoke gates before distribution.")
        ]
    }
}
