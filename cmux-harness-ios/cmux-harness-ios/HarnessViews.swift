import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HarnessRootView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    @EnvironmentObject private var pushBridge: PushNotificationBridge

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
        .overlay(alignment: .top) {
            if let banner = pushBridge.banner {
                PushApprovalBanner(
                    notification: banner,
                    openAction: {
                        openPushApproval(banner)
                    },
                    dismissAction: {
                        pushBridge.dismissBanner()
                    }
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pushBridge.banner?.id)
        .sheet(isPresented: $store.isShowingSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $store.isShowingNewSession) {
            NewSessionView(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.isShowingFileSearch },
                set: { isPresented in
                    if !isPresented {
                        store.send(.dismissFileSearch)
                    }
                }
            )
        ) {
            FileSearchView(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.isShowingJiraTickets },
                set: { isPresented in
                    if !isPresented {
                        store.send(.dismissJiraTickets)
                    }
                }
            )
        ) {
            JiraTicketsView(store: store)
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
        .onChange(of: pushBridge.pendingDeepLink) { _, notification in
            guard let notification else { return }
            openPushApproval(notification)
            pushBridge.pendingDeepLink = nil
        }
    }

    private func openPushApproval(_ notification: PushApprovalNotification) {
        store.send(.openPushApproval(notification))
        pushBridge.dismissBanner()
        PushNotificationBridge.clearApplicationBadge()
    }
}

private struct PushApprovalBanner: View {
    let notification: PushApprovalNotification
    let openAction: () -> Void
    let dismissAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: openAction) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(notification.workspaceName.isEmpty ? "Approval needed" : notification.workspaceName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(notification.request.isEmpty ? notification.reason : notification.request)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(3)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: dismissAction) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss approval notification")
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 10)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ConnectionDot(state: connectionState)

                Text(connectionTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)

                Spacer()

                if !store.isConnected {
                    AutoReconnectChip(
                        isEnabled: store.status?.enabled ?? false
                    ) {
                        store.send(.toggleGlobal(!(store.status?.enabled ?? false)))
                    }
                }
            }

            if let lastUpdated = store.lastUpdated {
                Label("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(16)
        .background(HomeGlassCard(cornerRadius: 18))
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
    let mode: WorkspaceAutoMode

    var body: some View {
        if mode.isEnabled {
            WorkspaceAutoModeIcon(mode: mode)
                .font(.caption.weight(.bold))
                .foregroundStyle(mode == .superAuto ? Color.orange : Color.accentColor)
                .frame(width: mode == .superAuto ? 26 : 18, height: 18)
                .accessibilityLabel(mode.accessibilityLabel)
        }
    }
}

private struct WorkspaceAutoModeIcon: View {
    let mode: WorkspaceAutoMode

    @ViewBuilder
    var body: some View {
        switch mode {
        case .off:
            Image(systemName: "circle")
        case .auto:
            Image(systemName: "bolt.fill")
        case .superAuto:
            HStack(spacing: 1) {
                Image(systemName: "bolt.fill")
                Image(systemName: "bolt.fill")
            }
        }
    }
}

private struct SessionStatusIndicators: View {
    let workspace: Workspace

    var body: some View {
        let autoMode = workspace.resolvedAutoMode
        if workspace.starred || autoMode.isEnabled {
            HStack(spacing: 4) {
                SessionStarIndicator(isStarred: workspace.starred)
                SessionAutoIndicator(mode: autoMode)
            }
        }
    }
}

private struct SessionContextMenu: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace

    var body: some View {
        Menu {
            Section("Auto Mode") {
                ForEach(WorkspaceAutoMode.allCases) { mode in
                    Button {
                        store.send(.setWorkspaceAutoMode(workspaceID: workspace.id, mode: mode))
                    } label: {
                        HStack(spacing: 8) {
                            WorkspaceAutoModeIcon(mode: mode)
                                .frame(width: 24)
                            Text(mode.menuLabel)
                            if workspace.resolvedAutoMode == mode {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
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
        case .skills:
            DetailFullHeightLayout {
                SkillsListView(store: store)
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
                    .simultaneousGesture(TapGesture().onEnded { _ in dismissKeyboard() })
                } else {
                    SessionDetailsDisclosureBar(
                        workspace: workspace,
                        sessionState: sessionState
                    ) {
                        store.send(.toggleDetailInfo)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .simultaneousGesture(TapGesture().onEnded { _ in dismissKeyboard() })
                }
            }

            TerminalScrollView(workspaceID: workspace.id, text: terminalText)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .simultaneousGesture(TapGesture().onEnded { _ in dismissKeyboard() })

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
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: dismissKeyboard)
        }
    }

    private func dismissKeyboard() {
        isInputFocused.wrappedValue = false
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
                    VStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.title3.weight(.semibold))

                        Text(tab.sessionLabel)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Capsule()
                            .fill(selection == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2.5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.white.opacity(0.62))
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

private enum HarnessHaptics {
    static func inputCTA() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
    }

    static func sendCTA() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
    }
}

private struct DetailInputBar: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace
    let isInputFocused: FocusState<Bool>.Binding
    @State private var inputSelection: TextSelection?
    @State private var dismissedSkillAutocompleteSignature: String?
    @State private var isActionMenuExpanded = false
    @State private var isShowingAttachmentOptions = false
    @State private var isShowingPhotoPicker = false
    @State private var isShowingFileImporter = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 10) {
            if let context = skillAutocompleteContext,
               dismissedSkillAutocompleteSignature != context.signature,
               !filteredSkillSuggestions(for: context).isEmpty {
                SkillAutocompletePanel(
                    suggestions: filteredSkillSuggestions(for: context),
                    cancelAction: {
                        dismissedSkillAutocompleteSignature = context.signature
                    },
                    selectAction: { skill in
                        replaceSkillToken(context, with: skill)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !attachments.isEmpty {
                AttachmentTray(
                    attachments: attachments,
                    removeAction: { attachment in
                        store.send(.removeAttachment(workspaceID: workspace.id, attachmentID: attachment.id))
                    },
                    retryAction: { attachment in
                        store.send(.retryAttachment(workspaceID: workspace.id, attachmentID: attachment.id))
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isActionMenuExpanded {
                HStack(spacing: 10) {
                    inputActionButton(
                        systemImage: "paperclip",
                        accessibilityLabel: "Attach file"
                    ) {
                        isShowingAttachmentOptions = true
                    }

                    Button {
                        HarnessHaptics.inputCTA()
                        store.send(.fileSearchTapped)
                    } label: {
                        Text("@")
                            .font(.headline.monospaced().weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.92))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
                    .accessibilityLabel("Add file path")

                    inputActionButton(
                        systemImage: "ticket",
                        accessibilityLabel: "Add Jira ticket"
                    ) {
                        store.send(.jiraTicketsTapped)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    HarnessHaptics.inputCTA()
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        isActionMenuExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(isActionMenuExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.92))
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
                .accessibilityLabel(isActionMenuExpanded ? "Hide input actions" : "Show input actions")

                TextField(
                    "Type a message or instruction...",
                    text: $store.detailDraft,
                    selection: $inputSelection,
                    axis: .vertical
                )
                    .font(.subheadline)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    }
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .submitLabel(.send)
                    .focused(isInputFocused)
                    .onSubmit {
                        sendDetailDraftWithHaptic()
                    }
                    .onChange(of: store.detailDraft) {
                        dismissedSkillAutocompleteSignature = nil
                        loadSkillsIfNeededForAutocomplete()
                    }
                    .onChange(of: inputSelection) {
                        loadSkillsIfNeededForAutocomplete()
                    }

                Button {
                    sendDetailDraftWithHaptic()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? .white : .white.opacity(0.46))
                .background(canSend ? Color.accentColor : Color.white.opacity(0.10), in: Circle())
                .disabled(!canSend)
            }

            HStack(spacing: 10) {
                ForEach(HarnessKey.allCases) { key in
                    Button {
                        HarnessHaptics.inputCTA()
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
        .animation(.easeInOut(duration: 0.16), value: skillAutocompleteContext?.signature)
        .animation(.easeInOut(duration: 0.16), value: attachments)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isActionMenuExpanded)
        .confirmationDialog("Attach", isPresented: $isShowingAttachmentOptions) {
            Button {
                HarnessHaptics.inputCTA()
                isShowingAttachmentOptions = false
                Task {
                    await Task.yield()
                    isShowingPhotoPicker = true
                }
            } label: {
                Label("Photo Library", systemImage: "photo")
            }
            Button {
                HarnessHaptics.inputCTA()
                isShowingAttachmentOptions = false
                Task {
                    await Task.yield()
                    isShowingFileImporter = true
                }
            } label: {
                Label("Files", systemImage: "folder")
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                store.send(.attachmentFilesPicked(workspaceID: workspace.id, urls))
            case let .failure(error):
                store.send(.attachmentPickerFailed(error.localizedDescription))
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await importPhotoItems(items)
                selectedPhotoItems = []
            }
        }
        .task(id: store.detailInputFocusRequest) {
            let request = store.detailInputFocusRequest
            guard request > 0 else { return }
            await focusInputAtEnd()
            guard !Task.isCancelled else { return }
            store.send(.detailInputFocusHandled(request))
        }
    }

    private var attachments: [TerminalAttachment] {
        store.terminalAttachments[workspace.id] ?? []
    }

    private var isUploadingAttachment: Bool {
        attachments.contains { $0.status == .uploading }
    }

    private var canSend: Bool {
        guard !isUploadingAttachment else { return false }
        let hasMessage = !store.detailDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUploadedAttachment = attachments.contains { $0.status == .uploaded && $0.uploadedPath != nil }
        return hasMessage || hasUploadedAttachment
    }

    private func sendDetailDraftWithHaptic() {
        guard canSend else { return }
        HarnessHaptics.sendCTA()
        store.send(.sendDetailDraft)
    }

    private func inputActionButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HarnessHaptics.inputCTA()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.92))
        .background(.ultraThinMaterial, in: Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @MainActor
    private func importPhotoItems(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    continue
                }
                if Int64(data.count) > HarnessAPI.attachmentMaxBytes {
                    store.send(.attachmentPickerFailed("File exceeds 20 MB limit"))
                    continue
                }
                let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                let fileExtension = contentType?.preferredFilenameExtension ?? "jpg"
                let filename = "photo-\(UUID().uuidString).\(fileExtension)"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try data.write(to: url, options: .atomic)
                urls.append(url)
            } catch {
                store.send(.attachmentPickerFailed(error.localizedDescription))
            }
        }
        if !urls.isEmpty {
            store.send(.attachmentFilesPicked(workspaceID: workspace.id, urls))
        }
    }

    @MainActor
    private func focusInputAtEnd() async {
        await Task.yield()
        isInputFocused.wrappedValue = true
        inputSelection = TextSelection(insertionPoint: store.detailDraft.endIndex)

        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else { return }
        isInputFocused.wrappedValue = true
        inputSelection = TextSelection(insertionPoint: store.detailDraft.endIndex)
    }

    private var skillAutocompleteContext: SkillAutocompleteContext? {
        SkillAutocompleteContext(draft: store.detailDraft, selection: inputSelection)
    }

    private var allSkills: [ProjectSkill] {
        store.projectSkills + store.userSkills
    }

    private func filteredSkillSuggestions(for context: SkillAutocompleteContext) -> [ProjectSkill] {
        allSkills
            .filter { skill in
                context.query.isEmpty || skill.name.localizedCaseInsensitiveContains(context.query)
            }
            .prefix(3)
            .map { $0 }
    }

    private func loadSkillsIfNeededForAutocomplete() {
        guard skillAutocompleteContext != nil,
              !store.hasSkills,
              !store.isLoadingSkills else {
            return
        }
        store.send(.loadSkills)
    }

    private func replaceSkillToken(_ context: SkillAutocompleteContext, with skill: ProjectSkill) {
        let replacement = "/\(skill.name)"
        var draft = store.detailDraft
        let cursorOffset = draft.distance(from: draft.startIndex, to: context.range.lowerBound) + replacement.count
        draft.replaceSubrange(context.range, with: replacement)
        store.detailDraft = draft
        dismissedSkillAutocompleteSignature = nil

        let cursorIndex = draft.index(draft.startIndex, offsetBy: cursorOffset)
        inputSelection = TextSelection(insertionPoint: cursorIndex)
        isInputFocused.wrappedValue = true
    }
}

private struct SkillAutocompleteContext: Equatable {
    let range: Range<String.Index>
    let query: String
    let signature: String

    init?(draft: String, selection: TextSelection?) {
        guard !draft.isEmpty else { return nil }
        let cursor = draft.insertionIndex(from: selection)
        guard cursor > draft.startIndex else { return nil }

        let prefix = draft[..<cursor]
        let tokenStart = prefix.lastIndex(where: { $0.isWhitespace }).map { draft.index(after: $0) } ?? draft.startIndex
        guard tokenStart < cursor, draft[tokenStart] == "/" else { return nil }

        let token = draft[tokenStart..<cursor]
        guard !token.contains(where: { $0.isWhitespace }) else { return nil }

        range = tokenStart..<cursor
        query = String(token.dropFirst())
        let startOffset = draft.distance(from: draft.startIndex, to: tokenStart)
        signature = "\(startOffset):\(String(token))"
    }
}

private struct AttachmentTray: View {
    let attachments: [TerminalAttachment]
    let removeAction: (TerminalAttachment) -> Void
    let retryAction: (TerminalAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        attachment: attachment,
                        removeAction: {
                            removeAction(attachment)
                        },
                        retryAction: {
                            retryAction(attachment)
                        }
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct AttachmentChip: View {
    let attachment: TerminalAttachment
    let removeAction: () -> Void
    let retryAction: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)

                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            if attachment.status == .uploading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.82))
            } else if attachment.status == .failed {
                Button {
                    HarnessHaptics.inputCTA()
                    retryAction()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Retry attachment upload")
            }

            Button {
                HarnessHaptics.inputCTA()
                removeAction()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.62))
            .accessibilityLabel("Remove attachment")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(height: 52)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
    }

    private var systemImage: String {
        let ext = attachment.displayName.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext) {
            return "photo"
        }
        if ext == "pdf" {
            return "doc.richtext"
        }
        if ["zip", "gz", "tar"].contains(ext) {
            return "archivebox"
        }
        return "doc"
    }

    private var statusText: String {
        switch attachment.status {
        case .uploading:
            return "Uploading"
        case .uploaded:
            return "Added"
        case .failed:
            return attachment.error ?? "Upload failed"
        }
    }

    private var iconColor: Color {
        switch attachment.status {
        case .failed:
            return .red.opacity(0.86)
        case .uploaded:
            return .green.opacity(0.88)
        case .uploading:
            return Color.accentColor
        }
    }

    private var statusColor: Color {
        switch attachment.status {
        case .failed:
            return .red.opacity(0.82)
        case .uploaded:
            return .green.opacity(0.78)
        case .uploading:
            return .white.opacity(0.52)
        }
    }

    private var borderColor: Color {
        switch attachment.status {
        case .failed:
            return .red.opacity(0.35)
        case .uploaded:
            return .green.opacity(0.30)
        case .uploading:
            return .white.opacity(0.16)
        }
    }
}

private struct SkillAutocompletePanel: View {
    let suggestions: [ProjectSkill]
    let cancelAction: () -> Void
    let selectAction: (ProjectSkill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Skills")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.64))
                Spacer()
                Button {
                    HarnessHaptics.inputCTA()
                    cancelAction()
                } label: {
                    Text("Cancel")
                }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }

            ForEach(suggestions) { skill in
                Button {
                    HarnessHaptics.inputCTA()
                    selectAction(skill)
                } label: {
                    HStack(spacing: 10) {
                        Text("/\(skill.name)")
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(skill.scope == "user" ? "User" : "Project")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
    }
}

private extension String {
    func insertionIndex(from selection: TextSelection?) -> String.Index {
        guard let selection else { return endIndex }

        let proposedIndex: String.Index?
        switch selection.indices {
        case let .selection(range):
            proposedIndex = range.upperBound
        case let .multiSelection(ranges):
            proposedIndex = ranges.ranges.last?.upperBound
        @unknown default:
            proposedIndex = nil
        }

        guard let proposedIndex,
              proposedIndex == endIndex || indices.contains(proposedIndex) else {
            return endIndex
        }
        return proposedIndex
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

private struct SkillsListView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        List {
            if store.isLoadingSkills && !store.hasSkills {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = store.skillsError {
                ErrorBanner(message: error) {
                    store.send(.loadSkills)
                }
            } else if !store.hasSkills {
                ContentUnavailableView("No Skills", systemImage: "wand.and.stars")
            } else {
                if !store.projectSkills.isEmpty {
                    Section("Project Skills") {
                        ForEach(store.projectSkills) { skill in
                            SkillMenuRow(store: store, skill: skill)
                        }
                    }
                }

                if !store.userSkills.isEmpty {
                    Section("User Skills") {
                        ForEach(store.userSkills) { skill in
                            SkillMenuRow(store: store, skill: skill)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            store.send(.loadSkills)
        }
    }
}

private struct SkillMenuRow: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let skill: ProjectSkill

    var body: some View {
        Menu {
            Button {
                store.send(.appendSkillInvocation(skill))
            } label: {
                Label("Claude Code", systemImage: "terminal")
            }

            Button {
                store.send(.appendSkillFilePath(skill))
            } label: {
                Label("File Path", systemImage: "doc.text")
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(skill.skillFilePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "plus.circle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.gray)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FileSearchView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search project files", text: fileSearchBinding)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                }

                if store.fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
                    ContentUnavailableView("Search Files", systemImage: "at")
                } else if store.isSearchingFiles && store.fileSearchResults.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let error = store.fileSearchError {
                    ErrorBanner(message: error) {
                        store.send(.fileSearchQueryChanged(store.fileSearchQuery))
                    }
                } else if store.fileSearchResults.isEmpty {
                    ContentUnavailableView("No Matches", systemImage: "doc.text.magnifyingglass")
                } else {
                    ForEach(store.fileSearchResults) { file in
                        Button {
                            store.send(.appendFilePath(file))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                Text(file.path)
                                    .font(.callout.monospaced())
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.send(.dismissFileSearch)
                    }
                }
            }
            .onAppear {
                isSearchFocused = true
            }
        }
    }

    private var fileSearchBinding: Binding<String> {
        Binding(
            get: { store.fileSearchQuery },
            set: { store.send(.fileSearchQueryChanged($0)) }
        )
    }
}

private struct JiraTicketsView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    @Environment(\.openURL) private var openURL
    @State private var copiedTicketKey: String?
    @State private var copiedToastID = UUID()

    var body: some View {
        NavigationStack {
            List {
                if store.isLoadingJiraTickets && store.jiraTickets.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let error = store.jiraTicketsError {
                    ErrorBanner(message: error) {
                        store.send(.loadAssignedJiraTickets)
                    }
                } else if store.jiraTickets.isEmpty {
                    ContentUnavailableView("No Jira Tickets", systemImage: "ticket")
                } else {
                    ForEach(store.jiraTickets) { ticket in
                        JiraTicketRow(
                            ticket: ticket,
                            copyKeyAction: {
                                copyTicketKey(ticket.key)
                            },
                            openLinkAction: {
                                openJiraTicket(ticket)
                            },
                            insertAction: {
                                store.send(.appendJiraTicketReference(ticket))
                            }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Jira")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) {
                if let copiedTicketKey {
                    JiraCopyToast(ticketKey: copiedTicketKey)
                        .padding(.top, 8)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.send(.loadAssignedJiraTickets)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoadingJiraTickets)
                    .accessibilityLabel("Refresh Jira tickets")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.send(.dismissJiraTickets)
                    }
                }
            }
            .task {
                if store.jiraTickets.isEmpty && !store.isLoadingJiraTickets {
                    store.send(.loadAssignedJiraTickets)
                }
            }
        }
    }

    private func copyTicketKey(_ key: String) {
        let toastID = UUID()
        UIPasteboard.general.string = key
        copiedToastID = toastID
        withAnimation(.easeInOut(duration: 0.18)) {
            copiedTicketKey = key
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard copiedToastID == toastID else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                copiedTicketKey = nil
            }
        }
    }

    private func openJiraTicket(_ ticket: JiraTicket) {
        guard let url = URL(string: ticket.url) else { return }
        openURL(url)
    }
}

private struct JiraTicketRow: View {
    let ticket: JiraTicket
    let copyKeyAction: () -> Void
    let openLinkAction: () -> Void
    let insertAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: copyKeyAction) {
                    Text(ticket.key)
                        .font(.callout.monospaced().weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .textSelection(.disabled)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(ticket.key)")

                Text(ticket.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                VStack(alignment: .leading, spacing: 6) {
                    JiraTicketPill(text: ticket.status, systemImage: "circle.dotted")
                    if !ticket.priority.isEmpty {
                        JiraTicketPill(text: ticket.priority, systemImage: "flag")
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 12) {
                Button(action: openLinkAction) {
                    Image(systemName: "link")
                        .font(.headline.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Open Jira ticket")

                Button(action: insertAction) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .accessibilityLabel("Insert Jira ticket link")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct JiraTicketPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text.isEmpty ? "Unknown" : text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct JiraCopyToast: View {
    let ticketKey: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Copied \(ticketKey)")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
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
                Label(
                    autoExpirationLabel(
                        expiresAt: autoExpiresAt,
                        now: timeline.date,
                        mode: workspace.resolvedAutoMode
                    ),
                    systemImage: "timer"
                )
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
        case .skills:
            return "Skills"
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
        case .skills:
            return "wand.and.stars"
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

private func autoExpirationLabel(expiresAt: Double, now: Date, mode: WorkspaceAutoMode) -> String {
    let remaining = expiresAt - now.timeIntervalSince1970
    if remaining <= 0 {
        return "\(mode.label) expired"
    }
    return "\(mode.label) \(formatRemainingDuration(remaining))"
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
