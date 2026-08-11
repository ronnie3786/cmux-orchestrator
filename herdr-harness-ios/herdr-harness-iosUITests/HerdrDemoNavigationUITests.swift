import XCTest

final class HerdrDemoNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDrillsFromWorkspaceToPaneToLiveSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()

        let workspace = app.buttons["iOS Doximity, Needs you, 3 panes"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 8), "The ranked workspace deck should appear in demo mode")
        XCTAssertTrue(app.staticTexts["Demo data is active"].exists)
        workspace.tap()

        XCTAssertTrue(app.navigationBars["iOS Doximity"].waitForExistence(timeout: 3))
        let blockedPane = app.buttons["Auth reducer review, Claude, Needs you"]
        XCTAssertTrue(blockedPane.waitForExistence(timeout: 3), "The blocked pane should be promoted to the top of the list")
        blockedPane.tap()

        XCTAssertTrue(app.navigationBars["Auth reducer review"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["Message Claude"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pause follow"].exists)
        XCTAssertTrue(app.buttons["Yes, proceed"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Herdr demo pane session"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
