import AVFoundation
import Combine
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
        .overlay {
            if let quickSessionCreation = store.quickSessionCreation {
                SessionCreationProgressOverlay(creation: quickSessionCreation)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(30)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pushBridge.banner?.id)
        .animation(.easeInOut(duration: 0.18), value: store.quickSessionCreation)
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

private struct SessionCreationProgressOverlay: View {
    let creation: QuickSessionCreation

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.08)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 330)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 14)
            .padding(24)
        }
    }

    private var title: String {
        switch creation.phase {
        case .creating:
            return "Starting New Session"
        case .switching:
            return "Opening New Session"
        }
    }

    private var message: String {
        switch creation.phase {
        case .creating:
            let directory = creation.directoryPath.abbreviatedPath(componentCount: 3)
            return "Creating a shell session in \(directory). We'll switch you over when it's ready."
        case .switching:
            return "The session is ready. Switching you over now."
        }
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

                SessionContextMenu(
                    store: store,
                    workspace: workspace,
                    newSessionAction: {
                        store.send(.newSessionFromWorkspaceTapped(workspaceID: workspace.id))
                    }
                )
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
    var newSessionAction: (() -> Void)? = nil
    var detailsAction: (() -> Void)? = nil

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

            if let detailsAction {
                Button {
                    detailsAction()
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
            }

            Button {
                store.send(.renameRequested(workspaceID: workspace.id))
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            if let newSessionAction {
                Divider()

                Button {
                    newSessionAction()
                } label: {
                    Label("New Session", systemImage: "plus.rectangle")
                }
                .disabled(store.isCreatingSession || store.quickSessionCreation != nil)
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
    @State private var isShowingSessionDetails = false

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
                SessionContextMenu(
                    store: store,
                    workspace: workspace,
                    newSessionAction: {
                        store.send(.newSessionFromWorkspaceTapped(workspaceID: workspace.id))
                    },
                    detailsAction: {
                        isShowingSessionDetails = true
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingSessionDetails) {
            SessionDetailsSheet(
                workspace: workspace,
                sessionState: sessionState,
                dismissAction: {
                    isShowingSessionDetails = false
                }
            )
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
    let isInputFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 10) {
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

private struct SessionDetailsSheet: View {
    let workspace: Workspace
    let sessionState: WorkspaceSessionState
    let dismissAction: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SessionDetailBackground()

                ScrollView {
                    SessionMetadataCard(
                        workspace: workspace,
                        sessionState: sessionState
                    )
                    .padding(16)
                }
            }
            .navigationTitle("Session Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black.opacity(0.92), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismissAction)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SessionMetadataCard: View {
    let workspace: Workspace
    let sessionState: WorkspaceSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            SessionInfoItem(
                title: "Worktree",
                value: worktreeValue,
                systemImage: "folder"
            )

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
    @State private var isShowingVoiceRecorder = false
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

                    inputActionButton(
                        systemImage: "mic.fill",
                        accessibilityLabel: "Record voice note"
                    ) {
                        isShowingVoiceRecorder = true
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
                    .submitLabel(.return)
                    .focused(isInputFocused)
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
        .sheet(isPresented: $isShowingVoiceRecorder) {
            VoiceNoteRecorderSheet(
                saveAction: { url in
                    store.send(.attachmentFilesPicked(workspaceID: workspace.id, [url]))
                    isShowingVoiceRecorder = false
                },
                discardAction: {
                    isShowingVoiceRecorder = false
                }
            )
            .presentationDetents([.height(430), .medium])
            .presentationDragIndicator(.visible)
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
        if ["m4a", "mp3", "wav", "aac", "caf"].contains(ext) {
            return "waveform"
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

private enum VoiceNoteRecorderStatus: Equatable {
    case idle
    case recording
    case finished
}

@MainActor
private final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let maxDuration: TimeInterval = 10 * 60
    private static let waveformSampleCount = 44

    @Published var status: VoiceNoteRecorderStatus = .idle
    @Published var elapsedTime: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var outputURL: URL?
    @Published var levelSamples: [CGFloat] = VoiceNoteRecorder.baselineSamples()
    @Published var isPlaying = false
    @Published var playbackTime: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?

    var isRecording: Bool {
        status == .recording
    }

    var canSave: Bool {
        status == .finished && outputURL != nil && elapsedTime > 0
    }

    var playbackProgress: Double {
        guard elapsedTime > 0 else { return 0 }
        return min(max(playbackTime / elapsedTime, 0), 1)
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            requestPermissionAndStart()
        }
    }

    func togglePlayback() {
        guard status == .finished, let outputURL else { return }
        if isPlaying {
            pausePlayback()
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let player: AVAudioPlayer
            if let existingPlayer = self.player {
                player = existingPlayer
            } else {
                player = try AVAudioPlayer(contentsOf: outputURL)
                player.delegate = self
                player.prepareToPlay()
                self.player = player
            }
            if player.duration > 0, player.currentTime >= player.duration {
                player.currentTime = 0
            }
            playbackTime = player.currentTime
            player.play()
            isPlaying = true
            startPlaybackTimer()
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
            stopPlaybackTimer()
        }
    }

    func discard() {
        cleanup(deleteFile: true)
    }

    func resetAfterSaving() {
        cleanup(deleteFile: false)
    }

    private func cleanup(deleteFile: Bool) {
        stopRecordingTimer()
        stopPlayback(reset: true)
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()
        if deleteFile, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        elapsedTime = 0
        playbackTime = 0
        errorMessage = nil
        levelSamples = Self.baselineSamples()
        status = .idle
    }

    private func requestPermissionAndStart() {
        errorMessage = nil
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecording()
        case .denied:
            errorMessage = "Microphone access is disabled for cmux harness."
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.startRecording()
                    } else {
                        self.errorMessage = "Microphone access is required to record voice notes."
                    }
                }
            }
        @unknown default:
            errorMessage = "Microphone permission is unavailable."
        }
    }

    private func startRecording() {
        do {
            discardCurrentFile()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = Self.makeVoiceNoteURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            recorder.record(forDuration: Self.maxDuration)

            self.recorder = recorder
            outputURL = url
            elapsedTime = 0
            playbackTime = 0
            levelSamples = Self.baselineSamples()
            status = .recording
            startRecordingTimer()
        } catch {
            errorMessage = error.localizedDescription
            cleanup(deleteFile: true)
        }
    }

    private func stopRecording() {
        let finalDuration = recorder?.currentTime ?? elapsedTime
        recorder?.stop()
        recorder = nil
        stopRecordingTimer()
        elapsedTime = min(finalDuration, Self.maxDuration)
        deactivateAudioSession()
        status = outputURL == nil ? .idle : .finished
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordingTimerTick()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let recorder {
            elapsedTime = recorder.currentTime
        }
    }

    private func recordingTimerTick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsedTime = min(recorder.currentTime, Self.maxDuration)
        appendLevelSample(Self.normalizedLevel(fromPower: recorder.averagePower(forChannel: 0)))
        if recorder.currentTime >= Self.maxDuration {
            stopRecording()
        }
    }

    private func appendLevelSample(_ sample: CGFloat) {
        var samples = levelSamples
        samples.append(sample)
        if samples.count > Self.waveformSampleCount {
            samples.removeFirst(samples.count - Self.waveformSampleCount)
        }
        levelSamples = samples
    }

    private func discardCurrentFile() {
        stopRecordingTimer()
        stopPlayback(reset: true)
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        elapsedTime = 0
        playbackTime = 0
        levelSamples = Self.baselineSamples()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func pausePlayback() {
        player?.pause()
        playbackTime = player?.currentTime ?? playbackTime
        isPlaying = false
        stopPlaybackTimer()
    }

    private func stopPlayback(reset: Bool) {
        stopPlaybackTimer()
        player?.stop()
        if reset {
            player?.currentTime = 0
            player = nil
            playbackTime = 0
        } else {
            playbackTime = player?.currentTime ?? playbackTime
        }
        isPlaying = false
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.playbackTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopPlaybackTimer()
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private static func baselineSamples() -> [CGFloat] {
        Array(repeating: 0.08, count: waveformSampleCount)
    }

    private static func normalizedLevel(fromPower power: Float) -> CGFloat {
        let clamped = min(max(power, -50), 0)
        let linear = pow(10, Double(clamped) / 35)
        return CGFloat(min(max(linear, 0.08), 1))
    }

    private static func makeVoiceNoteURL() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "voice-note-\(timestamp)-\(UUID().uuidString.prefix(8)).m4a"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            stopRecordingTimer()
            self.recorder = nil
            elapsedTime = min(Swift.max(elapsedTime, recorder.currentTime), Self.maxDuration)
            deactivateAudioSession()
            status = flag && outputURL != nil ? .finished : .idle
            if !flag {
                errorMessage = "Recording failed."
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stopPlaybackTimer()
            self.player?.currentTime = 0
            playbackTime = 0
            isPlaying = false
            deactivateAudioSession()
        }
    }

    deinit {
        recordingTimer?.invalidate()
        playbackTimer?.invalidate()
        recorder?.stop()
        player?.stop()
    }
}

private struct VoiceNoteRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceNoteRecorder()
    @State private var didSave = false

    let saveAction: (URL) -> Void
    let discardAction: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 4)

                recordingButton

                VoiceWaveformView(
                    samples: recorder.levelSamples,
                    isRecording: recorder.isRecording
                )

                VStack(spacing: 8) {
                    Text(durationText)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text(statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.center)
                }

                if recorder.status == .finished {
                    playbackPreview
                }

                if let errorMessage = recorder.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }

                Spacer(minLength: 4)

                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        HarnessHaptics.inputCTA()
                        discardRecording()
                    } label: {
                        Label("Discard", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        HarnessHaptics.sendCTA()
                        saveRecording()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!recorder.canSave)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .navigationTitle("Voice Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        discardRecording()
                    }
                }
            }
            .onDisappear {
                if !didSave {
                    recorder.discard()
                }
            }
        }
    }

    private var recordingButton: some View {
        Button {
            HarnessHaptics.inputCTA()
            recorder.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 96, height: 96)
                    .shadow(color: (recorder.isRecording ? Color.red : Color.accentColor).opacity(0.35), radius: 18, y: 8)

                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    private var durationText: String {
        formattedDuration(recorder.elapsedTime)
    }

    private var statusText: String {
        switch recorder.status {
        case .idle:
            return "Tap the microphone to start. Limit \(formattedDuration(VoiceNoteRecorder.maxDuration))."
        case .recording:
            return "Recording. Stops at \(formattedDuration(VoiceNoteRecorder.maxDuration))."
        case .finished:
            return "Ready to attach."
        }
    }

    private var statusColor: Color {
        switch recorder.status {
        case .recording:
            return .red
        case .finished:
            return .green
        case .idle:
            return .secondary
        }
    }

    private var playbackPreview: some View {
        HStack(spacing: 12) {
            Button {
                HarnessHaptics.inputCTA()
                recorder.togglePlayback()
            } label: {
                Image(systemName: recorder.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline.weight(.bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Circle())
            .accessibilityLabel(recorder.isPlaying ? "Pause preview" : "Play preview")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(formattedDuration(recorder.playbackTime)) / \(durationText)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: recorder.playbackProgress)
                    .tint(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func saveRecording() {
        guard let url = recorder.outputURL, recorder.canSave else { return }
        didSave = true
        recorder.resetAfterSaving()
        saveAction(url)
        dismiss()
    }

    private func discardRecording() {
        didSave = false
        recorder.discard()
        discardAction()
        dismiss()
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct VoiceWaveformView: View {
    let samples: [CGFloat]
    let isRecording: Bool

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let barWidth = max(2, (geometry.size.width - spacing * CGFloat(max(samples.count - 1, 0))) / CGFloat(max(samples.count, 1)))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor(index: index))
                        .frame(width: barWidth, height: max(4, geometry.size.height * min(max(sample, 0.08), 1)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .animation(.linear(duration: 0.08), value: samples)
    }

    private func barColor(index: Int) -> Color {
        let base = isRecording ? Color.red : Color.accentColor
        guard samples.count > 1 else { return base.opacity(0.62) }
        let recency = Double(index) / Double(samples.count - 1)
        return base.opacity(isRecording ? 0.28 + recency * 0.62 : 0.42)
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
            Section {
                Picker("Git view", selection: gitSegmentBinding) {
                    ForEach(GitDetailSegment.allCases) { segment in
                        Text(segment.label).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch store.gitSegment {
            case .status:
                gitStatusSections
            case .prComments:
                GitPRCommentsSections(store: store)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            switch store.gitSegment {
            case .status:
                store.send(.gitTick)
            case .prComments:
                store.send(.loadPRComments)
            }
        }
    }

    @ViewBuilder
    private var gitStatusSections: some View {
        Group {
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
    }

    private var gitSegmentBinding: Binding<GitDetailSegment> {
        Binding(
            get: { store.gitSegment },
            set: { store.send(.gitSegmentChanged($0)) }
        )
    }
}

private struct GitPRCommentsSections: View {
    @Bindable var store: StoreOf<HarnessFeature>
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle("Show resolved", isOn: includeResolvedBinding)
        } footer: {
            if let response = store.prCommentsResponse, response.hiddenResolvedCount > 0 {
                Text("\(response.hiddenResolvedCount) resolved thread\(response.hiddenResolvedCount == 1 ? "" : "s") hidden")
            }
        }

        if store.isLoadingPRComments && store.prCommentsResponse == nil {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let error = store.prCommentsError {
            ErrorBanner(message: error) {
                store.send(.loadPRComments)
            }
        } else if let response = store.prCommentsResponse {
            if let pr = response.pullRequest {
                Section("Pull Request") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("#\(pr.number) \(pr.title)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if let repo = response.repository {
                            Text("\(repo.owner)/\(repo.name)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let url = URL(string: pr.url) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open PR", systemImage: "link")
                        }
                    }
                }
            }

            if response.files.isEmpty {
                Section {
                    ContentUnavailableView(
                        response.hiddenResolvedCount > 0 ? "Only Resolved Threads" : "No PR Comments",
                        systemImage: "text.bubble",
                        description: Text(response.hiddenResolvedCount > 0 ? "Enable Show resolved to view resolved review threads." : "No code review threads were found for this branch.")
                    )
                }
            } else {
                ForEach(response.files) { fileGroup in
                    Section(fileGroup.path) {
                        ForEach(fileGroup.threads) { thread in
                            GitPRThreadRow(
                                thread: thread,
                                copyAction: {
                                    UIPasteboard.general.string = thread.promptReference(pullRequest: response.pullRequest)
                                },
                                openAction: {
                                    if let url = URL(string: thread.url) {
                                        openURL(url)
                                    }
                                },
                                insertAction: {
                                    store.send(.appendPRCommentThread(thread))
                                },
                                requestFixAction: {
                                    store.send(.requestFixForPRCommentThread(thread))
                                }
                            )
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No PR Data", systemImage: "text.bubble")
        }
    }

    private var includeResolvedBinding: Binding<Bool> {
        Binding(
            get: { store.includeResolvedPRComments },
            set: { store.send(.setPRCommentsIncludeResolved($0)) }
        )
    }
}

private struct GitPRThreadRow: View {
    let thread: GitHubPRThread
    let copyAction: () -> Void
    let openAction: () -> Void
    let insertAction: () -> Void
    let requestFixAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Label(thread.lineLabel, systemImage: "number")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                if thread.isResolved {
                    GitPRThreadPill(text: "Resolved", systemImage: "checkmark.circle")
                }
                if thread.isOutdated {
                    GitPRThreadPill(text: "Outdated", systemImage: "clock")
                }

                Spacer(minLength: 8)

                Button(action: insertAction) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .accessibilityLabel("Insert PR comment thread")

                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                        .font(.headline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Copy PR comment thread")

                if !thread.url.isEmpty {
                    Button(action: openAction) {
                        Image(systemName: "link")
                            .font(.headline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Open PR comment thread")
                }
            }

            if let codeContext = thread.codeContext, !codeContext.lines.isEmpty {
                GitPRCodeContextView(context: codeContext)
            }

            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(comment.author.isEmpty ? "unknown" : comment.author)
                            .font(.caption.weight(.bold))
                        if !comment.createdAt.isEmpty {
                            Text(comment.createdAt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(comment.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Button(action: requestFixAction) {
                Label("Request fix", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Request fix for PR comment thread")
        }
        .padding(.vertical, 5)
    }
}

private struct GitPRCodeContextView: View {
    let context: GitHubPRCodeContext

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(context.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(line.number)")
                            .foregroundStyle(line.isTarget ? Color.accentColor : Color.secondary)
                            .frame(width: 42, alignment: .trailing)

                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 12, weight: line.isTarget ? .semibold : .regular, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        line.isTarget ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                }
            }
            .padding(8)
        }
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct GitPRThreadPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
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
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            TextField("Jira key or URL", text: jiraLookupBinding)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .onSubmit {
                                    resolveLookup()
                                }

                            Button {
                                resolveLookup()
                            } label: {
                                if store.isResolvingJiraTicket {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 34, height: 34)
                                } else {
                                    Image(systemName: "magnifyingglass")
                                        .font(.headline.weight(.semibold))
                                        .frame(width: 34, height: 34)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canResolveLookup)
                            .accessibilityLabel("Look up Jira ticket")
                        }

                        if let error = store.jiraLookupError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Exact Lookup")
                } footer: {
                    Text("Paste a Jira key or browse URL from any project.")
                }

                if let ticket = store.resolvedJiraTicket {
                    Section("Lookup Result") {
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

                assignedTicketsContent
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

    @ViewBuilder
    private var assignedTicketsContent: some View {
        if store.isLoadingJiraTickets && store.jiraTickets.isEmpty {
            Section("Assigned") {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else if let error = store.jiraTicketsError {
            Section("Assigned") {
                ErrorBanner(message: error) {
                    store.send(.loadAssignedJiraTickets)
                }
            }
        } else if store.jiraTickets.isEmpty {
            Section("Assigned") {
                ContentUnavailableView("No Assigned Tickets", systemImage: "ticket")
            }
        } else {
            ForEach(groupedAssignedTickets, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.tickets) { ticket in
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
        }
    }

    private var jiraLookupBinding: Binding<String> {
        Binding(
            get: { store.jiraLookupQuery },
            set: { store.send(.jiraLookupQueryChanged($0)) }
        )
    }

    private var canResolveLookup: Bool {
        !store.jiraLookupQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isResolvingJiraTicket
    }

    private var groupedAssignedTickets: [(project: String, tickets: [JiraTicket])] {
        let groups = Dictionary(grouping: store.jiraTickets) { ticket in
            projectKey(for: ticket)
        }
        return groups
            .map { project, tickets in
                (
                    project: project,
                    tickets: tickets.sorted { lhs, rhs in
                        lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                lhs.project.localizedCaseInsensitiveCompare(rhs.project) == .orderedAscending
            }
    }

    private func resolveLookup() {
        guard canResolveLookup else { return }
        store.send(.resolveJiraTicket)
    }

    private func projectKey(for ticket: JiraTicket) -> String {
        if let projectKey = ticket.projectKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectKey.isEmpty {
            return projectKey
        }
        return ticket.key.split(separator: "-", maxSplits: 1).first.map(String.init) ?? "Other"
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
                    Image(systemName: "text.badge.plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .accessibilityLabel("Insert Jira ticket context")
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
    @State private var selectedLine: ParsedDiffLine?

    var body: some View {
        NavigationStack {
            Group {
                if diffSheet.isLoading {
                    ProgressView()
                } else if let error = diffSheet.error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else {
                    GeometryReader { proxy in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(parseUnifiedDiffLines(diffSheet.diff)) { line in
                                    DiffLineRow(line: line) {
                                        selectedLine = line
                                    }
                                }
                            }
                            .frame(minWidth: proxy.size.width, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .background(Color(.systemBackground))
                    }
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
        .sheet(item: $selectedLine) { line in
            DiffLineCommentSheet(
                file: diffSheet.file,
                line: line,
                submitAction: { reviewComment in
                    selectedLine = nil
                    store.send(.appendDiffLineReviewComment(reviewComment))
                }
            )
            .presentationDetents([.height(360), .medium])
            .presentationDragIndicator(.visible)
        }
    }
}

private enum ParsedDiffLineKind: Equatable {
    case metadata
    case hunk
    case context
    case addition
    case deletion
}

private struct ParsedDiffLine: Equatable, Identifiable {
    var id: Int
    var raw: String
    var kind: ParsedDiffLineKind
    var oldLineNumber: Int?
    var newLineNumber: Int?

    var isCommentable: Bool {
        switch kind {
        case .addition, .deletion, .context:
            return true
        case .metadata, .hunk:
            return false
        }
    }

    var marker: String {
        switch kind {
        case .addition:
            return "+"
        case .deletion:
            return "-"
        case .context:
            return " "
        case .hunk, .metadata:
            return ""
        }
    }

    var code: String {
        guard isCommentable, !raw.isEmpty else { return raw }
        return String(raw.dropFirst())
    }

    var displayText: String {
        isCommentable ? code : raw
    }

    var reviewLineNumber: Int? {
        switch kind {
        case .deletion:
            return oldLineNumber
        case .addition, .context:
            return newLineNumber ?? oldLineNumber
        case .metadata, .hunk:
            return nil
        }
    }

    var reviewSide: DiffLineCommentSide {
        switch kind {
        case .deletion:
            return .old
        case .addition:
            return .new
        case .context:
            return .context
        case .metadata, .hunk:
            return .context
        }
    }

    func reviewComment(file: String, comment: String) -> DiffLineReviewComment {
        DiffLineReviewComment(
            file: file,
            lineNumber: reviewLineNumber,
            side: reviewSide,
            code: code,
            comment: comment
        )
    }
}

private struct DiffLineRow: View {
    let line: ParsedDiffLine
    let commentAction: () -> Void

    var body: some View {
        Group {
            if line.isCommentable {
                Button(action: commentAction) {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(gutterColor)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)

            Text(line.newLineNumber.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(gutterColor)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)

            Text(line.marker)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(diffColor(for: line.raw))
                .frame(width: 18, alignment: .center)

            Text(line.displayText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(diffColor(for: line.raw))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 6)
                .padding(.trailing, 12)

            if line.isCommentable {
                Image(systemName: "text.bubble")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.secondary.opacity(0.62))
                    .padding(.horizontal, 10)
            }
        }
        .frame(minHeight: line.kind == .hunk ? 32 : 28, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if line.kind == .hunk {
            return Color.blue.opacity(0.10)
        }
        return diffBackground(for: line.raw)
    }

    private var gutterColor: Color {
        line.isCommentable ? .secondary : .secondary.opacity(0.5)
    }

    private var accessibilityLabel: String {
        let lineNumber = line.reviewLineNumber.map(String.init) ?? "unknown"
        return "Add review comment on line \(lineNumber)"
    }
}

private struct DiffLineCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isCommentFocused: Bool
    @State private var comment = ""

    let file: String
    let line: ParsedDiffLine
    let submitAction: (DiffLineReviewComment) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                selectedLinePreview

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $comment)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 130)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
                        }
                        .focused($isCommentFocused)

                    if comment.isEmpty {
                        Text("Comment")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    submit()
                } label: {
                    Label("Insert Comment", systemImage: "text.bubble.fill")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedComment.isEmpty)
            }
            .padding(18)
            .navigationTitle("Review Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await Task.yield()
                isCommentFocused = true
            }
        }
    }

    private var selectedLinePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(file, systemImage: "doc.text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(lineLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                Text(line.marker.isEmpty ? " " : line.marker)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(diffColor(for: line.raw))
                    .frame(width: 14)

                Text(line.code.isEmpty ? "(blank line)" : line.code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(diffBackground(for: line.raw).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
        }
    }

    private var lineLabel: String {
        guard let lineNumber = line.reviewLineNumber else { return line.reviewSide.promptLabel }
        return "\(lineNumber) \(line.reviewSide.promptLabel)"
    }

    private var trimmedComment: String {
        comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedComment.isEmpty else { return }
        submitAction(line.reviewComment(file: file, comment: trimmedComment))
        dismiss()
    }
}

private func parseUnifiedDiffLines(_ diff: String) -> [ParsedDiffLine] {
    var oldLineNumber: Int?
    var newLineNumber: Int?

    return diff.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
        .map { offset, rawSubstring in
            let raw = String(rawSubstring)

            if let hunkStart = parseHunkStart(from: raw) {
                oldLineNumber = hunkStart.old
                newLineNumber = hunkStart.new
                return ParsedDiffLine(
                    id: offset,
                    raw: raw,
                    kind: .hunk,
                    oldLineNumber: nil,
                    newLineNumber: nil
                )
            }

            if raw.hasPrefix("+"), !raw.hasPrefix("+++") {
                defer { newLineNumber = newLineNumber.map { $0 + 1 } }
                return ParsedDiffLine(
                    id: offset,
                    raw: raw,
                    kind: .addition,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber
                )
            }

            if raw.hasPrefix("-"), !raw.hasPrefix("---") {
                defer { oldLineNumber = oldLineNumber.map { $0 + 1 } }
                return ParsedDiffLine(
                    id: offset,
                    raw: raw,
                    kind: .deletion,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil
                )
            }

            if raw.hasPrefix(" ") {
                defer {
                    oldLineNumber = oldLineNumber.map { $0 + 1 }
                    newLineNumber = newLineNumber.map { $0 + 1 }
                }
                return ParsedDiffLine(
                    id: offset,
                    raw: raw,
                    kind: .context,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber
                )
            }

            return ParsedDiffLine(
                id: offset,
                raw: raw,
                kind: .metadata,
                oldLineNumber: nil,
                newLineNumber: nil
            )
        }
}

private func parseHunkStart(from line: String) -> (old: Int, new: Int)? {
    guard line.hasPrefix("@@") else { return nil }
    let parts = line.split(separator: " ")
    guard let oldPart = parts.first(where: { $0.hasPrefix("-") }),
          let newPart = parts.first(where: { $0.hasPrefix("+") }),
          let oldStart = parseHunkLineStart(oldPart),
          let newStart = parseHunkLineStart(newPart) else {
        return nil
    }
    return (oldStart, newStart)
}

private func parseHunkLineStart(_ part: Substring) -> Int? {
    let value = part.dropFirst()
    let lineStart = value.split(separator: ",", maxSplits: 1).first ?? value
    return Int(lineStart)
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
