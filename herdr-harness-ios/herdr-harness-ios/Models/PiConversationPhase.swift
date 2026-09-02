import Foundation

enum PiConversationPhase: String, Equatable, Sendable {
    case idle
    case working
    case failed
}

enum PiCompactionReason: String, Equatable, Sendable {
    case manual
    case threshold
    case overflow
    case unknown
}

/// Context compaction is orthogonal to an agent turn. Pi can compact while its
/// public extension context still reports idle, or between an overflowed turn
/// and its retry, so folding this into `PiConversationPhase` loses information.
struct PiCompactionActivity: Equatable, Sendable {
    let reason: PiCompactionReason
    let willRetry: Bool

    init(reason: PiCompactionReason, willRetry: Bool) {
        self.reason = reason
        self.willRetry = willRetry
    }

    init(event: PiJSONValue) {
        reason = PiCompactionReason(rawValue: event.string(for: "reason") ?? "") ?? .unknown
        willRetry = event.bool(for: "willRetry", "will_retry") ?? false
    }

    init?(snapshotState state: PiJSONValue?) {
        let details = state?["compaction"]
        let active = state?.bool(for: "isCompacting", "is_compacting")
            ?? details?.bool(for: "active")
            ?? false
        guard active else { return nil }
        reason = PiCompactionReason(
            rawValue: details?.string(for: "reason") ?? state?.string(for: "compactionReason") ?? ""
        ) ?? .unknown
        willRetry = details?.bool(for: "willRetry", "will_retry")
            ?? state?.bool(for: "compactionWillRetry", "compaction_will_retry")
            ?? false
    }

    var statusMessage: String {
        switch reason {
        case .manual, .unknown:
            "Compacting context…"
        case .threshold:
            "Compacting context automatically…"
        case .overflow where willRetry:
            "Compacting context after overflow, then retrying…"
        case .overflow:
            "Compacting context after overflow…"
        }
    }
}
