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

    @Test("Stream counters can be reset directly when a consumer tears down mid-stream")
    func streamBacklogResetsOnTeardown() {
        let backlog = HerdrPerfDiagnostics.StreamBacklog()
        backlog.noteYielded(.pi)
        backlog.noteYielded(.pi)
        #expect(backlog.current(.pi) == 2)
        backlog.reset(.pi)
        #expect(backlog.current(.pi) == 0)
    }

    @Test("The process footprint is available")
    func footprint() {
        #expect(HerdrPerfDiagnostics.currentFootprintMB() > 0)
    }

    @Test("Checkpoint ring preserves newest 64 entries in order")
    func checkpointRing() {
        let names: [StaticString] = [
            "stage1.ring.00", "stage1.ring.01", "stage1.ring.02", "stage1.ring.03", "stage1.ring.04",
            "stage1.ring.05", "stage1.ring.06", "stage1.ring.07", "stage1.ring.08", "stage1.ring.09",
            "stage1.ring.10", "stage1.ring.11", "stage1.ring.12", "stage1.ring.13", "stage1.ring.14",
            "stage1.ring.15", "stage1.ring.16", "stage1.ring.17", "stage1.ring.18", "stage1.ring.19",
            "stage1.ring.20", "stage1.ring.21", "stage1.ring.22", "stage1.ring.23", "stage1.ring.24",
            "stage1.ring.25", "stage1.ring.26", "stage1.ring.27", "stage1.ring.28", "stage1.ring.29",
            "stage1.ring.30", "stage1.ring.31", "stage1.ring.32", "stage1.ring.33", "stage1.ring.34",
            "stage1.ring.35", "stage1.ring.36", "stage1.ring.37", "stage1.ring.38", "stage1.ring.39",
            "stage1.ring.40", "stage1.ring.41", "stage1.ring.42", "stage1.ring.43", "stage1.ring.44",
            "stage1.ring.45", "stage1.ring.46", "stage1.ring.47", "stage1.ring.48", "stage1.ring.49",
            "stage1.ring.50", "stage1.ring.51", "stage1.ring.52", "stage1.ring.53", "stage1.ring.54",
            "stage1.ring.55", "stage1.ring.56", "stage1.ring.57", "stage1.ring.58", "stage1.ring.59",
            "stage1.ring.60", "stage1.ring.61", "stage1.ring.62", "stage1.ring.63", "stage1.ring.64",
            "stage1.ring.65", "stage1.ring.66", "stage1.ring.67", "stage1.ring.68", "stage1.ring.69"
        ]
        for name in names {
            HerdrPerfDiagnostics.checkpoint(name)
        }

        let snapshots = HerdrPerfDiagnostics.checkpointRingSnapshot(now: ContinuousClock().now)
            .filter { $0.name.hasPrefix("stage1.ring.") }
        let expectedNames = names.suffix(64).map(String.init(describing:))

        #expect(snapshots.count == 64)
        #expect(snapshots.map(\.name) == expectedNames)
        #expect(snapshots.last?.name == "stage1.ring.69")
        #expect(snapshots.allSatisfy { $0.age >= .zero })
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.0.age >= $0.1.age })
    }

    @Test("Current thread capture walks and symbolicates real frames")
    func currentThreadBacktrace() throws {
        #if arch(arm64)
        let sample = HerdrPerfDiagnostics.captureCurrentThreadSample()
        let result = try #require(sample)
        #expect(result.frames.count > 3)
        #expect(result.frames.contains { $0.symbolName != nil })
        #endif
    }
}
