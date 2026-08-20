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
    @State private var renamingWorkspace: HerdrWorkspace?
    @State private var workspaceName = ""
    @State private var renamingPane: HerdrPane?
    @State private var paneName = ""
    @State private var closingWorkspace: HerdrWorkspace?
    @State private var closingPane: HerdrPane?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HerdrBrandMark(size: 28)

                Text("herdr")
                    .font(.headline.monospaced().bold())
                    .foregroundStyle(HerdrTheme.text)

                Spacer()
            }

            WorkspaceSearchField(text: $query, placeholder: "filter chats")

            Button("new workspace", systemImage: "plus") {
                isPresentingCreateWorkspace = true
            }
            .font(.subheadline.monospaced().bold())
            .foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: 28)
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-workspace")

            Button("new pi session", systemImage: "bolt") {
                Task { await model.createQuickPiSession() }
            }
            .font(.subheadline.monospaced().bold())
            .foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: 28)
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-pi-session")

            HerdrSectionLabel(title: "chats", detail: "\(paneCount) total shown")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if tree.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 42)
                    } else {
                        ForEach(tree) { entry in
                            SidebarProjectRow(
                                workspace: entry.workspace,
                                isExpanded: entry.isExpanded,
                                action: { toggle(entry.workspace) }
                            )
                            .contextMenu {
                                Button("Open workspace", systemImage: "arrow.right.square") {
                                    openWorkspace(entry.workspace)
                                }
                                Button("Focus on Mac", systemImage: "scope") {
                                    Task { await model.focus(entry.workspace) }
                                }
                                .disabled(!model.canControl)
                                Button("Rename workspace", systemImage: "pencil") {
                                    workspaceName = entry.workspace.label
                                    renamingWorkspace = entry.workspace
                                }
                                .disabled(!model.canControl)
                                Button("New tab", systemImage: "plus.square.on.square") {
                                    Task { await model.createTab(in: entry.workspace) }
                                }
                                .disabled(!model.canControl)
                                Divider()
                                Button("Close workspace", systemImage: "xmark.rectangle", role: .destructive) {
                                    closingWorkspace = entry.workspace
                                }
                                .disabled(!model.canControl)
                            }

                            if entry.isExpanded {
                                ForEach(entry.sections) { section in
                                    let firstPane = firstPane(in: section.tab, workspace: entry.workspace)
                                    SidebarSectionRow(tab: section.tab)
                                        .contextMenu {
                                            Button("Focus on Mac", systemImage: "scope") {
                                                guard let firstPane else { return }
                                                Task { await model.focus(firstPane) }
                                            }
                                            .disabled(firstPane == nil || !model.canControl)
                                        }

                                    ForEach(section.chats) { pane in
                                        chatRow(pane)
                                    }
                                }

                                ForEach(entry.looseChats) { pane in
                                    chatRow(pane)
                                }

                                if entry.sections.isEmpty && entry.looseChats.isEmpty {
                                    Text("no panes yet")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(HerdrTheme.muted)
                                        .padding(.leading, 34)
                                        .frame(minHeight: 24)
                                }
                            }

                            Rectangle()
                                .fill(HerdrTheme.surface.opacity(0.65))
                                .frame(height: 1)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, HerdrTheme.pagePadding)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HerdrTheme.ink)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        .sheet(isPresented: $isPresentingCreateWorkspace) {
            CreateWorkspaceView { label, cwd in
                let created = await model.createWorkspace(label: label, cwd: cwd)
                if created { isPresentingCreateWorkspace = false }
                return created
            }
            .frame(minWidth: 460, minHeight: 320)
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

    private var tree: [SidebarTree.ProjectEntry] {
        SidebarTree.build(
            workspaces: model.workspaces,
            query: query,
            collapsedWorkspaceIDs: model.collapsedSidebarWorkspaceIDs
        )
    }

    private var paneCount: Int {
        tree.reduce(0) { count, entry in
            count + entry.looseChats.count + entry.sections.reduce(0) { $0 + $1.chats.count }
        }
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
            action: { open(pane) }
        )
        .contextMenu {
            Button("Focus on Mac", systemImage: "scope") {
                Task { await model.focus(pane) }
            }
            .disabled(!model.canControl)
            Button("Interrupt", systemImage: "stop.fill", role: .destructive) {
                Task { await model.sendKeys(["ctrl+c"], to: pane) }
            }
            .disabled(!model.canControl)
            Button("Rename pane", systemImage: "pencil") {
                paneName = pane.displayTitle
                renamingPane = pane
            }
            .disabled(!model.canControl)
            Menu("Split pane", systemImage: "rectangle.split.2x1") {
                Button("Split right", systemImage: "rectangle.split.2x1") {
                    Task { await model.split(pane, direction: "right") }
                }
                Button("Split down", systemImage: "rectangle.split.1x2") {
                    Task { await model.split(pane, direction: "down") }
                }
            }
            .disabled(!model.canControl)
            if pane.agentStatus == .unknown {
                Menu("Start agent", systemImage: "cpu") {
                    Button("Codex") { Task { await model.startAgent(in: pane, kind: "codex") } }
                    Button("Claude") { Task { await model.startAgent(in: pane, kind: "claude") } }
                    Button("OpenCode") { Task { await model.startAgent(in: pane, kind: "opencode") } }
                }
                .disabled(!model.canControl)
            }
            Divider()
            Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) {
                closingPane = pane
            }
            .disabled(!model.canControl)
        }
    }

    private func firstPane(in tab: HerdrTab, workspace: HerdrWorkspace) -> HerdrPane? {
        workspace.panes
            .filter { $0.tabID == tab.id }
            .sorted { $0.paneID < $1.paneID }
            .first
    }

    private func toggle(_ workspace: HerdrWorkspace) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.snappy) {
            model.toggleSidebarSection(workspace.id)
        }
    }

    private func open(_ pane: HerdrPane) {
        openPane(pane)
    }
}
