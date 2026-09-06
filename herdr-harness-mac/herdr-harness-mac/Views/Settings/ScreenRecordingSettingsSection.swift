import SwiftUI

struct ScreenRecordingSettingsSection: View {
    @State private var permission = HerdrScreenRecordingPermission()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            LabeledContent("Access", value: permission.hasAccess ? "Granted to this copy" : "Not granted to this copy")
            HStack {
                Button("Request Access", action: permission.requestAccess)
                    .disabled(permission.hasAccess)
                Button("Test Access") { Task { await permission.testAccess() } }
                    .disabled(permission.isTesting)
                Button("Open System Settings", action: permission.openSystemSettings)
            }
            if permission.isTesting { ProgressView("Checking access…") }
            if let result = permission.testResult {
                Text(result).herdrFont(.caption).textSelection(.enabled)
            }
            DisclosureGroup("Identify this copy of Herdr") {
                Text(permission.applicationURL.path).textSelection(.enabled)
                Text(permission.signingDescription)
                Button("Reveal This Copy", action: permission.revealApplication)
            }
            .herdrFont(.caption)
        } header: {
            Text("Screen & System Audio Recording")
        } footer: {
            if permission.isAdHocSigned {
                Text("This app has a build-specific signing identity. Replacing it can leave an enabled permission attached to an older build. Remove that entry in System Settings, add this installed copy, and quit and reopen Herdr. Releases signed with a consistent certificate prevent this identity from changing on every update.")
            } else {
                Text("Grant access to the installed copy shown above, then quit and reopen Herdr. Screen recording permission belongs to the app doing the capture; an agent using a separate helper may need permission for that helper too.")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permission.refresh() }
        }
    }
}
