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
        XCTAssertTrue(app.staticTexts["Question 1 of 3"].exists)

        let buildMethod = app.buttons["Build from current branch (default)"]
        XCTAssertTrue(buildMethod.exists)
        XCTAssertEqual(buildMethod.value as? String, "Not selected")
        buildMethod.tap()
        XCTAssertEqual(buildMethod.value as? String, "Selected")
        attachScreenshot(named: "02-opencode-native-selected-choice", from: app)

        let firstNextButton = app.buttons["Next"]
        XCTAssertTrue(firstNextButton.isEnabled)
        firstNextButton.tap()
        XCTAssertTrue(app.staticTexts["Question 2 of 3"].waitForExistence(timeout: 2))

        let exportMethod = app.buttons["development (Recommended)"]
        XCTAssertTrue(exportMethod.exists)
        exportMethod.tap()
        XCTAssertEqual(exportMethod.value as? String, "Selected")
        attachScreenshot(named: "03-opencode-native-next-question", from: app)

        let secondNextButton = app.buttons["Next"]
        XCTAssertTrue(secondNextButton.isEnabled)
        secondNextButton.tap()
        XCTAssertTrue(app.staticTexts["Question 3 of 3"].waitForExistence(timeout: 2))

        let configuration = app.buttons["Debug (default)"]
        XCTAssertTrue(configuration.exists)
        configuration.tap()
        XCTAssertEqual(configuration.value as? String, "Selected")

        let reviewButton = app.buttons["Review answers"]
        XCTAssertTrue(reviewButton.isEnabled)
        reviewButton.tap()

        XCTAssertTrue(app.staticTexts["Review answers"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Build from current branch (default)"].exists)
        XCTAssertTrue(app.staticTexts["development (Recommended)"].exists)
        XCTAssertTrue(app.staticTexts["Debug (default)"].exists)
        XCTAssertTrue(app.buttons["Submit"].exists)
        XCTAssertTrue(app.buttons["Submit"].isHittable)
        attachScreenshot(named: "04-opencode-native-review-submit", from: app)

        launchDemoSession("demo-workspace-2|demo-surface-2", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode terminal · Manual controls"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Previous"].exists)
        XCTAssertTrue(app.buttons["Next"].exists)
        XCTAssertTrue(app.buttons["Confirm"].exists)
        XCTAssertTrue(app.buttons["Reject"].exists)
        attachScreenshot(named: "05-opencode-safe-tui-fallback", from: app)

        launchDemoSession("demo-workspace-3|demo-surface-3", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode question"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["OpenCode terminal · Remote questions"].exists)

        let fallbackDefault = app.buttons["Build from current branch (default)"]
        XCTAssertTrue(fallbackDefault.exists)
        XCTAssertEqual(fallbackDefault.value as? String, "Selected")

        let fallbackExistingIPA = app.buttons["Publish an existing IPA"]
        XCTAssertTrue(fallbackExistingIPA.exists)
        XCTAssertEqual(fallbackExistingIPA.value as? String, "Not selected")
        XCTAssertTrue(app.buttons["Export from existing archive"].exists)
        XCTAssertTrue(app.buttons["Type your own answer"].exists)

        fallbackExistingIPA.tap()
        XCTAssertEqual(fallbackDefault.value as? String, "Not selected")
        XCTAssertEqual(fallbackExistingIPA.value as? String, "Selected")
        XCTAssertTrue(app.buttons["Next"].exists)
        XCTAssertTrue(app.buttons["Next"].isHittable)
        attachScreenshot(named: "06-opencode-tui-question-selection", from: app)

        launchDemoSession("demo-workspace-4|demo-surface-4", in: app)
        XCTAssertTrue(app.staticTexts["Review answers"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Build method"].exists)
        XCTAssertTrue(app.staticTexts["Build from current branch (default)"].exists)
        XCTAssertTrue(app.staticTexts["Export method"].exists)
        XCTAssertTrue(app.staticTexts["development (Recommended)"].exists)
        XCTAssertTrue(app.staticTexts["Configuration"].exists)
        XCTAssertTrue(app.staticTexts["Debug (default)"].exists)
        XCTAssertTrue(app.buttons["Edit answers"].exists)
        XCTAssertTrue(app.buttons["Edit answers"].isHittable)
        XCTAssertTrue(app.buttons["Submit"].exists)
        XCTAssertTrue(app.buttons["Submit"].isHittable)
        attachScreenshot(named: "07-opencode-tui-review-submit", from: app)
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
