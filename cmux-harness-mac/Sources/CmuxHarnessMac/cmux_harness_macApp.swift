import Foundation
import SwiftUI

@main
struct CmuxHarnessMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var appState = MacHarnessAppState()
    @StateObject private var supervisor = ServerSupervisor()
    @AppStorage("cmuxHarnessMacServerPort") private var serverPort = 9091

    init() {
        if CommandLine.arguments.contains("--smoke") {
            print("cmux-harness-mac smoke ok")
            Foundation.exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--server-smoke") {
            let rawPort = CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : ""
            let port = Int(rawPort) ?? 9101
            Foundation.exit(ServerSmokeRunner.run(port: port))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-smoke") {
            let outputDirectory = CommandLine.arguments.indices.contains(index + 1)
                ? CommandLine.arguments[index + 1]
                : "/tmp/cmux-harness-mac-render-smoke"
            Foundation.exit(RenderSmokeRunner.run(outputDirectory: outputDirectory))
        }
        LocalNotificationBridge.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(supervisor)
                .frame(minWidth: 1120, minHeight: 720)
                .onAppear {
                    appDelegate.supervisor = supervisor
                }
        }
        .commands {
            CommandMenu("Harness") {
                Button("Start Server") {
                    supervisor.start(port: serverPort)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Stop Server") {
                    supervisor.stop()
                }

                Button("Restart Server") {
                    supervisor.restart(port: serverPort)
                }

                Divider()

                Button("Open Browser Dashboard") {
                    supervisor.openBrowserDashboard()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Open cmux") {
                    supervisor.openCmux()
                }

                Button("Copy iPhone URL") {
                    supervisor.copyIPhoneURL()
                }
            }
        }

        MenuBarExtra("cmux Harness", systemImage: menuIcon) {
            Text("Server: \(supervisor.phase.label)")
            Text("cmux: \(appState.status.connected == true ? "Connected" : "Waiting")")
            Text("Workspaces: \(appState.workspaces.count)")
            Divider()
            Button("Start Server") { supervisor.start(port: serverPort) }
            Button("Stop Server") { supervisor.stop() }
            Button("Restart Server") { supervisor.restart(port: serverPort) }
            Button("Open Dashboard") { supervisor.openBrowserDashboard() }
            Button("Open cmux") { supervisor.openCmux() }
            Button("Copy iPhone URL") { supervisor.copyIPhoneURL() }
        }
    }

    private var menuIcon: String {
        appState.status.connected == true ? "terminal.fill" : "terminal"
    }
}
