import SwiftUI

struct WorkspaceListView: View {
    @Bindable var model: HerdrAppModel
    let selectWorkspace: (HerdrWorkspace) -> Void
    let selectPane: (HerdrPane) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentedSheet: WorkspaceListSheet?
    @State private var statusHapticTracker = AgentStatusHapticTracker()
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    WorkspaceHeader(model: model)

                    WorkspaceSearchField(text: $model.searchText)

                    if !model.attentionPanes.isEmpty {
                        AttentionStrip(model: model, selectPane: selectPane)
                    }

                    WorkspaceFilterBar(model: model)

                    HerdrSectionLabel(
                        title: "spaces",
                        detail: "\(model.visibleWorkspaces.count) / \(model.workspaces.count)"
                    )

                    Button("new workspace", systemImage: "plus", action: showCreateWorkspace)
                        .font(.subheadline.monospaced().bold())
                        .foregroundStyle(HerdrTheme.accent)
                        .frame(minHeight: 44)
                        .buttonStyle(.plain)

                    if model.visibleWorkspaces.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 42)
                    } else {
                        ForEach(model.visibleWorkspaces) { workspace in
                            Button {
                                selectWorkspace(workspace)
                            } label: {
                                WorkspaceCardView(
                                    workspace: workspace,
                                    isSelected: workspace.id == model.selectedWorkspaceID,
                                    worktreeConnector: worktreeConnector(
                                        for: workspace,
                                        in: model.visibleWorkspaces
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workspace-\(workspace.id)")
                            .accessibilityHint("Shows \(workspace.paneCount) panes")
                        }
                    }
                }
                .frame(maxWidth: Self.contentWidth, alignment: .leading)
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.top, 18)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Workspaces")
        .onChange(of: agentStatuses, initial: true) { _, statuses in
            if let event = statusHapticTracker.observe(statuses) {
                hapticPulse.fire(event)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            statusHapticTracker.setSceneActive(
                phase == .active,
                isDemoMode: model.isDemoMode,
                statuses: agentStatuses
            )
        }
        .onChange(of: model.lastUpdated) {
            statusHapticTracker.recordRefresh(statuses: agentStatuses)
        }
        .herdrHaptic(trigger: hapticPulse)
        .sheet(item: $presentedSheet) { _ in
            CreateWorkspaceView { label, cwd in
                let created = await model.createWorkspace(label: label, cwd: cwd)
                if created { presentedSheet = nil }
                return created
            }
        }
    }

    /// Keeps the switcher readable when it is given a full-width Mac column.
    private static let contentWidth = 620.0

    private func showCreateWorkspace() {
        presentedSheet = .create
    }

    private var agentStatuses: [String: AgentStatus] {
        AgentStatusHapticTracker.snapshot(model.workspaces)
    }

    private func worktreeConnector(
        for workspace: HerdrWorkspace,
        in workspaces: [HerdrWorkspace]
    ) -> String? {
        guard let worktree = workspace.worktree,
              worktree.isLinkedWorktree,
              workspaces.count(where: { $0.worktree?.repoRoot == worktree.repoRoot }) > 1,
              let index = workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return nil }

        let hasLaterSibling = workspaces.dropFirst(index + 1).contains {
            $0.worktree?.repoRoot == worktree.repoRoot && $0.worktree?.isLinkedWorktree == true
        }
        return hasLaterSibling ? "├─" : "└─"
    }

    private var emptyState: some View {
        Group {
            if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.filter == .all {
                ContentUnavailableView(
                    "No Herdr workspaces",
                    systemImage: "rectangle.3.group",
                    description: Text("Create a workspace here or on your Mac to begin.")
                )
            } else {
                ContentUnavailableView.search
            }
        }
    }
}

private enum WorkspaceListSheet: String, Identifiable {
    case create
    var id: String { rawValue }
}
