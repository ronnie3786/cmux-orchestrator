import ComposableArchitecture
import SwiftUI

struct HarnessRootView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        NavigationSplitView {
            WorkspaceListView(store: store)
        } detail: {
            if let workspace = store.selectedWorkspace {
                WorkspaceDetailView(store: store, workspace: workspace)
            } else {
                ZStack {
                    SessionDetailBackground()
                    ContentUnavailableView(
                        "No Session Selected",
                        systemImage: "terminal",
                        description: Text("Choose a cmux session.")
                    )
                    .foregroundStyle(.white)
                }
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
                HomeHeaderView(store: store)
                    .listRowInsets(EdgeInsets(top: 26, leading: 18, bottom: 14, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                DashboardSummaryView(store: store)
                    .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 14, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                SessionSearchFilterBar(store: store)
                    .listRowInsets(EdgeInsets(top: 14, leading: 18, bottom: 18, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                HStack {
                    Text("Sessions")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(store.visibleWorkspaces.count) \(store.visibleWorkspaces.count == 1 ? "session" : "sessions")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 10, trailing: 18))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                if store.isRefreshing && store.workspaces.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .tint(.white)
                        .listRowInsets(EdgeInsets(top: 24, leading: 18, bottom: 24, trailing: 18))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if store.workspaces.isEmpty {
                    HomeEmptyState(
                        title: "No Sessions",
                        message: "cmux sessions will appear here.",
                        systemImage: "terminal"
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 24, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if store.visibleWorkspaces.isEmpty {
                    HomeEmptyState(
                        title: "No Matches",
                        message: "Adjust search or filter.",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 24, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.visibleWorkspaces) { workspace in
                        WorkspaceCardView(store: store, workspace: workspace)
                            .tag(workspace.id)
                            .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 7, trailing: 18))
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
                    .padding(14)
                    .background(HomeGlassCard(cornerRadius: 16))
                    .foregroundStyle(.white)
                    .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 24, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(HomeBackground())
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .refreshable {
            store.send(.refresh)
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { store.selectedWorkspaceID },
            set: { store.send(.selectWorkspace($0)) }
        )
    }
}

private struct HomeBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.025, green: 0.032, blue: 0.044),
                Color.black,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct HomeHeaderView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 16) {
                Text("cmux")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    HomeActionButton(systemImage: "arrow.clockwise") {
                        store.send(.refresh)
                    }
                    .disabled(store.isRefreshing)

                    HomeActionButton(systemImage: "plus", isProminent: true) {
                        store.send(.newSessionButtonTapped)
                    }

                    HomeActionButton(systemImage: "gearshape") {
                        store.send(.settingsButtonTapped)
                    }
                }
            }

            Text("Manage your terminal sessions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct HomeActionButton: View {
    let systemImage: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.medium))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background {
            Circle()
                .fill(isProminent ? Color.accentColor : Color.white.opacity(0.1))
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(isProminent ? 0.0 : 0.16), lineWidth: 1)
                }
        }
    }
}

private struct DashboardSummaryView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ConnectionDot(state: connectionState)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(store.committedServerURLString)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()

                AutoReconnectChip(
                    isEnabled: store.status?.enabled ?? false
                ) {
                    store.send(.toggleGlobal(!(store.status?.enabled ?? false)))
                }
            }

            HStack(spacing: 10) {
                SummaryMetricTile(
                    title: "Sessions",
                    value: store.sessionCount,
                    systemImage: "terminal",
                    tint: .blue
                )
                SummaryMetricTile(
                    title: "Needs You",
                    value: store.waitingCount,
                    systemImage: "person.2.fill",
                    tint: .orange
                )
            }

            if let lastUpdated = store.lastUpdated {
                Label("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.62))
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(18)
        .background(HomeGlassCard(cornerRadius: 22))
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

private struct AutoReconnectChip: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isEnabled ? "Auto reconnect" : "Reconnect off", systemImage: isEnabled ? "checkmark.circle" : "pause.circle")
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(isEnabled ? Color.white.opacity(0.88) : Color.white.opacity(0.62))
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .tint(isEnabled ? .green : .orange)
    }
}

private struct SummaryMetricTile: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SessionSearchFilterBar: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.74))

                TextField(text: $store.sessionSearchText) {
                    Text("Search sessions...")
                        .foregroundStyle(.white.opacity(0.42))
                }
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(HomeGlassCard(cornerRadius: 20))

            Menu {
                Picker("Filter", selection: $store.sessionFilter) {
                    ForEach(SessionFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                    Text(store.sessionFilter.label)
                    Image(systemName: "chevron.down")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.56))
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(HomeGlassCard(cornerRadius: 20))
            }
        }
    }
}

private struct HomeEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.45))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(HomeGlassCard(cornerRadius: 18))
    }
}

private struct WorkspaceCardView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SessionStatusIndicators(workspace: workspace)
                    .padding(.top, 9)

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        store.send(.selectWorkspace(workspace.id))
                    } label: {
                        SessionTitleView(workspace: workspace)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                SessionContextMenu(store: store, workspace: workspace)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let branch = workspace.branch?.nonEmptyTrimmed {
                    SessionMetaChip(systemImage: "point.3.connected.trianglepath.dotted", value: branch.abbreviatedPath(componentCount: 2))
                }
                if let cwd = workspace.cwd?.nonEmptyTrimmed {
                    SessionMetaChip(systemImage: "folder", value: cwd.abbreviatedPath(componentCount: 2))
                }
            }

            HStack(spacing: 12) {
                SessionBadge(state: sessionState)
                AutoExpirationText(workspace: workspace)
                Spacer()
            }
        }
        .padding(14)
        .background(HomeGlassCard(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: isExpanded ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            store.send(.selectWorkspace(workspace.id))
        }
    }

    private var sessionState: WorkspaceSessionState {
        workspaceSessionState(for: workspace, entries: store.logEntries)
    }

    private var isExpanded: Bool {
        store.selectedWorkspaceID == workspace.id
    }

    private var cardBorderColor: Color {
        isExpanded ? .accentColor.opacity(0.8) : Color.white.opacity(0.14)
    }
}

private struct SessionStarIndicator: View {
    let isStarred: Bool

    var body: some View {
        if isStarred {
            Image(systemName: "star.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.yellow)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Starred")
        }
    }
}

private struct SessionAutoIndicator: View {
    let isEnabled: Bool

    var body: some View {
        if isEnabled {
            Image(systemName: "bolt.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Auto enabled")
        }
    }
}

private struct SessionStatusIndicators: View {
    let workspace: Workspace

    var body: some View {
        if workspace.starred || workspace.enabled {
            HStack(spacing: 4) {
                SessionStarIndicator(isStarred: workspace.starred)
                SessionAutoIndicator(isEnabled: workspace.enabled)
            }
        }
    }
}

private struct SessionContextMenu: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace

    var body: some View {
        Menu {
            Button {
                store.send(.toggleWorkspace(workspaceID: workspace.id, enabled: !workspace.enabled))
            } label: {
                Label("Auto", systemImage: workspace.enabled ? "checkmark.circle.fill" : "circle")
            }

            Button {
                store.send(.toggleWorkspaceStarred(workspaceID: workspace.id, starred: !workspace.starred))
            } label: {
                Label("Star", systemImage: workspace.starred ? "star.fill" : "star")
            }

            Divider()

            Button {
                store.send(.renameRequested(workspaceID: workspace.id))
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
    }
}

private struct SessionMetaChip: View {
    let systemImage: String
    let value: String

    var body: some View {
        Label(value, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.07), in: Capsule())
    }
}

private struct HomeGlassCard: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
    }
}

private struct WorkspaceDetailView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace
    @FocusState private var isDetailInputFocused: Bool

    var body: some View {
        ZStack {
            SessionDetailBackground()

            VStack(spacing: 0) {
                if !isDetailInputFocused {
                    SessionDetailTabBar(selection: detailTabBinding)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                detailContent
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isDetailInputFocused)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black.opacity(0.92), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    SessionStatusIndicators(workspace: workspace)
                    Text(workspace.displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                SessionContextMenu(store: store, workspace: workspace)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch store.detailTab {
        case .terminal:
            DetailTerminalLayout(
                store: store,
                workspace: workspace,
                terminalText: terminalText,
                sessionState: sessionState,
                showsMetadata: !isDetailInputFocused,
                isDetailInfoExpanded: store.isDetailInfoExpanded,
                isInputFocused: $isDetailInputFocused
            )
        case .git:
            DetailFullHeightLayout {
                GitStatusView(store: store)
            }
        case .activity:
            DetailFullHeightLayout {
                ActivityListView(entries: activityEntries)
            }
        }
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

private struct DetailTerminalLayout: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace
    let terminalText: String
    let sessionState: WorkspaceSessionState
    let showsMetadata: Bool
    let isDetailInfoExpanded: Bool
    let isInputFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 10) {
            if showsMetadata {
                if isDetailInfoExpanded {
                    SessionMetadataCard(
                        workspace: workspace,
                        sessionState: sessionState
                    ) {
                        store.send(.toggleDetailInfo)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    SessionDetailsDisclosureBar(
                        workspace: workspace,
                        sessionState: sessionState
                    ) {
                        store.send(.toggleDetailInfo)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            TerminalScrollView(workspaceID: workspace.id, text: terminalText)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            DetailInputBar(
                store: store,
                workspace: workspace,
                isInputFocused: isInputFocused
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DetailFullHeightLayout<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionDetailBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.01, green: 0.012, blue: 0.016),
                Color(red: 0.035, green: 0.044, blue: 0.06),
                Color.black,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct SessionDetailTabBar: View {
    @Binding var selection: DetailTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 8) {
                        Label(tab.sessionLabel, systemImage: tab.systemImage)
                            .font(.callout.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(selection == tab ? Color.accentColor : Color.white.opacity(0.62))

                        Capsule()
                            .fill(selection == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                }
        }
    }
}

private struct SessionMetadataCard: View {
    let workspace: Workspace
    let sessionState: WorkspaceSessionState
    let detailsAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                SessionInfoItem(
                    title: "Worktree",
                    value: worktreeValue,
                    systemImage: "folder"
                )

                Spacer(minLength: 12)

                Button(action: detailsAction) {
                    Label("Hide", systemImage: "chevron.up.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                }
            }

            HStack(spacing: 12) {
                SessionInfoItem(
                    title: "Branch",
                    value: workspace.branch?.nonEmptyTrimmed ?? "No branch",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )

                Divider()
                    .overlay(Color.white.opacity(0.16))
                    .frame(height: 32)

                SessionInfoItem(
                    title: "Directory",
                    value: directoryValue,
                    systemImage: "folder"
                )
            }

            HStack(spacing: 8) {
                SessionBadge(state: sessionState)
                if let cost = workspace.sessionCost, !cost.isEmpty {
                    Text(cost)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(costColor(cost))
                }
                AutoExpirationText(workspace: workspace)
                Spacer()
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
    }

    private var worktreeValue: String {
        if let cwd = workspace.cwd?.nonEmptyTrimmed {
            return cwd.abbreviatedPath(componentCount: 4)
        }
        return workspace.displayName.abbreviatedPath(componentCount: 4)
    }

    private var directoryValue: String {
        if let cwd = workspace.cwd?.nonEmptyTrimmed {
            return cwd.abbreviatedPath(componentCount: 2)
        }
        return workspace.displayName.abbreviatedPath(componentCount: 2)
    }
}

private struct SessionDetailsDisclosureBar: View {
    let workspace: Workspace
    let sessionState: WorkspaceSessionState
    let detailsAction: () -> Void

    var body: some View {
        Button(action: detailsAction) {
            HStack(spacing: 10) {
                Label("Show details", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Spacer(minLength: 8)

                SessionBadge(state: sessionState)
                AutoExpirationText(workspace: workspace)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.46))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show session details")
    }
}

private struct SessionInfoItem: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.48))
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailInputBar: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace
    let isInputFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Type a message or instruction...", text: $store.detailDraft)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(false)
                    .focused(isInputFocused)
                    .onSubmit {
                        store.send(.sendDetailDraft)
                    }

                Button {
                    store.send(.sendDetailDraft)
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Circle())
            }

            HStack(spacing: 10) {
                ForEach(HarnessKey.allCases) { key in
                    Button {
                        store.send(.sendKey(workspaceID: workspace.id, key))
                    } label: {
                        Label(key.label, systemImage: key.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.92))
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

private struct TerminalScrollView: View {
    let workspaceID: String
    let text: String
    private let bottomID = "terminal-bottom"
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 0
    @State private var scrollRevision = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(TerminalTextStyler.attributedString(for: text, colorScheme: colorScheme))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                    Color.clear
                        .frame(height: 8)
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
            .background(TerminalTextStyler.terminalBackground(for: colorScheme))
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
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle = workspace.cardSubtitle {
                Text(subtitle)
                    .font(.caption.weight(.semibold))
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

private struct SessionBadge: View {
    let state: WorkspaceSessionState

    var body: some View {
        Text(state.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor, in: Capsule())
            .overlay {
                Capsule().strokeBorder(foregroundColor.opacity(0.35), lineWidth: 1)
            }
            .accessibilityLabel(state.label)
    }

    private var foregroundColor: Color {
        switch state {
        case .session:
            return .green
        case .waiting:
            return .orange
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .session:
            return Color.green.opacity(0.14)
        case .waiting:
            return Color.orange.opacity(0.14)
        }
    }
}

private struct AutoExpirationText: View {
    let workspace: Workspace

    var body: some View {
        if let autoExpiresAt = workspace.autoExpiresAt, autoExpiresAt > 0 {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Label(autoExpirationLabel(expiresAt: autoExpiresAt, now: timeline.date), systemImage: "timer")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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

    func abbreviatedPath(componentCount: Int) -> String {
        guard let tail = pathTail(componentCount: componentCount) else { return self }
        return ".../\(tail)"
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

private extension DetailTab {
    var sessionLabel: String {
        switch self {
        case .terminal:
            return "Session"
        case .git:
            return "Git"
        case .activity:
            return "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal:
            return "terminal"
        case .git:
            return "point.3.connected.trianglepath.dotted"
        case .activity:
            return "waveform.path.ecg"
        }
    }
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

private func autoExpirationLabel(expiresAt: Double, now: Date) -> String {
    let remaining = expiresAt - now.timeIntervalSince1970
    if remaining <= 0 {
        return "Auto expired"
    }
    return "Auto \(formatRemainingDuration(remaining))"
}

private func formatRemainingDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(Int(seconds.rounded(.up)), 0)
    if totalSeconds >= 3_600 {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    if totalSeconds >= 60 {
        return "\(max(1, totalSeconds / 60))m"
    }
    return "\(totalSeconds)s"
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
