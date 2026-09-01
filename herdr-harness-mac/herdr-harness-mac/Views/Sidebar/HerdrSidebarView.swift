import AppKit
import SwiftUI

struct HerdrSidebarView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var activeWorkStore: ActiveWorkStore
    /// Routing is the shell's job — the sidebar states the intent, it does not
    /// infer it from a selection change (clicking the already-selected chat has
    /// to work too).
    let openPane: (HerdrPane) -> Void
    let openWorkspace: (HerdrWorkspace) -> Void
    let openActiveWork: () -> Void
    let isActiveWorkSelected: Bool
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
    @State private var snapshotCache = SidebarSnapshotCache()

    @MainActor
    private struct SidebarSnapshot {
        let scopedWorkspaces: [HerdrWorkspace]
        let tree: [SidebarTree.ProjectEntry]
        let machineGroups: [SidebarTree.MachineGroup]
        let unreadGroups: [SidebarTree.UnreadGroup]
        let starredGroups: [SidebarTree.StarredGroup]
        let staleGroups: [SidebarTree.StaleGroup]
        let showsMachineChrome: Bool

        init(model: HerdrAppModel, query: String) {
            if case let .machine(id) = model.machineScope {
                scopedWorkspaces = model.workspaces.filter { $0.machineID == id }
            } else {
                scopedWorkspaces = model.workspaces
            }
            showsMachineChrome = model.machineScope == .all && model.machines.count > 1
            let now = Date()
            let scopedPaneIDs = Set(scopedWorkspaces.flatMap(\.panes).map(\.id))
            let unreadPaneIDs = model.unreadPaneIDs.intersection(scopedPaneIDs)
            unreadGroups = SidebarTree.unreadGroups(
                workspaces: scopedWorkspaces,
                query: query,
                unreadIDs: unreadPaneIDs,
                machines: model.machines,
                recency: model.sidebarRecency,
                now: now
            )
            staleGroups = model.sidebarRecency == .all
                ? SidebarTree.staleGroups(
                    machines: model.machines,
                    workspaces: scopedWorkspaces,
                    query: query,
                    excludedPaneIDs: unreadPaneIDs,
                    now: now
                )
                : []
            let stalePaneIDs = Set(staleGroups.flatMap(\.chats).map(\.id))
            let promotedPaneIDs = unreadPaneIDs.union(stalePaneIDs)
            tree = SidebarTree.build(
                workspaces: scopedWorkspaces,
                query: query,
                collapsedWorkspaceIDs: model.collapsedSidebarWorkspaceIDs,
                collapsedTabIDs: model.collapsedSidebarTabIDs,
                starredIDs: model.starredChatIDs,
                recency: model.sidebarRecency,
                excludedPaneIDs: promotedPaneIDs,
                now: now
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
                machines: model.machines,
                recency: model.sidebarRecency,
                excludedPaneIDs: promotedPaneIDs,
                now: now
            )
        }

        var unreadCount: Int { unreadGroups.reduce(0) { $0 + $1.chats.count } }
        var starredCount: Int { starredGroups.reduce(0) { $0 + $1.chats.count } }
        var staleCount: Int { staleGroups.reduce(0) { $0 + $1.chats.count } }
        /// Every workspace row currently on screen, in render order — the scope an
        /// option-click expands or collapses.
        var allWorkspaceIDs: [String] {
            showsMachineChrome ? machineGroups.flatMap(\.entries).map(\.id) : tree.map(\.id)
        }
        var paneCount: Int {
            unreadCount + starredCount + staleCount + HerdrSidebarView.paneCount(
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
        let unreadPaneIDs: Set<String>
        let machineStates: [String: ConnectionState]
        let recency: SidebarRecency
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
            unreadPaneIDs: model.unreadPaneIDs,
            machineStates: model.machineStates,
            recency: model.sidebarRecency
        )
        let snapshot = resolvedSnapshot(fingerprint: fingerprint)
        VStack(alignment: .leading, spacing: 12) {
            header

            activeWorkCTA

            if model.machines.count > 1 {
                machinePicker
            }

            WorkspaceSearchField(text: $query, placeholder: "filter chats")
            creationControls

            HerdrSectionLabel(
                title: "chats",
                detail: sidebarCountDetail(snapshot.paneCount)
            )

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        unreadSection(snapshot)
                        starredSection(snapshot)
                        staleSection(snapshot)
                        workspaceContent(snapshot)
                    }
                }
                .scrollIndicators(.hidden)
                // Navigate ▸ Reveal in Sidebar (⇧⌘K). The model has already
                // un-collapsed the pane's machine, workspace, and tab; the filter
                // field is view-local `@State`, so clearing it is this view's half
                // of the job. Yield one turn so the rebuilt tree — and the row that
                // did not exist a moment ago — is laid out before asking the scroll
                // view for it.
                .task(id: model.sidebarRevealToken) {
                    guard model.sidebarRevealToken > 0,
                          let paneID = model.sidebarRevealPaneID
                    else { return }
                    if !query.isEmpty { query = "" }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy) {
                        proxy.scrollTo(paneID, anchor: .center)
                    }
                }
            }
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
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(model.sidebarRecency == .all ? HerdrTheme.mist : HerdrTheme.accent)
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-recent-filter")
            .accessibilityLabel("Chat range, \(model.sidebarRecency.title)")
            .help("Show chats from \(model.sidebarRecency.title.lowercased())")
        }
    }

    private var activeWorkCTA: some View {
        Button(action: openActiveWork) {
            HStack(spacing: 10) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .herdrFont(.headline, weight: .bold)
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(HerdrTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("active work")
                        .herdrFont(.subheadline, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                    Text(activeWorkSubtitle)
                        .herdrFont(.caption2, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if activeWorkStore.attentionCount > 0 {
                    Text("\(activeWorkStore.attentionCount)")
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(HerdrTheme.alert, in: Capsule())
                        .accessibilityLabel("\(activeWorkStore.attentionCount) need you")
                } else {
                    Image(systemName: "chevron.right")
                        .herdrFont(.caption2, weight: .bold)
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 48)
            .background(isActiveWorkSelected ? HerdrTheme.elevated : HerdrTheme.graphite.opacity(0.42))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isActiveWorkSelected ? HerdrTheme.accent : Color.clear)
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(
                        isActiveWorkSelected ? HerdrTheme.accent.opacity(0.48) : HerdrTheme.surface.opacity(0.72),
                        lineWidth: 1
                    )
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show Active Work")
        .accessibilityLabel(
            "Active Work, \(activeWorkSubtitle)" +
                (activeWorkStore.attentionCount > 0 ? ", \(activeWorkStore.attentionCount) need you" : "")
        )
        .accessibilityHint("Shows the Active Work board")
        .accessibilityAddTraits(isActiveWorkSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-active-work")
    }

    private var activeWorkSubtitle: String {
        guard activeWorkStore.hasLoaded else { return "loading board" }
        let work = activeWorkStore.activeItemCount
        if activeWorkStore.hasError {
            return activeWorkStore.items.isEmpty ? "board unavailable" : "\(work) active · may be stale"
        }
        if !activeWorkStore.response.jiraCandidatesStatus.ok {
            return "\(work) active · Jira stale"
        }
        let setup = activeWorkStore.jiraCandidates.filter { $0.workItemID == nil }.count
        if setup > 0 { return "\(work) active · \(setup) to set up" }
        return "\(work) active · \(activeWorkStore.activeAgentCount) agents"
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
                    Button {
                        Task { await model.createQuickPiSession(machineID: machine.id) }
                    } label: {
                        Label(
                            model.isCreatingQuickPiSession(machineID: machine.id)
                                ? "starting on \(machine.name)…"
                                : machine.name,
                            systemImage: model.isCreatingQuickPiSession(machineID: machine.id)
                                ? "hourglass"
                                : "bolt"
                        )
                    }
                    .disabled(
                        model.isCreatingQuickPiSession(machineID: machine.id)
                            || !model.canControl(machineID: machine.id)
                    )
                }
            } label: {
                quickPiActionLabel(machineID: nil)
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

            Button {
                Task { await model.createQuickPiSession(machineID: scopedMachineID) }
            } label: {
                quickPiActionLabel(machineID: scopedMachineID)
            }
            .buttonStyle(.plain)
            .disabled(
                scopedMachineID == nil
                    || model.isCreatingQuickPiSession(machineID: scopedMachineID)
                    || !(scopedMachineID.map { model.canControl(machineID: $0) } ?? false)
            )
            .accessibilityIdentifier("sidebar-new-pi-session")
        }
    }

    @ViewBuilder
    private func quickPiActionLabel(machineID: String?) -> some View {
        let isCreating = machineID.map { model.isCreatingQuickPiSession(machineID: $0) }
            ?? !model.quickPiSessionMachineIDs.isEmpty
        HStack(spacing: 7) {
            if isCreating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "bolt")
            }
            Text(isCreating ? "starting pi session…" : "new pi session")
        }
        .sidebarActionStyle()
    }

    @ViewBuilder
    private func unreadSection(_ snapshot: SidebarSnapshot) -> some View {
        if !snapshot.unreadGroups.isEmpty {
            HerdrSectionLabel(title: "unread", detail: "\(snapshot.unreadCount)")
                .padding(.top, 4)
                .accessibilityIdentifier("sidebar-unread-section")
                .accessibilityLabel("Unread chats")
                .accessibilityValue("\(snapshot.unreadCount)")
            ForEach(snapshot.unreadGroups) { group in
                Text(priorityGroupTitle(group.workspace, showsMachineChrome: snapshot.showsMachineChrome))
                    .herdrFont(
                        size: SidebarMetrics.projectLabelSize,
                        monospaced: true,
                        weight: .bold,
                        relativeTo: .caption
                    )
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
    private func starredSection(_ snapshot: SidebarSnapshot) -> some View {
        if !snapshot.starredGroups.isEmpty {
            HerdrSectionLabel(title: "starred", detail: "\(snapshot.starredCount)")
                .padding(.top, 4)
                .accessibilityIdentifier("sidebar-starred-section")
                .accessibilityLabel("Starred chats")
                .accessibilityValue("\(snapshot.starredCount)")
            ForEach(snapshot.starredGroups) { group in
                Text(priorityGroupTitle(group.workspace, showsMachineChrome: snapshot.showsMachineChrome))
                    .herdrFont(
                        size: SidebarMetrics.projectLabelSize,
                        monospaced: true,
                        weight: .bold,
                        relativeTo: .caption
                    )
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
    private func staleSection(_ snapshot: SidebarSnapshot) -> some View {
        if !snapshot.staleGroups.isEmpty {
            ForEach(snapshot.staleGroups) { group in
                HStack(spacing: 7) {
                    Label(
                        snapshot.showsMachineChrome
                            ? "\(group.machine.name.lowercased()) stale"
                            : "stale chats",
                        systemImage: "archivebox"
                    )
                    .herdrFont(.caption, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.mist)

                    Text("\(group.chats.count)")
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HerdrTheme.mist)
                        .clipShape(.capsule)

                    Spacer()

                    Button("review stale") {
                        presentStaleCleanup(group)
                    }
                    .buttonStyle(.plain)
                    .herdrFont(.caption, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.accent)
                    .disabled(!model.canControl(machineID: group.machine.id))
                    .accessibilityIdentifier("sidebar-review-stale-\(group.machine.id)")
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .frame(minHeight: 28)
                .accessibilityElement(children: .contain)

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
                        entriesContent(group.entries, allWorkspaceIDs: snapshot.allWorkspaceIDs)
                    }
                }
                machineSeparator
            }
        } else if snapshot.tree.isEmpty {
            if model.sidebarRecency != .all {
                if snapshot.unreadGroups.isEmpty && snapshot.starredGroups.isEmpty {
                    Text("no chats from \(model.sidebarRecency.title.lowercased())")
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 42)
                }
            } else if snapshot.unreadGroups.isEmpty
                && snapshot.staleGroups.isEmpty
                && snapshot.starredGroups.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 42)
            }
        } else {
            entriesContent(snapshot.tree, allWorkspaceIDs: snapshot.allWorkspaceIDs)
        }
    }

    @ViewBuilder
    private func entriesContent(
        _ entries: [SidebarTree.ProjectEntry],
        allWorkspaceIDs: [String]
    ) -> some View {
        ForEach(entries) { entry in
            SidebarProjectRow(
                workspace: entry.workspace,
                isExpanded: entry.isExpanded,
                action: { toggle(entry.workspace, allWorkspaceIDs: allWorkspaceIDs) }
            )
            .contextMenu { workspaceMenu(entry.workspace) }

            if entry.isExpanded {
                ForEach(entry.sections) { section in
                    SidebarSectionRow(
                        tab: section.tab,
                        isExpanded: section.isExpanded,
                        attentionStatus: tabAttentionStatus(section.tab, in: entry.workspace),
                        action: { toggle(section.tab, allTabIDs: entry.sections.map(\.id)) }
                    )
                        .contextMenu { tabMenu(section.tab, in: entry.workspace) }
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
        Divider()
        Button("Copy /send-to-herdr Command", systemImage: "doc.on.doc") {
            copySendToHerdrCommand(workspaceID: workspace.workspaceID, tabID: tab.tabID)
        }
        .disabled(firstPane == nil)
        .help("Paste into a Pi session on \(machineName(for: workspace.machineID))")
        .accessibilityIdentifier("sidebar-tab-copy-send-to-herdr-\(tab.id)")
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

    private func copySendToHerdrCommand(workspaceID: String, tabID: String) {
        let command = SendToHerdrCommand.text(workspaceID: workspaceID, tabID: tabID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func tabAttentionStatus(_ tab: HerdrTab, in workspace: HerdrWorkspace) -> AgentStatus? {
        let statuses = workspace.panes
            .filter { $0.scopedTabID == tab.id }
            .map(\.agentStatus)
        if statuses.contains(.blocked) { return .blocked }
        if statuses.contains(.done) { return .done }
        return nil
    }

    private func sidebarCountDetail(_ count: Int) -> String {
        switch model.sidebarRecency {
        case .today: "\(count) today"
        case .thisWeek: "\(count) this week"
        case .all: "\(count) total shown"
        }
    }

    private func presentStaleCleanup(_ group: SidebarTree.StaleGroup) {
        let paneIDs = Set(group.chats.map(\.paneID))
        let targetID = ([group.machine.id, "cleanup", "stale"] + paneIDs.sorted()).joined(separator: "|")
        model.cleanupPresenter.present(CleanupSheetTarget(
            id: targetID,
            machineID: group.machine.id,
            machineName: group.machine.name,
            workspaceID: nil,
            workspaceLabel: "stale chats",
            workspaceIDs: group.workspaceIDs,
            preferredPaneIDs: paneIDs
        ), using: model)
    }

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

    private var separator: some View {
        Rectangle()
            .fill(HerdrTheme.surface.opacity(0.65))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private var machineSeparator: some View {
        Rectangle()
            .fill(HerdrTheme.surface)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 18)
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

    private var isRenamingTab: Binding<Bool> {
        Binding(
            get: { renamingTab != nil },
            set: { if !$0 { renamingTab = nil } }
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
            statusSince: statusSince(for: pane),
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
        .id(pane.id)
    }

    private func priorityGroupTitle(_ workspace: HerdrWorkspace, showsMachineChrome: Bool) -> String {
        guard showsMachineChrome,
              let machineID = MachineScopedID.split(workspace.id)?.machineID,
              let machine = model.machines.first(where: { $0.id == machineID })
        else { return workspace.label.lowercased() }
        return "\(machine.name.lowercased()) · \(workspace.label.lowercased())"
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

    /// Option-click expands or collapses every workspace at once, the way
    /// option-clicking a file chevron works on a GitHub diff.
    ///
    /// `NSEvent.modifierFlags` rather than `onModifierKeysChanged`: the SwiftUI
    /// modifier would need `@State` on this view, and every Option press anywhere
    /// in the app would then invalidate the navigator's body — the exact cost
    /// `SidebarSnapshotCache` exists to avoid. This reads the flag once, at click
    /// time, and holds no state.
    private func toggle(_ workspace: HerdrWorkspace, allWorkspaceIDs: [String]) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !NSEvent.modifierFlags.contains(.option) else {
            // Expanding a whole fleet inserts hundreds of lazy rows at once;
            // animating that insert is the jank this column can least afford.
            model.toggleSidebarSection(workspace.id, applyingToAll: allWorkspaceIDs)
            return
        }
        withAnimation(.snappy) {
            model.toggleSidebarSection(workspace.id)
        }
    }

    private func toggle(_ tab: HerdrTab, allTabIDs: [String]) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !NSEvent.modifierFlags.contains(.option) else {
            // Expanding a whole fleet inserts hundreds of lazy rows at once;
            // animating that insert is the jank this column can least afford.
            model.toggleSidebarTabSection(tab.id, applyingToAll: allTabIDs)
            return
        }
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
