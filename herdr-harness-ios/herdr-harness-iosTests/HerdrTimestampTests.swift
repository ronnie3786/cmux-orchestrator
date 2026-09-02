import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Herdr timestamp")
struct HerdrTimestampTests {
    private let now = Date(timeIntervalSince1970: 1_735_732_800)

    @Test("Compact ages round down at every unit boundary")
    func compactAgeBoundaries() {
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-59), now: now) == "now")
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-60), now: now) == "1m")
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-59 * 60), now: now) == "59m")
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-60 * 60), now: now) == "1h")
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-23 * 3_600), now: now) == "23h")
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(-24 * 3_600), now: now) == "1d")
    }

    /// A pane whose `workingSince` is a few seconds ahead of the phone's clock
    /// should read `now`, not a negative age.
    @Test("A future timestamp clamps to now")
    func compactAgeClampsFutureTimestamps() {
        #expect(HerdrTimestamp.compactAge(since: now.addingTimeInterval(30), now: now) == "now")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(30), now: now) == "just now")
    }

    @Test("Spoken ages pluralise only past one unit")
    func spokenAgePluralisation() {
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-60), now: now) == "1 minute ago")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-120), now: now) == "2 minutes ago")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-3_600), now: now) == "1 hour ago")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-2 * 3_600), now: now) == "2 hours ago")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-24 * 3_600), now: now) == "1 day ago")
        #expect(HerdrTimestamp.spokenAge(since: now.addingTimeInterval(-48 * 3_600), now: now) == "2 days ago")
    }

    @Test("Parses ISO8601 with and without fractional seconds")
    func parsesBothISO8601Shapes() throws {
        let plain = try #require(HerdrTimestamp.date(from: "2026-08-11T14:42:00Z"))
        let fractional = try #require(HerdrTimestamp.date(from: "2026-08-11T14:42:00.123Z"))

        #expect(abs(fractional.timeIntervalSince(plain) - 0.123) < 0.001)
        #expect(HerdrTimestamp.string(from: plain) == "2026-08-11T14:42:00Z")
        #expect(HerdrTimestamp.date(from: "not a date") == nil)
    }
}
