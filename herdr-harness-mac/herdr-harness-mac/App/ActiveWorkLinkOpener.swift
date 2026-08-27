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
            resolveDefaultApplication: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
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
        resolveDefaultApplication: @MainActor (URL) -> URL?,
        resolveBuzzApplication: @MainActor () -> URL?,
        openNormally: @MainActor (URL) -> Bool,
        openWithApplication: @MainActor ([URL], URL, NSWorkspace.OpenConfiguration) async throws -> Void
    ) async -> OpenRoute {
        guard ActiveWorkURL.isOpenable(url) else { return .rejected }

        guard ActiveWorkURL.isBuzzMessageURL(url) else {
            return openNormally(url) ? .defaultApplication : .unavailable
        }

        if resolveDefaultApplication(url) != nil, openNormally(url) {
            return .defaultApplication
        }

        guard let applicationURL = resolveBuzzApplication() else {
            return openNormally(url) ? .defaultApplication : .unavailable
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            try await openWithApplication([url], applicationURL, configuration)
            return .explicitBuzzApplication
        } catch {
            return .unavailable
        }
    }

    private static func installedBuzzApplicationURL() -> URL? {
        if let registeredURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: buzzBundleIdentifier
        ) {
            return registeredURL
        }

        let candidates = [
            URL(fileURLWithPath: "/Applications/Buzz.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/Buzz.app", directoryHint: .isDirectory),
        ]
        return candidates.first { candidate in
            Bundle(url: candidate)?.bundleIdentifier == buzzBundleIdentifier
        }
    }
}
