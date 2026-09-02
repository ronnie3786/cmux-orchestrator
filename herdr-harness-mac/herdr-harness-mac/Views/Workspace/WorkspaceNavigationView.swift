import AppKit
import SwiftUI

/// The Mac shell. This is the iPad-regular `NavigationSplitView` branch of the
/// iOS `WorkspaceNavigationView`, collapsed to two columns: the persistent
/// navigator (which the iPhone build showed as an overlay drawer) and a detail
/// column that swaps between the pane session, the workspace overview, and the
/// attention deck. There is no compact branch — the Mac is always regular.
struct WorkspaceNavigationView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Bindable var activeWorkStore: ActiveWorkStore
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isFleetButtonHovered = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HerdrSidebarView(
                model: model,
                openPane: openSession,
                openWorkspace: { shell.showWorkspace(id: $0.id, model: model) }
            )
                // AppKit remembers a column the user has dragged, so ideal only
                // affects a fresh profile. Sidebar padding moves existing content.
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
                .background(HerdrTheme.ink)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HerdrTheme.ink)
                .toolbar { detailToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        // Revealing a pane in a column the user has hidden would be a silent
        // no-op, so ⇧⌘K brings the navigator back first.
        .onChange(of: model.sidebarRevealToken) { _, token in
            guard token > 0 else { return }
            withAnimation(.snappy) { columnVisibility = .all }
        }
        .task(id: model.connectionGeneration) {
            activeWorkStore.resetForConnectionChange()
            await refreshActiveWork()
        }
        .task(id: model.activeWorkRefreshTick) {
            guard activeWorkStore.hasLoaded else { return }
            await refreshActiveWork()
        }
        .task(id: model.primaryConnectionState) {
            guard model.primaryConnectionState == .live || model.primaryConnectionState == .demo,
                  !activeWorkStore.hasLoaded || activeWorkStore.hasError else { return }
            await refreshActiveWork()
        }
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
        case .activeWork:
            Group {
                if model.isDemoMode || model.activeWorkLegacyUI {
                    ActiveWorkContainerView(
                        store: activeWorkStore,
                        isControlEnabled: model.canControlPrimary,
                        refresh: refreshActiveWork,
                        createItem: createItem,
                        setupJira: setupJira,
                        transition: transition,
                        setLifecycle: setLifecycle,
                        openSession: openTrackedSession,
                        openURL: { url in
                            Task {
                                do {
                                    try await ActiveWorkLinkOpener.open(url)
                                } catch {
                                    model.toastMessage = error.localizedDescription
                                }
                            }
                        },
                        transcribeVoice: { try await model.transcribeVoiceNote(at: $0) },
                        askBoard: { question in
                            shell.presentAgent(prompt: activeWorkStore.agentPrompt(question: question))
                        }
                    )
                } else if let configuration = model.activeServerConfiguration {
                    ActiveWorkBoardWebView(
                        configuration: configuration,
                        openPane: { paneID, machineID in
                            shell.openPane(rawPaneID: paneID, machineID: machineID, model: model)
                        },
                        openExternal: { url in
                            Task {
                                do {
                                    try await ActiveWorkLinkOpener.open(url)
                                } catch {
                                    model.toastMessage = error.localizedDescription
                                }
                            }
                        },
                        copyText: { model.copyToPasteboard($0) },
                        popOut: { openWindow(id: HerdrWindowID.activeWorkBoard) }
                    )
                    .accessibilityIdentifier("active-work-container")
                } else {
                    ActiveWorkBoardEmptyStateView()
                        .accessibilityIdentifier("active-work-container")
                }
            }
        case .fleet:
            FleetManagementSheet(model: model, isEmbedded: true)
        case .attention:
            AttentionView(model: model) { pane, _ in
                openSession(pane)
            }
        case .activity:
            ActivityFeedView(model: model, selectPane: openSession)
        }
    }

    /// Every "open this pane" affordance goes through here. Assigning
    /// `selectedPaneID` alone is not enough: when the pane is already selected
    /// the assignment is a no-op and the detail would stay on whatever scope
    /// the user is looking at.
    private func openSession(_ pane: HerdrPane) {
        shell.openPane(id: pane.id, model: model)
    }

    private func openTrackedSession(_ session: ActiveWorkPiSession) {
        guard let paneID = session.paneID else { return }
        shell.openPane(rawPaneID: paneID, machineID: session.machineID, model: model)
    }

    private func refreshActiveWork() async {
        await activeWorkStore.refresh {
            try await model.fetchActiveWork()
        }
    }

    private func setupJira(_ candidate: ActiveWorkJiraCandidate) async throws {
        _ = try await model.setupActiveWorkJira(key: candidate.key)
        await refreshActiveWork()
    }

    private func createItem(kind: String, title: String, summary: String) async throws {
        _ = try await model.createActiveWorkItem(kind: kind, title: title, summary: summary)
        await refreshActiveWork()
    }

    private func transition(
        _ item: ActiveWorkItem,
        _ target: ActiveWorkPipelineStage
    ) async throws {
        _ = try await model.transitionActiveWorkItem(item, to: target)
        await refreshActiveWork()
    }

    private func setLifecycle(_ item: ActiveWorkItem, _ lifecycle: String) async throws {
        _ = try await model.setActiveWorkLifecycle(item, lifecycle: lifecycle)
        await refreshActiveWork()
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 2) {
                historyButton(
                    symbol: "chevron.left",
                    label: "Back",
                    help: "Go back to the previous pane or screen",
                    identifier: "nav-history-back",
                    isEnabled: shell.canGoBack
                ) { shell.goBack(model: model) }

                historyButton(
                    symbol: "chevron.right",
                    label: "Forward",
                    help: "Go forward",
                    identifier: "nav-history-forward",
                    isEnabled: shell.canGoForward
                ) { shell.goForward(model: model) }
            }
            .accessibilityIdentifier("nav-history-controls")
        }

        ToolbarItem(placement: .principal) {
            ZStack(alignment: .topTrailing) {
                Picker("Detail", selection: scopeSelection) {
                    ForEach(HerdrDetailScope.pickerCases) { scope in
                        Label(scope.label, systemImage: scope.symbol)
                            .tag(scope as HerdrDetailScope?)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("detail-scope-picker")

                if model.unreadAlertCount > 0 {
                    Text("\(model.unreadAlertCount)")
                        .herdrFont(.caption2, weight: .bold)
                        .foregroundStyle(HerdrTheme.ink)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(HerdrTheme.alert, in: Capsule())
                        .offset(x: 7, y: -7)
                        .allowsHitTesting(false)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Agent", systemImage: "sparkles") {
                shell.isAgentPresented = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canControl)
            .help("Ask a one-off question without creating a chat")
            .accessibilityIdentifier("open-headless-agent")
        }

        ToolbarItem(placement: .primaryAction) {
            HerdPulseButton()
        }

        ToolbarItem(placement: .primaryAction) {
            let isFleetActive = shell.resolvedScope(for: model) == .fleet

            Button {
                shell.show(.fleet, model: model)
            } label: {
                Label("Fleet", systemImage: HerdrDetailScope.fleet.symbol)
                    .labelStyle(.iconOnly)
                    .herdrHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                isFleetActive
                    ? HerdrTheme.accent
                    : isFleetButtonHovered ? HerdrTheme.text : HerdrTheme.mist
            )
            .background(
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius, style: .continuous)
                    .fill(
                        isFleetActive
                            ? HerdrTheme.accent.opacity(0.16)
                            : isFleetButtonHovered ? HerdrTheme.elevated.opacity(0.78) : .clear
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius, style: .continuous)
                    .strokeBorder(
                        isFleetActive ? HerdrTheme.accent.opacity(0.58) : .clear,
                        lineWidth: 1
                    )
            }
            .onHover { isFleetButtonHovered = $0 }
            .help(isFleetActive ? "Fleet is open" : "Open Fleet management")
            .accessibilityLabel("Fleet")
            .accessibilityValue(isFleetActive ? "Selected" : "Not selected")
            .accessibilityHint("Open Fleet management in the detail column")
            .accessibilityAddTraits(isFleetActive ? .isSelected : [])
            .accessibilityIdentifier("fleet-toolbar-button")
        }

        ToolbarItem(placement: .primaryAction) {
            ConnectionPill(state: model.connectionState)
        }
    }

    /// Reads the resolved scope when the picker has a matching segment, and
    /// otherwise returns nil so dedicated destinations leave every segment
    /// unselected. Writes are limited to actual picker cases.
    private var scopeSelection: Binding<HerdrDetailScope?> {
        Binding(
            get: {
                HerdrDetailScope.pickerSelection(for: shell.resolvedScope(for: model))
            },
            set: { scope in
                guard let scope = scope,
                      HerdrDetailScope.pickerSelection(for: scope) != nil else { return }
                shell.show(scope, model: model)
            }
        )
    }

    private func historyButton(
        symbol: String, label: String, help: String,
        identifier: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .herdrHitTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? HerdrTheme.mist : HerdrTheme.muted)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
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
