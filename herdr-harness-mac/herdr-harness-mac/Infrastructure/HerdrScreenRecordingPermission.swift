import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit
import Security

/// Only an explicit user action requests access. Opening Settings never raises a TCC prompt.
@MainActor
@Observable
final class HerdrScreenRecordingPermission {
    private(set) var hasAccess = false
    private(set) var isTesting = false
    private(set) var testResult: String?
    let applicationURL = Bundle.main.bundleURL
    let signingDescription: String
    let isAdHocSigned: Bool

    init() {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            _ = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        }
        let info = information as? [String: Any] ?? [:]
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        isAdHocSigned = flags & 0x2 != 0
        if isAdHocSigned {
            signingDescription = "Ad-hoc signed (identity changes with each build)"
        } else if let team = info[kSecCodeInfoTeamIdentifier as String] as? String {
            signingDescription = "Signed by team \(team)"
        } else {
            signingDescription = "No Apple team identity"
        }
        refresh()
    }

    func refresh() {
        hasAccess = CGPreflightScreenCaptureAccess()
    }

    func requestAccess() {
        hasAccess = CGRequestScreenCaptureAccess()
        testResult = hasAccess
            ? "Access granted. Use Test Access to verify this running copy."
            : "Enable this copy of Herdr in System Settings, then quit and reopen it."
    }

    func testAccess() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        // A preflight avoids turning a diagnostic into an unexpected permission prompt.
        refresh()
        guard hasAccess else {
            testResult = "This running copy does not have access. If the toggle is already on, quit Herdr, remove the stale entry, add this copy, and reopen it."
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            testResult = "Access verified: \(content.displays.count) display(s) available. No screen or audio was recorded."
        } catch {
            testResult = "macOS could not verify access: \(error.localizedDescription). Quit and reopen this copy after changing the permission."
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
    }
}
