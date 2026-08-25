import SwiftUI

struct HerdrSidebarView: View {
    @Bindable var model: HerdrAppModel
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.machines.count > 1 {
                machinePicker
            }

            WorkspaceSearchField(text: $query, placeholder: "filter chats")
            creationControls

            HerdrSectionLabel(title: "chats", detail: "\(paneCount) total shown")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    starredSection
                    workspaceContent
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 18)
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
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isPresentingMachines) {
            NavigationStack {
                MachinesView(model: model)
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
        .confirmationDialog("Close this workspace?", isPresented: isClosingWorkspace, titleVisibility: .visible) {
            Button("Close workspace", role: .destructive) {
                guard let workspace = closingWorkspace else { return }
                Task { await model.close(workspace) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(closingWorkspace?.paneCount ?? 0) pane processes in this workspace will stop.")
        }
        .confirmationDialog("Close this pane?", isPresented: isClosingPane, titleVisibility: .visible) {
            Button("Close pane", role: .destructive) {
                guard let pane = closingPane else { return }
                Task { await model.close(pane) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops the process running in \(closingPane?.displayTitle ?? "this pane").")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HerdrBrandMark(size: 28)
            Text("herdr")
                .font(.headline.monospaced().bold())
                .foregroundStyle(HerdrTheme.text)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(HerdrTheme.mist)
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-close")
            .accessibilityLabel("Close navigator")
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
                            .fill(model.connectionState(forMachine: machine.id).color)
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
                    .font(.caption.bold())
            }
            .font(.caption.monospaced().bold())
            .foregroundStyle(HerdrTheme.mist)
            .frame(minHeight: 30)
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
    private var starredSection: some View {
        if !starredGroups.isEmpty {
            HerdrSectionLabel(title: "starred", detail: "\(starredCount)")
                .padding(.top, 4)
            ForEach(starredGroups) { group in
                Text(starredGroupTitle(group))
                    .font(.caption.monospaced())
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1)
                    .padding(.leading, 34)
                    .padding(.top, 6)
                ForEach(group.chats) { chatRow($0) }
            }
            Rectangle()
                .fill(HerdrTheme.surface.opacity(0.65))
                .frame(height: 1)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if showsMachineChrome {
            ForEach(machineGroups) { group in
                SidebarMachineRow(
                    machine: group.machine,
                    state: group.state,
                    paneCount: machinePaneCount(for: group.machine.id),
                    isExpanded: group.isExpanded,
                    action: { toggle(group.machine) }
                )
                if group.isExpanded {
                    if group.entries.isEmpty {
                        Text("no workspaces yet")
                            .font(.caption.monospaced())
                            .foregroundStyle(HerdrTheme.muted)
                            .padding(.leading, 34)
                            .frame(minHeight: 36)
                    } else {
                        entriesContent(group.entries)
                    }
                }
                machineSeparator
            }
        } else if tree.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.top, 42)
        } else {
            entriesContent(tree)
        }
    }

    @ViewBuilder
    private func entriesContent(_ entries: [SidebarTree.ProjectEntry]) -> some View {
        ForEach(entries) { entry in
            SidebarProjectRow(workspace: entry.workspace, isExpanded: entry.isExpanded, action: { toggle(entry.workspace) })
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
                        .font(.caption.monospaced())
                        .foregroundStyle(HerdrTheme.muted)
                        .padding(.leading, 34)
                        .frame(minHeight: 36)
                }
            }
            separator
        }
    }

    @ViewBuilder
    private func workspaceMenu(_ workspace: HerdrWorkspace) -> some View {
        Button("Open workspace", systemImage: "arrow.right.square") {
            model.openWorkspace(id: workspace.id)
            dismiss()
        }
        Button("Focus on Mac", systemImage: "scope") { Task { await model.focus(workspace) } }
            .disabled(!model.canControl(machineID: workspace.machineID))
        Button("Rename workspace", systemImage: "pencil") {
            workspaceName = workspace.label
            renamingWorkspace = workspace
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        Button("New tab", systemImage: "folder.badge.plus") { Task { await model.createTab(in: workspace) } }
            .disabled(!model.canControl(machineID: workspace.machineID))
        Divider()
        Button("Close workspace", systemImage: "xmark.rectangle", role: .destructive) {
            closingWorkspace = workspace
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
    }

    private var separator: some View {
        Rectangle()
            .fill(HerdrTheme.surface.opacity(0.65))
            .frame(height: 1)
            .padding(.vertical, 10)
    }

    private var machineSeparator: some View {
        Rectangle()
            .fill(HerdrTheme.surface.opacity(0.65))
            .frame(height: 2)
            .padding(.vertical, 16)
    }

    private var scopedWorkspaces: [HerdrWorkspace] {
        guard case let .machine(id) = model.machineScope else { return model.workspaces }
        return model.workspaces.filter { $0.machineID == id }
    }

    private var tree: [SidebarTree.ProjectEntry] {
        SidebarTree.build(
            workspaces: scopedWorkspaces,
            query: query,
            collapsedWorkspaceIDs: model.collapsedSidebarWorkspaceIDs,
            collapsedTabIDs: model.collapsedSidebarTabIDs,
            starredIDs: model.starredChatIDs
        )
    }

    private var machineGroups: [SidebarTree.MachineGroup] {
        SidebarTree.machineGroups(
            machines: model.machines,
            states: model.machineStates,
            workspaces: model.workspaces,
            query: query,
            collapsedMachineIDs: model.collapsedSidebarMachineIDs,
            collapsedWorkspaceIDs: model.collapsedSidebarWorkspaceIDs,
            collapsedTabIDs: model.collapsedSidebarTabIDs,
            starredIDs: model.starredChatIDs
        )
    }

    private var starredGroups: [SidebarTree.StarredGroup] {
        SidebarTree.starredGroups(
            workspaces: scopedWorkspaces,
            query: query,
            starredIDs: model.starredChatIDs,
            machines: model.machines
        )
    }

    private var starredCount: Int { starredGroups.reduce(0) { $0 + $1.chats.count } }

    private var paneCount: Int {
        starredCount + paneCount(in: showsMachineChrome ? machineGroups.flatMap(\.entries) : tree)
    }

    private var showsMachineChrome: Bool {
        if case .all = model.machineScope { return model.machines.count > 1 }
        return false
    }

    private var scopedMachineID: String? {
        if case let .machine(id) = model.machineScope { return id }
        return nil
    }

    private var scopeTitle: String {
        if case let .machine(id) = model.machineScope,
           let machine = model.machines.first(where: { $0.id == id }) {
            return machine.name.lowercased()
        }
        return "all machines"
    }

    private var isRenamingWorkspace: Binding<Bool> {
        Binding(get: { renamingWorkspace != nil }, set: { if !$0 { renamingWorkspace = nil } })
    }

    private var isRenamingPane: Binding<Bool> {
        Binding(get: { renamingPane != nil }, set: { if !$0 { renamingPane = nil } })
    }

    private var isClosingWorkspace: Binding<Bool> {
        Binding(get: { closingWorkspace != nil }, set: { if !$0 { closingWorkspace = nil } })
    }

    private var isClosingPane: Binding<Bool> {
        Binding(get: { closingPane != nil }, set: { if !$0 { closingPane = nil } })
    }

    private var emptyState: some View {
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("No Herdr workspaces", systemImage: "rectangle.3.group", description: Text("Create a workspace here or on your Mac to begin."))
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
            Button(model.starredChatIDs.contains(pane.id) ? "Unstar chat" : "Star chat", systemImage: model.starredChatIDs.contains(pane.id) ? "star.slash" : "star") {
                model.toggleStarredChat(pane.id)
            }
            Button("Focus on Mac", systemImage: "scope") { Task { await model.focus(pane) } }
                .disabled(!model.canControl(machineID: pane.machineID))
            Button("Focus on Mac + Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                Task { await model.focusAndZoom(pane) }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Button("Interrupt", systemImage: "stop.fill", role: .destructive) { Task { await model.sendKeys(["ctrl+c"], to: pane) } }
                .disabled(!model.canControl(machineID: pane.machineID))
            Button("Rename pane", systemImage: "pencil") {
                paneName = pane.displayTitle
                renamingPane = pane
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Menu("Split pane", systemImage: "rectangle.split.2x1") {
                Button("Split right", systemImage: "rectangle.split.2x1") { Task { await model.split(pane, direction: "right") } }
                Button("Split down", systemImage: "rectangle.split.1x2") { Task { await model.split(pane, direction: "down") } }
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
            Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) { closingPane = pane }
                .disabled(!model.canControl(machineID: pane.machineID))
        }
    }

    private func starredGroupTitle(_ group: SidebarTree.StarredGroup) -> String {
        guard showsMachineChrome,
              let machineID = MachineScopedID.split(group.workspace.id)?.machineID,
              let machine = model.machines.first(where: { $0.id == machineID })
        else { return group.workspace.label.lowercased() }
        return "\(machine.name.lowercased()) · \(group.workspace.label.lowercased())"
    }

    private func paneCount(in entries: [SidebarTree.ProjectEntry]) -> Int {
        entries.reduce(0) { count, entry in
            count + entry.looseChats.count + entry.sections.reduce(0) { $0 + $1.chats.count }
        }
    }

    private func machinePaneCount(for machineID: String) -> Int {
        model.workspaces
            .filter { $0.machineID == machineID }
            .reduce(0) { $0 + $1.paneCount }
    }

    private func firstPane(in tab: HerdrTab, workspace: HerdrWorkspace) -> HerdrPane? {
        workspace.panes.filter { $0.scopedTabID == tab.id }.sorted { $0.paneID < $1.paneID }.first
    }

    private func presentCreateWorkspace(for machineID: String?) {
        creatingWorkspaceMachineID = machineID
        isPresentingCreateWorkspace = true
    }

    private func toggle(_ workspace: HerdrWorkspace) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.snappy) { model.toggleSidebarSection(workspace.id) }
    }

    private func toggle(_ tab: HerdrTab) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.snappy) { model.toggleSidebarTabSection(tab.id) }
    }

    private func toggle(_ machine: HerdrMachine) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.snappy) { model.toggleSidebarMachineSection(machine.id) }
    }

    private func open(_ pane: HerdrPane) {
        model.openPane(id: pane.id)
        dismiss()
    }

    private func dismiss() {
        withAnimation(.snappy) { model.isSidebarPresented = false }
    }
}

private extension View {
    func sidebarActionStyle() -> some View {
        font(.subheadline.monospaced().bold())
            .foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: 44)
    }
}
