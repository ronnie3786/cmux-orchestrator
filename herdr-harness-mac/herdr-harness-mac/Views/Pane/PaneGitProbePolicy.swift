import Foundation

enum PaneGitAvailability: Equatable {
    case checking
    case available
    case unavailable
}

enum PaneGitProbeResult: Equatable {
    case status(ok: Bool, rootPath: String?)
    case notFound
    case transientFailure
}

enum PaneGitProbePolicy {
    static let refreshInterval: Duration = .seconds(15)

    static func availability(
        after result: PaneGitProbeResult,
        preserving current: PaneGitAvailability
    ) -> PaneGitAvailability {
        switch result {
        case let .status(ok, rootPath):
            let normalizedRoot = rootPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ok && !normalizedRoot.isEmpty ? .available : .unavailable
        case .notFound:
            return .unavailable
        case .transientFailure:
            return current
        }
    }
}
