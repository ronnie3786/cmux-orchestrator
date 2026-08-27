import AppKit
import Foundation

@MainActor
enum PanePathOpener {
    enum OpenError: LocalizedError, Equatable {
        case invalidPath
        case finderRejected(path: String)

        var errorDescription: String? {
            switch self {
            case .invalidPath:
                "This session does not have a valid local folder path."
            case let .finderRejected(path):
                "Finder couldn’t open \(path). Make sure the folder exists and its volume is mounted."
            }
        }
    }

    static func open(path: String) async throws {
        try await open(path: path) { url, configuration in
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        }
    }

    static func open(
        path: String,
        openURL: @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> Void
    ) async throws {
        let url = try folderURL(for: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        do {
            try await openURL(url, configuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenError.finderRejected(path: url.path(percentEncoded: false))
        }
    }

    static func folderURL(for path: String) throws -> URL {
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\0") else {
            throw OpenError.invalidPath
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
