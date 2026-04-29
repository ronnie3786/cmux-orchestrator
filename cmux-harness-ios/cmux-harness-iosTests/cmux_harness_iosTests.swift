import ComposableArchitecture
import Foundation
import SwiftUI
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

        await store.send(.refreshSucceeded(RefreshPayload(status: status, log: []))) {
            $0.status = status
            $0.workspaces = [refreshedWorkspace]
            $0.logEntries = []
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

        await store.send(.refreshSucceeded(RefreshPayload(status: status, log: []))) {
            $0.status = status
            $0.workspaces = [remainingWorkspace]
            $0.logEntries = []
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
        await store.send(.appendSkillFilePath(projectSkill)) {
            $0.detailDraft = "Review this /ios-review `.claude/skills/ios-review/SKILL.md`"
            $0.detailDrafts[workspace.id] = "Review this /ios-review `.claude/skills/ios-review/SKILL.md`"
            $0.detailInputFocusRequest = 2
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
            surfaceLabel: "iOS App",
            surfaceTitle: "cmux",
            gitDirty: true,
            surfaceCreatedAt: "2026-04-26T11:00:00Z",
            surfaceAge: 3_600
        )
    }
}
