import SwiftUI

struct WorkspaceListView: View {
    @Bindable var model: HerdrAppModel
    let selectWorkspace: (HerdrWorkspace) -> Void
    let selectPane: (HerdrPane) -> Void
    @State private var presentedSheet: WorkspaceListSheet?

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
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Workspaces")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $presentedSheet) { _ in
            CreateWorkspaceView { label, cwd in
                let created = await model.createWorkspace(label: label, cwd: cwd)
                if created { presentedSheet = nil }
                return created
            }
            .presentationDetents([.medium])
        }
    }

    private func showCreateWorkspace() {
        presentedSheet = .create
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
