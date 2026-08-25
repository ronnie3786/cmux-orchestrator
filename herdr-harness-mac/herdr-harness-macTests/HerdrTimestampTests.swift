import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr timestamps")
struct HerdrTimestampTests {
    @Test("Parses timestamps with and without fractional seconds")
    func parsesBackendTimestamps() {
        #expect(HerdrTimestamp.date(from: "2026-08-25T12:34:56Z") != nil)
        #expect(HerdrTimestamp.date(from: "2026-08-25T12:34:56.123456Z") != nil)
        #expect(HerdrTimestamp.date(from: "not-a-date") == nil)
    }

    @Test("Formats compact and spoken elapsed ages")
    func formatsElapsedAges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-30), now: now) == "now")
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-22 * 60), now: now) == "22m")
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-3 * 3_600), now: now) == "3h")
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-8 * 86_400), now: now) == "8d")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-60), now: now) == "1 minute ago")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-2 * 86_400), now: now) == "2 days ago")
    }
}
