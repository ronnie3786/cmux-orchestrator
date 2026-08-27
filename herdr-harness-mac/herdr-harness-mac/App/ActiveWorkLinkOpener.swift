import AppKit
import Foundation

@MainActor
enum ActiveWorkLinkOpener {
    static let buzzBundleIdentifier = "xyz.block.buzz.app"

    enum OpenError: LocalizedError {
        case invalidLink
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidLink:
                "This link is not a valid Buzz discussion or web address."
            case .unavailable:
                "This link couldn’t be opened. Make sure its app is installed on this Mac."
            }
        }
    }

    enum OpenRoute: Equatable {
        case defaultApplication
        case explicitBuzzApplication
        case rejected
        case unavailable
    }

    static func open(_ url: URL) async throws {
        let route = await open(
            url,
            resolveBuzzApplication: installedBuzzApplicationURL,
            openNormally: { NSWorkspace.shared.open($0) },
            openWithApplication: { urls, applicationURL, configuration in
                try await withCheckedThrowingContinuation { continuation in
                    NSWorkspace.shared.open(
                        urls,
                        withApplicationAt: applicationURL,
                        configuration: configuration
                    ) { _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        )

        switch route {
        case .defaultApplication, .explicitBuzzApplication:
            return
        case .rejected:
            throw OpenError.invalidLink
        case .unavailable:
            throw OpenError.unavailable
        }
    }

    @discardableResult
    static func open(
        _ url: URL,
        resolveBuzzApplication: @MainActor () -> URL?,
        openNormally: @MainActor (URL) -> Bool,
        openWithApplication: @MainActor ([URL], URL, NSWorkspace.OpenConfiguration) async throws -> Void
    ) async -> OpenRoute {
        guard ActiveWorkURL.isOpenable(url) else { return .rejected }

        guard ActiveWorkURL.isBuzzMessageURL(url) else {
            return openNormally(url) ? .defaultApplication : .unavailable
        }

        guard let applicationURL = resolveBuzzApplication() else { return .unavailable }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        do {
            try await openWithApplication([url], applicationURL, configuration)
            return .explicitBuzzApplication
        } catch {
            return .unavailable
        }
    }

    private static func installedBuzzApplicationURL() -> URL? {
        let runningApplications = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        let fixedInstallations = [
            URL(fileURLWithPath: "/Applications/Buzz.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/Buzz.app", directoryHint: .isDirectory),
        ]
        let registeredInstallation = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: buzzBundleIdentifier
        )
        return (runningApplications + fixedInstallations + [registeredInstallation].compactMap { $0 })
            .first(where: isDesktopBuzzApplication)
    }

    private static func isDesktopBuzzApplication(_ applicationURL: URL) -> Bool {
        guard let bundle = Bundle(url: applicationURL) else { return false }
        return bundle.bundleIdentifier == buzzBundleIdentifier
            && bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "buzz-desktop"
    }
}
