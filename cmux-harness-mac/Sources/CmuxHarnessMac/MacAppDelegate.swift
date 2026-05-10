import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var supervisor: ServerSupervisor?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor [weak supervisor] in
            supervisor?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
