import SwiftUI

/// The Mac shell. This is the iPad-regular `NavigationSplitView` branch of the
/// iOS `WorkspaceNavigationView`, collapsed to two columns: the persistent
/// navigator (which the iPhone build showed as an overlay drawer) and a detail
/// column that swaps between the pane session, the workspace overview, and the
/// attention deck. There is no compact branch — the Mac is always regular.
struct WorkspaceNavigationView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HerdrSidebarView(
                model: model,
                openPane: openSession,
                openWorkspace: { shell.showWorkspace(id: $0.id, model: model) }
            )
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
                .background(HerdrTheme.ink)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HerdrTheme.ink)
                .toolbar { detailToolbar }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detail: some View {
        switch shell.resolvedScope(for: model) {
        case .session:
            if let pane = model.pane(id: model.selectedPaneID) {
                PaneSessionView(model: model, pane: pane)
                    .id(pane.id)
            } else {
                placeholder(
                    "Choose a pane",
                    symbol: "terminal",
                    detail: "Open a terminal or agent session."
                )
            }
        case .workspace:
            if let workspace = model.workspace(id: model.selectedWorkspaceID) {
                WorkspacePaneListView(model: model, workspace: workspace, selectPane: openSession)
            } else {
                placeholder(
                    "Choose a workspace",
                    symbol: "rectangle.3.group",
                    detail: "Its tabs and panes will appear here."
                )
            }
        case .attention:
            AttentionView(model: model) { pane, alert in
                openSession(pane)
                if let alert {
                    Task { await model.markAlertRead(alert) }
                }
            }
        }
    }

    /// Every "open this pane" affordance goes through here. Assigning
    /// `selectedPaneID` alone is not enough: when the pane is already selected
    /// the assignment is a no-op and the detail would stay on whatever scope
    /// the user is looking at.
    private func openSession(_ pane: HerdrPane) {
        shell.showSession()
        model.openPane(id: pane.id)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Detail", selection: scopeSelection) {
                ForEach(HerdrDetailScope.allCases) { scope in
                    Label(scope.label, systemImage: scope.symbol)
                        .tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("detail-scope-picker")
        }

        ToolbarItem(placement: .primaryAction) {
            HerdPulseButton()
        }

        ToolbarItem(placement: .primaryAction) {
            ConnectionPill(state: model.connectionState)
        }
    }

    /// Reads the *resolved* scope so the control always reflects what is on
    /// screen, and writes the requested one straight through to the shell.
    private var scopeSelection: Binding<HerdrDetailScope> {
        Binding(
            get: { shell.resolvedScope(for: model) },
            set: { shell.detailScope = $0 }
        )
    }

    private func placeholder(_ title: String, symbol: String, detail: String) -> some View {
        ZStack {
            HerdrBackground()

            ContentUnavailableView(
                title,
                systemImage: symbol,
                description: Text(detail)
            )
        }
    }
}
