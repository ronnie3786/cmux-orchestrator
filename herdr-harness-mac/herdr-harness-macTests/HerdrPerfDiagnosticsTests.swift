import Testing
@testable import herdr_harness_mac

@Suite("Herdr performance diagnostics")
struct HerdrPerfDiagnosticsTests {
    @Test("Stall duration only reports unanswered pings")
    func stallDuration() {
        let clock = ContinuousClock()
        let sentAt = clock.now
        let now = sentAt.advanced(by: .seconds(3))

        #expect(HerdrPerfDiagnostics.stallDuration(now: now, pingSentAt: sentAt, acked: true) == nil)
        #expect(HerdrPerfDiagnostics.stallDuration(now: now, pingSentAt: nil, acked: false) == nil)
        #expect(HerdrPerfDiagnostics.stallDuration(now: now, pingSentAt: sentAt, acked: false) == .seconds(3))
    }

    @Test("Stream counters never become negative and reset after overflow")
    func streamBacklog() {
        let backlog = HerdrPerfDiagnostics.StreamBacklog()
        backlog.noteConsumed(.terminal)
        #expect(backlog.current(.terminal) == 0)
        backlog.noteYielded(.terminal)
        backlog.noteYielded(.terminal)
        #expect(backlog.current(.terminal) == 2)
        backlog.noteOverflow(.terminal)
        #expect(backlog.current(.terminal) == 0)
    }

    @Test("The process footprint is available")
    func footprint() {
        #expect(HerdrPerfDiagnostics.currentFootprintMB() > 0)
    }
}
