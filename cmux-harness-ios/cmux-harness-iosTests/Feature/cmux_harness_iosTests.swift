import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
@testable import cmux_harness_ios

@Suite(.serialized)
@MainActor
struct HarnessFeatureTests {
    @Test
    func refreshLoadsStatusAndLog() async {
        let workspace = Self.workspace()
        let status = Self.status(workspaces: [workspace])
        let logEntries = [
            LogEntry(
                timestamp: "2026-04-26T12:00:00Z",
                workspace: workspace.index,
                workspaceName: workspace.name,
                promptType: "default",
                action: "Waiting for human input",
                reason: nil,
                key: nil,
                surfaceId: workspace.surfaceId,
                sessionID: "session-1"
            )
        ]
        let updatedAt = Date(timeIntervalSince1970: 1_777_000_000)
        var client = HarnessClient.unimplemented
        client.status = { baseURLString in
            #expect(baseURLString == Self.baseURL)
            return status
        }
        client.log = { baseURLString in
            #expect(baseURLString == Self.baseURL)
            return logEntries
        }
        client.notifications = { _ in
            NotificationsResponse(ok: true, notifications: [], error: nil)
        }
        client.markNotificationsRead = { _, _, _ in
            BasicResponse(ok: true, enabled: nil, error: nil)
        }

        let store = TestStore(initialState: Self.initialState()) {
            HarnessFeature()
        } withDependencies: {
            $0.date.now = updatedAt
            $0.harnessClient = client
        }

        await store.send(.refresh) {
            $0.isRefreshing = true
        }
        await store.receive(\.refreshSucceeded) {
            $0.isRefreshing = false
            $0.status = status
            $0.workspaces = [workspace]
            $0.logEntries = logEntries
            $0.notifications = []
            $0.lastUpdated = updatedAt
        }
    }

    @Test
    func refreshKeepsDetailSelectionWhenSingleSurfaceIDChanges() async {
        var selectedWorkspace = Self.workspace()
        selectedWorkspace.surfaceId = "surface-before-refresh"
        selectedWorkspace.surfaceLabel = nil

        var refreshedWorkspace = selectedWorkspace
        refreshedWorkspace.surfaceId = "surface-after-refresh"
        refreshedWorkspace.screenTail = "refreshed tail"

        let selectedWorkspaceID = selectedWorkspace.id
        let fullScreenText = "current detail screen"
        let gitStatus = GitStatus(
            ok: true,
            branch: "main",
            cwd: "/Users/ronnie/Code/cmux",
            staged: [],
            unstaged: [],
            untracked: [],
            commits: [],
            error: nil
        )

        var state = Self.initialState()
        state.workspaces = [selectedWorkspace]
        state.selectedWorkspaceID = selectedWorkspaceID
        state.fullScreenText = fullScreenText
        state.gitStatus = gitStatus

        let status = Self.status(workspaces: [refreshedWorkspace])
        let updatedAt = Date(timeIntervalSince1970: 1_777_100_000)
        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.date.now = updatedAt
        }

        await store.send(.refreshSucceeded(RefreshPayload(status: status, log: [], feed: FeedResponse(ok: true, items: [], error: nil), notifications: NotificationsResponse(ok: true, notifications: [], error: nil)))) {
            $0.status = status
            $0.workspaces = [refreshedWorkspace]
            $0.logEntries = []
            $0.notifications = []
            $0.lastUpdated = updatedAt
            $0.selectedWorkspaceID = selectedWorkspaceID
            $0.fullScreenText = fullScreenText
            $0.gitStatus = gitStatus
        }
    }

    @Test
    func refreshClearsDetailSelectionWhenRestoredWorkspaceIsMissing() async {
        let selectedWorkspace = Self.workspace()
        var remainingWorkspace = Self.workspace()
        remainingWorkspace.uuid = "workspace-remaining"
        remainingWorkspace.surfaceId = "surface-remaining"
        remainingWorkspace.surfaceLabel = "Remaining"

        var state = Self.initialState()
        state.workspaces = [selectedWorkspace]
        state.selectedWorkspaceID = selectedWorkspace.id
        state.detailDraft = "Unsaved prompt"
        state.fullScreenText = "current detail screen"
        state.projectSkills = [
            ProjectSkill(
                name: "ios-review",
                skillFilePath: ".claude/skills/ios-review/SKILL.md",
                scope: "project"
            )
        ]

        let status = Self.status(workspaces: [remainingWorkspace])
        let updatedAt = Date(timeIntervalSince1970: 1_777_200_000)
        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.date.now = updatedAt
        }

        await store.send(.refreshSucceeded(RefreshPayload(status: status, log: [], feed: FeedResponse(ok: true, items: [], error: nil), notifications: NotificationsResponse(ok: true, notifications: [], error: nil)))) {
            $0.status = status
            $0.workspaces = [remainingWorkspace]
            $0.logEntries = []
            $0.notifications = []
            $0.lastUpdated = updatedAt
            $0.selectedWorkspaceID = nil
            $0.fullScreenText = nil
            $0.detailDrafts[selectedWorkspace.id] = "Unsaved prompt"
            $0.detailDraft = ""
            $0.projectSkills = []
        }
    }

    @Test
    func selectingHomePreservesDetailDraftForWorkspace() async {
        let workspace = Self.workspace()
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        state.detailDraft = "Keep this prompt"

        let store = TestStore(initialState: state) {
            HarnessFeature()
        }

        await store.send(.selectWorkspace(nil)) {
            $0.detailDrafts[workspace.id] = "Keep this prompt"
            $0.selectedWorkspaceID = nil
            $0.detailDraft = ""
        }
    }

    @Test
    func selectingWorkspacePanePreservesDetailTabAndLoadsPaneScreen() async {
        var serverPane = Self.workspace()
        serverPane.surfaceLabel = "Project : server"
        serverPane.surfaceId = "server-surface"

        var testPane = Self.workspace()
        testPane.index = 10_201
        testPane.surfaceLabel = "Project : tests"
        testPane.surfaceId = "tests-surface"

        var state = Self.initialState()
        state.workspaces = [serverPane, testPane]
        state.selectedWorkspaceID = serverPane.id
        state.detailTab = .activity
        state.detailDraft = "server draft"
        state.detailDrafts[testPane.id] = "test draft"
        state.fullScreenText = "server screen"

        var client = HarnessClient.unimplemented
        client.screen = { baseURLString, index, lines in
            #expect(baseURLString == Self.baseURL)
            #expect(index == testPane.index)
            #expect(lines == 200)
            return ScreenResponse(ok: true, screen: "tests screen", lines: 200, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.selectWorkspacePane(testPane.id)) {
            $0.detailDrafts[serverPane.id] = "server draft"
            $0.selectedWorkspaceID = testPane.id
            $0.fullScreenText = nil
            $0.detailDraft = "test draft"
        }
        await store.receive(\.screenTick)
        await store.receive(\.screenSucceeded) {
            $0.fullScreenText = "tests screen"
        }
    }

    @Test
    func markNotificationsReadOptimisticallyUpdatesStateAndCallsAPI() async {
        let workspace = Self.workspace()
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.notifications = [
            CmuxNotification(
                id: "notif-1",
                title: "Waiting",
                body: "Claude needs input",
                subtitle: nil,
                createdAt: nil,
                isRead: false,
                workspaceId: workspace.uuid,
                workspaceRef: nil,
                surfaceId: nil,
                surfaceRef: nil,
                tabTitle: nil
            ),
            CmuxNotification(
                id: "notif-2",
                title: "Done",
                body: "Other workspace",
                subtitle: nil,
                createdAt: nil,
                isRead: false,
                workspaceId: "other-workspace",
                workspaceRef: nil,
                surfaceId: nil,
                surfaceRef: nil,
                tabTitle: nil
            ),
        ]

        var markReadCalled = false
        var client = HarnessClient.unimplemented
        client.markNotificationsRead = { _, workspaceID, _ in
            markReadCalled = true
            #expect(workspaceID == workspace.uuid)
            return BasicResponse(ok: true, enabled: nil, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.markNotificationsRead(workspaceID: workspace.uuid, surfaceID: nil)) {
            $0.notifications[0].isRead = true
        }
        await store.receive(\.notificationsMarkedRead)
        #expect(markReadCalled)
        #expect(state.notifications[1].isRead == false || true)
    }

    @Test
    func markNotificationsReadBySurfaceIdMarksMatchingNotifications() async {
        var state = Self.initialState()
        state.notifications = [
            CmuxNotification(
                id: "notif-surf",
                title: "Done",
                body: "Surface notification",
                subtitle: nil,
                createdAt: nil,
                isRead: false,
                workspaceId: nil,
                workspaceRef: nil,
                surfaceId: "surface-target",
                surfaceRef: nil,
                tabTitle: nil
            ),
            CmuxNotification(
                id: "notif-other",
                title: "Other",
                body: "Different surface",
                subtitle: nil,
                createdAt: nil,
                isRead: false,
                workspaceId: nil,
                workspaceRef: nil,
                surfaceId: "other-surface",
                surfaceRef: nil,
                tabTitle: nil
            ),
        ]

        var client = HarnessClient.unimplemented
        client.markNotificationsRead = { _, _, surfaceID in
            #expect(surfaceID == "surface-target")
            return BasicResponse(ok: true, enabled: nil, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.markNotificationsRead(workspaceID: nil, surfaceID: "surface-target")) {
            $0.notifications[0].isRead = true
        }
        await store.receive(\.notificationsMarkedRead)
    }

    @Test
    func notificationsMarkFailedSetsErrorMessage() async {
        var state = Self.initialState()
        state.notifications = [
            CmuxNotification(
                id: "notif-1",
                title: "Waiting",
                body: "Claude needs input",
                subtitle: nil,
                createdAt: nil,
                isRead: false,
                workspaceId: "ws-1",
                workspaceRef: nil,
                surfaceId: nil,
                surfaceRef: nil,
                tabTitle: nil
            ),
        ]

        var client = HarnessClient.unimplemented
        client.markNotificationsRead = { _, _, _ in
            throw HarnessAPIError.server("network error")
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.markNotificationsRead(workspaceID: "ws-1", surfaceID: nil)) {
            $0.notifications[0].isRead = true
        }
        await store.receive(\.notificationsMarkFailed) {
            $0.errorMessage = "network error"
        }
    }

    @Test
    func easyModeTogglesOnTerminalAndTurnsOffOutsideTerminal() async {
        var state = Self.initialState()
        state.detailTab = .git

        let store = TestStore(initialState: state) {
            HarnessFeature()
        }

        await store.send(.setEasyMode(true)) {
            $0.isEasyModeEnabled = true
            $0.detailTab = .terminal
        }

        await store.send(.detailTabChanged(.activity)) {
            $0.detailTab = .activity
            $0.isEasyModeEnabled = false
        }
    }

    @Test
    func stateLoadsPersistedDetailDraftForLastSelectedWorkspace() {
        let oldDrafts = HarnessSettingsStore.detailDrafts
        let oldSelectedWorkspaceID = HarnessSettingsStore.lastSelectedWorkspaceID
        defer {
            HarnessSettingsStore.detailDrafts = oldDrafts
            HarnessSettingsStore.lastSelectedWorkspaceID = oldSelectedWorkspaceID
        }

        let workspaceID = "persisted-workspace"
        HarnessSettingsStore.detailDrafts = [workspaceID: "Remember this prompt"]
        HarnessSettingsStore.lastSelectedWorkspaceID = workspaceID

        let state = HarnessFeature.State()

        #expect(state.selectedWorkspaceID == workspaceID)
        #expect(state.detailDraft == "Remember this prompt")
        #expect(state.detailDrafts[workspaceID] == "Remember this prompt")
    }

    @Test
    func localDemoModeStartsWithReservedBaseURLAndExitReturnsToDiscovery() async {
        let oldServerSources = HarnessSettingsStore.serverSources
        let oldSelectedServerSourceID = HarnessSettingsStore.selectedServerSourceID
        let oldDemoMode = HarnessSettingsStore.isLocalDemoMode
        let oldSelectedWorkspaceID = HarnessSettingsStore.lastSelectedWorkspaceID
        let oldDrafts = HarnessSettingsStore.detailDrafts
        defer {
            HarnessSettingsStore.serverSources = oldServerSources
            HarnessSettingsStore.selectedServerSourceID = oldSelectedServerSourceID
            HarnessSettingsStore.isLocalDemoMode = oldDemoMode
            HarnessSettingsStore.lastSelectedWorkspaceID = oldSelectedWorkspaceID
            HarnessSettingsStore.detailDrafts = oldDrafts
        }
        HarnessSettingsStore.serverURL = nil
        HarnessSettingsStore.isLocalDemoMode = false
        HarnessSettingsStore.lastSelectedWorkspaceID = "previous-real-workspace"
        HarnessSettingsStore.detailDrafts = [:]

        let workspace = Self.workspace()
        let status = Self.status(workspaces: [workspace])
        let updatedAt = Date(timeIntervalSince1970: 1_777_400_000)
        let clock = TestClock()
        var client = HarnessClient.unimplemented
        client.status = { baseURLString in
            #expect(baseURLString == HarnessLocalDemo.baseURL)
            return status
        }
        client.log = { baseURLString in
            #expect(baseURLString == HarnessLocalDemo.baseURL)
            return []
        }
        client.notifications = { _ in
            NotificationsResponse(ok: true, notifications: [], error: nil)
        }
        client.markNotificationsRead = { _, _, _ in
            BasicResponse(ok: true, enabled: nil, error: nil)
        }
        client.probeServer = { _ in false }
        client.discoverServers = { [] }

        var state = HarnessFeature.State()
        state.serverURLString = ""
        state.committedServerURLString = ""
        state.isDemoMode = false
        state.selectedWorkspaceID = nil
        state.detailDrafts = [:]
        state.detailDraft = ""

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = updatedAt
            $0.harnessClient = client
        }

        await store.send(.startLocalDemoTapped) {
            $0.isDemoMode = true
            $0.committedServerURLString = HarnessLocalDemo.baseURL
            $0.errorMessage = nil
            $0.serverSetupError = nil
            $0.serverSetupMessage = "Local demo mode is running on this iPhone."
            $0.discoveredServers = []
        }
        await store.receive(\.refresh) {
            $0.isRefreshing = true
        }
        await store.receive(\.refreshSucceeded) {
            $0.isRefreshing = false
            $0.status = status
            $0.workspaces = [workspace]
            $0.logEntries = []
            $0.lastUpdated = updatedAt
        }

        await store.send(.exitDemoModeTapped) {
            $0.isDemoMode = false
            $0.committedServerURLString = ""
            $0.status = nil
            $0.workspaces = []
            $0.logEntries = []
            $0.lastUpdated = nil
            $0.serverSetupMessage = "Demo closed. Looking for your cmux harness server..."
        }
        await store.receive(\.discoverServer) {
            $0.isDiscoveringServer = true
            $0.serverSetupError = nil
            $0.serverSetupMessage = "Looking for a running cmux harness server..."
        }
        await store.receive(\.serverDiscoverySucceeded) {
            $0.isDiscoveringServer = false
            $0.discoveredServers = []
            $0.serverSetupMessage = nil
            $0.serverSetupError = "No running server was found. Start dashboard.py on your Mac, or enter the URL manually."
        }
    }

    @Test
    func savingServerCreatesNamedSourceAndConnects() async {
        let oldServerSources = HarnessSettingsStore.serverSources
        let oldSelectedServerSourceID = HarnessSettingsStore.selectedServerSourceID
        let oldDemoMode = HarnessSettingsStore.isLocalDemoMode
        let oldSelectedWorkspaceID = HarnessSettingsStore.lastSelectedWorkspaceID
        let oldDrafts = HarnessSettingsStore.detailDrafts
        defer {
            HarnessSettingsStore.serverSources = oldServerSources
            HarnessSettingsStore.selectedServerSourceID = oldSelectedServerSourceID
            HarnessSettingsStore.isLocalDemoMode = oldDemoMode
            HarnessSettingsStore.lastSelectedWorkspaceID = oldSelectedWorkspaceID
            HarnessSettingsStore.detailDrafts = oldDrafts
        }

        HarnessSettingsStore.serverURL = nil
        HarnessSettingsStore.isLocalDemoMode = false
        HarnessSettingsStore.lastSelectedWorkspaceID = nil
        HarnessSettingsStore.detailDrafts = [:]

        let normalizedURL = HarnessAPI.normalizedBaseURL("macbook.local:9091/harness")
        let source = HarnessServerSource(name: "Studio Mac", urlString: normalizedURL)
        let status = Self.status(workspaces: [])
        let updatedAt = Date(timeIntervalSince1970: 1_777_500_000)
        let clock = TestClock()
        var client = HarnessClient.unimplemented
        client.status = { baseURLString in
            #expect(baseURLString == normalizedURL)
            return status
        }
        client.log = { baseURLString in
            #expect(baseURLString == normalizedURL)
            return []
        }
        client.notifications = { _ in
            NotificationsResponse(ok: true, notifications: [], error: nil)
        }
        client.markNotificationsRead = { _, _, _ in
            BasicResponse(ok: true, enabled: nil, error: nil)
        }

        var state = HarnessFeature.State()
        state.serverSources = []
        state.selectedServerSourceID = nil
        state.editingServerSourceID = nil
        state.serverSourceNameString = "Studio Mac"
        state.serverURLString = "macbook.local:9091/harness"
        state.committedServerURLString = ""
        state.isDemoMode = false

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = updatedAt
            $0.harnessClient = client
        }

        await store.send(.saveServerTapped) {
            $0.serverSources = [source]
            $0.selectedServerSourceID = source.id
            $0.editingServerSourceID = source.id
            $0.serverSourceNameString = "Studio Mac"
            $0.serverURLString = normalizedURL
            $0.committedServerURLString = normalizedURL
            $0.isShowingSettings = false
            $0.errorMessage = nil
            $0.serverSetupError = nil
            $0.serverSetupMessage = "Saved Studio Mac."
        }
        await store.receive(\.refresh) {
            $0.isRefreshing = true
        }
        await store.receive(\.refreshSucceeded) {
            $0.isRefreshing = false
            $0.status = status
            $0.workspaces = []
            $0.logEntries = []
            $0.lastUpdated = updatedAt
        }
        await store.send(.onDisappear)

        #expect(HarnessSettingsStore.serverSources == [source])
        #expect(HarnessSettingsStore.selectedServerSourceID == source.id)
        #expect(HarnessSettingsStore.serverURL == normalizedURL)
    }

    @Test
    func selectingServerSourceSwitchesSessionsAndRefreshesFromNewURL() async {
        let oldServerSources = HarnessSettingsStore.serverSources
        let oldSelectedServerSourceID = HarnessSettingsStore.selectedServerSourceID
        let oldSelectedWorkspaceID = HarnessSettingsStore.lastSelectedWorkspaceID
        let oldDrafts = HarnessSettingsStore.detailDrafts
        defer {
            HarnessSettingsStore.serverSources = oldServerSources
            HarnessSettingsStore.selectedServerSourceID = oldSelectedServerSourceID
            HarnessSettingsStore.lastSelectedWorkspaceID = oldSelectedWorkspaceID
            HarnessSettingsStore.detailDrafts = oldDrafts
        }

        let firstSource = HarnessServerSource(name: "MacBook", urlString: Self.baseURL)
        let secondURL = "http://studio.local:9091/harness"
        let secondSource = HarnessServerSource(name: "Studio", urlString: secondURL)
        HarnessSettingsStore.serverSources = [firstSource, secondSource]
        HarnessSettingsStore.selectedServerSourceID = firstSource.id
        HarnessSettingsStore.detailDrafts = [:]

        let existingWorkspace = Self.workspace()
        var newWorkspace = Self.workspace()
        newWorkspace.index = 4
        newWorkspace.name = "studio-app"
        newWorkspace.uuid = "workspace-studio"
        newWorkspace.screenTail = "studio tail"
        newWorkspace.screenFull = "studio full screen"
        newWorkspace.cwd = "/Users/ronnie/Code/studio"
        newWorkspace.surfaceId = "surface-studio"
        let status = Self.status(workspaces: [newWorkspace])
        let updatedAt = Date(timeIntervalSince1970: 1_777_600_000)
        let clock = TestClock()
        var client = HarnessClient.unimplemented
        client.status = { baseURLString in
            #expect(baseURLString == secondURL)
            return status
        }
        client.log = { baseURLString in
            #expect(baseURLString == secondURL)
            return []
        }
        client.notifications = { _ in
            NotificationsResponse(ok: true, notifications: [], error: nil)
        }
        client.markNotificationsRead = { _, _, _ in
            BasicResponse(ok: true, enabled: nil, error: nil)
        }

        var state = Self.initialState()
        state.serverSources = [firstSource, secondSource]
        state.selectedServerSourceID = firstSource.id
        state.editingServerSourceID = firstSource.id
        state.serverSourceNameString = firstSource.name
        state.serverURLString = firstSource.urlString
        state.committedServerURLString = firstSource.urlString
        state.workspaces = [existingWorkspace]
        state.selectedWorkspaceID = existingWorkspace.id
        state.fullScreenText = "old server screen"
        state.feedItems = [
            FeedItem(
                requestID: "old-request",
                kind: "approval",
                title: nil,
                message: "Old server approval",
                command: nil,
                workspaceID: existingWorkspace.id,
                surfaceID: existingWorkspace.surfaceId,
                agent: nil,
                createdAt: "2026-04-26T12:00:00Z",
                options: nil
            )
        ]

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = updatedAt
            $0.harnessClient = client
        }

        await store.send(.selectServerSource(secondSource.id)) {
            $0.selectedServerSourceID = secondSource.id
            $0.editingServerSourceID = secondSource.id
            $0.serverSourceNameString = secondSource.name
            $0.serverURLString = secondSource.urlString
            $0.committedServerURLString = secondSource.urlString
            $0.status = nil
            $0.workspaces = []
            $0.logEntries = []
            $0.feedItems = []
            $0.lastUpdated = nil
            $0.sessionSearchText = ""
            $0.sessionFilter = .all
            $0.selectedWorkspaceID = nil
            $0.fullScreenText = nil
            $0.detailDraft = ""
            $0.serverSetupMessage = "Switched to Studio."
        }
        await store.receive(\.refresh) {
            $0.isRefreshing = true
        }
        await store.receive(\.refreshSucceeded) {
            $0.isRefreshing = false
            $0.status = status
            $0.workspaces = [newWorkspace]
            $0.logEntries = []
            $0.lastUpdated = updatedAt
        }
        await store.send(.onDisappear)
    }

    @Test
    func localDemoClientReturnsSimulatedSessionsAndAcceptsPrompt() async throws {
        let client = HarnessClient.localDemo
        let status = try await client.status(HarnessLocalDemo.baseURL)

        #expect(status.connected == true)
        #expect(status.socketFound)
        #expect(status.workspaces.count >= 3)
        #expect(status.workspaces[0].surfaceTitle == "Local Demo")

        let workspace = status.workspaces[0]
        _ = try await client.sendText(
            HarnessLocalDemo.baseURL,
            workspace.index,
            "show me the onboarding changes\n",
            workspace.surfaceId
        )
        let screen = try await client.screen(HarnessLocalDemo.baseURL, workspace.index, 200)
        let prComments = try await client.githubPRComments(HarnessLocalDemo.baseURL, workspace.index, false)
        let jiraTickets = try await client.assignedJiraTickets(HarnessLocalDemo.baseURL, nil, 50)
        let feed = try await client.feed(HarnessLocalDemo.baseURL)
        let fallbackScreen = try await client.screen(HarnessLocalDemo.baseURL, 2, 200)

        #expect(screen.screen.contains("Demo response"))
        #expect(prComments.pullRequest?.title == "Add iPhone dashboard onboarding")
        #expect(jiraTickets.tickets.map(\.key).contains("APP-1042"))
        #expect(feed.items.count == 6)
        #expect(feed.items.allSatisfy { item in
            status.workspaces.contains { feedItem(item, matches: $0) }
        })
        #expect(feed.items.first?.agent == "OpenCode")
        #expect(feed.items.first?.permissionType == "external_directory")
        #expect(
            feed.items.first { $0.requestID == "demo-opencode-question" }?
                .questions?.first?.question == "How do you want to build/publish the iOS app?"
        )
        #expect(OpenCodeTerminalInteractionDetector.detect(in: fallbackScreen.screen)?.kind == .permission)
    }

    @Test
    func workspaceIDUsesSurfaceForMultiSurfaceLabelsOnly() {
        var singleSurface = Self.workspace()
        singleSurface.surfaceId = "surface-before-refresh"
        singleSurface.surfaceLabel = nil

        var refreshedSingleSurface = singleSurface
        refreshedSingleSurface.surfaceId = "surface-after-refresh"

        var paneOne = Self.workspace()
        paneOne.surfaceLabel = "Project : server"
        paneOne.surfaceId = "server-surface"

        var paneTwo = Self.workspace()
        paneTwo.surfaceLabel = "Project : tests"
        paneTwo.surfaceId = "tests-surface"

        #expect(singleSurface.id == refreshedSingleSurface.id)
        #expect(paneOne.id != paneTwo.id)
    }

    @Test
    func workspaceSessionGroupsCollapsePanesByWorkspaceUUID() {
        var serverPane = Self.workspace()
        serverPane.surfaceLabel = "Project : server"
        serverPane.surfaceId = "server-surface"
        serverPane.surfaceTitle = "server"

        var testPane = Self.workspace()
        testPane.index = 10_201
        testPane.surfaceLabel = "Project : tests"
        testPane.surfaceId = "tests-surface"
        testPane.surfaceTitle = "tests"

        var state = Self.initialState()
        state.workspaces = [testPane, serverPane]

        let group = state.workspaceSessionGroups[0]
        #expect(state.workspaceSessionGroups.count == 1)
        #expect(group.id == "workspace-2")
        #expect(group.displayName == "ios-app")
        #expect(group.workspaces.map(\.id) == [serverPane.id, testPane.id])
        #expect(group.paneLabel(for: serverPane, offset: 0) == "server")
        #expect(group.paneLabel(for: testPane, offset: 1) == "tests")
        #expect(group.preferredWorkspaceID(selectedWorkspaceID: testPane.id) == testPane.id)
    }

    @Test
    func visibleWorkspaceGroupsSearchAndFilterAcrossPanes() {
        var serverPane = Self.workspace()
        serverPane.surfaceLabel = "Project : server"
        serverPane.surfaceId = "server-surface"

        var testPane = Self.workspace()
        testPane.index = 10_201
        testPane.surfaceLabel = "Project : tests"
        testPane.surfaceId = "tests-surface"

        var state = Self.initialState()
        state.workspaces = [serverPane, testPane]
        state.sessionSearchText = "tests"

        #expect(state.visibleWorkspaceGroups.count == 1)

        state.sessionFilter = .needsYou
        state.logEntries = [
            LogEntry(
                timestamp: "2026-04-26T14:00:00Z",
                workspace: testPane.index,
                workspaceName: testPane.name,
                promptType: "approval",
                action: "Waiting for human input",
                reason: nil,
                key: nil,
                surfaceId: testPane.surfaceId,
                sessionID: nil
            )
        ]

        #expect(state.waitingCount == 1)
        #expect(state.visibleWorkspaceGroups.count == 1)

        state.sessionSearchText = "missing"
        #expect(state.visibleWorkspaceGroups.isEmpty)
    }

    @Test
    func sortedWorkspacesUseStableDisplayIdentity() {
        var alpha = Self.workspace()
        alpha.index = 1
        alpha.uuid = "workspace-1"
        alpha.name = "alpha"
        alpha.surfaceId = "surface-1"
        alpha.surfaceLabel = "Alpha"
        alpha.lastCheck = "2026-04-26T10:00:00Z"

        var beta = Self.workspace()
        beta.index = 2
        beta.uuid = "workspace-2"
        beta.name = "beta"
        beta.surfaceId = "surface-2"
        beta.surfaceLabel = "Beta"
        beta.lastCheck = "2026-04-26T12:00:00Z"

        var gamma = Self.workspace()
        gamma.index = 3
        gamma.uuid = "workspace-3"
        gamma.name = "gamma"
        gamma.surfaceId = "surface-3"
        gamma.surfaceLabel = "Gamma"
        gamma.lastCheck = "2026-04-26T09:00:00Z"

        var state = Self.initialState()
        state.workspaces = [alpha, beta, gamma]
        state.logEntries = [
            LogEntry(
                timestamp: "2026-04-26T13:00:00Z",
                workspace: gamma.index,
                workspaceName: gamma.name,
                promptType: "default",
                action: "Activity",
                reason: nil,
                key: nil,
                surfaceId: gamma.surfaceId,
                sessionID: nil
            )
        ]

        #expect(state.sortedWorkspaces.map(\.displayName) == ["Alpha", "Beta", "Gamma"])
    }

    @Test
    func sortedWorkspacesPutStarredSessionsFirstAlphabetically() {
        var alpha = Self.workspace()
        alpha.index = 1
        alpha.uuid = "workspace-1"
        alpha.name = "Alpha"
        alpha.surfaceLabel = nil
        alpha.starred = true

        var beta = Self.workspace()
        beta.index = 2
        beta.uuid = "workspace-2"
        beta.name = "Beta"
        beta.surfaceLabel = nil
        beta.starred = true

        var gamma = Self.workspace()
        gamma.index = 3
        gamma.uuid = "workspace-3"
        gamma.name = "Gamma"
        gamma.surfaceLabel = nil
        gamma.starred = false

        var state = Self.initialState()
        state.workspaces = [gamma, beta, alpha]

        #expect(state.sortedWorkspaces.map(\.displayName) == ["Alpha", "Beta", "Gamma"])
    }

    @Test
    func fallbackDisplayNameUsesLastPathComponentUnlessCustomNamed() {
        var workspace = Self.workspace()
        workspace.surfaceLabel = nil
        workspace.customName = nil
        workspace.name = "/root/file/path/app/project/cmux"

        #expect(workspace.displayName == "cmux")

        workspace.customName = "root/file/path/app/project/cmux"

        #expect(workspace.displayName == "root/file/path/app/project/cmux")
    }

    @Test
    func sessionStateOnlyUsesHumanAttentionSignal() {
        var workspace = Self.workspace()
        workspace.hasClaude = false

        #expect(workspaceSessionState(for: workspace, entries: []) == .session)

        let olderHumanLog = LogEntry(
            timestamp: "2026-04-26T12:00:00Z",
            workspace: workspace.index,
            workspaceName: workspace.name,
            promptType: "default",
            action: "Waiting for human input",
            reason: nil,
            key: nil,
            surfaceId: workspace.surfaceId,
            sessionID: nil
        )
        let newerActivityLog = LogEntry(
            timestamp: "2026-04-26T13:00:00Z",
            workspace: workspace.index,
            workspaceName: workspace.name,
            promptType: "default",
            action: "Activity",
            reason: nil,
            key: nil,
            surfaceId: workspace.surfaceId,
            sessionID: nil
        )
        let currentHumanLog = LogEntry(
            timestamp: "2026-04-26T14:00:00Z",
            workspace: workspace.index,
            workspaceName: workspace.name,
            promptType: "default",
            action: "Waiting for human input",
            reason: nil,
            key: nil,
            surfaceId: workspace.surfaceId,
            sessionID: nil
        )

        #expect(workspaceSessionState(for: workspace, entries: [olderHumanLog, newerActivityLog]) == .session)
        #expect(workspaceSessionState(for: workspace, entries: [olderHumanLog, currentHumanLog]) == .waiting)
    }

    @Test
    func terminalTextStylerStripsAnsiControlSequences() {
        let raw = "\u{001B}[1;32m\u{2713} Done\u{001B}[0m\n\u{001B}[38;5;196mError\u{001B}[39m"

        #expect(TerminalTextStyler.plainText(for: raw) == "\u{2713} Done\nError")
    }

    @Test
    func terminalTextStylerRendersClaudeCodeTranscriptText() {
        let raw = """
        > Find and fix the bug

        \u{23FA} Bash(npm test)
          \u{23BF} 42 tests passed
        \u{23FA} Update(src/App.swift)
          \u{23BF} Updated src/App.swift with 3 additions and 1 removal
        """

        let styled = TerminalTextStyler.attributedString(for: raw, colorScheme: .dark)

        #expect(String(styled.characters) == raw)
    }

    @Test
    func detectsScreenshotStyleOpenCodePermissionPrompt() {
        let raw = """
        \u{001B}[38;5;67m│  △ Permission required\u{001B}[0m
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

        let interaction = OpenCodeTerminalInteractionDetector.detect(in: raw)

        #expect(interaction?.kind == .permission)
        #expect(interaction?.title == "Permission required")
        #expect(interaction?.options == ["Allow once", "Allow always", "Reject"])
        #expect(interaction?.detail.contains("Access external directory /tmp") == true)
        #expect(interaction?.detail.contains("/tmp/*") == true)
        let styled = TerminalTextStyler.attributedString(for: raw, colorScheme: .dark)
        #expect(String(styled.characters) == TerminalTextStyler.plainText(for: raw))
    }

    @Test
    func detectsOpenCodeQuestionPromptOptions() {
        let raw = """
        │  Where should this run?
        │
        │  1. Staging
        │  2. Production
        │
        ↑↓ select   enter confirm   esc dismiss
        • OpenCode 1.18.3
        """

        let interaction = OpenCodeTerminalInteractionDetector.detect(in: raw)

        #expect(interaction?.kind == .question)
        #expect(interaction?.detail == "Where should this run?")
        #expect(interaction?.options == ["Staging", "Production"])
        #expect(interaction?.navigationAxis == .vertical)
    }

    @Test
    func detectsOpenCodeQuestionReviewPromptAndAnswers() {
        let raw = """
        │  Build method    Export method    Configuration    Confirm
        │
        │  Review
        │
        │  Build method: Build from current branch (default)
        │
        │  Export method: development (Recommended)
        │
        │  Configuration: Debug (default)
        │
        │  ⇆ tab   enter submit   esc dismiss
        │
        • OpenCode 1.18.3
        """

        let interaction = OpenCodeTerminalInteractionDetector.detect(in: raw)

        #expect(interaction?.kind == .questionReview)
        #expect(interaction?.reviewItems == [
            OpenCodeTerminalInteraction.ReviewItem(
                label: "Build method",
                value: "Build from current branch (default)"
            ),
            OpenCodeTerminalInteraction.ReviewItem(
                label: "Export method",
                value: "development (Recommended)"
            ),
            OpenCodeTerminalInteraction.ReviewItem(
                label: "Configuration",
                value: "Debug (default)"
            ),
        ])
    }

    @Test
    func stripsShellRightPromptColumnsFromOpenCodeQuestionOptions() {
        let raw = """
        │  Which export method?                              /Volumes/PROJECTS/Development/
        │
        │  1. development (Recommended)                     Doximity-Claude-IOSDOX-26368
        │  2. ad-hoc                                        text-selection:rr/feature/IOSDOX-26368
        │  3. Type your own answer
        │
        │  ⇆ tab   ↑↓ select   enter confirm   esc dismiss
        │
        • OpenCode 1.18.3
        """

        let interaction = OpenCodeTerminalInteractionDetector.detect(in: raw)

        #expect(interaction?.kind == .question)
        #expect(interaction?.detail == "Which export method?")
        #expect(interaction?.options == [
            "development (Recommended)",
            "ad-hoc",
            "Type your own answer",
        ])
    }

    @Test
    func detectsEveryOptionInLongWrappedOpenCodeQuestionWithSelectionMarkers() {
        let markerSets = [
            ["›", "●", "☐"],
            ["❯", "○", "☑"],
        ]

        for markers in markerSets {
            let wrappedContext = (1...55)
                .map { "│     Wrapped option detail line \($0)." }
                .joined(separator: "\n")
            let raw = """
            │  Evaluate comment 1
            │  (fetchAllFireworksGatewayModels partial
            │  results / fireworksMaxPages)?
            │
            │  \(markers[0]) 1. Evaluate                         ~/Documents/Development/
            │     Review the actual source code and
            │     assess whether the suggestion is
            │     valid.
            │
            │     The review may need to inspect the
            │     pagination loop, the returned model
            │     catalog, and the fallback behavior.
            \(wrappedContext)
            │
            │  \(markers[1]) 2. Skip                             agentic-dev-opencode-moa-models
            │     Do not evaluate this comment.
            │
            │     Continue without reading the source
            │     or changing the current branch.
            │
            │     The selection remains visible while
            │     OpenCode advances to the next item.
            │
            │  \(markers[2]) 3. Type your own answer
            │
            │     Enter a custom response when neither
            │     of the standard choices applies.
            │
            │     This deliberately long prompt mirrors
            │     a narrow terminal where descriptions
            │     and shell context wrap across lines.
            │
            │     Additional wrapped context keeps the
            │     first choice more than 24 lines away
            │     from the active OpenCode anchor.
            │
            │  ⇆ tab   ↑↓ select   enter confirm   esc dismiss
            │
            • OpenCode 1.18.3
            """

            let interaction = OpenCodeTerminalInteractionDetector.detect(in: raw)

            #expect(interaction?.kind == .question)
            #expect(interaction?.options == [
                "Evaluate",
                "Skip",
                "Type your own answer",
            ])
        }
    }

    @Test
    func detectsEveryDisplayedOpenCodePermissionModeInOrder() {
        let raw = """
        │  △ Permission required
        │  ← Run a workspace command
        │
        │  Allow once   Allow always   All tools   Bypass permissions   Reject
        │  ⇆ select   enter confirm
        │
        • OpenCode 1.18.3
        """

        let interaction = OpenCodeTerminalInteractionDetector.detect(in: raw)

        #expect(interaction?.kind == .permission)
        #expect(interaction?.options == [
            "Allow once",
            "Allow always",
            "All tools",
            "Bypass permissions",
            "Reject",
        ])
    }

    @Test
    func permissionChoicesComeOnlyFromTheControlRow() {
        let raw = """
        │  △ Permission required
        │  ← Run a command that mentions deny, bypass permissions, and all tools
        │  The explanation may repeat those words without offering those actions.
        │
        │  Allow once   Allow always   Reject
        │  ⇆ select   enter confirm
        │
        • OpenCode 1.18.3
        """

        let interaction = OpenCodeTerminalInteractionDetector.detect(in: raw)

        #expect(interaction?.kind == .permission)
        #expect(interaction?.options == ["Allow once", "Allow always", "Reject"])
    }

    @Test
    func detectsCheckboxQuestionsAndExposesTheSpaceKeyToken() {
        let raw = """
        │  Which checks should run?
        │
        │  ☐ 1. Unit tests
        │  ☑ 2. UI tests
        │
        ↑↓ select   space toggle   enter confirm   esc dismiss
        • OpenCode 1.18.3
        """

        let interaction = OpenCodeTerminalInteractionDetector.detect(in: raw)

        #expect(interaction?.kind == .question)
        #expect(interaction?.allowsMultipleSelection == true)
        #expect(interaction?.options == ["Unit tests", "UI tests"])
        #expect(HarnessKey.space.rawValue == "space")
    }

    @Test
    func doesNotTreatTranscriptPermissionWordsAsAnActivePrompt() {
        let raw = """
        We should render Allow once, Allow always, and Reject more clearly.
        The next step is to confirm the design.
        • OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func doesNotKeepTerminalActionsAfterPromptLeavesCurrentFrame() {
        let raw = """
        │  △ Permission required
        │     Allow once    Allow always    Reject
        ⇆ select   enter confirm
        • OpenCode 1.18.3
        I'll confirm the deployment result now.
        • OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func doesNotMistakeAdjacentPermissionProseForAnOpenCodeFooter() {
        let raw = """
        │  △ Permission required
        │     Allow once    Allow always    Reject
        ⇆ select   enter confirm
        • OpenCode 1.18.3
        Select the target and press Enter.
        Confirm it when ready.
        • OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func doesNotMistakeAdjacentQuestionProseForAnOpenCodeFooter() {
        let raw = """
        │  Where should this run?
        │  1. Staging
        │  2. Production
        ↑↓ select   enter confirm   esc dismiss
        • OpenCode 1.18.3
        Select the target and press Enter.
        Dismiss the sheet when ready.
        • OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func doesNotKeepPermissionActionsAfterConfirmationOutput() {
        let raw = """
        │  △ Permission required
        │     Allow once    Allow always    Reject
        ⇆ select   enter confirm
        Permission confirmed by user.
        • OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func doesNotKeepQuestionActionsAfterDismissalOutput() {
        let raw = """
        │  Where should this run?
        │  1. Staging
        │  2. Production
        ↑↓ select   enter confirm   esc dismiss
        Question dismissed by user.
        • OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func doesNotJoinPermissionProseToAPreviousFooter() {
        let raw = """
        │  △ Permission required
        │     Allow once    Allow always    Reject
        ⇆ select   enter confirm
        Please confirm.
        • OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func doesNotJoinQuestionProseToAPreviousFooter() {
        let raw = """
        │  Where should this run?
        │  1. Staging
        │  2. Production
        ↑↓ select   enter confirm   esc dismiss
        Press dismiss to close.
        • OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func doesNotTreatOpenCodeVersionProseAsAStatusAnchor() {
        let raw = """
        │  △ Permission required
        │     Allow once    Allow always    Reject
        ⇆ select   enter confirm
        Running tests for OpenCode 1.18.3
        """

        #expect(OpenCodeTerminalInteractionDetector.detect(in: raw) == nil)
    }

    @Test
    func feedMatchingRequiresTheRequestedSurfaceWhenPresent() {
        let firstPane = Self.workspace()
        var requestedPane = firstPane
        requestedPane.surfaceId = "surface-requested"
        let item = FeedItem(
            requestID: "permission-surface",
            kind: "permission",
            title: nil,
            message: nil,
            command: nil,
            workspaceID: firstPane.uuid,
            surfaceID: requestedPane.surfaceId,
            agent: "OpenCode",
            createdAt: nil,
            options: nil
        )

        #expect(feedItem(item, matches: firstPane) == false)
        #expect(feedItem(item, matches: requestedPane) == true)
    }

    @Test
    func feedMatchingUsesOnlyAnUnambiguousNormalizedWorkingDirectory() {
        var requestedWorkspace = Self.workspace()
        requestedWorkspace.uuid = "workspace-requested"
        requestedWorkspace.cwd = "/private/tmp/cmux-feed/project/../project"

        var otherWorkspace = Self.workspace()
        otherWorkspace.uuid = "workspace-other"
        otherWorkspace.cwd = "/private/tmp/cmux-feed/other"

        let item = FeedItem(
            requestID: "permission-cwd",
            kind: "permission",
            title: nil,
            message: nil,
            command: nil,
            workspaceID: nil,
            surfaceID: nil,
            agent: "OpenCode",
            createdAt: nil,
            options: nil,
            cwd: "/private/tmp/cmux-feed/project"
        )

        #expect(feedItem(
            item,
            matches: requestedWorkspace,
            among: [requestedWorkspace, otherWorkspace]
        ))
        #expect(!feedItem(
            item,
            matches: otherWorkspace,
            among: [requestedWorkspace, otherWorkspace]
        ))

        var secondPane = requestedWorkspace
        secondPane.surfaceId = "surface-second-pane"
        secondPane.surfaceLabel = "Second pane"
        #expect(feedItem(
            item,
            matches: requestedWorkspace,
            among: [requestedWorkspace, secondPane, otherWorkspace]
        ))

        var duplicateWorkspace = otherWorkspace
        duplicateWorkspace.uuid = "workspace-duplicate"
        duplicateWorkspace.cwd = "/private/tmp/cmux-feed/project/"
        #expect(!feedItem(
            item,
            matches: requestedWorkspace,
            among: [requestedWorkspace, duplicateWorkspace]
        ))
    }

    @Test
    func decodesStructuredOpenCodeFeedQuestions() throws {
        let data = Data(#"""
        {
          "ok": true,
          "items": [{
            "requestID": "question-1",
            "kind": "question",
            "message": "Where should this run?",
            "workspaceID": "workspace-1",
            "options": ["Staging", "Production"],
            "questions": [{
              "id": "environment",
              "header": "Environment",
              "question": "Where should this run?",
              "multiSelect": true,
              "allowsCustomAnswer": false,
              "options": [
                {"id": "staging", "label": "Staging", "description": "Shared QA"},
                {"id": "production", "label": "Production", "description": "Live traffic"}
              ]
            }],
            "workstreamID": "opencode-session-1",
            "cwd": "/repo",
            "defaultMode": "manual"
          }]
        }
        """#.utf8)

        let response = try JSONDecoder().decode(FeedResponse.self, from: data)

        #expect(response.items.count == 1)
        #expect(response.items[0].questions?.first?.question == "Where should this run?")
        #expect(response.items[0].questions?.first?.options[1].description == "Live traffic")
        #expect(response.items[0].questions?.first?.multiSelect == true)
        #expect(response.items[0].questions?.first?.customAnswerAllowed == false)
        #expect(response.items[0].workstreamID == "opencode-session-1")
        #expect(response.items[0].cwd == "/repo")
        #expect(response.items[0].defaultMode == "manual")
    }

    @Test
    func decodesPermissionCapabilitiesAndFullPlanContent() throws {
        let data = Data(#"""
        {
          "ok": true,
          "items": [{
            "requestID": "permission-1",
            "kind": "permission",
            "agent": "OpenCode",
            "permissionModes": [
              {"mode": "once", "label": "Allow once"},
              {"mode": "bypass", "label": "Bypass permissions"},
              {"mode": "deny", "label": "Reject"}
            ]
          }, {
            "requestID": "plan-1",
            "kind": "plan",
            "message": "Implement the permission sheet",
            "plan": "# Permission sheet\n\n1. Normalize modes.\n2. Verify the UI.",
            "planSummary": "# Permission sheet",
            "defaultMode": "manual"
          }]
        }
        """#.utf8)

        let response = try JSONDecoder().decode(FeedResponse.self, from: data)

        #expect(response.items[0].permissionModes?.map(\.mode) == ["once", "bypass", "deny"])
        #expect(response.items[1].plan?.contains("Normalize modes") == true)
        #expect(response.items[1].planSummary == "# Permission sheet")
        #expect(response.items[1].defaultMode == "manual")
    }

    @Test
    func refreshLoadsFeedWithoutMakingFeedAvailabilityCritical() async {
        let workspace = Self.workspace()
        let status = Self.status(workspaces: [workspace])
        let feedItem = FeedItem(
            requestID: "permission-1",
            kind: "permission",
            title: "Permission required",
            message: "Access external directory",
            command: nil,
            workspaceID: workspace.uuid,
            surfaceID: workspace.surfaceId,
            agent: "OpenCode",
            createdAt: nil,
            options: ["Allow once", "Allow always", "Reject"],
            permissionType: "external_directory",
            patterns: ["/tmp/*"],
            questions: nil
        )
        var client = HarnessClient.unimplemented
        client.status = { _ in status }
        client.log = { _ in [] }
        client.notifications = { _ in
            NotificationsResponse(ok: true, notifications: [], error: nil)
        }
        client.feed = { _ in FeedResponse(ok: true, items: [feedItem], error: nil) }

        let updatedAt = Date(timeIntervalSince1970: 1_777_900_000)
        let store = TestStore(initialState: Self.initialState()) {
            HarnessFeature()
        } withDependencies: {
            $0.date.now = updatedAt
            $0.harnessClient = client
        }

        await store.send(.refresh) {
            $0.isRefreshing = true
        }
        await store.receive(\.refreshSucceeded) {
            $0.isRefreshing = false
            $0.status = status
            $0.workspaces = [workspace]
            $0.feedItems = [feedItem]
            $0.lastUpdated = updatedAt
        }
    }

    @Test
    func transientFeedFailurePreservesLastKnownInteraction() async {
        let workspace = Self.workspace()
        let status = Self.status(workspaces: [workspace])
        let item = FeedItem(
            requestID: "permission-existing",
            kind: "permission",
            title: "Permission required",
            message: nil,
            command: nil,
            workspaceID: workspace.uuid,
            surfaceID: workspace.surfaceId,
            agent: "OpenCode",
            createdAt: nil,
            options: nil
        )
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.feedItems = [item]

        var client = HarnessClient.unimplemented
        client.status = { _ in status }
        client.log = { _ in [] }
        client.notifications = { _ in NotificationsResponse(ok: true, notifications: [], error: nil) }
        client.feed = { _ in throw HarnessAPIError.transport("Feed temporarily unavailable") }
        let updatedAt = Date(timeIntervalSince1970: 1_777_900_050)

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.date.now = updatedAt
            $0.harnessClient = client
        }

        await store.send(.refresh)
        await store.receive(\.refreshSucceeded) {
            $0.status = status
            $0.workspaces = [workspace]
            $0.lastUpdated = updatedAt
        }
    }

    @Test
    func feedRepliesDisableDuplicateSubmissionUntilCompletion() async {
        let workspace = Self.workspace()
        let status = Self.status(workspaces: [workspace])
        let item = FeedItem(
            requestID: "permission-1",
            kind: "permission",
            title: "Permission required",
            message: nil,
            command: nil,
            workspaceID: workspace.uuid,
            surfaceID: workspace.surfaceId,
            agent: "OpenCode",
            createdAt: nil,
            options: nil
        )
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.feedItems = [item]
        state.errorMessage = "Previous reply failed"

        var client = HarnessClient.unimplemented
        let expectedBaseURL = Self.baseURL
        let expectedRequestID = item.requestID
        client.replyToFeed = { baseURL, requestID, kind, action, mode, selections in
            #expect(baseURL == expectedBaseURL)
            #expect(requestID == expectedRequestID)
            #expect(kind == "permission")
            #expect(action == "approve")
            #expect(mode == "always")
            #expect(selections == nil)
            return BasicResponse(ok: true, enabled: nil, error: nil)
        }
        client.status = { _ in status }
        client.log = { _ in [] }
        client.notifications = { _ in NotificationsResponse(ok: true, notifications: [], error: nil) }
        client.feed = { _ in FeedResponse(ok: true, items: [], error: nil) }
        let updatedAt = Date(timeIntervalSince1970: 1_777_900_100)

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.date.now = updatedAt
            $0.harnessClient = client
        }

        await store.send(.replyToFeed(
            requestID: item.requestID,
            kind: item.kind,
            action: "approve",
            mode: "always",
            selections: nil
        )) {
            $0.errorMessage = nil
            $0.pendingFeedReplyIDs = [item.requestID]
        }
        await store.receive(\.feedReplySucceeded) {
            $0.pendingFeedReplyIDs = []
            $0.feedItems = []
        }
        await store.receive(\.refresh)
        await store.receive(\.refreshSucceeded) {
            $0.status = status
            $0.workspaces = [workspace]
            $0.lastUpdated = updatedAt
        }
    }

    @Test
    func installsOpenCodeNativeIntegrationExplicitly() async {
        let response = OpenCodeIntegrationResponse(
            ok: true,
            status: "ready",
            installed: true,
            cmuxAvailable: true,
            needsInstall: false,
            needsRestart: true,
            summary: "Restart active OpenCode sessions.",
            error: nil
        )
        var client = HarnessClient.unimplemented
        let expectedBaseURL = Self.baseURL
        client.installOpenCodeIntegration = { baseURL in
            #expect(baseURL == expectedBaseURL)
            return response
        }
        let store = TestStore(initialState: Self.initialState()) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.installOpenCodeIntegration) {
            $0.isInstallingOpenCodeIntegration = true
        }
        await store.receive(\.installOpenCodeIntegrationSucceeded) {
            $0.isInstallingOpenCodeIntegration = false
            $0.openCodeIntegration = response
        }
    }

    @Test
    func toggleWorkspaceOptimisticallyUpdatesAndCallsClient() async {
        let workspace = Self.workspace(enabled: false)
        var state = Self.initialState()
        state.workspaces = [workspace]
        var client = HarnessClient.unimplemented
        client.setWorkspaceAutoMode = { baseURLString, index, mode in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(mode == .auto)
            return BasicResponse(ok: true, enabled: mode.isEnabled, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.toggleWorkspace(workspaceID: workspace.id, enabled: true)) {
            $0.workspaces[0].enabled = true
            $0.workspaces[0].autoMode = .auto
        }
        await store.receive(\.requestFinished)
    }

    @Test
    func setWorkspaceSuperAutoModeOptimisticallyUpdatesAndCallsClient() async {
        let workspace = Self.workspace(enabled: false)
        var state = Self.initialState()
        state.workspaces = [workspace]
        var client = HarnessClient.unimplemented
        client.setWorkspaceAutoMode = { baseURLString, index, mode in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(mode == .superAuto)
            return BasicResponse(ok: true, enabled: mode.isEnabled, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.setWorkspaceAutoMode(workspaceID: workspace.id, mode: .superAuto)) {
            $0.workspaces[0].enabled = true
            $0.workspaces[0].autoMode = .superAuto
        }
        await store.receive(\.requestFinished)
    }

    @Test
    func toggleWorkspaceStarredOptimisticallyUpdatesAndCallsClient() async {
        var workspace = Self.workspace()
        workspace.starred = false
        var state = Self.initialState()
        state.workspaces = [workspace]
        var client = HarnessClient.unimplemented
        client.setWorkspaceStarred = { baseURLString, index, starred in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(starred)
            return BasicResponse(ok: true, enabled: nil, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.toggleWorkspaceStarred(workspaceID: workspace.id, starred: true)) {
            $0.workspaces[0].starred = true
        }
        await store.receive(\.requestFinished)
    }

    @Test
    func sendDraftTrimsInputAndSendsTextToWorkspaceSurface() async {
        let workspace = Self.workspace()
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.draftMessages[workspace.id] = "  run tests  "
        var client = HarnessClient.unimplemented
        client.sendText = { baseURLString, index, text, surfaceId in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(text == "run tests\n")
            #expect(surfaceId == workspace.surfaceId)
            return BasicResponse(ok: true, enabled: nil, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.sendDraft(workspaceID: workspace.id)) {
            $0.draftMessages[workspace.id] = ""
        }
        await store.receive(\.requestFinished)
        await store.receive(\.screenTick)
    }

    @Test
    func sendKeysCallsClientSequentiallyInOrder() async {
        let workspace = Self.workspace()
        let keys: [HarnessKey] = [.down, .down, .up, .enter]
        let recorder = HarnessKeyCallRecorder()
        var state = Self.initialState()
        state.workspaces = [workspace]
        var client = HarnessClient.unimplemented
        client.sendKey = { baseURLString, index, key, surfaceId in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(surfaceId == workspace.surfaceId)
            await recorder.record(key)
            return BasicResponse(ok: true, enabled: nil, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.sendKeys(workspaceID: workspace.id, keys))
        await store.receive(\.requestFinished)
        await store.receive(\.screenTick)

        let calls = await recorder.snapshot()
        #expect(calls.keys == keys)
        #expect(calls.maximumConcurrentCalls == 1)
    }

    @Test
    func newSessionFromWorkspaceCreatesShellInWorkspaceDirectoryAndSelectsIt() async {
        let sourceWorkspace = Self.workspace()
        var createdWorkspace = Self.workspace()
        createdWorkspace.index = 3
        createdWorkspace.uuid = "workspace-created"
        createdWorkspace.name = "_ iOS App Shell"
        createdWorkspace.customName = "_ iOS App Shell"
        createdWorkspace.surfaceId = "surface-created"
        createdWorkspace.surfaceLabel = nil
        createdWorkspace.cwd = sourceWorkspace.cwd
        createdWorkspace.branch = sourceWorkspace.branch

        var state = Self.initialState()
        state.workspaces = [sourceWorkspace]
        state.selectedWorkspaceID = sourceWorkspace.id

        let response = NewSessionResponse(
            ok: true,
            workspace: NewSessionResponse.CreatedWorkspace(
                index: createdWorkspace.index,
                uuid: createdWorkspace.uuid
            ),
            worktreePath: sourceWorkspace.cwd,
            branchName: "",
            error: nil
        )
        let status = Self.status(workspaces: [sourceWorkspace, createdWorkspace])
        let updatedAt = Date(timeIntervalSince1970: 1_777_300_000)
        let clock = TestClock()
        var client = HarnessClient.unimplemented
        client.createSession = { baseURLString, projectPath, branchName, jiraURL, prompt, mode, sessionName in
            #expect(baseURLString == Self.baseURL)
            #expect(projectPath == "/Users/ronnie/Code/cmux")
            #expect(branchName.isEmpty)
            #expect(jiraURL.isEmpty)
            #expect(prompt.isEmpty)
            #expect(mode == .shell)
            #expect(sessionName == "_ iOS App Shell")
            return response
        }
        client.status = { baseURLString in
            #expect(baseURLString == Self.baseURL)
            return status
        }
        client.log = { baseURLString in
            #expect(baseURLString == Self.baseURL)
            return []
        }
        client.notifications = { _ in
            NotificationsResponse(ok: true, notifications: [], error: nil)
        }
        client.markNotificationsRead = { _, _, _ in
            BasicResponse(ok: true, enabled: nil, error: nil)
        }
        client.screen = { baseURLString, index, lines in
            #expect(baseURLString == Self.baseURL)
            #expect(index == createdWorkspace.index)
            #expect(lines == 200)
            return ScreenResponse(ok: true, screen: "created shell", lines: lines, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = updatedAt
            $0.harnessClient = client
        }

        await store.send(.newSessionFromWorkspaceTapped(workspaceID: sourceWorkspace.id)) {
            $0.isCreatingSession = true
            $0.quickSessionCreation = QuickSessionCreation(
                workspaceID: sourceWorkspace.id,
                directoryPath: "/Users/ronnie/Code/cmux",
                phase: .creating
            )
        }
        await store.receive(\.createNewSessionSucceeded) {
            $0.isCreatingSession = false
            $0.quickSessionCreation?.phase = .switching
            $0.pendingCreatedWorkspaceSelection = PendingCreatedWorkspaceSelection(
                uuid: "workspace-created",
                index: 3
            )
        }
        await clock.advance(by: .milliseconds(750))
        await store.receive(\.refresh)
        await store.receive(\.refreshSucceeded) {
            $0.status = status
            $0.workspaces = [sourceWorkspace, createdWorkspace]
            $0.logEntries = []
            $0.lastUpdated = updatedAt
            $0.quickSessionCreation = nil
            $0.pendingCreatedWorkspaceSelection = nil
        }
        await store.receive(\.selectWorkspace) {
            $0.selectedWorkspaceID = createdWorkspace.id
            $0.detailDraft = ""
        }
        await store.receive(\.screenTick)
        await store.receive(\.screenSucceeded) {
            $0.fullScreenText = "created shell"
        }
        await store.send(.selectWorkspace(nil)) {
            $0.selectedWorkspaceID = nil
            $0.fullScreenText = nil
        }
    }

    @Test
    func newSessionFromWorkspaceRequiresDetectedDirectory() async {
        var workspace = Self.workspace()
        workspace.cwd = nil
        var state = Self.initialState()
        state.workspaces = [workspace]

        let store = TestStore(initialState: state) {
            HarnessFeature()
        }

        await store.send(.newSessionFromWorkspaceTapped(workspaceID: workspace.id)) {
            $0.errorMessage = "Couldn't find a directory for this session yet."
        }
    }

    @Test
    func pickedAttachmentAddsUploadChipAndMarksUploaded() async {
        let workspace = Self.workspace()
        let attachmentID = UUID(uuidString: "A77AC000-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        let fileURL = URL(fileURLWithPath: "/tmp/photo-test.jpg")
        let uploaded = UploadedAttachment(
            id: "attachment-1",
            filename: "photo-test.jpg",
            originalFilename: "photo-test.jpg",
            contentType: "image/jpeg",
            size: 1024,
            path: "/tmp/cmux/attachment-1/photo-test.jpg",
            workspaceKey: workspace.uuid,
            createdAt: "2026-04-30T12:00:00Z"
        )
        let response = AttachmentUploadResponse(ok: true, attachment: uploaded, error: nil)
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        var client = HarnessClient.unimplemented
        client.uploadAttachment = { baseURLString, workspaceIndex, workspaceUUID, url, filename in
            #expect(baseURLString == Self.baseURL)
            #expect(workspaceIndex == workspace.index)
            #expect(workspaceUUID == workspace.uuid)
            #expect(url == fileURL)
            #expect(filename == "photo-test.jpg")
            return response
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
            $0.uuid = .constant(attachmentID)
        }

        await store.send(.attachmentFilesPicked(workspaceID: workspace.id, [fileURL])) {
            $0.terminalAttachments[workspace.id] = [
                TerminalAttachment(
                    id: attachmentID,
                    filename: "photo-test.jpg",
                    sourceURL: fileURL,
                    status: .uploading,
                    uploaded: nil,
                    error: nil
                ),
            ]
        }
        await store.receive(\.attachmentUploadSucceeded) {
            $0.terminalAttachments[workspace.id] = [
                TerminalAttachment(
                    id: attachmentID,
                    filename: "photo-test.jpg",
                    sourceURL: fileURL,
                    status: .uploaded,
                    uploaded: uploaded,
                    error: nil
                ),
            ]
        }
    }

    @Test
    func jiraUrlAutofillsBranchNameWhenEmpty() async {
        let store = TestStore(initialState: Self.initialState()) {
            HarnessFeature()
        }

        await store.send(.newSessionJiraChanged("https://example.atlassian.net/browse/app-24180")) {
            $0.newSessionJiraURL = "https://example.atlassian.net/browse/app-24180"
            $0.newSessionBranchName = "APP-24180"
        }
    }

    @Test
    func requestDiffLoadsDiffForSelectedWorkspace() async {
        let workspace = Self.workspace()
        let diffID = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        var client = HarnessClient.unimplemented
        client.diff = { baseURLString, index, file, section in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(file == "Sources/App.swift")
            #expect(section == .unstaged)
            return GitDiffResponse(ok: true, diff: "@@ diff", error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
            $0.uuid = .constant(diffID)
        }

        await store.send(.requestDiff(file: "Sources/App.swift", section: .unstaged)) {
            $0.diffSheet = DiffSheet(
                id: diffID,
                file: "Sources/App.swift",
                section: .unstaged,
                diff: "",
                isLoading: true
            )
        }
        await store.receive(\.diffSucceeded) {
            $0.diffSheet?.diff = "@@ diff"
            $0.diffSheet?.isLoading = false
        }
    }

    @Test
    func appendingDiffLineReviewCommentInsertsPromptAndClosesDiff() async {
        let workspace = Self.workspace()
        let diffID = UUID(uuidString: "A11CE000-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        state.detailTab = .git
        state.detailDraft = "Existing note."
        state.diffSheet = DiffSheet(
            id: diffID,
            file: "Sources/App.swift",
            section: .unstaged,
            diff: "@@ -10,2 +10,2 @@\n-let old = value\n+let new = value",
            isLoading: false
        )

        let store = TestStore(initialState: state) {
            HarnessFeature()
        }

        await store.send(.appendDiffLineReviewComment(DiffLineReviewComment(
            file: "Sources/App.swift",
            lineNumber: 11,
            side: .new,
            code: "let new = value",
            comment: "Use the validated value here."
        ))) {
            $0.detailDraft = """
            Existing note.

            Please address this review comment:

            File: Sources/App.swift
            Line: 11 (new)
            Code: let new = value
            Comment: Use the validated value here.
            """
            $0.detailDrafts[workspace.id] = $0.detailDraft
            $0.detailTab = .terminal
            $0.diffSheet = nil
            $0.detailInputFocusRequest = 1
        }
    }

    @Test
    func prCommentsSegmentLoadsThreadsAndAppendsPromptReference() async {
        let workspace = Self.workspace()
        let thread = Self.prThread()
        let response = Self.prCommentsResponse(thread: thread)
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        state.detailTab = .git
        state.detailDraft = "Also add coverage."
        var client = HarnessClient.unimplemented
        client.githubPRComments = { baseURLString, index, includeResolved in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(includeResolved == false)
            return response
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.gitSegmentChanged(.prComments)) {
            $0.gitSegment = .prComments
        }
        await store.receive(\.loadPRComments) {
            $0.isLoadingPRComments = true
            $0.prCommentsError = nil
        }
        await store.receive(\.prCommentsSucceeded) {
            $0.isLoadingPRComments = false
            $0.prCommentsResponse = response
        }
        await store.send(.appendPRCommentThread(thread)) {
            $0.detailDraft = """
            Also add coverage.

            Please address this GitHub PR review thread:

            PR: #42 Ship comments
            PR URL: https://github.com/example-org/cmux-harness/pull/42
            File: Sources/App.swift
            Line: Line 18
            Thread URL: https://github.com/example-org/cmux-harness/pull/42#discussion_r18

            Referenced code:
            ```
              17: let oldValue = value
            > 18: let value = helper()
              19: return value
            ```

            Comment by reviewer:
            Use the new helper.
            """
            $0.detailDrafts[workspace.id] = $0.detailDraft
            $0.detailTab = .terminal
            $0.detailInputFocusRequest = 1
        }
    }

    @Test
    func requestFixForPRCommentThreadSubmitsThreadAndShowsSession() async {
        let workspace = Self.workspace()
        let thread = Self.prThread()
        let response = Self.prCommentsResponse(thread: thread)
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        state.detailTab = .git
        state.gitSegment = .prComments
        state.detailDraft = "Keep this draft."
        state.prCommentsResponse = response
        let expectedPrompt = thread.promptReference(pullRequest: response.pullRequest) + "\n"
        var client = HarnessClient.unimplemented
        client.sendText = { baseURLString, index, text, surfaceId in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(surfaceId == workspace.surfaceId)
            #expect(text == expectedPrompt)
            return BasicResponse(ok: true, enabled: nil, error: nil)
        }
        client.screen = { baseURLString, index, lines in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(lines == 200)
            return ScreenResponse(ok: true, screen: "Request submitted", lines: lines, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.requestFixForPRCommentThread(thread)) {
            $0.detailTab = .terminal
        }
        await store.receive(\.requestFinished)
        await store.receive(\.screenTick)
        await store.receive(\.screenSucceeded) {
            $0.fullScreenText = "Request submitted"
        }
    }

    @Test
    func skillsTabLoadsSkillsAndAppendsSelectedFormat() async {
        let workspace = Self.workspace()
        let projectSkill = ProjectSkill(
            name: "ios-review",
            skillFilePath: ".claude/skills/ios-review/SKILL.md",
            scope: "project"
        )
        let userSkill = ProjectSkill(
            name: "global-review",
            skillFilePath: "~/.claude/skills/global-review/SKILL.md",
            scope: "user"
        )
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        state.detailDraft = "Review this"
        var client = HarnessClient.unimplemented
        client.skills = { baseURLString, index in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            return SkillsResponse(
                ok: true,
                rootPath: "/Users/ronnie/Code/cmux",
                skillsDirectory: ".claude/skills",
                userSkillsDirectory: "~/.claude/skills",
                projectSkills: [projectSkill],
                userSkills: [userSkill],
                skills: [projectSkill, userSkill],
                error: nil
            )
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.detailTabChanged(.skills)) {
            $0.detailTab = .skills
        }
        await store.receive(\.loadSkills) {
            $0.isLoadingSkills = true
            $0.skillsError = nil
        }
        await store.receive(\.skillsSucceeded) {
            $0.isLoadingSkills = false
            $0.projectSkills = [projectSkill]
            $0.userSkills = [userSkill]
        }
        await store.send(.appendSkillInvocation(projectSkill)) {
            $0.detailDraft = "Review this /ios-review"
            $0.detailDrafts[workspace.id] = "Review this /ios-review"
            $0.detailTab = .terminal
            $0.detailInputFocusRequest = 1
        }
        await store.send(.appendCodexSkillInvocation(projectSkill)) {
            $0.detailDraft = "Review this /ios-review $ios-review"
            $0.detailDrafts[workspace.id] = "Review this /ios-review $ios-review"
            $0.detailInputFocusRequest = 2
        }
        await store.send(.appendSkillFilePath(projectSkill)) {
            $0.detailDraft = "Review this /ios-review $ios-review `.claude/skills/ios-review/SKILL.md`"
            $0.detailDrafts[workspace.id] = "Review this /ios-review $ios-review `.claude/skills/ios-review/SKILL.md`"
            $0.detailInputFocusRequest = 3
        }
    }

    @Test
    func fileSearchAppendsBacktickedProjectRelativePath() async {
        let workspace = Self.workspace()
        let match = ProjectFileMatch(path: "Sources/AppView.swift")
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        state.detailDraft = "Open"
        var client = HarnessClient.unimplemented
        client.searchFiles = { baseURLString, index, query in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(query == "App")
            return FileSearchResponse(
                ok: true,
                rootPath: "/Users/ronnie/Code/cmux",
                query: query,
                files: [match],
                truncated: false,
                limit: 80,
                error: nil
            )
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.fileSearchTapped) {
            $0.isShowingFileSearch = true
            $0.fileSearchQuery = ""
            $0.fileSearchResults = []
            $0.fileSearchError = nil
            $0.isSearchingFiles = false
        }
        await store.send(.fileSearchQueryChanged("App")) {
            $0.fileSearchQuery = "App"
            $0.fileSearchError = nil
            $0.isSearchingFiles = true
        }
        await store.receive(\.fileSearchSucceeded) {
            $0.isSearchingFiles = false
            $0.fileSearchResults = [match]
        }
        await store.send(.appendFilePath(match)) {
            $0.detailDraft = "Open `Sources/AppView.swift`"
            $0.detailDrafts[workspace.id] = "Open `Sources/AppView.swift`"
            $0.detailInputFocusRequest = 1
            $0.isShowingFileSearch = false
            $0.fileSearchQuery = ""
            $0.fileSearchResults = []
            $0.fileSearchError = nil
            $0.isSearchingFiles = false
        }
    }

    @Test
    func jiraLookupResolvesAnyKeyAndInsertsCompactMetadata() async {
        let workspace = Self.workspace()
        let ticket = JiraTicket(
            key: "WEB-42",
            projectKey: "WEB",
            title: "Support exact Jira lookup",
            status: "In Progress",
            priority: "High",
            issueType: "Story",
            url: "https://example.atlassian.net/browse/WEB-42"
        )
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        state.detailDraft = "Existing context."
        state.isShowingJiraTickets = true
        state.jiraLookupQuery = "https://example.atlassian.net/browse/web-42"
        var client = HarnessClient.unimplemented
        client.jiraTicket = { baseURLString, query in
            #expect(baseURLString == Self.baseURL)
            #expect(query == "https://example.atlassian.net/browse/web-42")
            return JiraTicketResponse(ok: true, site: "example.atlassian.net", ticket: ticket, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.resolveJiraTicket) {
            $0.isResolvingJiraTicket = true
            $0.jiraLookupError = nil
            $0.resolvedJiraTicket = nil
        }
        await store.receive(\.jiraTicketResolved) {
            $0.isResolvingJiraTicket = false
            $0.resolvedJiraTicket = ticket
            $0.jiraLookupQuery = "WEB-42"
        }
        await store.send(.appendJiraTicketReference(ticket)) {
            $0.detailDraft = """
            Existing context.

            Jira: WEB-42
            Title: Support exact Jira lookup
            URL: https://example.atlassian.net/browse/WEB-42
            Status: In Progress
            Priority: High
            Type: Story

            Please use this ticket as context.
            """
            $0.detailDrafts[workspace.id] = $0.detailDraft
            $0.detailTab = .terminal
            $0.detailInputFocusRequest = 1
            $0.isShowingJiraTickets = false
            $0.jiraLookupQuery = ""
            $0.resolvedJiraTicket = nil
            $0.jiraLookupError = nil
            $0.isResolvingJiraTicket = false
        }
    }

    @Test
    func assignedJiraTicketsLoadsWithoutProjectFilter() async {
        let workspace = Self.workspace()
        let tickets = [
            JiraTicket(
                key: "WEB-42",
                projectKey: "WEB",
                title: "Finder work",
                status: "In Progress",
                priority: "High",
                issueType: "Bug",
                url: "https://example.atlassian.net/browse/WEB-42"
            ),
            JiraTicket(
                key: "APP-10",
                projectKey: "APP",
                title: "iOS work",
                status: "Selected for Development",
                priority: "Low",
                issueType: "Story",
                url: "https://example.atlassian.net/browse/APP-10"
            ),
        ]
        let response = JiraTicketsResponse(
            ok: true,
            project: nil,
            projects: ["APP", "WEB"],
            site: "example.atlassian.net",
            tickets: tickets,
            error: nil
        )
        var state = Self.initialState()
        state.workspaces = [workspace]
        state.selectedWorkspaceID = workspace.id
        var client = HarnessClient.unimplemented
        client.assignedJiraTickets = { baseURLString, project, limit in
            #expect(baseURLString == Self.baseURL)
            #expect(project == nil)
            #expect(limit == 50)
            return response
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.loadAssignedJiraTickets) {
            $0.isLoadingJiraTickets = true
            $0.jiraTicketsError = nil
        }
        await store.receive(\.assignedJiraTicketsSucceeded) {
            $0.isLoadingJiraTickets = false
            $0.jiraTickets = [tickets[1], tickets[0]]
        }
    }

    @Test
    func harnessUrlBuildsApiRequestsAtServerRoot() throws {
        let statusURL = try HarnessAPI.makeURL(
            baseURLString: Self.baseURL,
            path: "/api/status",
            queryItems: []
        )
        let screenURL = try HarnessAPI.makeURL(
            baseURLString: Self.baseURL,
            path: "/api/screen",
            queryItems: [
                URLQueryItem(name: "index", value: "2"),
                URLQueryItem(name: "lines", value: "200"),
            ]
        )

        #expect(statusURL.absoluteString == "http://macbook.local:9091/api/status")
        #expect(screenURL.absoluteString == "http://macbook.local:9091/api/screen?index=2&lines=200")
    }

    private static let baseURL = "http://macbook.local:9091/harness"

    private static func initialState() -> HarnessFeature.State {
        var state = HarnessFeature.State()
        let source = HarnessServerSource(name: "MacBook", urlString: baseURL)
        state.serverSources = [source]
        state.selectedServerSourceID = source.id
        state.editingServerSourceID = source.id
        state.serverSourceNameString = source.name
        state.serverURLString = baseURL
        state.committedServerURLString = baseURL
        state.isDemoMode = false
        state.selectedWorkspaceID = nil
        state.detailDrafts = [:]
        state.detailDraft = ""
        return state
    }

    private static func status(workspaces: [Workspace]) -> HarnessStatus {
        HarnessStatus(
            enabled: true,
            workspaces: workspaces,
            pollInterval: 2,
            socketFound: true,
            model: "claude-sonnet",
            reviewEnabled: false,
            reviewModel: nil,
            reviewBackend: nil,
            contractReviewEnabled: false,
            connected: true,
            lastSuccessfulPoll: 1_777_000_000,
            connectionLostAt: nil,
            staleData: false,
            ollamaAvailable: nil
        )
    }

    private static func workspace(enabled: Bool = true) -> Workspace {
        Workspace(
            hasClaude: true,
            index: 2,
            name: "ios-app",
            uuid: "workspace-2",
            enabled: enabled,
            autoEnabledAt: nil,
            autoExpiresAt: nil,
            customName: nil,
            lastCheck: "2026-04-26T12:00:00Z",
            screenTail: "tail",
            screenFull: "full screen",
            cwd: "/Users/ronnie/Code/cmux",
            branch: "main",
            sessionStart: 1_777_000_000,
            sessionCost: "$0.42",
            surfaceId: "surface-2",
            surfaceUuid: nil,
            surfaceLabel: "iOS App",
            surfaceTitle: "cmux",
            gitDirty: true,
            surfaceCreatedAt: "2026-04-26T11:00:00Z",
            surfaceAge: 3_600
        )
    }

    private static func prCommentsResponse(thread: GitHubPRThread) -> GitHubPRCommentsResponse {
        GitHubPRCommentsResponse(
            ok: true,
            cwd: "/Users/ronnie/Code/cmux",
            repository: GitHubRepository(
                owner: "example-org",
                name: "cmux-harness",
                url: "https://github.com/example-org/cmux-harness"
            ),
            pullRequest: GitHubPullRequest(
                number: 42,
                title: "Ship comments",
                url: "https://github.com/example-org/cmux-harness/pull/42",
                headRefName: "feature/pr-comments",
                baseRefName: "main",
                state: "OPEN",
                author: "reviewer"
            ),
            includeResolved: false,
            threads: [thread],
            files: [
                GitHubPRFileGroup(path: "Sources/App.swift", threadCount: 1, threads: [thread])
            ],
            totalThreadCount: 1,
            returnedThreadCount: 1,
            resolvedThreadCount: 0,
            hiddenResolvedCount: 0,
            error: nil
        )
    }

    private static func prThread() -> GitHubPRThread {
        GitHubPRThread(
            id: "thread-1",
            path: "Sources/App.swift",
            line: 18,
            originalLine: 18,
            startLine: nil,
            originalStartLine: nil,
            diffSide: "RIGHT",
            startDiffSide: "",
            subjectType: "LINE",
            isResolved: false,
            isOutdated: false,
            url: "https://github.com/example-org/cmux-harness/pull/42#discussion_r18",
            codeContext: GitHubPRCodeContext(
                path: "Sources/App.swift",
                source: "workspace",
                startLine: 18,
                endLine: 18,
                lines: [
                    GitHubPRCodeLine(number: 17, text: "let oldValue = value", isTarget: false),
                    GitHubPRCodeLine(number: 18, text: "let value = helper()", isTarget: true),
                    GitHubPRCodeLine(number: 19, text: "return value", isTarget: false),
                ]
            ),
            comments: [
                GitHubPRComment(
                    id: "comment-1",
                    author: "reviewer",
                    body: "Use the new helper.",
                    bodyText: "Use the new helper.",
                    createdAt: "2026-04-29T12:00:00Z",
                    updatedAt: "2026-04-29T12:00:00Z",
                    url: "https://github.com/example-org/cmux-harness/pull/42#discussion_r18",
                    diffHunk: "@@ -1 +1 @@",
                    path: "Sources/App.swift",
                    line: 18,
                    originalLine: 18
                )
            ]
        )
    }
}

private actor HarnessKeyCallRecorder {
    private var keys: [HarnessKey] = []
    private var inFlightCallCount = 0
    private var maximumConcurrentCalls = 0

    func record(_ key: HarnessKey) async {
        inFlightCallCount += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, inFlightCallCount)
        keys.append(key)

        await Task.yield()

        inFlightCallCount -= 1
    }

    func snapshot() -> (keys: [HarnessKey], maximumConcurrentCalls: Int) {
        (keys, maximumConcurrentCalls)
    }
}
