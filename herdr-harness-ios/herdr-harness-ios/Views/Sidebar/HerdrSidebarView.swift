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
    @State private var renamingTab: HerdrTab?
    @State private var tabName = ""
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

            // The inbox rides inside the scroll region rather than above it.
            // Pinned, an expanded inbox would permanently squeeze the chat
            // list — which is what people actually open the drawer for — so the
            // "chats" label comes along and the two read as peer sections.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    SidebarWorkInboxView(model: model)
                        .padding(.bottom, 8)

                    HerdrSectionLabel(
                        title: "chats",
                        detail: sidebarCountDetail(paneCount),
                        monospaced: false
                    )
                    .padding(.bottom, 2)

                    starredSection
                    workspaceContent
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, SidebarMetrics.containerHorizontalPadding)
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
        .alert("Rename tab", isPresented: isRenamingTab) {
            TextField("Tab name", text: $tabName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                guard let tab = renamingTab else { return }
                Task { await model.rename(tab, label: tabName) }
            }
            .disabled(tabName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new label appears in Herdr on every connected client.")
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
            Menu {
                ForEach(SidebarRecency.allCases) { recency in
                    Button {
                        model.sidebarRecency = recency
                    } label: {
                        Label(
                            recency.title,
                            systemImage: recency == model.sidebarRecency ? "checkmark" : recency.symbolName
                        )
                    }
                }
            } label: {
                Image(systemName: model.sidebarRecency.symbolName)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(model.sidebarRecency == .all ? HerdrTheme.mist : HerdrTheme.accent)
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-recent-filter")
            .accessibilityLabel("Chat range, \(model.sidebarRecency.title)")
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
            .font(.caption.bold())
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

            Menu {
                ForEach(model.machines) { machine in
                    Button(machine.name) {
                        model.presentAgent(machineID: machine.id)
                        dismiss()
                    }
                }
            } label: {
                Label("run agent", systemImage: "sparkles")
                    .sidebarActionStyle()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-run-agent")
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

            Button("run agent", systemImage: "sparkles") {
                model.presentAgent(machineID: scopedMachineID)
                dismiss()
            }
            .sidebarActionStyle()
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-run-agent")
        }
    }

    @ViewBuilder
    private var starredSection: some View {
        if !starredGroups.isEmpty {
            HerdrSectionLabel(title: "starred", detail: "\(starredCount)", monospaced: false)
                .padding(.top, 4)
            ForEach(starredGroups) { group in
                Text(starredGroupTitle(group))
                    .font(.caption.bold())
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1)
                    .padding(.leading, SidebarMetrics.chatRowLeadingPadding)
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
                            .font(.caption)
                            .foregroundStyle(HerdrTheme.muted)
                            .padding(.leading, SidebarMetrics.chatRowLeadingPadding)
                            .frame(minHeight: SidebarMetrics.placeholderRowHeight)
                    } else {
                        entriesContent(group.entries)
                    }
                }
                machineSeparator
            }
        } else if tree.isEmpty {
            if model.sidebarRecency != .all {
                if starredGroups.isEmpty {
                    Text("no chats from \(model.sidebarRecency.title.lowercased())")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 42)
                }
            } else {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 42)
            }
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
                    SidebarSectionRow(tab: section.tab, isExpanded: section.isExpanded, action: { toggle(section.tab) })
                        .contextMenu { tabMenu(section.tab, in: entry.workspace) }
                    if section.isExpanded {
                        ForEach(section.chats) { chatRow($0) }
                    }
                }
                ForEach(entry.looseChats) { chatRow($0) }
                if entry.sections.isEmpty && entry.looseChats.isEmpty {
                    Text("no panes yet")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                        .padding(.leading, SidebarMetrics.chatRowLeadingPadding)
                        .frame(minHeight: SidebarMetrics.placeholderRowHeight)
                }
            }
            separator
        }
    }

    @ViewBuilder
    private func tabMenu(_ tab: HerdrTab, in workspace: HerdrWorkspace) -> some View {
        let firstPane = firstPane(in: tab, workspace: workspace)
        Button("Focus on Mac", systemImage: "scope") {
            guard let firstPane else { return }
            Task { await model.focus(firstPane) }
        }
        .disabled(firstPane == nil || !model.canControl(machineID: workspace.machineID))
        Button("Rename tab", systemImage: "pencil") {
            tabName = tab.label
            renamingTab = tab
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        .accessibilityIdentifier("sidebar-tab-rename-\(tab.id)")
        Button("New Pi Chat", systemImage: "plus.bubble") {
            Task { await model.addPane(toTab: tab, in: workspace, running: "pi") }
        }
        .disabled(firstPane == nil || !model.canControl(machineID: workspace.machineID))
        Button("New Shell", systemImage: "terminal") {
            Task { await model.addPane(toTab: tab, in: workspace) }
        }
        .disabled(firstPane == nil || !model.canControl(machineID: workspace.machineID))
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
            starredIDs: model.starredChatIDs,
            recency: model.sidebarRecency
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
            starredIDs: model.starredChatIDs,
            recency: model.sidebarRecency
        )
    }

    private var starredGroups: [SidebarTree.StarredGroup] {
        SidebarTree.starredGroups(
            workspaces: scopedWorkspaces,
            query: query,
            starredIDs: model.starredChatIDs,
            machines: model.machines,
            recency: model.sidebarRecency
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

    private var isRenamingTab: Binding<Bool> {
        Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })
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
            statusSince: statusSince(for: pane),
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

    private func sidebarCountDetail(_ count: Int) -> String {
        switch model.sidebarRecency {
        case .today: "\(count) today"
        case .thisWeek: "\(count) this week"
        case .all: "\(count) total shown"
        }
    }

    /// When the pane's current status started.
    ///
    /// `workingSince` is the server's own clock for a working pane. Every other
    /// status is dated from the newest alert that still matches it — the alert
    /// feed is the only place the snapshot records *when* a pane became blocked
    /// or done. A pane whose status has no matching alert simply has no age, and
    /// `SidebarStatusAgeLabel` falls back to the bare status word.
    private func statusSince(for pane: HerdrPane) -> Date? {
        let newestMatchingAlert = model.alerts.lazy
            .filter {
                $0.machineID == pane.machineID
                    && $0.paneID == pane.paneID
                    && $0.status == pane.agentStatus
            }
            .compactMap(\.createdDate)
            .max()
        if pane.agentStatus == .working {
            return pane.workingSince ?? newestMatchingAlert
        }
        return newestMatchingAlert
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
        font(.subheadline.bold())
            .foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: 44)
    }
}
