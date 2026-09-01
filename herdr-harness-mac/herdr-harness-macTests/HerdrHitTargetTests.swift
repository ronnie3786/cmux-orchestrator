import Testing
@testable import herdr_harness_mac

@Suite("Herdr hit targets")
struct HerdrHitTargetTests {
    @Test("Minimum target aligns with compact control chrome")
    func minimumHitTargetMatchesCompactControlChrome() {
        #expect(HerdrTheme.minHitTarget == 28)
        #expect(HerdrTheme.minHitTarget >= PiChatChrome.controlHeight - 2)
    }
}
