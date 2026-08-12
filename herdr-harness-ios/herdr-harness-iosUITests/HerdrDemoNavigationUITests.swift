import XCTest

final class HerdrDemoNavigationUITests: XCTestCase {
    private let screenshotDirectory = URL(fileURLWithPath: "/tmp/herdr-ios-goal-screens", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(
            at: screenshotDirectory,
            withIntermediateDirectories: true
        )
    }

    @MainActor
    func testFullScreenPaneModesAndExpandableControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()

        let workspace = app.buttons["iOS Doximity, Needs you, 3 panes"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 8), "The workspace switcher should appear in demo mode")
        workspace.tap()

        let blockedPane = app.buttons["Auth reducer review, Claude, Needs you"]
        XCTAssertTrue(blockedPane.waitForExistence(timeout: 3))
        blockedPane.tap()

        XCTAssertTrue(app.navigationBars["Auth reducer review"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["prompt-composer"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Pane detail should hide the app tab bar")
        XCTAssertFalse(app.buttons["Yes, proceed"].exists, "Canned response chips should not consume pane space")

        for key in ["up", "down", "tab", "enter"] {
            XCTAssertTrue(app.buttons["terminal-key-\(key)"].exists)
        }
        XCTAssertFalse(app.buttons["terminal-key-left"].exists)
        try saveScreenshot("01-terminal-collapsed", app: app)

        app.buttons["terminal-controls-toggle"].tap()
        XCTAssertTrue(app.buttons["terminal-key-left"].waitForExistence(timeout: 2))
        for key in ["left", "right", "escape", "backspace"] {
            XCTAssertTrue(app.buttons["terminal-key-\(key)"].exists)
        }
        try saveScreenshot("02-terminal-expanded", app: app)

        try selectPaneMode("Git", app: app)
        XCTAssertTrue(app.staticTexts["staged"].waitForExistence(timeout: 3))
        try saveScreenshot("03-git-status", app: app)

        let diffButton = app.buttons["View diff for herdr-harness-ios/Views/Pane/PaneSessionView.swift"]
        XCTAssertTrue(diffButton.waitForExistence(timeout: 2))
        diffButton.tap()
        XCTAssertTrue(app.navigationBars["herdr-harness-ios/Views/Pane/PaneSessionView.swift"].waitForExistence(timeout: 3))
        try saveScreenshot("04-git-diff", app: app)
        app.buttons["Done"].tap()

        try selectPaneMode("Skills", app: app)
        XCTAssertTrue(app.staticTexts["workspace skills"].waitForExistence(timeout: 3))
        try saveScreenshot("05-skills", app: app)

        try selectPaneMode("Terminal", app: app)
        app.buttons["terminal-controls-toggle"].tap()
        XCTAssertTrue(app.buttons["Insert a workspace file path"].waitForExistence(timeout: 2))

        app.buttons["Insert a workspace file path"].tap()
        let fileSearch = app.textFields["Search project files"]
        XCTAssertTrue(fileSearch.waitForExistence(timeout: 3))
        fileSearch.tap()
        fileSearch.typeText("Pane")
        XCTAssertTrue(app.buttons["Insert herdr-harness-ios/Views/Pane/PaneSessionView.swift"].waitForExistence(timeout: 3))
        try saveScreenshot("06-file-search", app: app)
        app.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["Insert Jira ticket context"].waitForExistence(timeout: 3))
        app.buttons["Insert Jira ticket context"].tap()
        XCTAssertTrue(app.navigationBars["JIRA CONTEXT"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["MOB-1842"].waitForExistence(timeout: 3))
        try saveScreenshot("07-jira-context", app: app)
        app.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["Record a voice note"].waitForExistence(timeout: 3))
        app.buttons["Record a voice note"].tap()
        XCTAssertTrue(app.navigationBars["VOICE NOTE"].waitForExistence(timeout: 3))
        try saveScreenshot("08-voice-note", app: app)
        app.buttons["Close"].tap()
    }

    @MainActor
    private func selectPaneMode(_ mode: String, app: XCUIApplication) throws {
        let menu = app.buttons["Pane actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let modeButton = app.buttons["\(mode) view"]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 2), "The pane menu should expose \(mode)")
        modeButton.tap()
    }

    @MainActor
    private func saveScreenshot(_ name: String, app: XCUIApplication) throws {
        let screenshot = app.screenshot()
        try screenshot.pngRepresentation.write(to: screenshotDirectory.appending(path: "\(name).png"))

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
