import XCTest

final class HerdrQuickVoiceUITests: HerdrUITestCase {
    @MainActor
    func testMicrophoneIsAttachedAndOpensItsOwnReceipt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrResetSidebarState", "-herdr.hud.enabled", "YES", "-herdr.quickVoice.enabled", "YES"]
        app.launch()
        let mic = app.control(identifier: "quick-voice-microphone")
        let orb = app.control(identifier: "hud-orb")
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        XCTAssertTrue(orb.exists)
        XCTAssertGreaterThan(mic.frame.midX, orb.frame.midX)
        XCTAssertGreaterThan(mic.frame.midY, orb.frame.midY)
        XCTAssertLessThan(mic.frame.midX - orb.frame.midX, 40)
        XCTAssertLessThan(mic.frame.midY - orb.frame.midY, 40)

        let initialOrb = orb.frame
        mic.click()
        let card = app.control(identifier: "quick-voice-request-card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(orb.exists, "Voice capture must leave the orb visible instead of opening the chat HUD")
        XCTAssertEqual(orb.frame.maxX, initialOrb.maxX, accuracy: 2)
        XCTAssertEqual(orb.frame.minY, initialOrb.minY, accuracy: 2)
        // Demo mode never requests microphone permission or sends a prompt.
        XCTAssertTrue(app.text(containing: "What do you need done?").exists)
        app.control(named: "Close voice request").click()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertTrue(mic.exists)

        orb.click()
        XCTAssertTrue(orb.waitForNonExistence(timeout: 5), "Clicking the orb still opens the normal chat HUD")
        XCTAssertFalse(card.exists)
        app.terminate()
    }
}
