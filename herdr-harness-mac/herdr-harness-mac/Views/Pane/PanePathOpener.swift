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
        try await open(path: path) { folderURLs in
            NSWorkspace.shared.activateFileViewerSelecting(folderURLs)
        }
    }

    static func open(
        path: String,
        revealInFinder: @MainActor ([URL]) throws -> Void
    ) async throws {
        let folderPath = try validatedPath(path)
        let folderURL = URL(filePath: folderPath, directoryHint: .isDirectory)

        do {
            try revealInFinder([folderURL])
        } catch where HerdrCancellation.isCancellation(error) {
            throw CancellationError()
        } catch {
            throw OpenError.finderRejected(path: folderPath)
        }
    }

    static func validatedPath(_ path: String) throws -> String {
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\0") else {
            throw OpenError.invalidPath
        }
        return path
    }
}
