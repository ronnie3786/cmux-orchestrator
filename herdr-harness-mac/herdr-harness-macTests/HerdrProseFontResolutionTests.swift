import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("Herdr prose Inter font bundling")
struct HerdrProseFontResolutionTests {
    @Test("Inter-Regular resolves from the app bundle")
    func interRegularResolves() {
        #expect(HerdrProse.isInterRegularAvailable())
    }

    @Test(
        "All Inter faces referenced by HerdrProse resolve",
        arguments: ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold", "Inter-Italic"]
    )
    func allInterFacesResolve(postScriptName: String) throws {
        let font = try #require(NSFont(name: postScriptName, size: 15))
        #expect(font.fontName == postScriptName)
    }
}
