import Testing
@testable import herdr_harness_mac

@Suite("Terminal frame coalescer")
struct TerminalFrameCoalescerTests {
    @Test("The first frame commits immediately")
    func firstFrameCommitsImmediately() {
        let clock = ContinuousClock()
        var coalescer = TerminalFrameCoalescer()

        let decision = coalescer.register(now: clock.now)
        #expect(decision == .commitNow)
    }

    @Test("Fast frames retain the first commit deadline")
    func fastFrameDefersToWindowDeadline() {
        let clock = ContinuousClock()
        let first = clock.now
        var coalescer = TerminalFrameCoalescer()

        let firstDecision = coalescer.register(now: first)
        #expect(firstDecision == .commitNow)
        let deferredDecision = coalescer.register(now: first.advanced(by: .milliseconds(10)))
        #expect(
            deferredDecision == .defer(deadline: first.advanced(by: .milliseconds(50)))
        )
        let laterDecision = coalescer.register(now: first.advanced(by: .milliseconds(60)))
        #expect(laterDecision == .commitNow)
    }

    @Test("A deferred commit restarts the window")
    func markCommittedRestartsWindow() {
        let clock = ContinuousClock()
        let first = clock.now
        var coalescer = TerminalFrameCoalescer()

        #expect(coalescer.window == .milliseconds(50))
        _ = coalescer.register(now: first)
        coalescer.markCommitted(now: first.advanced(by: .milliseconds(30)))
        let decision = coalescer.register(now: first.advanced(by: .milliseconds(40)))
        #expect(decision == .defer(deadline: first.advanced(by: .milliseconds(80))))
    }
}
