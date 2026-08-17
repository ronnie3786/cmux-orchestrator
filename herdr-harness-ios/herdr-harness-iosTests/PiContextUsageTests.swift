import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Pi context usage")
struct PiContextUsageTests {
    @Test("Summary compacts token counts")
    func summaryCompactsTokenCounts() throws {
        let usage = PiContextUsage(
            from: .object([
                "tokens": .number(12_345),
                "contextWindow": .number(192_000),
                "percent": .number(6.43),
            ])
        )
        #expect(usage?.summary == "12.3k / 192k")
        #expect(usage?.percentText == "6%")
        #expect(usage?.fraction == (12_345.0 / 192_000))
    }

    @Test("All-null usage decodes as unknown")
    func allNullUsageIsUnknown() {
        let usage = PiContextUsage(
            from: .object([
                "tokens": .null,
                "contextWindow": .null,
                "percent": .null,
            ])
        )
        #expect(usage == nil)
    }

    @Test("Percent-only usage still yields a fraction")
    func percentOnlyUsage() {
        let usage = PiContextUsage(
            from: .object(["percent": .number(87)])
        )
        #expect(usage?.fraction == 0.87)
        #expect(usage?.percentText == "87%")
        #expect(usage?.summary == nil)
    }
}
