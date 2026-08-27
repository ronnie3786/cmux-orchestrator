import SwiftUI

struct PaneActionsMenu: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    @Binding var selectedMode: PaneDetailMode
    var gitIsAvailable = false
    @State private var isConfirmingClose = false
    @State private var isConfirmingEndPiAndClose = false
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        paneActionsMenu
            .confirmationDialog(
                "Close this pane?",
                isPresented: $isConfirmingClose,
                titleVisibility: .visible
            ) {
                Button("Close pane", role: .destructive) {
                    Task { await model.close(pane) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This stops the process running in \(pane.displayTitle).")
            }
            .confirmationDialog(
                "End Pi and close this pane?",
                isPresented: $isConfirmingEndPiAndClose,
                titleVisibility: .visible
            ) {
                Button("End Pi & close pane", role: .destructive) {
                    Task { await model.endPiSessionAndClosePane(in: pane) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Sends /quit to the Pi session, waits for it to exit, then closes \(pane.displayTitle).")
            }
            .alert("Rename pane", isPresented: $isRenaming) {
                TextField("Pane name", text: $renameText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    Task { await model.rename(pane, label: renameText) }
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("This label is shared with Herdr on your Mac.")
            }
            .accessibilityIdentifier("pane-mode-toggle")
    }

    private var paneActionsMenu: some View {
        Menu("Pane actions", systemImage: "ellipsis.circle") {
            viewModeSection
            Divider()
            focusActions
            piSessionActions
            paneManagementActions
            Divider()
            closeAction
        }
    }

    private var viewModeSection: some View {
        Section("View") {
            ForEach(availableModes) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    Label(
                        mode.label,
                        systemImage: selectedMode == mode ? "checkmark.circle.fill" : mode.symbol
                    )
                }
                .accessibilityLabel("\(mode.label) view")
                .accessibilityIdentifier("pane-mode-\(mode.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var focusActions: some View {
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
    }

    @ViewBuilder
    private var piSessionActions: some View {
        if pane.supportsPiSemanticChat || isPiPane {
            if pane.piSemantic?.capabilities.compact == true {
                Button("Compact Pi chat", systemImage: "arrow.down.right.and.arrow.up.left") {
                    Task { await model.compactPiChat(in: pane) }
                }
                .accessibilityIdentifier("pane-action-compact-pi-chat")
                .disabled(!model.canControl(machineID: pane.machineID))
            }

            Button("New Pi chat", systemImage: "plus.bubble") {
                Task { await model.startNewPiChat(in: pane) }
            }
            .accessibilityIdentifier("pane-action-new-pi-chat")
            .disabled(!model.canControl(machineID: pane.machineID))

            Button("End Pi session", systemImage: "xmark.bubble", role: .destructive) {
                Task { await model.endPiSession(in: pane) }
            }
            .accessibilityIdentifier("pane-action-end-pi-session")
            .disabled(!model.canControl(machineID: pane.machineID))

            Button("End Pi & close pane", systemImage: "xmark.rectangle", role: .destructive) {
                isConfirmingEndPiAndClose = true
            }
            .accessibilityIdentifier("pane-action-end-pi-and-close-pane")
            .disabled(!model.canControl(machineID: pane.machineID))
        }
    }

    @ViewBuilder
    private var paneManagementActions: some View {
        Button("Rename pane", systemImage: "pencil") {
            renameText = pane.displayTitle
            isRenaming = true
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
    }

    private var closeAction: some View {
        Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) {
            isConfirmingClose = true
        }
        .disabled(!model.canControl(machineID: pane.machineID))
    }

    private var isPiPane: Bool {
        [pane.agent, pane.displayAgent].contains {
            $0?.caseInsensitiveCompare("pi") == .orderedSame
        }
    }

    private var availableModes: [PaneDetailMode] {
        PaneDetailMode.allCases.filter { mode in
            (mode != .chat || pane.supportsPiSemanticChat)
                && (mode != .git || gitIsAvailable)
        }
    }
}
