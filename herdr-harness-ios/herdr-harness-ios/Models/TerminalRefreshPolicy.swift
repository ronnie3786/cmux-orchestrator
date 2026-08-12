import Foundation

enum TerminalRefreshPolicy {
    static let streamSilenceLimit: TimeInterval = 25

    static func shouldDisplaySnapshot(
        force: Bool,
        streamAdvancedDuringRequest: Bool,
        snapshotChangedWithoutFrame: Bool,
        lastStreamActivityAt: Date?,
        now: Date = .now
    ) -> Bool {
        if streamAdvancedDuringRequest { return false }
        if force { return true }
        if snapshotChangedWithoutFrame { return true }
        return isStreamStale(lastStreamActivityAt: lastStreamActivityAt, now: now)
    }

    static func isStreamStale(
        lastStreamActivityAt: Date?,
        now: Date = .now
    ) -> Bool {
        guard let lastStreamActivityAt else { return true }
        return now.timeIntervalSince(lastStreamActivityAt) >= streamSilenceLimit
    }
}
