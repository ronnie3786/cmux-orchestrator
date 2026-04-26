import ComposableArchitecture
import SwiftUI

struct HarnessRootView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        NavigationSplitView {
            WorkspaceListView(store: store)
                .navigationTitle("cmux")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            store.send(.refresh)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)

                        Button {
                            store.send(.newSessionButtonTapped)
                        } label: {
                            Image(systemName: "plus")
                        }

                        Button {
                            store.send(.settingsButtonTapped)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        } detail: {
            if let workspace = store.selectedWorkspace {
                WorkspaceDetailView(store: store, workspace: workspace)
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "terminal",
                    description: Text("Choose a cmux session.")
                )
            }
        }
        .sheet(isPresented: $store.isShowingSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $store.isShowingNewSession) {
            NewSessionView(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.diffSheet != nil },
                set: { isPresented in
                    if !isPresented {
                        store.send(.closeDiff)
                    }
                }
            )
        ) {
            if let diffSheet = store.diffSheet {
                DiffSheetView(store: store, diffSheet: diffSheet)
            }
        }
        .alert(
            "Rename Session",
            isPresented: Binding(
                get: { store.renameWorkspaceID != nil },
                set: { isPresented in
                    if !isPresented {
                        store.send(.cancelRename)
                    }
                }
            )
        ) {
            TextField("Name", text: $store.renameText)
            Button("Save") {
                store.send(.commitRename)
            }
            Button("Cancel", role: .cancel) {
                store.send(.cancelRename)
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
        .onDisappear {
            store.send(.onDisappear)
        }
    }
}

private struct WorkspaceListView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                DashboardSummaryView(store: store)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section("Sessions") {
                if store.isRefreshing && store.workspaces.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if store.workspaces.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("cmux sessions will appear here.")
                    )
                } else {
                    ForEach(store.sortedWorkspaces) { workspace in
                        WorkspaceCardView(store: store, workspace: workspace)
                            .tag(workspace.id)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }

            if let error = store.errorMessage {
                Section {
                    ErrorBanner(message: error) {
                        store.send(.clearError)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { store.selectedWorkspaceID },
            set: { store.send(.selectWorkspace($0)) }
        )
    }
}

private struct DashboardSummaryView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ConnectionDot(state: connectionState)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionTitle)
                        .font(.headline)
                    Text(store.committedServerURLString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle(
                    "Auto",
                    isOn: Binding(
                        get: { store.status?.enabled ?? false },
                        set: { store.send(.toggleGlobal($0)) }
                    )
                )
                .labelsHidden()
            }

            HStack(spacing: 10) {
                StatPill(title: "Active", value: store.activeCount, tint: .green)
                StatPill(title: "Needs You", value: store.waitingCount, tint: .orange)
                StatPill(title: "Idle", value: store.idleCount, tint: .secondary)
            }

            if let lastUpdated = store.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionState: ConnectionDot.State {
        if store.isConnected {
            return .connected
        }
        if store.hasSocket {
            return .reconnecting
        }
        return .offline
    }

    private var connectionTitle: String {
        if store.isConnected {
            return "Connected"
        }
        if store.hasSocket {
            return "Reconnecting"
        }
        return "No cmux Socket"
    }
}

private struct WorkspaceCardView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                StatusGlyph(state: sessionState)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        store.send(.selectWorkspace(workspace.id))
                    } label: {
                        SessionTitleView(workspace: workspace)
                    }
                    .buttonStyle(.plain)

                    MetaLine(workspace: workspace, showsPath: false)
                }

                Spacer(minLength: 8)

                Menu {
                    Button {
                        store.send(.selectWorkspace(workspace.id))
                    } label: {
                        Label("Open", systemImage: "rectangle.expand.vertical")
                    }
                    Button {
                        store.send(.renameRequested(workspaceID: workspace.id))
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Toggle(
                        "Auto Approve",
                        isOn: Binding(
                            get: { workspace.enabled },
                            set: { store.send(.toggleWorkspace(workspaceID: workspace.id, enabled: $0)) }
                        )
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }
            }

            if isExpanded {
                Divider()

                Text(workspace.terminalPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Send message", text: draftBinding)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit {
                                store.send(.sendDraft(workspaceID: workspace.id))
                            }

                        Button {
                            store.send(.sendDraft(workspaceID: workspace.id))
                        } label: {
                            Image(systemName: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    HStack(spacing: 8) {
                        ForEach(HarnessKey.allCases) { key in
                            Button {
                                store.send(.sendKey(workspaceID: workspace.id, key))
                            } label: {
                                Label(key.label, systemImage: key.systemImage)
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel(key.label)
                        }

                        Spacer()

                        Toggle(
                            "Auto",
                            isOn: Binding(
                                get: { workspace.enabled },
                                set: { store.send(.toggleWorkspace(workspaceID: workspace.id, enabled: $0)) }
                            )
                        )
                        .font(.caption)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            if !isExpanded {
                Button {
                    store.send(.selectWorkspace(workspace.id))
                } label: {
                    Label("Open terminal", systemImage: "terminal")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(cardBorderColor, lineWidth: isExpanded ? 1.5 : 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            store.send(.selectWorkspace(workspace.id))
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { store.draftMessages[workspace.id, default: ""] },
            set: { store.send(.draftChanged(workspaceID: workspace.id, text: $0)) }
        )
    }

    private var sessionState: WorkspaceSessionState {
        workspaceSessionState(for: workspace, entries: store.logEntries)
    }

    private var isExpanded: Bool {
        store.selectedWorkspaceID == workspace.id
    }

    private var cardBorderColor: Color {
        isExpanded ? .accentColor.opacity(0.6) : Color(.separator).opacity(0.55)
    }
}

private struct WorkspaceDetailView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            Picker("View", selection: detailTabBinding) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .bottom])

            Group {
                switch store.detailTab {
                case .terminal:
                    TerminalScrollView(workspaceID: workspace.id, text: terminalText)
                case .git:
                    GitStatusView(store: store)
                case .activity:
                    ActivityListView(entries: activityEntries)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if store.detailTab == .terminal {
                DetailInputBar(store: store, workspace: workspace)
                    .background(.bar)
            }
        }
        .navigationTitle(workspace.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Toggle(
                    "Auto",
                    isOn: Binding(
                        get: { workspace.enabled },
                        set: { store.send(.toggleWorkspace(workspaceID: workspace.id, enabled: $0)) }
                    )
                )
                .labelsHidden()

                Button {
                    store.send(.renameRequested(workspaceID: workspace.id))
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(state: sessionState)
                Text(sessionState.label)
                    .font(.subheadline.weight(.semibold))
                if let cost = workspace.sessionCost, !cost.isEmpty {
                    Text(cost)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(costColor(cost))
                }
                Spacer()
            }

            MetaLine(workspace: workspace)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var detailTabBinding: Binding<DetailTab> {
        Binding(
            get: { store.detailTab },
            set: { store.send(.detailTabChanged($0)) }
        )
    }

    private var terminalText: String {
        let text = store.fullScreenText ?? workspace.screenFull ?? workspace.screenTail ?? ""
        return text.isEmpty ? "(no terminal data yet)" : text
    }

    private var sessionState: WorkspaceSessionState {
        workspaceSessionState(for: workspace, entries: store.logEntries)
    }

    private var activityEntries: [LogEntry] {
        store.logEntries.filter { $0.workspace == workspace.index }
    }
}

private struct DetailInputBar: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Type a message or instruction", text: $store.detailDraft)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        store.send(.sendDetailDraft)
                    }

                Button {
                    store.send(.sendDetailDraft)
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                ForEach(HarnessKey.allCases) { key in
                    Button {
                        store.send(.sendKey(workspaceID: workspace.id, key))
                    } label: {
                        Label(key.label, systemImage: key.systemImage)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
        }
        .padding()
    }
}

private struct TerminalScrollView: View {
    let workspaceID: String
    let text: String
    private let bottomID = "terminal-bottom"
    @State private var contentHeight: CGFloat = 0
    @State private var scrollRevision = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()

                    Color.clear
                        .frame(height: 12)
                        .id(bottomID)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: TerminalContentHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                }
            }
            .background(Color(.systemBackground))
            .defaultScrollAnchor(.bottom)
            .onAppear {
                requestBottomScroll()
            }
            .onChange(of: workspaceID) {
                requestBottomScroll()
            }
            .onChange(of: text) {
                requestBottomScroll()
            }
            .onPreferenceChange(TerminalContentHeightKey.self) { height in
                guard contentHeight != height else { return }
                contentHeight = height
                requestBottomScroll()
            }
            .task(id: scrollRevision) {
                await scrollToBottom(proxy)
            }
        }
    }

    private func requestBottomScroll() {
        scrollRevision &+= 1
    }

    @MainActor
    private func scrollToBottom(_ proxy: ScrollViewProxy) async {
        await Task.yield()
        scroll(proxy)

        for delay in [50_000_000, 150_000_000, 300_000_000] as [UInt64] {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            scroll(proxy)
        }
    }

    @MainActor
    private func scroll(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

private struct TerminalContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct GitStatusView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        List {
            if store.isLoadingGit && store.gitStatus == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = store.gitError {
                ErrorBanner(message: error) {
                    store.send(.gitTick)
                }
            } else if let git = store.gitStatus {
                Section("Repository") {
                    LabeledContent("Branch", value: git.branch?.isEmpty == false ? git.branch! : "Unknown")
                    LabeledContent("Path", value: git.cwd?.isEmpty == false ? git.cwd! : "No git repo")
                }

                if git.staged.isEmpty && git.unstaged.isEmpty && git.untracked.isEmpty {
                    Section {
                        ContentUnavailableView("Clean", systemImage: "checkmark.circle")
                    }
                }

                if !git.staged.isEmpty {
                    Section("Staged") {
                        ForEach(git.staged) { file in
                            GitFileRow(
                                file: file.file,
                                status: file.status,
                                section: .staged,
                                store: store
                            )
                        }
                    }
                }

                if !git.unstaged.isEmpty || !git.untracked.isEmpty {
                    Section("Unstaged") {
                        ForEach(git.unstaged) { file in
                            GitFileRow(
                                file: file.file,
                                status: file.status,
                                section: .unstaged,
                                store: store
                            )
                        }
                        ForEach(git.untracked, id: \.self) { file in
                            GitFileRow(
                                file: file,
                                status: "?",
                                section: .untracked,
                                store: store
                            )
                        }
                    }
                }

                if !git.commits.isEmpty {
                    Section("Recent Commits") {
                        ForEach(git.commits) { commit in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(commit.message)
                                    .lineLimit(2)
                                Text(commit.hash)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Git Data", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            store.send(.gitTick)
        }
    }
}

private struct GitFileRow: View {
    let file: String
    let status: String
    let section: GitFileSection
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        HStack(spacing: 10) {
            Text(status)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(section == .staged ? .green : .orange)
                .frame(width: 24)

            Text(file)
                .font(.callout.monospaced())
                .lineLimit(2)

            Spacer()

            Button {
                store.send(.requestDiff(file: file, section: section))
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                store.send(.requestDiff(file: file, section: section))
            } label: {
                Label("Diff", systemImage: "doc.text.magnifyingglass")
            }
            .tint(.blue)

            if section == .staged {
                Button {
                    store.send(.unstageFile(file))
                } label: {
                    Label("Unstage", systemImage: "minus.circle")
                }
                .tint(.orange)
            } else {
                Button {
                    store.send(.stageFile(file))
                } label: {
                    Label("Stage", systemImage: "plus.circle")
                }
                .tint(.green)
            }
        }
        .contextMenu {
            Button {
                store.send(.requestDiff(file: file, section: section))
            } label: {
                Label("View Diff", systemImage: "doc.text.magnifyingglass")
            }

            if section == .staged {
                Button {
                    store.send(.unstageFile(file))
                } label: {
                    Label("Unstage File", systemImage: "minus.circle")
                }
            } else {
                Button {
                    store.send(.stageFile(file))
                } label: {
                    Label("Stage File", systemImage: "plus.circle")
                }
            }
        }
    }
}

private struct ActivityListView: View {
    let entries: [LogEntry]

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle")
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.action ?? "Activity")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if let timestamp = entry.timestamp {
                                Text(formatTimestamp(timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let promptType = entry.promptType, !promptType.isEmpty {
                            Text(promptType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let reason = entry.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct SettingsView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $store.serverURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.send(.dismissSettings)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.send(.saveServerTapped)
                    }
                }
            }
        }
    }
}

private struct NewSessionView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    Picker("Mode", selection: $store.newSessionMode) {
                        ForEach(NewSessionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Project path", text: $store.newSessionProjectPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if store.newSessionMode == .shell {
                        TextField("Name", text: $store.newSessionName)
                            .textInputAutocapitalization(.words)
                    }
                }

                if store.newSessionMode == .claude {
                    Section("Worktree") {
                        TextField(
                            "JIRA URL",
                            text: Binding(
                                get: { store.newSessionJiraURL },
                                set: { store.send(.newSessionJiraChanged($0)) }
                            )
                        )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                        TextField("Branch", text: $store.newSessionBranchName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Prompt") {
                        TextField("Initial prompt", text: $store.newSessionPrompt, axis: .vertical)
                            .lineLimit(4...10)
                    }
                }

                if let error = store.newSessionError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.send(.dismissNewSession)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.isCreatingSession ? "Creating" : "Create") {
                        store.send(.createNewSession)
                    }
                    .disabled(store.isCreatingSession)
                }
            }
        }
    }
}

private struct DiffSheetView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let diffSheet: DiffSheet

    var body: some View {
        NavigationStack {
            Group {
                if diffSheet.isLoading {
                    ProgressView()
                } else if let error = diffSheet.error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diffSheet.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                Text(String(line))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(diffColor(for: String(line)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 1)
                                    .background(diffBackground(for: String(line)))
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .background(Color(.systemBackground))
                }
            }
            .navigationTitle(diffSheet.file)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.send(.closeDiff)
                    }
                }
            }
        }
    }
}

private struct SessionTitleView: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workspace.cardTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle = workspace.cardSubtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MetaLine: View {
    let workspace: Workspace
    var showsPath = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsPath, let cwd = workspace.cwd, !cwd.isEmpty {
                Label(cwd, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack(spacing: 12) {
                if let branch = workspace.branch, !branch.isEmpty {
                    Label(branch, systemImage: "point.3.connected.trianglepath.dotted")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let lastCheck = workspace.lastCheck, !lastCheck.isEmpty {
                    Label(formatTimestamp(lastCheck), systemImage: "clock")
                }
                if let surfaceTitle = workspace.surfaceTitle, !surfaceTitle.isEmpty {
                    Label(surfaceTitle, systemImage: "square.split.2x1")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct StatusGlyph: View {
    let state: WorkspaceSessionState

    var body: some View {
        Image(systemName: state.systemImage)
            .symbolRenderingMode(.palette)
            .foregroundStyle(primaryColor, primaryColor.opacity(0.18))
            .imageScale(.large)
            .accessibilityLabel(state.label)
    }

    private var primaryColor: Color {
        switch state {
        case .active:
            return .green
        case .waiting:
            return .orange
        case .idle:
            return .secondary
        }
    }
}

private struct ConnectionDot: View {
    enum State {
        case connected
        case reconnecting
        case offline
    }

    let state: State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .shadow(color: color.opacity(0.4), radius: 4)
    }

    private var color: Color {
        switch state {
        case .connected:
            return .green
        case .reconnecting:
            return .orange
        case .offline:
            return .red
        }
    }
}

private struct StatPill: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ErrorBanner: View {
    let message: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: action)
                .font(.caption)
        }
    }
}

private func formatTimestamp(_ value: String) -> String {
    if let date = ISO8601DateFormatter().date(from: value) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return value
}

private extension Workspace {
    var cardTitle: String {
        if let pathTail = displayName.pathTail(componentCount: 2) {
            return pathTail
        }
        return displayName
    }

    var cardSubtitle: String? {
        if let cwd = cwd?.nonEmptyTrimmed {
            return cwd
        }
        if displayName != cardTitle, displayName.contains("/") {
            return displayName
        }
        if let surfaceTitle = surfaceTitle?.nonEmptyTrimmed, surfaceTitle != cardTitle {
            return surfaceTitle
        }
        return nil
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func pathTail(componentCount: Int) -> String? {
        let components = replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { component in
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed != "..." && trimmed != "…"
            }

        guard components.count > 1 else { return nil }
        return components.suffix(max(1, componentCount)).joined(separator: "/")
    }
}

private func workspaceSessionState(for workspace: Workspace, entries: [LogEntry]) -> WorkspaceSessionState {
    if let action = entries.first(where: { $0.workspace == workspace.index })?.action,
       action.localizedCaseInsensitiveContains("human") {
        return .waiting
    }
    return workspace.hasClaude ? .active : .idle
}

private func costColor(_ value: String) -> Color {
    let number = Double(value.replacingOccurrences(of: "$", with: "")) ?? 0
    if number >= 5 {
        return .red
    }
    if number >= 2 {
        return .orange
    }
    return .secondary
}

private func diffColor(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") {
        return .green
    }
    if line.hasPrefix("-") && !line.hasPrefix("---") {
        return .red
    }
    if line.hasPrefix("@@") {
        return .blue
    }
    return .primary
}

private func diffBackground(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") {
        return Color.green.opacity(0.08)
    }
    if line.hasPrefix("-") && !line.hasPrefix("---") {
        return Color.red.opacity(0.08)
    }
    if line.hasPrefix("@@") {
        return Color.blue.opacity(0.08)
    }
    return Color.clear
}
