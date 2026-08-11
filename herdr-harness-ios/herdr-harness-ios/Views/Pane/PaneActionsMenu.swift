import SwiftUI

struct PaneActionsMenu: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    @State private var isConfirmingClose = false
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        Menu("Pane actions", systemImage: "ellipsis.circle") {
            Button("Focus on Mac", systemImage: "scope") {
                Task { await model.focus(pane) }
            }

            Button("Rename pane", systemImage: "pencil") {
                renameText = pane.displayTitle
                isRenaming = true
            }

            Menu("Split pane", systemImage: "rectangle.split.2x1") {
                Button("Split right", systemImage: "rectangle.split.2x1") {
                    Task { await model.split(pane, direction: "right") }
                }
                Button("Split down", systemImage: "rectangle.split.1x2") {
                    Task { await model.split(pane, direction: "down") }
                }
            }

            if pane.agentStatus == .unknown {
                Menu("Start agent", systemImage: "cpu") {
                    Button("Codex") { Task { await model.startAgent(in: pane, kind: "codex") } }
                    Button("Claude") { Task { await model.startAgent(in: pane, kind: "claude") } }
                    Button("OpenCode") { Task { await model.startAgent(in: pane, kind: "opencode") } }
                }
            }

            Divider()

            Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) {
                isConfirmingClose = true
            }
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
        .disabled(!model.canControl)
    }
}
