import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Pi session cost")
struct PiSessionCostTests {
    @Test("Decodes camel-case cost fields")
    func decodesCamelCaseFields() {
        let cost = PiSessionCost(
            from: .object([
                "totalUSD": .number(1.25),
                "totalTokens": .number(4_200),
            ])
        )

        #expect(cost?.totalUSD == 1.25)
        #expect(cost?.totalTokens == 4_200)
    }

    @Test("Decodes snake-case cost fields")
    func decodesSnakeCaseFields() {
        let cost = PiSessionCost(
            from: .object([
                "total_usd": .number(2.5),
                "total_tokens": .number(8_400),
            ])
        )

        #expect(cost?.totalUSD == 2.5)
        #expect(cost?.totalTokens == 8_400)
    }

    @Test("Nil input decodes as unknown cost")
    func nilInputIsUnknown() {
        #expect(PiSessionCost(from: nil) == nil)
    }

    @Test("Absent cost fields decode as unknown")
    func absentFieldsAreUnknown() {
        #expect(PiSessionCost(from: .object([:])) == nil)
    }

    @Test("All-null cost fields decode as unknown")
    func allNullFieldsAreUnknown() {
        #expect(PiSessionCost(
            from: .object([
                "totalUSD": .null,
                "totalTokens": .null,
            ])
        ) == nil)
    }

    @Test("Zero cost displays with cents")
    func zeroSummary() {
        #expect(PiSessionCost(from: .object(["totalUSD": .number(0)]))?.summary == "$0.00")
    }

    @Test("Tiny non-zero cost displays below one cent")
    func tinySummary() {
        #expect(PiSessionCost(from: .object(["totalUSD": .number(0.004)]))?.summary == "<$0.01")
    }

    @Test("Sub-ten-dollar cost displays with cents")
    func subTenDollarSummary() {
        #expect(PiSessionCost(from: .object(["totalUSD": .number(0.42)]))?.summary == "$0.42")
        #expect(PiSessionCost(from: .object(["totalUSD": .number(9.994)]))?.summary == "$9.99")
    }

    @Test("Ten-dollar cost rounds to cents")
    func tenDollarSummary() {
        #expect(PiSessionCost(from: .object(["totalUSD": .number(12.345)]))?.summary == "$12.35")
    }

    @Test("Hundred-dollar cost drops cents")
    func hundredDollarSummary() {
        #expect(PiSessionCost(from: .object(["totalUSD": .number(134.2)]))?.summary == "$134")
    }
}
