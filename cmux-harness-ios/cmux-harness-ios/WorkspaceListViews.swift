import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WorkspaceListView: View {
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

struct HomeBackground: View {
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

struct HomeHeaderView: View {
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

struct HomeActionButton: View {
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

struct DashboardSummaryView: View {
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

struct AutoReconnectChip: View {
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

struct SessionSearchFilterBar: View {
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

struct HomeEmptyState: View {
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

struct WorkspaceCardView: View {
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

struct SessionStarIndicator: View {
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

struct SessionAutoIndicator: View {
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

struct WorkspaceAutoModeIcon: View {
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

struct SessionStatusIndicators: View {
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

struct SessionContextMenu: View {
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

struct SessionMetaChip: View {
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

struct HomeGlassCard: View {
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
