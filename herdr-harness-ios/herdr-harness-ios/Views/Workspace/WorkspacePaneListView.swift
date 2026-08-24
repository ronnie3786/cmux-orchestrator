import SwiftUI

struct WorkspacePaneListView: View {
    @Bindable var model: HerdrAppModel
    let workspace: HerdrWorkspace
    let selectPane: (HerdrPane) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isRenamingWorkspace = false
    @State private var isConfirmingWorkspaceClose = false
    @State private var workspaceName = ""

    var body: some View {
        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    WorkspaceHeroView(workspace: workspace)

                    ForEach(workspace.tabs) { tab in
                        tabSection(tab)
                    }

                    if workspace.tabs.isEmpty {
                        paneRows(workspace.sortedPanes)
                    }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .navigationTitle(workspace.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if horizontalSizeClass == .compact {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Open navigator", systemImage: "sidebar.leading") {
                        model.isSidebarPresented = true
                    }
                    .accessibilityIdentifier("sidebar-toggle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Workspace actions", systemImage: "ellipsis.circle") {
                    Button("Focus on Mac", systemImage: "scope") {
                        Task { await model.focus(workspace) }
                    }
                    Button("Rename workspace", systemImage: "pencil") {
                        workspaceName = workspace.label
                        isRenamingWorkspace = true
                    }
                    Button("New tab", systemImage: "folder.badge.plus") {
                        Task { await model.createTab(in: workspace) }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    Divider()
                    Button("Close workspace", systemImage: "xmark.rectangle", role: .destructive) {
                        isConfirmingWorkspaceClose = true
                    }
                }
                .disabled(!model.canControl)
            }
        }
        .alert("Rename workspace", isPresented: $isRenamingWorkspace) {
            TextField("Workspace name", text: $workspaceName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                Task { await model.rename(workspace, label: workspaceName) }
            }
            .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new label appears in Herdr on every connected client.")
        }
        .confirmationDialog(
            "Close this workspace?",
            isPresented: $isConfirmingWorkspaceClose,
            titleVisibility: .visible
        ) {
            Button("Close workspace", role: .destructive) {
                Task { await model.close(workspace) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(workspace.paneCount) pane processes in this workspace will stop.")
        }
    }

    private func tabSection(_ tab: HerdrTab) -> some View {
        let panes = workspace.sortedPanes.filter { $0.scopedTabID == tab.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tab.label, systemImage: "folder")
                    .font(.headline.bold())
                Spacer()
                Text("^[\(panes.count) pane](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            paneRows(panes)
        }
    }

    private func paneRows(_ panes: [HerdrPane]) -> some View {
        VStack(spacing: 10) {
            ForEach(panes) { pane in
                Button {
                    selectPane(pane)
                } label: {
                    PaneCardView(
                        pane: pane,
                        isSelected: pane.id == model.selectedPaneID
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pane-\(pane.id)")
            }
        }
    }
}
