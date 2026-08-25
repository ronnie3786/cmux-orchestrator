import SwiftUI

struct HerdrSidebarView: View {
    @Bindable var model: HerdrAppModel
    /// Routing is the shell's job — the sidebar states the intent, it does not
    /// infer it from a selection change (clicking the already-selected chat has
    /// to work too).
    let openPane: (HerdrPane) -> Void
    let openWorkspace: (HerdrWorkspace) -> Void
    @State private var query = ""
    @State private var isPresentingCreateWorkspace = false
    @State private var isPresentingMachines = false
    @State private var creatingWorkspaceMachineID: String?
    @State private var renamingWorkspace: HerdrWorkspace?
    @State private var workspaceName = ""
    @State private var renamingPane: HerdrPane?
    @State private var paneName = ""
    @State private var closingWorkspace: HerdrWorkspace?
    @State private var closingPane: HerdrPane?
    @State private var snapshotCache = SidebarSnapshotCache()

    @MainActor
    private struct SidebarSnapshot {
        let scopedWorkspaces: [HerdrWorkspace]
        let tree: [SidebarTree.ProjectEntry]
        let machineGroups: [SidebarTree.MachineGroup]
        let starredGroups: [SidebarTree.StarredGroup]
        let showsMachineChrome: Bool

        init(model: HerdrAppModel, query: String) {
            if case let .machine(id) = model.machineScope {
                scopedWorkspaces = model.workspaces.filter { $0.machineID == id }
            } else {
                scopedWorkspaces = model.workspaces
            }
            showsMachineChrome = model.machineScope == .all && model.machines.count > 1
            tree = SidebarTree.build(
                workspaces: scopedWorkspaces,
                query: query,
                collapsedWorkspaceIDs: model.collapsedSidebarWorkspaceIDs,
                collapsedTabIDs: model.collapsedSidebarTabIDs,
                starredIDs: model.starredChatIDs
            )
            machineGroups = SidebarTree.machineGroups(
                machines: model.machines,
                states: model.machineStates,
                entries: tree,
                query: query,
                collapsedMachineIDs: model.collapsedSidebarMachineIDs
            )
            starredGroups = SidebarTree.starredGroups(
                workspaces: scopedWorkspaces,
                query: query,
                starredIDs: model.starredChatIDs,
                machines: model.machines
            )
        }

        var starredCount: Int { starredGroups.reduce(0) { $0 + $1.chats.count } }
        var paneCount: Int {
            starredCount + HerdrSidebarView.paneCount(
                in: showsMachineChrome ? machineGroups.flatMap(\.entries) : tree
            )
        }
    }

    private struct SidebarSnapshotFingerprint: Equatable {
        let fleetRevision: Int
        let query: String
        let machineScope: MachineScope
        let machines: [HerdrMachine]
        let collapsedWorkspaceIDs: Set<String>
        let collapsedMachineIDs: Set<String>
        let collapsedTabIDs: Set<String>
        let starredChatIDs: Set<String>
        let machineStates: [String: ConnectionState]
    }

    @MainActor
    private final class SidebarSnapshotCache {
        var fingerprint: SidebarSnapshotFingerprint?
        var snapshot: SidebarSnapshot?
    }

    var body: some View {
        @Bindable var cleanupPresenter = model.cleanupPresenter
        let fingerprint = SidebarSnapshotFingerprint(
            fleetRevision: model.fleetRevision,
            query: query,
            machineScope: model.machineScope,
            machines: model.machines,
            collapsedWorkspaceIDs: model.collapsedSidebarWorkspaceIDs,
            collapsedMachineIDs: model.collapsedSidebarMachineIDs,
            collapsedTabIDs: model.collapsedSidebarTabIDs,
            starredChatIDs: model.starredChatIDs,
            machineStates: model.machineStates
        )
        let snapshot = resolvedSnapshot(fingerprint: fingerprint)
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.machines.count > 1 {
                machinePicker
            }

            WorkspaceSearchField(text: $query, placeholder: "filter chats")
            creationControls

            HerdrSectionLabel(title: "chats", detail: "\(snapshot.paneCount) total shown")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    starredSection(snapshot)
                    workspaceContent(snapshot)
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HerdrTheme.ink)
        .sheet(isPresented: $isPresentingCreateWorkspace) {
            CreateWorkspaceView { label, cwd in
                let created = await model.createWorkspace(
                    label: label,
                    cwd: cwd,
                    machineID: creatingWorkspaceMachineID
                )
                if created { isPresentingCreateWorkspace = false }
                return created
            }
            .frame(minWidth: 460, minHeight: 320)
        }
        .sheet(isPresented: $isPresentingMachines) {
            MachinesView(model: model)
                .frame(minWidth: 460, minHeight: 420)
        }
        .sheet(item: $cleanupPresenter.target) { target in
            if let controller = cleanupPresenter.controller {
                CleanupSheet(target: target, controller: controller)
            }
        }
        .alert("Rename workspace", isPresented: isRenamingWorkspace) {
            TextField("Workspace name", text: $workspaceName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                guard let workspace = renamingWorkspace else { return }
                Task { await model.rename(workspace, label: workspaceName) }
            }
            .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new label appears in Herdr on every connected client.")
        }
        .alert("Rename pane", isPresented: isRenamingPane) {
            TextField("Pane name", text: $paneName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                guard let pane = renamingPane else { return }
                Task { await model.rename(pane, label: paneName) }
            }
            .disabled(paneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This label is shared with Herdr on your Mac.")
        }
        .confirmationDialog(
            "Close this workspace?",
            isPresented: isClosingWorkspace,
            titleVisibility: .visible
        ) {
            Button("Close workspace", role: .destructive) {
                guard let workspace = closingWorkspace else { return }
                Task { await model.close(workspace) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(closingWorkspace?.paneCount ?? 0) pane processes in this workspace will stop.")
        }
        .confirmationDialog(
            "Close this pane?",
            isPresented: isClosingPane,
            titleVisibility: .visible
        ) {
            Button("Close pane", role: .destructive) {
                guard let pane = closingPane else { return }
                Task { await model.close(pane) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops the process running in \(closingPane?.displayTitle ?? "this pane").")
        }
    }

    @MainActor
    private func resolvedSnapshot(fingerprint: SidebarSnapshotFingerprint) -> SidebarSnapshot {
        if snapshotCache.fingerprint == fingerprint, let cached = snapshotCache.snapshot {
            return cached
        }
        let rebuilt = SidebarSnapshot(model: model, query: query)
        snapshotCache.fingerprint = fingerprint
        snapshotCache.snapshot = rebuilt
        return rebuilt
    }

    private var header: some View {
        HStack(spacing: 10) {
            HerdrBrandMark(size: 28)
            Text("herdr")
                .herdrFont(.headline, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
            Spacer()
        }
    }

    private var machinePicker: some View {
        Menu {
            Button("All Machines") { model.setMachineScope(.all) }
            ForEach(model.machines) { machine in
                Button {
                    model.setMachineScope(.machine(machine.id))
                } label: {
                    Label {
                        Text(machine.name)
                    } icon: {
                        Circle()
                            .fill(SidebarTone.status.opacity(machineStatusOpacity(for: machine.id)))
                            .frame(width: 8, height: 8)
                    }
                }
            }
            Divider()
            Button("Manage Machines…", systemImage: "server.rack") {
                isPresentingMachines = true
            }
        } label: {
            HStack(spacing: 7) {
                Text(scopeTitle)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .herdrFont(.caption, weight: .bold)
            }
            .herdrFont(.caption, monospaced: true, weight: .bold)
            .foregroundStyle(HerdrTheme.mist)
            .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-machine-picker")
    }

    @ViewBuilder
    private var creationControls: some View {
        if showsMachineChrome {
            Menu {
                ForEach(model.machines) { machine in
                    Button(machine.name) { presentCreateWorkspace(for: machine.id) }
                }
            } label: {
                Label("new workspace", systemImage: "plus")
                    .sidebarActionStyle()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-workspace")

            Menu {
                ForEach(model.machines) { machine in
                    Button(machine.name) {
                        Task { await model.createQuickPiSession(machineID: machine.id) }
                    }
                }
            } label: {
                Label("new pi session", systemImage: "bolt")
                    .sidebarActionStyle()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-pi-session")
        } else {
            Button("new workspace", systemImage: "plus") {
                presentCreateWorkspace(for: scopedMachineID)
            }
            .sidebarActionStyle()
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-workspace")

            Button("new pi session", systemImage: "bolt") {
                Task { await model.createQuickPiSession(machineID: scopedMachineID) }
            }
            .sidebarActionStyle()
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-pi-session")
        }
    }

    @ViewBuilder
    private func starredSection(_ snapshot: SidebarSnapshot) -> some View {
        if !snapshot.starredGroups.isEmpty {
            HerdrSectionLabel(title: "starred", detail: "\(snapshot.starredCount)")
                .padding(.top, 4)
            ForEach(snapshot.starredGroups) { group in
                Text(starredGroupTitle(group, showsMachineChrome: snapshot.showsMachineChrome))
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1)
                    .padding(.leading, 34)
                    .padding(.top, 6)
                ForEach(group.chats) { chatRow($0) }
            }
            separator
        }
    }

    @ViewBuilder
    private func workspaceContent(_ snapshot: SidebarSnapshot) -> some View {
        if snapshot.showsMachineChrome {
            ForEach(snapshot.machineGroups) { group in
                SidebarMachineRow(
                    machine: group.machine,
                    state: group.state,
                    paneCount: machinePaneCount(for: group.machine.id),
                    isExpanded: group.isExpanded,
                    action: { toggle(group.machine) }
                )
                .contextMenu { machineMenu(group.machine) }
                if group.isExpanded {
                    if group.entries.isEmpty {
                        Text("no workspaces yet")
                            .herdrFont(.caption, monospaced: true)
                            .foregroundStyle(HerdrTheme.muted)
                            .padding(.leading, 34)
                            .frame(minHeight: 24)
                    } else {
                        entriesContent(group.entries)
                    }
                }
                machineSeparator
            }
        } else if snapshot.tree.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.top, 42)
        } else {
            entriesContent(snapshot.tree)
        }
    }

    @ViewBuilder
    private func entriesContent(_ entries: [SidebarTree.ProjectEntry]) -> some View {
        ForEach(entries) { entry in
            SidebarProjectRow(
                workspace: entry.workspace,
                isExpanded: entry.isExpanded,
                action: { toggle(entry.workspace) }
            )
            .contextMenu { workspaceMenu(entry.workspace) }

            if entry.isExpanded {
                ForEach(entry.sections) { section in
                    let firstPane = firstPane(in: section.tab, workspace: entry.workspace)
                    SidebarSectionRow(tab: section.tab, isExpanded: section.isExpanded, action: { toggle(section.tab) })
                        .contextMenu {
                            Button("Focus on Mac", systemImage: "scope") {
                                guard let firstPane else { return }
                                Task { await model.focus(firstPane) }
                            }
                            .disabled(firstPane == nil || !model.canControl(machineID: entry.workspace.machineID))
                            Button("New Pi Chat", systemImage: "plus.bubble") {
                                Task { await model.addPane(toTab: section.tab, in: entry.workspace, running: "pi") }
                            }
                            .disabled(firstPane == nil || !model.canControl(machineID: entry.workspace.machineID))
                            Button("New Shell", systemImage: "terminal") {
                                Task { await model.addPane(toTab: section.tab, in: entry.workspace) }
                            }
                            .disabled(firstPane == nil || !model.canControl(machineID: entry.workspace.machineID))
                        }
                    if section.isExpanded {
                        ForEach(section.chats) { chatRow($0) }
                    }
                }

                ForEach(entry.looseChats) { chatRow($0) }

                if entry.sections.isEmpty && entry.looseChats.isEmpty {
                    Text("no panes yet")
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                        .padding(.leading, 34)
                        .frame(minHeight: 24)
                }
            }
            separator
        }
    }

    @ViewBuilder
    private func workspaceMenu(_ workspace: HerdrWorkspace) -> some View {
        Button("Open workspace", systemImage: "arrow.right.square") {
            openWorkspace(workspace)
        }
        Button("Focus on Mac", systemImage: "scope") {
            Task { await model.focus(workspace) }
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        Button("Rename workspace", systemImage: "pencil") {
            workspaceName = workspace.label
            renamingWorkspace = workspace
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        .accessibilityIdentifier("sidebar-workspace-cleanup-\(workspace.workspaceID)")
        Button("New tab", systemImage: "folder.badge.plus") {
            Task { await model.createTab(in: workspace) }
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        Button("Smart Cleanup This Workspace…", systemImage: "sparkles") {
            model.cleanupPresenter.present(CleanupSheetTarget(
                id: "\(workspace.machineID)|cleanup|\(workspace.workspaceID)",
                machineID: workspace.machineID,
                machineName: machineName(for: workspace.machineID),
                workspaceID: workspace.workspaceID,
                workspaceLabel: workspace.label
            ), using: model)
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        Divider()
        Button("Close workspace", systemImage: "xmark.rectangle", role: .destructive) {
            closingWorkspace = workspace
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
    }

    @ViewBuilder
    private func machineMenu(_ machine: HerdrMachine) -> some View {
        Button("Smart Cleanup…", systemImage: "sparkles") {
            model.cleanupPresenter.present(CleanupSheetTarget(
                id: "\(machine.id)|cleanup|all",
                machineID: machine.id,
                machineName: machine.name,
                workspaceID: nil,
                workspaceLabel: nil
            ), using: model)
        }
        .disabled(!model.canControl(machineID: machine.id))
        .accessibilityIdentifier("sidebar-machine-cleanup-\(machine.id)")
    }

    private func machineName(for machineID: String) -> String {
        model.machines.first(where: { $0.id == machineID })?.name ?? "this machine"
    }

    private var separator: some View {
        Rectangle()
            .fill(HerdrTheme.surface.opacity(0.65))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private var machineSeparator: some View {
        Rectangle()
            .fill(HerdrTheme.surface.opacity(0.65))
            .frame(height: 2)
            .padding(.vertical, 16)
    }

    private var showsMachineChrome: Bool {
        if case .all = model.machineScope { return model.machines.count > 1 }
        return false
    }

    private var scopedMachineID: String? {
        if case let .machine(id) = model.machineScope { return id }
        return model.machines.count == 1 ? model.machines.first?.id : nil
    }

    private var scopeTitle: String {
        if case let .machine(id) = model.machineScope,
           let machine = model.machines.first(where: { $0.id == id }) {
            return machine.name.lowercased()
        }
        return "all machines"
    }

    private var isRenamingWorkspace: Binding<Bool> {
        Binding(
            get: { renamingWorkspace != nil },
            set: { if !$0 { renamingWorkspace = nil } }
        )
    }

    private var isRenamingPane: Binding<Bool> {
        Binding(
            get: { renamingPane != nil },
            set: { if !$0 { renamingPane = nil } }
        )
    }

    private var isClosingWorkspace: Binding<Bool> {
        Binding(
            get: { closingWorkspace != nil },
            set: { if !$0 { closingWorkspace = nil } }
        )
    }

    private var isClosingPane: Binding<Bool> {
        Binding(
            get: { closingPane != nil },
            set: { if !$0 { closingPane = nil } }
        )
    }

    private var emptyState: some View {
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    private func chatRow(_ pane: HerdrPane) -> some View {
        SidebarChatRow(
            pane: pane,
            isSelected: pane.id == model.selectedPaneID,
            isStarred: model.starredChatIDs.contains(pane.id),
            action: { open(pane) }
        )
        .contextMenu {
            Button(
                model.starredChatIDs.contains(pane.id) ? "Unstar chat" : "Star chat",
                systemImage: model.starredChatIDs.contains(pane.id) ? "star.slash" : "star"
            ) {
                model.toggleStarredChat(pane.id)
            }
            Button("Focus on Mac", systemImage: "scope") {
                Task { await model.focus(pane) }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Button("Focus on Mac + Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                Task { await model.focusAndZoom(pane) }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Button("Interrupt", systemImage: "stop.fill", role: .destructive) {
                Task { await model.sendKeys(["ctrl+c"], to: pane) }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Button("Rename pane", systemImage: "pencil") {
                paneName = pane.displayTitle
                renamingPane = pane
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Menu("Split pane", systemImage: "rectangle.split.2x1") {
                Button("Split right", systemImage: "rectangle.split.2x1") {
                    Task { await model.split(pane, direction: "right") }
                }
                Button("Split down", systemImage: "rectangle.split.1x2") {
                    Task { await model.split(pane, direction: "down") }
                }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            if pane.agentStatus == .unknown {
                Menu("Start agent", systemImage: "cpu") {
                    Button("Codex") { Task { await model.startAgent(in: pane, kind: "codex") } }
                    Button("Claude") { Task { await model.startAgent(in: pane, kind: "claude") } }
                    Button("OpenCode") { Task { await model.startAgent(in: pane, kind: "opencode") } }
                }
                .disabled(!model.canControl(machineID: pane.machineID))
            }
            Divider()
            Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) {
                closingPane = pane
            }
            .disabled(!model.canControl(machineID: pane.machineID))
        }
    }

    private func starredGroupTitle(_ group: SidebarTree.StarredGroup, showsMachineChrome: Bool) -> String {
        guard showsMachineChrome,
              let machineID = MachineScopedID.split(group.workspace.id)?.machineID,
              let machine = model.machines.first(where: { $0.id == machineID })
        else { return group.workspace.label.lowercased() }
        return "\(machine.name.lowercased()) · \(group.workspace.label.lowercased())"
    }

    private static func paneCount(in entries: [SidebarTree.ProjectEntry]) -> Int {
        entries.reduce(0) { count, entry in
            count + entry.looseChats.count + entry.sections.reduce(0) { $0 + $1.chats.count }
        }
    }

    private func machinePaneCount(for machineID: String) -> Int {
        model.workspaces
            .filter { $0.machineID == machineID }
            .reduce(0) { $0 + $1.paneCount }
    }

    private func machineStatusOpacity(for machineID: String) -> Double {
        switch model.connectionState(forMachine: machineID) {
        case .live, .demo: 1
        case .connecting: 0.7
        case .disconnected, .failed: 0.45
        }
    }

    private func firstPane(in tab: HerdrTab, workspace: HerdrWorkspace) -> HerdrPane? {
        workspace.panes
            .filter { $0.scopedTabID == tab.id }
            .sorted { $0.paneID < $1.paneID }
            .first
    }

    private func presentCreateWorkspace(for machineID: String?) {
        creatingWorkspaceMachineID = machineID
        isPresentingCreateWorkspace = true
    }

    private func toggle(_ workspace: HerdrWorkspace) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.snappy) {
            model.toggleSidebarSection(workspace.id)
        }
    }

    private func toggle(_ tab: HerdrTab) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.snappy) {
            model.toggleSidebarTabSection(tab.id)
        }
    }

    private func toggle(_ machine: HerdrMachine) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.snappy) {
            model.toggleSidebarMachineSection(machine.id)
        }
    }

    private func open(_ pane: HerdrPane) {
        openPane(pane)
    }
}

private extension View {
    func sidebarActionStyle() -> some View {
        herdrFont(.subheadline, monospaced: true, weight: .bold)
            .foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: 28)
    }
}
