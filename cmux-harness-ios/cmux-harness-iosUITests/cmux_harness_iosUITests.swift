//
//  cmux_harness_iosUITests.swift
//  cmux-harness-iosUITests
//
//  Created by Ronnie Rocha on 4/26/26.
//

import XCTest

final class cmux_harness_iosUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testOpenCodeInteractionProofScreenshots() throws {
        let app = XCUIApplication()

        launchDemoSession("demo-workspace-0|demo-surface-0", in: app)
        XCTAssertTrue(app.staticTexts["Permission required"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Allow once"].exists)
        XCTAssertTrue(app.buttons["Always allow"].exists)
        XCTAssertTrue(app.buttons["Reject"].exists)
        attachScreenshot(named: "01-opencode-native-permission", from: app)

        launchDemoSession("demo-workspace-1|demo-surface-1", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode question"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Staging"].exists)
        XCTAssertTrue(app.buttons["Production"].exists)
        attachScreenshot(named: "02-opencode-native-question", from: app)

        launchDemoSession("demo-workspace-2|demo-surface-2", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode terminal · Manual controls"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Previous"].exists)
        XCTAssertTrue(app.buttons["Next"].exists)
        XCTAssertTrue(app.buttons["Confirm"].exists)
        XCTAssertTrue(app.buttons["Reject"].exists)
        attachScreenshot(named: "03-opencode-safe-tui-fallback", from: app)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func launchDemoSession(_ workspaceID: String, in app: XCUIApplication) {
        app.terminate()
        app.launchArguments = [
            "-cmuxHarnessLocalDemoMode", "YES",
            "-cmuxHarnessLastSelectedWorkspaceID", workspaceID,
            "-cmuxHarnessSuppressNotificationPrompt",
        ]
        app.launch()
    }

    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
