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
                    Text("\(store.visibleWorkspaceGroups.count) \(store.visibleWorkspaceGroups.count == 1 ? "session" : "sessions")")
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
                } else if store.visibleWorkspaceGroups.isEmpty {
                    HomeEmptyState(
                        title: "No Matches",
                        message: "Adjust search or filter.",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 24, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.visibleWorkspaceGroups) { group in
                        WorkspaceCardView(store: store, group: group)
                            .tag(group.preferredWorkspaceID(selectedWorkspaceID: store.selectedWorkspaceID))
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

            if !store.isDemoMode && !store.serverSources.isEmpty {
                HomeServerSourceMenu(store: store)
                    .padding(.top, 8)
            }
        }
    }
}

struct HomeServerSourceMenu: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        Menu {
            ForEach(store.serverSources) { source in
                Button {
                    store.send(.selectServerSource(source.id))
                } label: {
                    Label(
                        source.name,
                        systemImage: source.id == store.selectedServerSourceID ? "checkmark.circle.fill" : "server.rack"
                    )
                }
            }

            Divider()

            Button {
                store.send(.settingsButtonTapped)
            } label: {
                Label("Manage Sources", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                Text(store.activeServerSourceName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.1), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
        }
        .accessibilityLabel("CMUX source")
        .accessibilityValue(store.activeServerSourceName)
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

            if store.isDemoMode {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This is simulated iPhone-only data. Connect your own Mac dashboard when you are ready.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        store.send(.exitDemoModeTapped)
                    } label: {
                        Label("Connect Real Server", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.black))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(Color.orange, in: Capsule())
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(HomeGlassCard(cornerRadius: 18))
    }

    private var connectionState: ConnectionDot.State {
        if store.isDemoMode {
            return .demo
        }
        if store.isConnected {
            return .connected
        }
        if store.hasSocket {
            return .reconnecting
        }
        return .offline
    }

    private var connectionTitle: String {
        if store.isDemoMode {
            return "Local Demo Mode"
        }
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
    let group: WorkspaceSessionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SessionStatusIndicators(workspace: workspace)
                    .padding(.top, 9)

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        store.send(.selectWorkspace(preferredWorkspaceID))
                    } label: {
                        SessionGroupTitleView(group: group)
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
                if group.hasMultiplePanes {
                    SessionMetaChip(systemImage: "rectangle.split.2x1", value: "\(group.paneCount) panes")
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
            store.send(.selectWorkspace(preferredWorkspaceID))
        }
    }

    private var workspace: Workspace {
        group.primaryWorkspace
    }

    private var preferredWorkspaceID: String {
        group.preferredWorkspaceID(selectedWorkspaceID: store.selectedWorkspaceID)
    }

    private var sessionState: WorkspaceSessionState {
        return workspaceSessionState(for: group, entries: store.logEntries)
    }

    private var isExpanded: Bool {
        group.containsWorkspace(id: store.selectedWorkspaceID)
    }

    private var cardBorderColor: Color {
        isExpanded ? .accentColor.opacity(0.8) : Color.white.opacity(0.14)
    }
}

struct SessionGroupTitleView: View {
    let group: WorkspaceSessionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var title: String {
        group.displayName.pathTail(componentCount: 2) ?? group.displayName
    }

    private var subtitle: String? {
        if let cwd = group.primaryWorkspace.cwd?.nonEmptyTrimmed {
            return cwd
        }
        if group.displayName != title, group.displayName.contains("/") {
            return group.displayName
        }
        if group.hasMultiplePanes {
            return "\(group.paneCount) panes"
        }
        return nil
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
    var isEasyModeEnabled: Bool? = nil
    var easyModeAction: (() -> Void)? = nil

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

            if let isEasyModeEnabled, let easyModeAction {
                Section("Input") {
                    Button {
                        easyModeAction()
                    } label: {
                        Label(
                            isEasyModeEnabled ? "Turn Off Easy Mode" : "Easy Mode",
                            systemImage: isEasyModeEnabled ? "hand.tap.fill" : "hand.tap"
                        )
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
            Label("Session Options", systemImage: "ellipsis")
                .font(.headline.weight(.bold))
                .labelStyle(.iconOnly)
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
