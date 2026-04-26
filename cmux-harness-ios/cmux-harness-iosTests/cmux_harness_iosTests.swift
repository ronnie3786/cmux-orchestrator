import ComposableArchitecture
import Foundation
import Testing
@testable import cmux_harness_ios

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
            $0.lastUpdated = updatedAt
        }
    }

    @Test
    func sortedWorkspacesUseLatestActivityFirst() {
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

        #expect(state.sortedWorkspaces.map(\.displayName) == ["Gamma", "Beta", "Alpha"])
    }

    @Test
    func toggleWorkspaceOptimisticallyUpdatesAndCallsClient() async {
        let workspace = Self.workspace(enabled: false)
        var state = Self.initialState()
        state.workspaces = [workspace]
        var client = HarnessClient.unimplemented
        client.setWorkspaceEnabled = { baseURLString, index, enabled in
            #expect(baseURLString == Self.baseURL)
            #expect(index == workspace.index)
            #expect(enabled)
            return BasicResponse(ok: true, enabled: enabled, error: nil)
        }

        let store = TestStore(initialState: state) {
            HarnessFeature()
        } withDependencies: {
            $0.harnessClient = client
        }

        await store.send(.toggleWorkspace(workspaceID: workspace.id, enabled: true)) {
            $0.workspaces[0].enabled = true
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
    func jiraUrlAutofillsBranchNameWhenEmpty() async {
        let store = TestStore(initialState: Self.initialState()) {
            HarnessFeature()
        }

        await store.send(.newSessionJiraChanged("https://doximity.atlassian.net/browse/iosdox-24180")) {
            $0.newSessionJiraURL = "https://doximity.atlassian.net/browse/iosdox-24180"
            $0.newSessionBranchName = "IOSDOX-24180"
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

        #expect(statusURL.absoluteString == "http://doximity-m4.tail1db61d.ts.net:9091/api/status")
        #expect(screenURL.absoluteString == "http://doximity-m4.tail1db61d.ts.net:9091/api/screen?index=2&lines=200")
    }

    private static let baseURL = "http://doximity-m4.tail1db61d.ts.net:9091/harness"

    private static func initialState() -> HarnessFeature.State {
        var state = HarnessFeature.State()
        state.serverURLString = baseURL
        state.committedServerURLString = baseURL
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
            customName: nil,
            lastCheck: "2026-04-26T12:00:00Z",
            screenTail: "tail",
            screenFull: "full screen",
            cwd: "/Users/ronnie/Code/cmux",
            branch: "main",
            sessionStart: 1_777_000_000,
            sessionCost: "$0.42",
            surfaceId: "surface-2",
            surfaceLabel: "iOS App",
            surfaceTitle: "cmux",
            gitDirty: true,
            surfaceCreatedAt: "2026-04-26T11:00:00Z",
            surfaceAge: 3_600
        )
    }
}
