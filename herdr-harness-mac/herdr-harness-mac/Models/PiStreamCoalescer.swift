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
        case compactionChange
        case pendingInteraction
        case turnBoundary
        case turnCompletion
        case streamReset
        case connectionChange

        var bypassesWindow: Bool {
            switch self {
            case .delta:
                false
            case .phaseTransition, .compactionChange, .pendingInteraction, .turnBoundary,
                 .turnCompletion, .streamReset, .connectionChange:
                true
            }
        }
    }

    enum Decision: Sendable, Equatable {
        case flushNow
        case coalesce(deadline: ContinuousClock.Instant)
    }

    /// The window deltas coalesce into when the main thread is keeping up.
    let baseWindow: Duration
    /// The window in force right now. Grows (up to `maxWindow`) while flushes
    /// run late — the main thread is behind on layout — and shrinks back once
    /// they run on time, so a saturated UI publishes fewer, larger batches
    /// instead of queueing a layout pass per token.
    private(set) var window: Duration
    static let maxWindow: Duration = .seconds(1)
    /// A flush this late means the main actor could not even run the flush
    /// task on time; it is busy in layout, so the next window doubles.
    static let latenessThreshold: Duration = .milliseconds(80)
    private var windowOpenedAt: ContinuousClock.Instant?

    init(window: Duration = .milliseconds(120)) {
        self.baseWindow = window
        self.window = window
    }

    /// Feed how late a coalesced flush actually ran relative to its deadline.
    mutating func noteFlushLateness(_ lateness: Duration) {
        if lateness > Self.latenessThreshold {
            window = min(window * 2, Self.maxWindow)
        } else if lateness < Self.latenessThreshold / 4 {
            window = max(window / 2, baseWindow)
        }
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
