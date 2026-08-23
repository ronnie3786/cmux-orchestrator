/// Limits terminal UI commits while retaining the most recent applied frame.
///
/// `ContinuousClock` keeps the window monotonic, so a wall-clock adjustment
/// cannot make a busy terminal publish a burst of stale frames.
struct TerminalFrameCoalescer: Sendable {
    enum Decision: Sendable, Equatable {
        case commitNow
        case `defer`(deadline: ContinuousClock.Instant)
    }

    let window: Duration
    private var lastCommitAt: ContinuousClock.Instant?

    init(window: Duration = .milliseconds(50)) {
        self.window = window
    }

    mutating func register(now: ContinuousClock.Instant) -> Decision {
        guard let lastCommitAt else {
            self.lastCommitAt = now
            return .commitNow
        }
        guard lastCommitAt.duration(to: now) < window else {
            self.lastCommitAt = now
            return .commitNow
        }
        return .defer(deadline: lastCommitAt.advanced(by: window))
    }

    mutating func markCommitted(now: ContinuousClock.Instant) {
        lastCommitAt = now
    }
}
