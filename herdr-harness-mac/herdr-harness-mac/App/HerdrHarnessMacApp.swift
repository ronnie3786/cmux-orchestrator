import SwiftUI

/// Scene identifiers. `HerdPulseMenuBarCard` needs the main window's id so
/// "Open Herdr" can *re*-open it after the user closed it — the case the button
/// exists for.
enum HerdrWindowID {
    static let main = "herdr-main"
}

@main
struct HerdrHarnessMacApp: App {
    @NSApplicationDelegateAdaptor(HerdrMacAppDelegate.self) private var appDelegate
    @State private var model = HerdrAppModel()
    @State private var herdPulse = HerdPulseCoordinator()
    @State private var shell = HerdrShellState()
    @State private var connectionDriver = HerdrConnectionDriver()

    var body: some Scene {
        // A single `Window`, not a `WindowGroup`: Herdr shows one fleet, and a
        // uniquely-identified window is the only kind `openWindow(id:)` can
        // bring back once it has been closed.
        Window("Herdr", id: HerdrWindowID.main) {
            AppRootView(model: model, shell: shell, driver: connectionDriver)
                .environment(herdPulse)
                .frame(minWidth: 1000, minHeight: 680)
                .background(HerdrTheme.ink)
                .preferredColorScheme(.dark)
                .tint(HerdrTheme.accent)
        }
        .defaultSize(width: 1240, height: 820)
        // The ink background bleeds into the title bar; the detail toolbar
        // supplies the only chrome the window needs.
        .windowStyle(.hiddenTitleBar)
        .commands {
            HerdrMacCommands(model: model, shell: shell, herdPulse: herdPulse)
        }

        // ⌘, — replaces the iOS Settings tab.
        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 640)
                .background(HerdrTheme.ink)
                .preferredColorScheme(.dark)
                .tint(HerdrTheme.accent)
        }

        // Herd Pulse: the menu-bar replacement for the iOS Live Activity.
        HerdPulseMenuBar.scene(pulse: herdPulse)
    }
}

// MARK: - Menu commands

struct HerdrMacCommands: Commands {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Bindable var herdPulse: HerdPulseCoordinator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Workspace") {
                shell.isCreatingWorkspace = true
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.canControl)
        }

        // View menu, after the system's own "Toggle Sidebar" item.
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Go to Attention") {
                shell.detailScope = .attention
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Focus Chat") {
                focusPane(mode: .chat)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Focus Terminal") {
                focusPane(mode: .terminal)
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("Workspace Overview") {
                shell.detailScope = .workspace
            }
            .keyboardShortcut("4", modifiers: .command)

            Divider()

            // The only in-app way to start Pulse. The menu-bar extra is not
            // inserted while Pulse is off, so its own Start button cannot be
            // the entry point — it does not exist yet.
            Button(herdPulse.isRunning ? "Stop Herd Pulse" : "Start Herd Pulse") {
                Task { await herdPulse.toggle() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(herdPulse.isBusy)

            Button("Refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("Navigate") {
            Button("Next Pane") {
                stepPane(by: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Pane") {
                stepPane(by: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }

    private func focusPane(mode: PaneDetailMode) {
        shell.detailScope = .session
        NotificationCenter.default.post(name: .herdrFocusPaneMode, object: mode)
    }

    /// Panes in the order the sidebar draws them, so ⇧⌘] walks the tree
    /// top-to-bottom regardless of which sections happen to be collapsed.
    private func orderedPanes() -> [HerdrPane] {
        SidebarTree
            .build(workspaces: model.workspaces, query: "", collapsedWorkspaceIDs: [])
            .flatMap { entry in
                entry.sections.flatMap(\.chats) + entry.looseChats
            }
    }

    private func stepPane(by offset: Int) {
        let panes = orderedPanes()
        guard !panes.isEmpty else { return }
        let target: Int
        if let current = panes.firstIndex(where: { $0.id == model.selectedPaneID }) {
            target = (current + offset + panes.count) % panes.count
        } else {
            target = offset > 0 ? 0 : panes.count - 1
        }
        shell.detailScope = .session
        model.openPane(id: panes[target].id)
    }
}
