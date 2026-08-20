/// Coalesces publication requests after the reducer has synchronously applied
/// each stream envelope. It never delays reducer state changes, only the
/// store's publication of that already-applied state.
///
/// `ContinuousClock` keeps the window monotonic and independent of wall-clock
/// or timezone changes, while allowing deterministic instant arithmetic in
/// tests without timers or real sleeping.
struct PiStreamCoalescer: Sendable {
    enum Trigger: Sendable, Equatable {
        case delta
        case phaseTransition
        case pendingInteraction
        case turnBoundary
        case turnCompletion
        case streamReset
        case connectionChange

        var bypassesWindow: Bool {
            switch self {
            case .delta:
                false
            case .phaseTransition, .pendingInteraction, .turnBoundary,
                 .turnCompletion, .streamReset, .connectionChange:
                true
            }
        }
    }

    enum Decision: Sendable, Equatable {
        case flushNow
        case coalesce(deadline: ContinuousClock.Instant)
    }

    let window: Duration
    private var windowOpenedAt: ContinuousClock.Instant?

    init(window: Duration = .milliseconds(120)) {
        self.window = window
    }

    mutating func register(_ trigger: Trigger, now: ContinuousClock.Instant) -> Decision {
        if trigger.bypassesWindow {
            windowOpenedAt = nil
            return .flushNow
        }

        guard let openedAt = windowOpenedAt else {
            windowOpenedAt = now
            return .coalesce(deadline: now.advanced(by: window))
        }

        let deadline = openedAt.advanced(by: window)
        if now >= deadline {
            windowOpenedAt = nil
            return .flushNow
        }
        return .coalesce(deadline: deadline)
    }

    mutating func markFlushed() {
        windowOpenedAt = nil
    }
}
