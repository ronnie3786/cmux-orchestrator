import Testing

#if os(iOS)
@testable import herdr_harness_ios
#elseif os(macOS)
@testable import herdr_harness_mac
#endif

@Suite("Pi stream coalescer")
struct PiStreamCoalescerTests {
    @Test("Bypass triggers flush immediately and clear an open window")
    func bypassTriggersFlushAndClearWindow() {
        let clock = ContinuousClock()
        let now = clock.now
        let bypasses: [PiStreamCoalescer.Trigger] = [
            .phaseTransition,
            .pendingInteraction,
            .turnBoundary,
            .turnCompletion,
            .streamReset,
            .connectionChange,
        ]

        for trigger in bypasses {
            var coalescer = PiStreamCoalescer(window: .milliseconds(120))
            #expect(coalescer.register(trigger, now: now) == .flushNow)
            _ = coalescer.register(.delta, now: now)

            #expect(coalescer.register(trigger, now: now.advanced(by: .milliseconds(10))) == .flushNow)
            #expect(
                coalescer.register(.delta, now: now.advanced(by: .milliseconds(20)))
                    == .coalesce(deadline: now.advanced(by: .milliseconds(140)))
            )
        }
    }

    @Test("First delta opens a window")
    func firstDeltaOpensWindow() {
        let clock = ContinuousClock()
        let now = clock.now
        var coalescer = PiStreamCoalescer(window: .milliseconds(120))

        #expect(
            coalescer.register(.delta, now: now)
                == .coalesce(deadline: now.advanced(by: .milliseconds(120)))
        )
    }

    @Test("Rapid deltas retain the first deadline")
    func rapidDeltasRetainDeadline() {
        let clock = ContinuousClock()
        let now = clock.now
        let deadline = now.advanced(by: .milliseconds(120))
        var coalescer = PiStreamCoalescer(window: .milliseconds(120))

        #expect(coalescer.register(.delta, now: now) == .coalesce(deadline: deadline))
        #expect(
            coalescer.register(.delta, now: now.advanced(by: .milliseconds(10)))
                == .coalesce(deadline: deadline)
        )
        #expect(
            coalescer.register(.delta, now: now.advanced(by: .milliseconds(110)))
                == .coalesce(deadline: deadline)
        )
    }

    @Test("Delta at a deadline flushes and the next delta opens another window")
    func deltaAtDeadlineFlushesAndReopensWindow() {
        let clock = ContinuousClock()
        let now = clock.now
        var coalescer = PiStreamCoalescer(window: .milliseconds(120))

        _ = coalescer.register(.delta, now: now)
        #expect(coalescer.register(.delta, now: now.advanced(by: .milliseconds(120))) == .flushNow)
        #expect(
            coalescer.register(.delta, now: now.advanced(by: .milliseconds(130)))
                == .coalesce(deadline: now.advanced(by: .milliseconds(250)))
        )
    }

    @Test("Continuous deltas cannot be coalesced longer than one window")
    func continuousDeltasRespectMaximumLatency() {
        let clock = ContinuousClock()
        let now = clock.now
        let window: Duration = .milliseconds(120)
        var coalescer = PiStreamCoalescer(window: window)

        // Independently tracks (outside the coalescer's own internal state) how
        // long the oldest not-yet-published delta has been waiting, so this test
        // verifies the coalescer's real guarantee: no single delta is ever held
        // longer than `window` from its own arrival, rather than the gap between
        // successive flush timestamps, which can legitimately exceed `window` if
        // there is simply an idle gap with no incoming deltas.
        var oldestPendingArrival: ContinuousClock.Instant?

        for milliseconds in stride(from: 0, through: 600, by: 10) {
            let instant = now.advanced(by: .milliseconds(milliseconds))
            if oldestPendingArrival == nil {
                oldestPendingArrival = instant
            }
            if coalescer.register(.delta, now: instant) == .flushNow {
                if let oldestPendingArrival {
                    #expect(oldestPendingArrival.duration(to: instant) <= window)
                }
                oldestPendingArrival = nil
            }
        }
    }
}
