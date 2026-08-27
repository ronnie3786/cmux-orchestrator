import AppKit
import Foundation

@MainActor
enum CmuxApplicationActivator {
    static let bundleIdentifier = "com.cmuxterm.app"

    enum ActivationError: LocalizedError, Equatable {
        case applicationNotFound(bundleIdentifier: String)

        var errorDescription: String? {
            switch self {
            case let .applicationNotFound(bundleIdentifier):
                "cmux is not installed (bundle identifier: \(bundleIdentifier))"
            }
        }
    }

    static func activate() async throws {
        try await activate(
            resolveApplicationURL: { bundleIdentifier in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            },
            openApplication: { applicationURL, configuration in
                _ = try await NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                )
            }
        )
    }

    static func activate(
        resolveApplicationURL: @MainActor (String) -> URL?,
        openApplication: @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> Void
    ) async throws {
        guard let applicationURL = resolveApplicationURL(bundleIdentifier) else {
            throw ActivationError.applicationNotFound(bundleIdentifier: bundleIdentifier)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        try await openApplication(applicationURL, configuration)
    }
}
