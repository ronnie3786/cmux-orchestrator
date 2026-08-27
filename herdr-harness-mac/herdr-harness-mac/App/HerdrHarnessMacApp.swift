import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var activeWorkStore = ActiveWorkStore()
    @State private var connectionDriver = HerdrConnectionDriver()
    @State private var fontScale = HerdrFontScaleStore()
    @State private var cleanupSettings = CleanupSettingsStore()

    var body: some Scene {
        // A single `Window`, not a `WindowGroup`: Herdr shows one fleet, and a
        // uniquely-identified window is the only kind `openWindow(id:)` can
        // bring back once it has been closed.
        Window("Herdr", id: HerdrWindowID.main) {
            AppRootView(
                model: model,
                shell: shell,
                activeWorkStore: activeWorkStore,
                driver: connectionDriver
            )
                .environment(herdPulse)
                // Apple documents `dynamicTypeSize` as not affecting text size
                // on macOS, so Herdr uses this custom scale environment instead.
                .environment(\.herdrFontScale, fontScale.scale)
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
            HerdrMacCommands(
                model: model,
                shell: shell,
                herdPulse: herdPulse,
                fontScale: fontScale
            )
        }

        // ⌘, — replaces the iOS Settings tab.
        Settings {
            SettingsView(model: model, fontScale: fontScale, cleanupSettings: cleanupSettings)
                .environment(\.herdrFontScale, fontScale.scale)
                .frame(width: 560, height: 640)
                .background(HerdrTheme.ink)
                .preferredColorScheme(.dark)
                .tint(HerdrTheme.accent)
        }

        // Herd Pulse: the menu-bar replacement for the iOS Live Activity.
        HerdPulseMenuBar.scene(pulse: herdPulse, model: model, shell: shell)
            .environment(\.herdrFontScale, fontScale.scale)
    }
}

// MARK: - Menu commands

struct HerdrMacCommands: Commands {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Bindable var herdPulse: HerdPulseCoordinator
    @Bindable var fontScale: HerdrFontScaleStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Workspace") {
                shell.isCreatingWorkspace = true
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.canControl)

            Button("Ask Agent…") {
                shell.isAgentPresented = true
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
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

            Button("Activity Feed") {
                shell.detailScope = .activity
            }
            .keyboardShortcut("5", modifiers: .command)

            Button("Active Work") {
                shell.showActiveWork()
            }
            .keyboardShortcut("6", modifiers: .command)

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

            Divider()

            Button("Increase Text Size") {
                fontScale.increase()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Decrease Text Size") {
                fontScale.decrease()
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Text Size") {
                fontScale.reset()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandMenu("Navigate") {
            Button("Open Chat…") {
                shell.presentCommandPalette()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!model.hasCompletedSetup)

            Button("Focus Current Pane on Mac") {
                guard let pane = selectedPane else { return }
                Task { await model.focus(pane) }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift, .option])
            .disabled(!canFocusSelectedPane)

            Button("Focus Current Pane on Mac + Zoom") {
                guard let pane = selectedPane else { return }
                Task { await model.focusAndZoom(pane) }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!canFocusSelectedPane)

            Divider()

            Button("Next Pane") {
                stepPane(by: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Pane") {
                stepPane(by: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
        }

        CommandGroup(after: .help) {
            Button("Reveal Diagnostics Folder") {
                revealDiagnosticsFolder()
            }

            Button("Export Diagnostics…") {
                Task { await exportDiagnostics() }
            }
        }
    }

    private func focusPane(mode: PaneDetailMode) {
        shell.detailScope = .session
        NotificationCenter.default.post(name: .herdrFocusPaneMode, object: mode)
    }

    private var selectedPane: HerdrPane? {
        model.pane(id: model.selectedPaneID)
    }

    private var canFocusSelectedPane: Bool {
        selectedPane.map { model.canControl(machineID: $0.machineID) } == true
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

    private func revealDiagnosticsFolder() {
        let directory = diagnosticsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            Self.logger.error("unable to create diagnostics directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func exportDiagnostics() async {
        let directory = diagnosticsDirectory
        let fileManager = FileManager.default
        guard (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.isEmpty == false else {
            Self.logger.notice("diagnostics export requested with no diagnostics available")
            return
        }

        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("herdr-diagnostics-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        let sourceDirectory = directory.deletingLastPathComponent()

        let zipFailureMessage = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", temporaryURL.path, "Herdr"]
            process.currentDirectoryURL = sourceDirectory
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return "diagnostics zip failed to launch: \(error.localizedDescription)"
            }
            guard process.terminationStatus == 0 else {
                return "diagnostics zip exited with status \(process.terminationStatus)"
            }
            return nil
        }.value

        if let zipFailureMessage {
            Self.logger.error("\(zipFailureMessage, privacy: .public)")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "herdr-diagnostics-\(Self.exportTimestamp()).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: temporaryURL, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            Self.logger.error("diagnostics export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var diagnosticsDirectory: URL {
        HerdrHangReporter.defaultHangsDirectory().deletingLastPathComponent()
    }

    private static let logger = Logger(subsystem: "dev.ronnierocha.herdr-harness", category: "diagnostics")

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
