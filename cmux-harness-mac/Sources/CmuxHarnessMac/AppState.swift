import Foundation

@MainActor
final class MacHarnessAppState: ObservableObject {
    private enum DefaultsKey {
        static let mode = "cmuxHarnessMacMode"
        static let serverURL = "cmuxHarnessMacServerURL"
        static let committedServerURL = "cmuxHarnessMacCommittedServerURL"
        static let tailscaleHost = "cmuxHarnessMacTailscaleHost"
    }

    @Published var mode: HarnessMode = .managedServer
    @Published var serverURLString = "http://localhost:9091/harness"
    @Published var committedServerURLString = "http://localhost:9091/harness"
    @Published var tailscaleHostString = ""
    @Published var serverSetupMessage: String?
    @Published var serverSetupError: String?
    @Published var isDiscoveringServer = false
    @Published var discoveredServers: [DiscoveredHarnessServer] = []
    @Published var status: HarnessStatus = DemoHarnessStore.status()
    @Published var workspaces: [Workspace] = DemoHarnessStore.workspaces()
    @Published var selectedWorkspaceID: String? = DemoHarnessStore.workspaces().first?.id
    @Published var screenText: String = DemoHarnessStore.terminalScreen
    @Published var draft: String = ""
    @Published var feedItems: [FeedItem] = DemoHarnessStore.feed()
    @Published var logEntries: [LogEntry] = DemoHarnessStore.logEntries()
    @Published var gitStatus: GitStatus = DemoHarnessStore.gitStatus()
    @Published var diffText: String = DemoHarnessStore.diff(for: "Sources/Dashboard/GitDiffView.swift")
    @Published var selectedGitFile: String? = "Sources/Dashboard/GitDiffView.swift"
    @Published var selectedGitSection: String = "unstaged"
    @Published var isLoadingDiff = false
    @Published var diffError: String?
    @Published var prThreads: [GitHubPRThread] = DemoHarnessStore.prThreads()
    @Published var jiraTickets: [JiraTicket] = DemoHarnessStore.jiraTickets()
    @Published var jiraLookupQuery = ""
    @Published var resolvedJiraTicket: JiraTicket?
    @Published var jiraLookupError: String?
    @Published var fileMatches: [ProjectFileMatch] = DemoHarnessStore.fileMatches()
    @Published var skills: [ProjectSkill] = DemoHarnessStore.skills()
    @Published var projectSkills: [ProjectSkill] = DemoHarnessStore.skills()
    @Published var userSkills: [ProjectSkill] = []
    @Published var attachments: [String: [TerminalAttachment]] = [:]
    @Published var searchText: String = ""
    @Published var fileSearchQuery: String = "ServerSupervisor"
    @Published var includeResolvedPRComments: Bool = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var isCreatingSession = false
    @Published var renameWorkspaceID: String?
    @Published var renameText = ""
    @Published var newSessionMode: NewSessionMode = .claude
    @Published var newSessionProjectPath = "~/Documents/Development/sample-app"
    @Published var newSessionBranchName = ""
    @Published var newSessionJiraURL = ""
    @Published var newSessionPrompt = ""
    @Published var newSessionName = "Shell"
    @Published var newSessionError: String?

    private var refreshTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private var gitTask: Task<Void, Never>?
    private var notifiedFeedIDs = Set<String>()

    init(defaults: UserDefaults = .standard) {
        if let rawMode = defaults.string(forKey: DefaultsKey.mode),
           let savedMode = HarnessMode(rawValue: rawMode) {
            mode = savedMode
        }
        if let savedServerURL = defaults.string(forKey: DefaultsKey.serverURL), !savedServerURL.isEmpty {
            serverURLString = savedServerURL
        }
        if let savedCommittedURL = defaults.string(forKey: DefaultsKey.committedServerURL), !savedCommittedURL.isEmpty {
            committedServerURLString = savedCommittedURL
        } else {
            committedServerURLString = serverURLString
        }
        if let savedTailscaleHost = defaults.string(forKey: DefaultsKey.tailscaleHost) {
            tailscaleHostString = savedTailscaleHost
        }
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var visibleWorkspaces: [Workspace] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaces
            .sorted {
                if ($0.starred ?? false) != ($1.starred ?? false) {
                    return ($0.starred ?? false) && !($1.starred ?? false)
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            .filter { workspace in
                trimmed.isEmpty
                || workspace.displayName.localizedCaseInsensitiveContains(trimmed)
                || (workspace.branch ?? "").localizedCaseInsensitiveContains(trimmed)
                || (workspace.cwd ?? "").localizedCaseInsensitiveContains(trimmed)
            }
    }

    func start(supervisor: ServerSupervisor, launchManagedServer: Bool = true, preferredPort: Int? = nil) {
        if mode == .managedServer, launchManagedServer {
            supervisor.start(port: preferredPort)
        }
        startPolling(supervisor: supervisor)
    }

    func stop() {
        refreshTask?.cancel()
        screenTask?.cancel()
        gitTask?.cancel()
        refreshTask = nil
        screenTask = nil
        gitTask = nil
    }

    func switchMode(_ newMode: HarnessMode, supervisor: ServerSupervisor, preferredPort: Int? = nil) {
        mode = newMode
        persistConnection()
        errorMessage = nil
        serverSetupError = nil
        if newMode == .localDemo {
            supervisor.stop()
            loadDemo()
        } else if newMode == .managedServer {
            supervisor.start(port: preferredPort)
            committedServerURLString = supervisor.baseURLString
            persistConnection()
        } else {
            supervisor.stop()
        }
        startPolling(supervisor: supervisor)
    }

    func useExternalServerURL(_ value: String, supervisor: ServerSupervisor) async {
        let normalized = HarnessAPIClient.normalizedBaseURL(value)
        guard !normalized.isEmpty else {
            serverSetupError = "Enter a server URL."
            return
        }
        do {
            let client = HarnessAPIClient(baseURLString: normalized)
            _ = try await client.status()
            serverURLString = normalized
            committedServerURLString = normalized
            mode = .externalServer
            persistConnection()
            supervisor.stop()
            serverSetupMessage = "Connected to \(normalized)"
            serverSetupError = nil
            startPolling(supervisor: supervisor)
        } catch {
            serverSetupError = error.localizedDescription
        }
    }

    func tryTailscaleHost(supervisor: ServerSupervisor) async {
        UserDefaults.standard.set(tailscaleHostString, forKey: DefaultsKey.tailscaleHost)
        let url = HarnessAPIClient.harnessURLFromHost(tailscaleHostString)
        await useExternalServerURL(url, supervisor: supervisor)
    }

    func discoverServers() async {
        isDiscoveringServer = true
        serverSetupMessage = "Looking for server..."
        serverSetupError = nil
        let servers = await HarnessServerDiscovery.discover()
        discoveredServers = servers
        isDiscoveringServer = false
        serverSetupMessage = servers.isEmpty ? "No cmux harness servers found on LAN." : "Found \(servers.count) server\(servers.count == 1 ? "" : "s")."
    }

    func useDiscoveredServer(_ server: DiscoveredHarnessServer, supervisor: ServerSupervisor) async {
        await useExternalServerURL(server.urlString, supervisor: supervisor)
    }

    func startPolling(supervisor: ServerSupervisor) {
        stop()
        refreshTask = Task { [weak self, weak supervisor] in
            while !Task.isCancelled {
                guard let self, let supervisor else { return }
                await self.refresh(supervisor: supervisor)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        screenTask = Task { [weak self, weak supervisor] in
            while !Task.isCancelled {
                guard let self, let supervisor else { return }
                await self.refreshScreen(supervisor: supervisor)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        gitTask = Task { [weak self, weak supervisor] in
            while !Task.isCancelled {
                guard let self, let supervisor else { return }
                await self.refreshTools(supervisor: supervisor)
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    func refresh(supervisor: ServerSupervisor) async {
        if mode == .localDemo {
            loadDemo()
            return
        }
        do {
            let client = apiClient(supervisor: supervisor)
            async let status = client.status()
            async let log = client.log()
            let loadedStatus = try await status
            self.status = loadedStatus
            self.workspaces = loadedStatus.workspaces
            self.logEntries = (try? await log) ?? []
            if selectedWorkspaceID == nil || !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
                selectedWorkspaceID = workspaces.first?.id
            }
            lastUpdated = Date()
            errorMessage = nil
            if let feed = try? await client.feed() {
                notifyForNewFeedItems(feed.items)
                feedItems = feed.items
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshScreen(supervisor: ServerSupervisor) async {
        guard mode != .localDemo, let workspace = selectedWorkspace else { return }
        do {
            let response = try await apiClient(supervisor: supervisor).screen(index: workspace.index, lines: 500)
            screenText = response.screen
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshTools(supervisor: ServerSupervisor) async {
        guard mode != .localDemo, let workspace = selectedWorkspace else { return }
        let client = apiClient(supervisor: supervisor)
        if let git = try? await client.gitStatus(index: workspace.index) {
            gitStatus = git
        }
        if let pr = try? await client.prComments(index: workspace.index, includeResolved: includeResolvedPRComments) {
            prThreads = pr.threads ?? []
        }
        if let jira = try? await client.jiraTickets() {
            jiraTickets = jira.resolvedTickets
        }
        if let found = try? await client.searchFiles(index: workspace.index, query: fileSearchQuery) {
            fileMatches = found.resolvedMatches
        }
        if let loadedSkills = try? await client.skills(index: workspace.index) {
            projectSkills = loadedSkills.projectSkills ?? []
            userSkills = loadedSkills.userSkills ?? []
            skills = projectSkills + userSkills
        }
    }

    func sendDraft(supervisor: ServerSupervisor) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let workspace = selectedWorkspace else { return }
        draft = ""
        if mode == .localDemo {
            screenText += "\n\n$ \(text)\nDemo response accepted locally."
            logEntries.insert(LogEntry(timestamp: ISO8601DateFormatter().string(from: Date()), workspace: workspace.index, workspaceName: workspace.displayName, promptType: "manual", action: "demo input", reason: text, key: nil, surfaceId: workspace.surfaceId), at: 0)
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).sendText(index: workspace.index, text: text + "\n", surfaceId: workspace.surfaceId)
            await refreshScreen(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendKey(_ key: String, supervisor: ServerSupervisor) async {
        guard let workspace = selectedWorkspace else { return }
        if mode == .localDemo {
            screenText += "\nDemo key event: \(key)"
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).sendKey(index: workspace.index, key: key, surfaceId: workspace.surfaceId)
            await refreshScreen(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAutoMode(_ modeValue: WorkspaceAutoMode, supervisor: ServerSupervisor) async {
        guard let workspace = selectedWorkspace else { return }
        if mode == .localDemo {
            mutateSelectedWorkspace { $0.autoMode = modeValue; $0.enabled = modeValue.isEnabled }
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).setWorkspaceAutoMode(index: workspace.index, mode: modeValue)
            await refresh(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setGlobalEnabled(_ enabled: Bool, supervisor: ServerSupervisor) async {
        if mode == .localDemo {
            status.enabled = enabled
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).setGlobalEnabled(enabled)
            await refresh(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleStar(_ workspace: Workspace, supervisor: ServerSupervisor) async {
        let newValue = !(workspace.starred ?? false)
        if mode == .localDemo {
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index].starred = newValue
            }
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).setWorkspaceStarred(index: workspace.index, starred: newValue)
            await refresh(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginRename(_ workspace: Workspace) {
        renameWorkspaceID = workspace.id
        renameText = workspace.displayName
    }

    func commitRename(supervisor: ServerSupervisor) async {
        guard let workspaceID = renameWorkspaceID,
              let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            renameWorkspaceID = nil
            return
        }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if mode == .localDemo {
            if let index = workspaces.firstIndex(where: { $0.id == workspaceID }) {
                workspaces[index].customName = name
            }
            renameWorkspaceID = nil
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).renameWorkspace(index: workspace.index, name: name)
            renameWorkspaceID = nil
            await refresh(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadDiff(file: String, section: String = "unstaged", supervisor: ServerSupervisor) async {
        selectedGitFile = file
        selectedGitSection = section
        diffError = nil
        isLoadingDiff = true
        defer { isLoadingDiff = false }

        if mode == .localDemo {
            diffText = DemoHarnessStore.diff(for: file)
            return
        }
        guard let workspace = selectedWorkspace else { return }
        do {
            let response = try await apiClient(supervisor: supervisor).gitDiff(index: workspace.index, file: file, section: section)
            diffText = response.diff
        } catch {
            diffText = ""
            diffError = error.localizedDescription
        }
    }

    func openSelectedGitFile(supervisor: ServerSupervisor) async {
        guard mode != .localDemo,
              let workspace = selectedWorkspace,
              let selectedGitFile else { return }
        do {
            _ = try await apiClient(supervisor: supervisor).openGitFile(index: workspace.index, file: selectedGitFile)
        } catch {
            diffError = error.localizedDescription
        }
    }

    func stageFile(_ file: String, supervisor: ServerSupervisor) async {
        guard let workspace = selectedWorkspace else { return }
        if mode == .localDemo {
            moveDemoGitFile(file, toStaged: true)
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).stageFile(index: workspace.index, file: file)
            await refreshTools(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unstageFile(_ file: String, supervisor: ServerSupervisor) async {
        guard let workspace = selectedWorkspace else { return }
        if mode == .localDemo {
            moveDemoGitFile(file, toStaged: false)
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).unstageFile(index: workspace.index, file: file)
            await refreshTools(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func lookupJira(supervisor: ServerSupervisor) async {
        let query = jiraLookupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        jiraLookupError = nil
        if mode == .localDemo {
            resolvedJiraTicket = DemoHarnessStore.jiraTickets().first {
                $0.key.localizedCaseInsensitiveContains(query) || ($0.summary ?? "").localizedCaseInsensitiveContains(query)
            }
            if resolvedJiraTicket == nil {
                jiraLookupError = "Demo ticket not found"
            }
            return
        }
        do {
            let response = try await apiClient(supervisor: supervisor).jiraTicket(query: query)
            if !response.ok {
                jiraLookupError = response.error ?? "Jira lookup failed"
            } else {
                resolvedJiraTicket = response.resolvedTicket
            }
        } catch {
            jiraLookupError = error.localizedDescription
        }
    }

    func replyToFeed(_ item: FeedItem, action: String, supervisor: ServerSupervisor) async {
        if mode == .localDemo {
            feedItems.removeAll { $0.id == item.id }
            return
        }
        do {
            _ = try await apiClient(supervisor: supervisor).replyToFeed(item, action: action)
            await refresh(supervisor: supervisor)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createNewSession(supervisor: ServerSupervisor) async {
        newSessionError = nil
        isCreatingSession = true
        defer { isCreatingSession = false }

        if mode == .localDemo {
            let index = (workspaces.map(\.index).max() ?? 2) + 1
            let uuid = "demo-created-\(index)"
            let displayName = newSessionMode == .shell
                ? (newSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Demo Shell" : newSessionName)
                : "Demo Task \(index)"
            let workspace = Workspace(
                hasClaude: newSessionMode == .claude,
                index: index,
                name: displayName,
                uuid: uuid,
                enabled: true,
                autoMode: .auto,
                starred: false,
                customName: displayName,
                lastCheck: ISO8601DateFormatter().string(from: Date()),
                screenTail: "Created \(displayName)\n\(newSessionPrompt)",
                screenFull: "Created \(displayName)\n\(newSessionPrompt)",
                cwd: newSessionProjectPath,
                branch: newSessionBranchName.isEmpty ? "demo/new-session-\(index)" : newSessionBranchName,
                sessionCost: "$0.00",
                surfaceId: "demo-surface-\(index)",
                surfaceLabel: displayName,
                surfaceTitle: newSessionMode.rawValue,
                gitDirty: false,
                surfaceAge: 0
            )
            workspaces.append(workspace)
            selectedWorkspaceID = workspace.id
            screenText = workspace.screenFull ?? ""
            return
        }

        do {
            let response = try await apiClient(supervisor: supervisor).createSession(
                projectPath: newSessionProjectPath,
                branchName: newSessionBranchName,
                jiraURL: newSessionJiraURL,
                prompt: newSessionPrompt,
                mode: newSessionMode,
                sessionName: newSessionName
            )
            if !response.ok {
                newSessionError = response.error ?? "Session creation failed"
                return
            }
            await refresh(supervisor: supervisor)
            if let uuid = response.workspace?.uuid {
                selectedWorkspaceID = workspaces.first { $0.uuid == uuid }?.id ?? selectedWorkspaceID
            }
        } catch {
            newSessionError = error.localizedDescription
        }
    }

    func addAttachment(_ url: URL, supervisor: ServerSupervisor) async {
        guard let workspace = selectedWorkspace else { return }
        let workspaceID = workspace.id
        let attachment = TerminalAttachment(sourceURL: url, filename: url.lastPathComponent, state: .uploading)
        attachments[workspaceID, default: []].append(attachment)

        await uploadAttachment(attachment, workspace: workspace, workspaceID: workspaceID, supervisor: supervisor)
    }

    func removeAttachment(workspaceID: String, attachmentID: UUID) {
        attachments[workspaceID]?.removeAll { $0.id == attachmentID }
        if attachments[workspaceID]?.isEmpty == true {
            attachments[workspaceID] = nil
        }
    }

    func retryAttachment(workspaceID: String, attachmentID: UUID, supervisor: ServerSupervisor) async {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              var attachment = attachments[workspaceID]?.first(where: { $0.id == attachmentID }) else {
            return
        }

        attachment.state = .uploading
        attachment.uploaded = nil
        replaceAttachment(attachment, workspaceID: workspaceID)
        await uploadAttachment(attachment, workspace: workspace, workspaceID: workspaceID, supervisor: supervisor)
    }

    private func uploadAttachment(_ attachment: TerminalAttachment, workspace: Workspace, workspaceID: String, supervisor: ServerSupervisor) async {
        var attachment = attachment
        if mode == .localDemo {
            attachment.state = .uploaded
            attachment.uploaded = UploadedAttachment(id: attachment.id.uuidString, filename: attachment.filename, path: attachment.sourceURL.path, url: nil, contentType: nil, size: nil)
            replaceAttachment(attachment, workspaceID: workspaceID)
            draft += "\n[Attachment: \(attachment.filename)]"
            return
        }

        do {
            let response = try await apiClient(supervisor: supervisor).uploadAttachment(workspace: workspace, fileURL: attachment.sourceURL, filename: attachment.filename)
            attachment.state = .uploaded
            attachment.uploaded = response.attachment
            replaceAttachment(attachment, workspaceID: workspaceID)
            let filename = response.attachment?.filename ?? attachment.filename
            draft += "\n[Attachment: \(filename)]"
        } catch {
            attachment.state = .failed(error.localizedDescription)
            replaceAttachment(attachment, workspaceID: workspaceID)
        }
    }

    private func loadDemo() {
        status = DemoHarnessStore.status()
        workspaces = DemoHarnessStore.workspaces()
        if selectedWorkspaceID == nil || !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = workspaces.first?.id
        }
        screenText = selectedWorkspace?.screenFull ?? DemoHarnessStore.terminalScreen
        feedItems = DemoHarnessStore.feed()
        logEntries = DemoHarnessStore.logEntries()
        gitStatus = DemoHarnessStore.gitStatus()
        diffText = DemoHarnessStore.diff(for: "Sources/Dashboard/GitDiffView.swift")
        selectedGitFile = "Sources/Dashboard/GitDiffView.swift"
        selectedGitSection = "unstaged"
        isLoadingDiff = false
        diffError = nil
        prThreads = DemoHarnessStore.prThreads()
        jiraTickets = DemoHarnessStore.jiraTickets()
        fileMatches = DemoHarnessStore.fileMatches()
        skills = DemoHarnessStore.skills()
        projectSkills = DemoHarnessStore.skills()
        userSkills = []
        lastUpdated = Date()
    }

    private func apiClient(supervisor: ServerSupervisor) -> HarnessAPIClient {
        if mode == .externalServer {
            return HarnessAPIClient(baseURLString: committedServerURLString)
        }
        committedServerURLString = supervisor.baseURLString
        return supervisor.apiClient
    }

    private func persistConnection() {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: DefaultsKey.mode)
        defaults.set(serverURLString, forKey: DefaultsKey.serverURL)
        defaults.set(committedServerURLString, forKey: DefaultsKey.committedServerURL)
        defaults.set(tailscaleHostString, forKey: DefaultsKey.tailscaleHost)
    }

    private func mutateSelectedWorkspace(_ mutate: (inout Workspace) -> Void) {
        guard let selectedWorkspaceID,
              let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) else {
            return
        }
        mutate(&workspaces[index])
    }

    private func replaceAttachment(_ attachment: TerminalAttachment, workspaceID: String) {
        guard var list = attachments[workspaceID],
              let index = list.firstIndex(where: { $0.id == attachment.id }) else {
            attachments[workspaceID, default: []].append(attachment)
            return
        }
        list[index] = attachment
        attachments[workspaceID] = list
    }

    private func notifyForNewFeedItems(_ items: [FeedItem]) {
        for item in items where !notifiedFeedIDs.contains(item.id) {
            notifiedFeedIDs.insert(item.id)
            LocalNotificationBridge.notifyFeedItem(item)
        }
    }

    private func moveDemoGitFile(_ file: String, toStaged: Bool) {
        var staged = gitStatus.staged ?? []
        var unstaged = gitStatus.unstaged ?? []
        if toStaged {
            if let index = unstaged.firstIndex(where: { $0.file == file }) {
                staged.append(unstaged.remove(at: index))
            }
        } else if let index = staged.firstIndex(where: { $0.file == file }) {
            unstaged.append(staged.remove(at: index))
        }
        gitStatus.staged = staged
        gitStatus.unstaged = unstaged
    }
}
