import SwiftUI

struct PaneActionsMenu: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    @Binding var selectedMode: PaneDetailMode
    var isPiCompacting = false
    /// Mirrors the Mac's `PaneSessionHeader` parameters. Defaulted so the flag
    /// and the action can be added at the single call site without touching
    /// anything else.
    var showsPiSessionSummary = false
    var summarizePiSession: () -> Void = { }
    @State private var isConfirmingClose = false
    @State private var isConfirmingEndPiAndClose = false
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        Menu("Pane actions", systemImage: "ellipsis.circle") {
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

            Divider()

            Button("Focus on Mac", systemImage: "scope") {
                Task { await model.focus(pane) }
            }
            .disabled(!model.canControl)

            Button("Focus on Mac + Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                Task { await model.focusAndZoom(pane) }
            }
            .disabled(!model.canControl)

            Button("Interrupt", systemImage: "stop.fill", role: .destructive) {
                Task { await model.sendKeys(["ctrl+c"], to: pane) }
            }
            .disabled(!model.canControl)

            // Gated on the Pi session id, not on `supportsPiSemanticChat`: the
            // summary reads the transcript off disk in a separate headless
            // session, so a pane whose semantic bridge is no longer connected
            // can still be summarized.
            if showsPiSessionSummary {
                Button("Summarize Pi session", systemImage: "list.bullet.clipboard", action: summarizePiSession)
                    // The run is dispatched to the pane's machine, not the
                    // primary connection, so this row checks that machine.
                    .disabled(!model.canControl(machineID: pane.machineID))
                    .accessibilityIdentifier("pane-summarize-pi-session")
                    .accessibilityHint("Opens a short summary generated in a separate headless Pi session")
            }

            if pane.supportsPiSemanticChat || [pane.agent, pane.displayAgent].contains(where: { $0?.caseInsensitiveCompare("pi") == .orderedSame }) {
                Button("Compact Pi chat", systemImage: "arrow.down.right.and.arrow.up.left") {
                    Task { await model.compactPiChat(in: pane) }
                }
                .accessibilityIdentifier("pane-action-compact-pi-chat")
                .disabled(piSessionMutationIsDisabled)

                Button("New Pi chat", systemImage: "plus.bubble") {
                    Task { await model.startNewPiChat(in: pane) }
                }
                .accessibilityIdentifier("pane-action-new-pi-chat")
                .disabled(piSessionMutationIsDisabled)

                Button("End Pi session", systemImage: "xmark.bubble", role: .destructive) {
                    Task { await model.endPiSession(in: pane) }
                }
                .accessibilityIdentifier("pane-action-end-pi-session")
                .disabled(piSessionMutationIsDisabled)

                Button("End Pi & close pane", systemImage: "xmark.rectangle", role: .destructive) {
                    isConfirmingEndPiAndClose = true
                }
                .accessibilityIdentifier("pane-action-end-pi-and-close-pane")
                .disabled(piSessionMutationIsDisabled)
            }

            Button("Rename pane", systemImage: "pencil") {
                renameText = pane.displayTitle
                isRenaming = true
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
                isConfirmingClose = true
            }
            .disabled(!model.canControl)
        }
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

    private var availableModes: [PaneDetailMode] {
        PaneDetailMode.allCases.filter { $0 != .chat || pane.supportsPiSemanticChat }
    }

    private var piSessionMutationIsDisabled: Bool {
        !Self.piSessionMutationsEnabled(
            // Every one of these runs against the pane's own machine, and each
            // handler guards on it and returns silently. Gating on the
            // aggregate connection would leave the row tappable and mute.
            canControl: model.canControl(machineID: pane.machineID),
            isCompacting: isPiCompacting
        )
    }

    static func piSessionMutationsEnabled(canControl: Bool, isCompacting: Bool) -> Bool {
        canControl && !isCompacting
    }
}
