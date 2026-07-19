import ComposableArchitecture
import Foundation

enum HarnessLocalDemo {
    nonisolated static let baseURL = "cmux-demo://local/harness"

    nonisolated static func isDemoURL(_ value: String) -> Bool {
        HarnessAPI.normalizedBaseURL(value) == baseURL
    }
}

struct HarnessClient: Sendable {
    var discoverServers: @Sendable () async -> [DiscoveredHarnessServer]
    var probeServer: @Sendable (String) async -> Bool
    var status: @Sendable (String) async throws -> HarnessStatus
    var log: @Sendable (String) async throws -> [LogEntry]
    var notifications: @Sendable (String) async throws -> NotificationsResponse
    var feed: @Sendable (String) async throws -> FeedResponse
    var openCodeIntegration: @Sendable (String) async throws -> OpenCodeIntegrationResponse
    var installOpenCodeIntegration: @Sendable (String) async throws -> OpenCodeIntegrationResponse
    var replyToFeed: @Sendable (String, String, String, String?, String?, [String]?) async throws -> BasicResponse
    var screen: @Sendable (String, Int, Int) async throws -> ScreenResponse
    var setGlobalEnabled: @Sendable (String, Bool) async throws -> BasicResponse
    var setWorkspaceEnabled: @Sendable (String, Int, Bool) async throws -> BasicResponse
    var setWorkspaceAutoMode: @Sendable (String, Int, WorkspaceAutoMode) async throws -> BasicResponse
    var setWorkspaceStarred: @Sendable (String, Int, Bool) async throws -> BasicResponse
    var renameWorkspace: @Sendable (String, Int, String) async throws -> BasicResponse
    var sendText: @Sendable (String, Int, String, String?) async throws -> BasicResponse
    var sendKey: @Sendable (String, Int, HarnessKey, String?) async throws -> BasicResponse
    var createSession: @Sendable (
        String,
        String,
        String,
        String,
        String,
        NewSessionMode,
        String
    ) async throws -> NewSessionResponse
    var gitStatus: @Sendable (String, Int) async throws -> GitStatus
    var stageFile: @Sendable (String, Int, String) async throws -> BasicResponse
    var unstageFile: @Sendable (String, Int, String) async throws -> BasicResponse
    var diff: @Sendable (String, Int, String, GitFileSection) async throws -> GitDiffResponse
    var githubPRComments: @Sendable (String, Int, Bool) async throws -> GitHubPRCommentsResponse
    var skills: @Sendable (String, Int) async throws -> SkillsResponse
    var searchFiles: @Sendable (String, Int, String) async throws -> FileSearchResponse
    var assignedJiraTickets: @Sendable (String, String?, Int) async throws -> JiraTicketsResponse
    var jiraTicket: @Sendable (String, String) async throws -> JiraTicketResponse
    var uploadAttachment: @Sendable (String, Int, String, URL, String?) async throws -> AttachmentUploadResponse
    var clearPushApproval: @Sendable (String, String, String, String?) async throws -> BasicResponse
}

extension HarnessClient {
    nonisolated private static let liveDemoStore = LocalDemoHarnessStore()

    nonisolated static let live = liveClient(demoStore: liveDemoStore)

    nonisolated static var localDemo: Self {
        localDemoClient(store: LocalDemoHarnessStore())
    }

    nonisolated private static func liveClient(demoStore: LocalDemoHarnessStore) -> Self {
        Self(
            discoverServers: {
                await HarnessServerDiscovery.discover()
            },
            probeServer: { baseURLString in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return true
                }
                do {
                    _ = try await HarnessAPI.status(baseURLString: baseURLString)
                    return true
                } catch {
                    return false
                }
            },
            status: { baseURLString in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.status()
                }
                return try await HarnessAPI.status(baseURLString: baseURLString)
            },
            log: { baseURLString in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.log()
                }
                return try await HarnessAPI.log(baseURLString: baseURLString)
            },
            notifications: { baseURLString in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.notifications()
                }
                return try await HarnessAPI.notifications(baseURLString: baseURLString)
            },
            feed: { baseURLString in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.feed()
                }
                return try await HarnessAPI.feed(baseURLString: baseURLString)
            },
            openCodeIntegration: { baseURLString in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return OpenCodeIntegrationResponse(
                        ok: true,
                        status: "ready",
                        installed: true,
                        cmuxAvailable: true,
                        needsInstall: false,
                        needsRestart: false,
                        summary: "OpenCode native controls are enabled in the demo.",
                        error: nil
                    )
                }
                return try await HarnessAPI.openCodeIntegration(baseURLString: baseURLString)
            },
            installOpenCodeIntegration: { baseURLString in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return OpenCodeIntegrationResponse(
                        ok: true,
                        status: "ready",
                        installed: true,
                        cmuxAvailable: true,
                        needsInstall: false,
                        needsRestart: false,
                        summary: "OpenCode native controls are enabled in the demo.",
                        error: nil
                    )
                }
                return try await HarnessAPI.installOpenCodeIntegration(baseURLString: baseURLString)
            },
            replyToFeed: { baseURLString, requestID, kind, action, mode, selections in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.replyToFeed(requestID: requestID)
                }
                return try await HarnessAPI.replyToFeed(
                    baseURLString: baseURLString,
                    requestID: requestID,
                    kind: kind,
                    action: action,
                    mode: mode,
                    selections: selections
                )
            },
            screen: { baseURLString, index, lines in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.screen(index: index, lines: lines)
                }
                return try await HarnessAPI.screen(baseURLString: baseURLString, index: index, lines: lines)
            },
            setGlobalEnabled: { baseURLString, enabled in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.setGlobalEnabled(enabled)
                }
                return try await HarnessAPI.setGlobalEnabled(baseURLString: baseURLString, enabled: enabled)
            },
            setWorkspaceEnabled: { baseURLString, index, enabled in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.setWorkspaceEnabled(index: index, enabled: enabled)
                }
                return try await HarnessAPI.setWorkspaceEnabled(
                    baseURLString: baseURLString,
                    index: index,
                    enabled: enabled
                )
            },
            setWorkspaceAutoMode: { baseURLString, index, mode in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.setWorkspaceAutoMode(index: index, mode: mode)
                }
                return try await HarnessAPI.setWorkspaceAutoMode(
                    baseURLString: baseURLString,
                    index: index,
                    mode: mode
                )
            },
            setWorkspaceStarred: { baseURLString, index, starred in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.setWorkspaceStarred(index: index, starred: starred)
                }
                return try await HarnessAPI.setWorkspaceStarred(
                    baseURLString: baseURLString,
                    index: index,
                    starred: starred
                )
            },
            renameWorkspace: { baseURLString, index, name in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.renameWorkspace(index: index, name: name)
                }
                return try await HarnessAPI.renameWorkspace(baseURLString: baseURLString, index: index, name: name)
            },
            sendText: { baseURLString, index, text, surfaceId in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.sendText(index: index, text: text, surfaceId: surfaceId)
                }
                return try await HarnessAPI.sendText(
                    baseURLString: baseURLString,
                    index: index,
                    text: text,
                    surfaceId: surfaceId
                )
            },
            sendKey: { baseURLString, index, key, surfaceId in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.sendKey(index: index, key: key, surfaceId: surfaceId)
                }
                return try await HarnessAPI.sendKey(
                    baseURLString: baseURLString,
                    index: index,
                    key: key,
                    surfaceId: surfaceId
                )
            },
            createSession: { baseURLString, projectPath, branchName, jiraURL, prompt, mode, sessionName in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.createSession(
                        projectPath: projectPath,
                        branchName: branchName,
                        jiraURL: jiraURL,
                        prompt: prompt,
                        mode: mode,
                        sessionName: sessionName
                    )
                }
                return try await HarnessAPI.createSession(
                    baseURLString: baseURLString,
                    projectPath: projectPath,
                    branchName: branchName,
                    jiraURL: jiraURL,
                    prompt: prompt,
                    mode: mode,
                    sessionName: sessionName
                )
            },
            gitStatus: { baseURLString, index in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.gitStatus(index: index)
                }
                return try await HarnessAPI.gitStatus(baseURLString: baseURLString, index: index)
            },
            stageFile: { baseURLString, index, file in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.stageFile(index: index, file: file)
                }
                return try await HarnessAPI.stageFile(baseURLString: baseURLString, index: index, file: file)
            },
            unstageFile: { baseURLString, index, file in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.unstageFile(index: index, file: file)
                }
                return try await HarnessAPI.unstageFile(baseURLString: baseURLString, index: index, file: file)
            },
            diff: { baseURLString, index, file, section in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.diff(index: index, file: file, section: section)
                }
                return try await HarnessAPI.diff(baseURLString: baseURLString, index: index, file: file, section: section)
            },
            githubPRComments: { baseURLString, index, includeResolved in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.githubPRComments(index: index, includeResolved: includeResolved)
                }
                return try await HarnessAPI.githubPRComments(
                    baseURLString: baseURLString,
                    index: index,
                    includeResolved: includeResolved
                )
            },
            skills: { baseURLString, index in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.skills(index: index)
                }
                return try await HarnessAPI.skills(baseURLString: baseURLString, index: index)
            },
            searchFiles: { baseURLString, index, query in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.searchFiles(index: index, query: query)
                }
                return try await HarnessAPI.searchFiles(baseURLString: baseURLString, index: index, query: query)
            },
            assignedJiraTickets: { baseURLString, project, limit in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.assignedJiraTickets(project: project, limit: limit)
                }
                return try await HarnessAPI.assignedJiraTickets(
                    baseURLString: baseURLString,
                    project: project,
                    limit: limit
                )
            },
            jiraTicket: { baseURLString, query in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.jiraTicket(query: query)
                }
                return try await HarnessAPI.jiraTicket(baseURLString: baseURLString, query: query)
            },
            uploadAttachment: { baseURLString, workspaceIndex, workspaceUUID, fileURL, filename in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return await demoStore.uploadAttachment(
                        workspaceIndex: workspaceIndex,
                        workspaceUUID: workspaceUUID,
                        fileURL: fileURL,
                        filename: filename
                    )
                }
                return try await HarnessAPI.uploadAttachment(
                    baseURLString: baseURLString,
                    workspaceIndex: workspaceIndex,
                    workspaceUUID: workspaceUUID,
                    fileURL: fileURL,
                    filename: filename
                )
            },
            clearPushApproval: { baseURLString, workspaceID, workspaceUUID, surfaceID in
                if HarnessLocalDemo.isDemoURL(baseURLString) {
                    return BasicResponse(ok: true, enabled: nil, error: nil)
                }
                return try await HarnessAPI.clearPushApproval(
                    baseURLString: baseURLString,
                    workspaceID: workspaceID,
                    workspaceUUID: workspaceUUID,
                    surfaceID: surfaceID
                )
            }
        )
    }

    nonisolated private static func localDemoClient(store: LocalDemoHarnessStore) -> Self {
        Self(
            discoverServers: { [] },
            probeServer: { HarnessLocalDemo.isDemoURL($0) },
            status: { _ in await store.status() },
            log: { _ in await store.log() },
            notifications: { _ in await store.notifications() },
            feed: { _ in await store.feed() },
            openCodeIntegration: { _ in
                OpenCodeIntegrationResponse(
                    ok: true,
                    status: "ready",
                    installed: true,
                    cmuxAvailable: true,
                    needsInstall: false,
                    needsRestart: false,
                    summary: "OpenCode native controls are enabled in the demo.",
                    error: nil
                )
            },
            installOpenCodeIntegration: { _ in
                OpenCodeIntegrationResponse(
                    ok: true,
                    status: "ready",
                    installed: true,
                    cmuxAvailable: true,
                    needsInstall: false,
                    needsRestart: false,
                    summary: "OpenCode native controls are enabled in the demo.",
                    error: nil
                )
            },
            replyToFeed: { _, requestID, _, _, _, _ in await store.replyToFeed(requestID: requestID) },
            screen: { _, index, lines in await store.screen(index: index, lines: lines) },
            setGlobalEnabled: { _, enabled in await store.setGlobalEnabled(enabled) },
            setWorkspaceEnabled: { _, index, enabled in await store.setWorkspaceEnabled(index: index, enabled: enabled) },
            setWorkspaceAutoMode: { _, index, mode in await store.setWorkspaceAutoMode(index: index, mode: mode) },
            setWorkspaceStarred: { _, index, starred in await store.setWorkspaceStarred(index: index, starred: starred) },
            renameWorkspace: { _, index, name in await store.renameWorkspace(index: index, name: name) },
            sendText: { _, index, text, surfaceId in await store.sendText(index: index, text: text, surfaceId: surfaceId) },
            sendKey: { _, index, key, surfaceId in await store.sendKey(index: index, key: key, surfaceId: surfaceId) },
            createSession: { _, projectPath, branchName, jiraURL, prompt, mode, sessionName in
                await store.createSession(
                    projectPath: projectPath,
                    branchName: branchName,
                    jiraURL: jiraURL,
                    prompt: prompt,
                    mode: mode,
                    sessionName: sessionName
                )
            },
            gitStatus: { _, index in await store.gitStatus(index: index) },
            stageFile: { _, index, file in await store.stageFile(index: index, file: file) },
            unstageFile: { _, index, file in await store.unstageFile(index: index, file: file) },
            diff: { _, index, file, section in await store.diff(index: index, file: file, section: section) },
            githubPRComments: { _, index, includeResolved in
                await store.githubPRComments(index: index, includeResolved: includeResolved)
            },
            skills: { _, index in await store.skills(index: index) },
            searchFiles: { _, index, query in await store.searchFiles(index: index, query: query) },
            assignedJiraTickets: { _, project, limit in await store.assignedJiraTickets(project: project, limit: limit) },
            jiraTicket: { _, query in await store.jiraTicket(query: query) },
            uploadAttachment: { _, workspaceIndex, workspaceUUID, fileURL, filename in
                await store.uploadAttachment(
                    workspaceIndex: workspaceIndex,
                    workspaceUUID: workspaceUUID,
                    fileURL: fileURL,
                    filename: filename
                )
            },
            clearPushApproval: { _, _, _, _ in BasicResponse(ok: true, enabled: nil, error: nil) }
        )
    }
}

private actor LocalDemoHarnessStore {
    private var globalEnabled = true
    private var nextWorkspaceIndex = 5
    private var workspaces: [Workspace]
    private var screenByIndex: [Int: String]
    private var logEntries: [LogEntry]
    private var feedItems: [FeedItem]

    init() {
        let seeds = Self.seedWorkspaces()
        self.workspaces = seeds
        self.screenByIndex = Dictionary(uniqueKeysWithValues: seeds.map { ($0.index, Self.seedScreen(for: $0.index)) })
        self.logEntries = Self.seedLogEntries()
        self.feedItems = Self.seedFeedItems()
    }

    func status() -> HarnessStatus {
        let now = Date().timeIntervalSince1970
        return HarnessStatus(
            enabled: globalEnabled,
            workspaces: workspaces.map { workspace in
                var copy = workspace
                let screen = screenByIndex[workspace.index] ?? workspace.screenFull ?? ""
                copy.screenFull = screen
                copy.screenTail = Self.tail(screen, maxLines: 10)
                copy.lastCheck = Self.isoTimestamp()
                return copy
            },
            pollInterval: 2,
            socketFound: true,
            model: "local-demo",
            reviewEnabled: true,
            reviewModel: "local-demo",
            reviewBackend: "on-device",
            contractReviewEnabled: false,
            connected: true,
            lastSuccessfulPoll: now,
            connectionLostAt: nil,
            staleData: false,
            ollamaAvailable: nil
        )
    }

    func log() -> [LogEntry] {
        logEntries
    }

    func notifications() -> NotificationsResponse {
        let now = ISO8601DateFormatter().string(from: Date())
        let unread = CmuxNotification(
            id: "demo-notif-1",
            title: "Session done",
            body: "Review PR #423",
            subtitle: "",
            createdAt: now,
            isRead: false,
            workspaceId: "demo-workspace-1",
            workspaceRef: "workspace:1",
            surfaceId: "demo-surface-1",
            surfaceRef: "surface:1",
            tabTitle: "sample-app : Review PR comments"
        )
        return NotificationsResponse(ok: true, notifications: [unread], error: nil)
    }

    func feed() -> FeedResponse {
        FeedResponse(ok: true, items: feedItems, error: nil)
    }

    func replyToFeed(requestID: String) -> BasicResponse {
        feedItems.removeAll { $0.requestID == requestID }
        return BasicResponse(ok: true, enabled: nil, error: nil)
    }

    func screen(index: Int, lines: Int) -> ScreenResponse {
        let screen = screenByIndex[index] ?? "Demo session \(index)\nNo terminal output yet."
        return ScreenResponse(ok: true, screen: Self.tail(screen, maxLines: max(lines, 1)), lines: lines, error: nil)
    }

    func setGlobalEnabled(_ enabled: Bool) -> BasicResponse {
        globalEnabled = enabled
        return BasicResponse(ok: true, enabled: enabled, error: nil)
    }

    func setWorkspaceEnabled(index: Int, enabled: Bool) -> BasicResponse {
        setWorkspaceAutoMode(index: index, mode: enabled ? .auto : .off)
    }

    func setWorkspaceAutoMode(index: Int, mode: WorkspaceAutoMode) -> BasicResponse {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.index == index }) else {
            return BasicResponse(ok: false, enabled: nil, error: "Demo workspace not found")
        }
        workspaces[workspaceIndex].enabled = mode.isEnabled
        workspaces[workspaceIndex].autoMode = mode
        workspaces[workspaceIndex].autoEnabledAt = mode.isEnabled ? Date().timeIntervalSince1970 : nil
        workspaces[workspaceIndex].autoExpiresAt = nil
        return BasicResponse(ok: true, enabled: mode.isEnabled, error: nil)
    }

    func setWorkspaceStarred(index: Int, starred: Bool) -> BasicResponse {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.index == index }) else {
            return BasicResponse(ok: false, enabled: nil, error: "Demo workspace not found")
        }
        workspaces[workspaceIndex].starred = starred
        return BasicResponse(ok: true, enabled: nil, error: nil)
    }

    func renameWorkspace(index: Int, name: String) -> BasicResponse {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.index == index }) else {
            return BasicResponse(ok: false, enabled: nil, error: "Demo workspace not found")
        }
        workspaces[workspaceIndex].customName = name
        appendLog(index: index, action: "Renamed demo session", reason: name)
        return BasicResponse(ok: true, enabled: nil, error: nil)
    }

    func sendText(index: Int, text: String, surfaceId: String?) -> BasicResponse {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return BasicResponse(ok: true, enabled: nil, error: nil)
        }
        appendScreen(
            index: index,
            lines: [
                "",
                "$ \(prompt)",
                "Demo response: this prompt was accepted locally on the iPhone.",
                "In a real cmux session, the Mac dashboard would forward it to the selected terminal surface.",
                "Suggested next step: connect this app to your own dashboard when you are ready.",
            ]
        )
        appendLog(index: index, action: "Demo prompt sent", reason: prompt)
        return BasicResponse(ok: true, enabled: nil, error: nil)
    }

    func sendKey(index: Int, key: HarnessKey, surfaceId: String?) -> BasicResponse {
        appendScreen(index: index, lines: ["", "Demo key event: \(key.rawValue)"])
        appendLog(index: index, action: "Demo key sent", reason: key.rawValue)
        return BasicResponse(ok: true, enabled: nil, error: nil)
    }

    func createSession(
        projectPath: String,
        branchName: String,
        jiraURL: String,
        prompt: String,
        mode: NewSessionMode,
        sessionName: String
    ) -> NewSessionResponse {
        let index = nextWorkspaceIndex
        nextWorkspaceIndex += 1

        let trimmedName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = mode == .shell
            ? (trimmedName.isEmpty ? "Demo Shell" : trimmedName)
            : "Demo Task \(index)"
        let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "~/Projects/sample-app"
            : projectPath
        let uuid = "demo-workspace-\(index)"
        let surfaceId = "demo-surface-\(index)"
        let workspace = Workspace(
            hasClaude: mode != .shell,
            index: index,
            name: displayName,
            uuid: uuid,
            enabled: true,
            autoMode: .auto,
            starred: false,
            autoEnabledAt: Date().timeIntervalSince1970,
            autoExpiresAt: nil,
            customName: displayName,
            lastCheck: Self.isoTimestamp(),
            screenTail: nil,
            screenFull: nil,
            cwd: cwd,
            branch: branch.isEmpty ? "demo/new-session-\(index)" : branch,
            sessionStart: Date().timeIntervalSince1970,
            sessionCost: "$0.00",
            surfaceId: surfaceId,
            surfaceUuid: surfaceId,
            surfaceLabel: displayName,
            surfaceTitle: "Local Demo",
            gitDirty: false,
            surfaceCreatedAt: Self.isoTimestamp(),
            surfaceAge: 0
        )
        workspaces.append(workspace)
        screenByIndex[index] = """
        cmux local demo
        Created \(displayName)

        Project: \(cwd)
        Branch: \(branch.isEmpty ? "demo/new-session-\(index)" : branch)

        \(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No initial prompt was provided." : "Initial prompt: \(prompt)")
        """
        appendLog(index: index, action: "Created demo session", reason: displayName)
        return NewSessionResponse(
            ok: true,
            workspace: NewSessionResponse.CreatedWorkspace(index: index, uuid: uuid),
            worktreePath: cwd,
            branchName: branch,
            error: nil
        )
    }

    func gitStatus(index: Int) -> GitStatus {
        GitStatus(
            ok: true,
            branch: "feature/local-demo-onboarding",
            cwd: workspace(index: index)?.cwd ?? "~/Projects/sample-app",
            staged: [
                GitFile(status: "M", file: "Sources/App/OnboardingView.swift"),
            ],
            unstaged: [
                GitFile(status: "M", file: "Sources/App/DashboardClient.swift"),
                GitFile(status: "A", file: "Sources/App/DemoModeBanner.swift"),
            ],
            untracked: [
                "Tests/DemoModeTests.swift",
            ],
            commits: [
                GitCommit(hash: "a1b2c3d", message: "Add connection setup screen"),
                GitCommit(hash: "d4e5f6a", message: "Improve session detail controls"),
            ],
            error: nil
        )
    }

    func stageFile(index: Int, file: String) -> BasicResponse {
        appendLog(index: index, action: "Demo staged file", reason: file)
        return BasicResponse(ok: true, enabled: nil, error: nil)
    }

    func unstageFile(index: Int, file: String) -> BasicResponse {
        appendLog(index: index, action: "Demo unstaged file", reason: file)
        return BasicResponse(ok: true, enabled: nil, error: nil)
    }

    func diff(index: Int, file: String, section: GitFileSection) -> GitDiffResponse {
        GitDiffResponse(
            ok: true,
            diff: """
            diff --git a/\(file) b/\(file)
            index 1a2b3c4..5d6e7f8 100644
            --- a/\(file)
            +++ b/\(file)
            @@ -12,6 +12,12 @@ struct OnboardingView: View {
                 Text("Connect to your Mac")
                     .font(.headline)

            +    DemoModeBanner(
            +        title: "Local demo mode",
            +        message: "Everything here is simulated on this iPhone."
            +    )
            +
                 Button("Scan LAN") {
                     store.send(.discoverServer)
                 }
            """,
            error: nil
        )
    }

    func githubPRComments(index: Int, includeResolved: Bool) -> GitHubPRCommentsResponse {
        let activeThread = GitHubPRThread(
            id: "demo-thread-1",
            path: "Sources/App/OnboardingView.swift",
            line: 42,
            originalLine: 42,
            startLine: nil,
            originalStartLine: nil,
            diffSide: "RIGHT",
            startDiffSide: "",
            subjectType: "LINE",
            isResolved: false,
            isOutdated: false,
            url: "https://github.com/example-org/sample-app/pull/128#discussion_r42",
            codeContext: GitHubPRCodeContext(
                path: "Sources/App/OnboardingView.swift",
                source: "local-demo",
                startLine: 40,
                endLine: 44,
                lines: [
                    GitHubPRCodeLine(number: 40, text: "VStack(alignment: .leading) {", isTarget: false),
                    GitHubPRCodeLine(number: 41, text: "Text(\"Try the demo\")", isTarget: false),
                    GitHubPRCodeLine(number: 42, text: "Button(\"Start\") { startDemo() }", isTarget: true),
                    GitHubPRCodeLine(number: 43, text: "}", isTarget: false),
                ]
            ),
            comments: [
                GitHubPRComment(
                    id: "demo-comment-1",
                    author: "reviewer",
                    body: "Make this CTA clearly say that no Mac server is required.",
                    bodyText: "Make this CTA clearly say that no Mac server is required.",
                    createdAt: "2026-05-05T12:00:00Z",
                    updatedAt: "2026-05-05T12:00:00Z",
                    url: "https://github.com/example-org/sample-app/pull/128#discussion_r42",
                    diffHunk: "@@ -40,4 +40,5 @@",
                    path: "Sources/App/OnboardingView.swift",
                    line: 42,
                    originalLine: 42
                ),
            ]
        )
        let resolvedThread = GitHubPRThread(
            id: "demo-thread-2",
            path: "Sources/App/DashboardClient.swift",
            line: 18,
            originalLine: 18,
            startLine: nil,
            originalStartLine: nil,
            diffSide: "RIGHT",
            startDiffSide: "",
            subjectType: "LINE",
            isResolved: true,
            isOutdated: false,
            url: "https://github.com/example-org/sample-app/pull/128#discussion_r18",
            codeContext: nil,
            comments: [
                GitHubPRComment(
                    id: "demo-comment-2",
                    author: "reviewer",
                    body: "This fallback copy looks good.",
                    bodyText: "This fallback copy looks good.",
                    createdAt: "2026-05-05T11:30:00Z",
                    updatedAt: "2026-05-05T11:30:00Z",
                    url: "https://github.com/example-org/sample-app/pull/128#discussion_r18",
                    diffHunk: "",
                    path: "Sources/App/DashboardClient.swift",
                    line: 18,
                    originalLine: 18
                ),
            ]
        )
        let visibleThreads = includeResolved ? [activeThread, resolvedThread] : [activeThread]
        return GitHubPRCommentsResponse(
            ok: true,
            cwd: workspace(index: index)?.cwd ?? "~/Projects/sample-app",
            repository: GitHubRepository(
                owner: "example-org",
                name: "sample-app",
                url: "https://github.com/example-org/sample-app"
            ),
            pullRequest: GitHubPullRequest(
                number: 128,
                title: "Add iPhone dashboard onboarding",
                url: "https://github.com/example-org/sample-app/pull/128",
                headRefName: "feature/local-demo-onboarding",
                baseRefName: "main",
                state: "OPEN",
                author: "teammate"
            ),
            includeResolved: includeResolved,
            threads: visibleThreads,
            files: [
                GitHubPRFileGroup(
                    path: "Sources/App/OnboardingView.swift",
                    threadCount: 1,
                    threads: [activeThread]
                ),
            ],
            totalThreadCount: 2,
            returnedThreadCount: visibleThreads.count,
            resolvedThreadCount: 1,
            hiddenResolvedCount: includeResolved ? 0 : 1,
            error: nil
        )
    }

    func skills(index: Int) -> SkillsResponse {
        let projectSkill = ProjectSkill(
            name: "ios-ui-review",
            skillFilePath: ".claude/skills/ios-ui-review/SKILL.md",
            scope: "project"
        )
        let userSkill = ProjectSkill(
            name: "release-checklist",
            skillFilePath: "~/.claude/skills/release-checklist/SKILL.md",
            scope: "user"
        )
        return SkillsResponse(
            ok: true,
            rootPath: workspace(index: index)?.cwd ?? "~/Projects/sample-app",
            skillsDirectory: ".claude/skills",
            userSkillsDirectory: "~/.claude/skills",
            projectSkills: [projectSkill],
            userSkills: [userSkill],
            skills: [projectSkill, userSkill],
            error: nil
        )
    }

    func searchFiles(index: Int, query: String) -> FileSearchResponse {
        let allFiles = [
            "Sources/App/OnboardingView.swift",
            "Sources/App/DashboardClient.swift",
            "Sources/App/DemoModeBanner.swift",
            "Sources/App/SessionListView.swift",
            "Tests/DemoModeTests.swift",
        ]
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = allFiles
            .filter { trimmedQuery.isEmpty || $0.localizedCaseInsensitiveContains(trimmedQuery) }
            .map(ProjectFileMatch.init(path:))
        return FileSearchResponse(
            ok: true,
            rootPath: workspace(index: index)?.cwd ?? "~/Projects/sample-app",
            query: query,
            files: matches,
            truncated: false,
            limit: 80,
            error: nil
        )
    }

    func assignedJiraTickets(project: String?, limit: Int) -> JiraTicketsResponse {
        let tickets = Self.seedJiraTickets()
        let filtered = project.flatMap { project in
            let normalized = project.uppercased()
            return tickets.filter { $0.projectKey?.uppercased() == normalized }
        } ?? tickets
        return JiraTicketsResponse(
            ok: true,
            project: project,
            projects: ["APP", "WEB"],
            site: "example.atlassian.net",
            tickets: Array(filtered.prefix(limit)),
            error: nil
        )
    }

    func jiraTicket(query: String) -> JiraTicketResponse {
        let normalized = jiraKey(from: query) ?? query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let ticket = Self.seedJiraTickets().first { $0.key.uppercased() == normalized }
            ?? Self.seedJiraTickets().first
        return JiraTicketResponse(ok: ticket != nil, site: "example.atlassian.net", ticket: ticket, error: nil)
    }

    func uploadAttachment(
        workspaceIndex: Int,
        workspaceUUID: String,
        fileURL: URL,
        filename: String?
    ) -> AttachmentUploadResponse {
        let originalFilename = filename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? filename!
            : fileURL.lastPathComponent
        return AttachmentUploadResponse(
            ok: true,
            attachment: UploadedAttachment(
                id: UUID().uuidString,
                filename: originalFilename,
                originalFilename: originalFilename,
                contentType: "application/octet-stream",
                size: 1024,
                path: "/tmp/cmux-local-demo/\(workspaceUUID)/\(originalFilename)",
                workspaceKey: workspaceUUID,
                createdAt: Self.isoTimestamp()
            ),
            error: nil
        )
    }

    private func workspace(index: Int) -> Workspace? {
        workspaces.first { $0.index == index }
    }

    private func appendScreen(index: Int, lines: [String]) {
        let existing = screenByIndex[index] ?? ""
        screenByIndex[index] = (existing + "\n" + lines.joined(separator: "\n"))
            .trimmingCharacters(in: .newlines)
    }

    private func appendLog(index: Int, action: String, reason: String?) {
        let workspace = workspace(index: index)
        logEntries.insert(
            LogEntry(
                timestamp: Self.isoTimestamp(),
                workspace: index,
                workspaceName: workspace?.name,
                promptType: "demo",
                action: action,
                reason: reason,
                key: nil,
                surfaceId: workspace?.surfaceId,
                sessionID: workspace?.uuid
            ),
            at: 0
        )
        logEntries = Array(logEntries.prefix(30))
    }

    private static func seedWorkspaces() -> [Workspace] {
        [
            Workspace(
                hasClaude: true,
                index: 0,
                name: "sample-app : Polish onboarding",
                uuid: "demo-workspace-0",
                enabled: true,
                autoMode: .superAuto,
                starred: true,
                autoEnabledAt: Date().timeIntervalSince1970 - 900,
                autoExpiresAt: nil,
                customName: nil,
                lastCheck: isoTimestamp(),
                screenTail: nil,
                screenFull: nil,
                cwd: "~/Projects/sample-app",
                branch: "feature/local-demo-onboarding",
                sessionStart: Date().timeIntervalSince1970 - 3_600,
                sessionCost: "$0.00",
                surfaceId: "demo-surface-0",
                surfaceUuid: "demo-surface-0",
                surfaceLabel: "Onboarding polish",
                surfaceTitle: "Local Demo",
                gitDirty: true,
                surfaceCreatedAt: isoTimestamp(),
                surfaceAge: 3_600
            ),
            Workspace(
                hasClaude: true,
                index: 1,
                name: "sample-app : Review PR comments",
                uuid: "demo-workspace-1",
                enabled: true,
                autoMode: .auto,
                starred: false,
                autoEnabledAt: Date().timeIntervalSince1970 - 600,
                autoExpiresAt: nil,
                customName: nil,
                lastCheck: isoTimestamp(),
                screenTail: nil,
                screenFull: nil,
                cwd: "~/Projects/sample-app",
                branch: "feature/pr-review-flow",
                sessionStart: Date().timeIntervalSince1970 - 2_400,
                sessionCost: "$0.00",
                surfaceId: "demo-surface-1",
                surfaceUuid: "demo-surface-1",
                surfaceLabel: "PR review",
                surfaceTitle: "Local Demo",
                gitDirty: true,
                surfaceCreatedAt: isoTimestamp(),
                surfaceAge: 2_400
            ),
            Workspace(
                hasClaude: false,
                index: 2,
                name: "sample-app : Shell",
                uuid: "demo-workspace-2",
                enabled: false,
                autoMode: .off,
                starred: false,
                autoEnabledAt: nil,
                autoExpiresAt: nil,
                customName: "Build shell",
                lastCheck: isoTimestamp(),
                screenTail: nil,
                screenFull: nil,
                cwd: "~/Projects/sample-app",
                branch: "main",
                sessionStart: Date().timeIntervalSince1970 - 1_800,
                sessionCost: "$0.00",
                surfaceId: "demo-surface-2",
                surfaceUuid: "demo-surface-2",
                surfaceLabel: "Build shell",
                surfaceTitle: "Local Demo",
                gitDirty: false,
                surfaceCreatedAt: isoTimestamp(),
                surfaceAge: 1_800
            ),
            Workspace(
                hasClaude: true,
                index: 3,
                name: "sample-app : OpenCode question fallback",
                uuid: "demo-workspace-3",
                enabled: false,
                autoMode: .off,
                starred: false,
                autoEnabledAt: nil,
                autoExpiresAt: nil,
                customName: "OpenCode question fallback",
                lastCheck: isoTimestamp(),
                screenTail: nil,
                screenFull: nil,
                cwd: "~/Projects/sample-app",
                branch: "feature/opencode-remote-questions",
                sessionStart: Date().timeIntervalSince1970 - 1_200,
                sessionCost: "$0.00",
                surfaceId: "demo-surface-3",
                surfaceUuid: "demo-surface-3",
                surfaceLabel: "OpenCode question fallback",
                surfaceTitle: "Local Demo",
                gitDirty: false,
                surfaceCreatedAt: isoTimestamp(),
                surfaceAge: 1_200
            ),
            Workspace(
                hasClaude: true,
                index: 4,
                name: "sample-app : OpenCode review fallback",
                uuid: "demo-workspace-4",
                enabled: false,
                autoMode: .off,
                starred: false,
                autoEnabledAt: nil,
                autoExpiresAt: nil,
                customName: "OpenCode review fallback",
                lastCheck: isoTimestamp(),
                screenTail: nil,
                screenFull: nil,
                cwd: "~/Projects/sample-app",
                branch: "feature/opencode-remote-questions",
                sessionStart: Date().timeIntervalSince1970 - 900,
                sessionCost: "$0.00",
                surfaceId: "demo-surface-4",
                surfaceUuid: "demo-surface-4",
                surfaceLabel: "OpenCode review fallback",
                surfaceTitle: "Local Demo",
                gitDirty: false,
                surfaceCreatedAt: isoTimestamp(),
                surfaceAge: 900
            ),
        ]
    }

    private static func seedScreen(for index: Int) -> String {
        switch index {
        case 0:
            return """
            cmux local demo - simulated terminal

            $ git status --short
             M Sources/App/OnboardingView.swift
             M Sources/App/DashboardClient.swift
            ?? Tests/DemoModeTests.swift

            Reviewing onboarding copy...
            Found one place where the setup screen can better explain LAN and Tailscale.
            Waiting for your input before applying the next change.
            """
        case 1:
            return """
            cmux local demo - simulated PR review

            Loading GitHub review comments with gh...
            1 active thread found on Sources/App/OnboardingView.swift.

            Suggested fix:
            - Make the demo CTA explicit.
            - Add a persistent banner while demo mode is active.
            """
        case 2:
            return """
            │  △ Permission required
            │  ← Access external directory /tmp
            │
            │  Patterns
            │
            │  - /tmp/*
            │
            │     Allow once    Allow always    Reject
            ctrl+f fullscreen   ⇆ select   enter
            confirm
            │
            • OpenCode 1.18.3
            """
        case 3:
            return """
            → Asked 3 questions

            ▣ Build · DeepSeek V4 Flash

            │ Build method   Export method   Configuration   Confirm
            │
            │ How do you want to build/publish the iOS app?
            │
            │ 1. Build from current branch (default)   /Volumes/PROJECTS/Development/
            │    Build and archive from the current Git branch, then publish via tailnet
            │ 2. Publish an existing IPA   Doximity-Claude-IOSDOX-26368-markdown-text-selection
            │    Skip building and publish an existing .ipa file
            │ 3. Export from existing archive   rr/feature/IOSDOX-26368-markdown-text-selection
            │    Export and publish from a pre-existing .xcarchive
            │ 4. Type your own answer   /Volumes/PROJECTS/Development/
            │
            │ ⇆ tab   ↑↓ select   enter confirm   esc dismiss
            │
            • OpenCode 1.18.3
            """
        case 4:
            return """
            → Asked 3 questions

            ▣ Build · DeepSeek V4 Flash

            │ Build method   Export method   Configuration   Confirm
            │
            │ Review
            │
            │ Build method: Build from current branch (default)
            │
            │ Export method: development (Recommended)
            │
            │ Configuration: Debug (default)
            │
            │ ⇆ tab   enter submit   esc dismiss
            │
            • OpenCode 1.18.3
            """
        default:
            return "Demo session \(index)\nNo terminal output yet."
        }
    }

    private static func seedLogEntries() -> [LogEntry] {
        [
            LogEntry(
                timestamp: isoTimestamp(),
                workspace: 0,
                workspaceName: "sample-app : Polish onboarding",
                promptType: "demo",
                action: "Waiting for human input",
                reason: "Review the suggested onboarding copy.",
                key: nil,
                surfaceId: "demo-surface-0",
                sessionID: "demo-workspace-0"
            ),
            LogEntry(
                timestamp: isoTimestamp(),
                workspace: 1,
                workspaceName: "sample-app : Review PR comments",
                promptType: "demo",
                action: "Activity",
                reason: "Loaded one active PR review thread.",
                key: nil,
                surfaceId: "demo-surface-1",
                sessionID: "demo-workspace-1"
            ),
        ]
    }

    private static func seedJiraTickets() -> [JiraTicket] {
        [
            JiraTicket(
                key: "APP-1042",
                projectKey: "APP",
                title: "Make iPhone setup understandable without a Mac server",
                status: "In Progress",
                priority: "High",
                issueType: "Story",
                url: "https://example.atlassian.net/browse/APP-1042"
            ),
            JiraTicket(
                key: "WEB-218",
                projectKey: "WEB",
                title: "Show dashboard readiness checks on the homepage",
                status: "Selected for Development",
                priority: "Medium",
                issueType: "Task",
                url: "https://example.atlassian.net/browse/WEB-218"
            ),
        ]
    }

    private static func seedFeedItems() -> [FeedItem] {
        [
            FeedItem(
                requestID: "demo-opencode-permission",
                kind: "permission",
                title: "Access external directory",
                message: "OpenCode needs access outside this workspace.",
                command: nil,
                workspaceID: "demo-workspace-0",
                surfaceID: "demo-surface-0",
                agent: "OpenCode",
                createdAt: isoTimestamp(),
                options: nil,
                permissionType: "external_directory",
                patterns: ["/tmp/*"],
                questions: nil
            ),
            FeedItem(
                requestID: "demo-opencode-question",
                kind: "question",
                title: "Choose deployment target",
                message: nil,
                command: nil,
                workspaceID: "demo-workspace-1",
                surfaceID: "demo-surface-1",
                agent: "OpenCode",
                createdAt: isoTimestamp(),
                options: nil,
                permissionType: nil,
                patterns: nil,
                questions: [
                    FeedItem.Question(
                        id: "build-method",
                        header: "Build method",
                        question: "How do you want to build/publish the iOS app?",
                        multiSelect: false,
                        options: [
                            FeedItem.Option(
                                id: "current-branch",
                                label: "Build from current branch (default)",
                                description: "Build and archive from the current Git branch, then publish via tailnet."
                            ),
                            FeedItem.Option(
                                id: "existing-ipa",
                                label: "Publish an existing IPA",
                                description: "Skip building and publish an existing .ipa file."
                            ),
                            FeedItem.Option(
                                id: "existing-archive",
                                label: "Export from existing archive",
                                description: "Export and publish from a pre-existing .xcarchive."
                            ),
                        ]
                    ),
                    FeedItem.Question(
                        id: "export-method",
                        header: "Export method",
                        question: "Which export method?",
                        multiSelect: false,
                        options: [
                            FeedItem.Option(
                                id: "development",
                                label: "development (Recommended)",
                                description: "Best for a personal device in the development provisioning profile."
                            ),
                            FeedItem.Option(
                                id: "ad-hoc",
                                label: "ad-hoc",
                                description: "Better for sharing with multiple registered devices."
                            ),
                        ]
                    ),
                    FeedItem.Question(
                        id: "configuration",
                        header: "Configuration",
                        question: "Which build configuration?",
                        multiSelect: false,
                        options: [
                            FeedItem.Option(
                                id: "debug",
                                label: "Debug (default)",
                                description: "Keep debug symbols and development diagnostics enabled."
                            ),
                            FeedItem.Option(
                                id: "release",
                                label: "Release",
                                description: "Use optimized release build settings."
                            ),
                        ]
                    ),
                ]
            ),
        ]
    }

    private static func tail(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private static func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

enum HarnessClientError: Error, Equatable, Sendable {
    case unimplemented(String)
}

extension HarnessClient {
    nonisolated static let unimplemented = Self(
        discoverServers: { [] },
        probeServer: { _ in false },
        status: { _ in throw HarnessClientError.unimplemented("status") },
        log: { _ in throw HarnessClientError.unimplemented("log") },
        notifications: { _ in throw HarnessClientError.unimplemented("notifications") },
        feed: { _ in throw HarnessClientError.unimplemented("feed") },
        openCodeIntegration: { _ in throw HarnessClientError.unimplemented("openCodeIntegration") },
        installOpenCodeIntegration: { _ in throw HarnessClientError.unimplemented("installOpenCodeIntegration") },
        replyToFeed: { _, _, _, _, _, _ in throw HarnessClientError.unimplemented("replyToFeed") },
        screen: { _, _, _ in throw HarnessClientError.unimplemented("screen") },
        setGlobalEnabled: { _, _ in throw HarnessClientError.unimplemented("setGlobalEnabled") },
        setWorkspaceEnabled: { _, _, _ in throw HarnessClientError.unimplemented("setWorkspaceEnabled") },
        setWorkspaceAutoMode: { _, _, _ in throw HarnessClientError.unimplemented("setWorkspaceAutoMode") },
        setWorkspaceStarred: { _, _, _ in throw HarnessClientError.unimplemented("setWorkspaceStarred") },
        renameWorkspace: { _, _, _ in throw HarnessClientError.unimplemented("renameWorkspace") },
        sendText: { _, _, _, _ in throw HarnessClientError.unimplemented("sendText") },
        sendKey: { _, _, _, _ in throw HarnessClientError.unimplemented("sendKey") },
        createSession: { _, _, _, _, _, _, _ in throw HarnessClientError.unimplemented("createSession") },
        gitStatus: { _, _ in throw HarnessClientError.unimplemented("gitStatus") },
        stageFile: { _, _, _ in throw HarnessClientError.unimplemented("stageFile") },
        unstageFile: { _, _, _ in throw HarnessClientError.unimplemented("unstageFile") },
        diff: { _, _, _, _ in throw HarnessClientError.unimplemented("diff") },
        githubPRComments: { _, _, _ in throw HarnessClientError.unimplemented("githubPRComments") },
        skills: { _, _ in throw HarnessClientError.unimplemented("skills") },
        searchFiles: { _, _, _ in throw HarnessClientError.unimplemented("searchFiles") },
        assignedJiraTickets: { _, _, _ in throw HarnessClientError.unimplemented("assignedJiraTickets") },
        jiraTicket: { _, _ in throw HarnessClientError.unimplemented("jiraTicket") },
        uploadAttachment: { _, _, _, _, _ in throw HarnessClientError.unimplemented("uploadAttachment") },
        clearPushApproval: { _, _, _, _ in throw HarnessClientError.unimplemented("clearPushApproval") }
    )
}

private enum HarnessClientKey: DependencyKey {
    static let liveValue = HarnessClient.live
    static let testValue = HarnessClient.unimplemented
}

extension DependencyValues {
    var harnessClient: HarnessClient {
        get { self[HarnessClientKey.self] }
        set { self[HarnessClientKey.self] = newValue }
    }
}
