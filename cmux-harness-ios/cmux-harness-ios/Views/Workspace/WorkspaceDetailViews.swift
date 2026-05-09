import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WorkspaceDetailView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace
    @FocusState private var isDetailInputFocused: Bool
    @State private var isShowingSessionDetails = false

    var body: some View {
        ZStack {
            SessionDetailBackground()

            VStack(spacing: 0) {
                if store.isDemoMode && !isDetailInputFocused {
                    DemoModeBanner {
                        store.send(.exitDemoModeTapped)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

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
        return workspaceSessionState(for: workspace, entries: store.logEntries)
    }

    private var activityEntries: [LogEntry] {
        store.logEntries.filter { $0.workspace == workspace.index }
    }
}

struct DetailTerminalLayout: View {
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

struct DetailFullHeightLayout<Content: View>: View {
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

struct SessionDetailBackground: View {
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

struct SessionDetailTabBar: View {
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

struct SessionDetailsSheet: View {
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

struct SessionMetadataCard: View {
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

struct SessionInfoItem: View {
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
