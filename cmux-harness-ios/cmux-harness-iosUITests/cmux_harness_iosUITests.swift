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
        let nativePermissionSheet = interactionSheet(in: app)
        XCTAssertTrue(nativePermissionSheet.exists)

        let nativeAllowOnce = app.buttons["Allow once"]
        let nativeAllowAlways = app.buttons["Allow always"]
        let nativeReject = app.buttons["Reject"]
        XCTAssertTrue(nativeAllowOnce.exists)
        XCTAssertEqual(nativeAllowOnce.value as? String, "Selected")
        attachScreenshot(named: "01-opencode-native-permission-medium", from: app)

        let mediumHeight = stableHeight(of: nativePermissionSheet)
        nativePermissionSheet.swipeUp(velocity: .slow)
        XCTAssertTrue(waitForHeightIncrease(of: nativePermissionSheet, from: mediumHeight))
        XCTAssertTrue(makeHittable(nativeAllowAlways, byScrollingUpIn: nativePermissionSheet))
        nativeAllowAlways.tap()
        XCTAssertEqual(nativeAllowOnce.value as? String, "Not selected")
        XCTAssertEqual(nativeAllowAlways.value as? String, "Selected")
        XCTAssertTrue(makeHittable(nativeReject, byScrollingUpIn: nativePermissionSheet))
        XCTAssertTrue(makeHittable(app.buttons["Confirm"], byScrollingUpIn: nativePermissionSheet))
        attachScreenshot(named: "02-opencode-native-permission-expanded", from: app)

        launchDemoSession("demo-workspace-1|demo-surface-1", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode question"].waitForExistence(timeout: 8))
        let nativeQuestionSheet = interactionSheet(in: app)
        XCTAssertTrue(nativeQuestionSheet.exists)
        XCTAssertTrue(app.staticTexts["Question 1 of 3"].exists)

        let buildMethod = app.buttons["Build from current branch (default)"]
        XCTAssertTrue(makeHittable(buildMethod, byScrollingUpIn: nativeQuestionSheet))
        XCTAssertEqual(buildMethod.value as? String, "Not selected")
        buildMethod.tap()
        XCTAssertEqual(buildMethod.value as? String, "Selected")
        attachScreenshot(named: "03-opencode-native-selected-choice", from: app)

        let firstNextButton = app.buttons["Next"]
        XCTAssertTrue(makeHittable(firstNextButton, byScrollingUpIn: nativeQuestionSheet))
        XCTAssertTrue(firstNextButton.isEnabled)
        firstNextButton.tap()
        XCTAssertTrue(app.staticTexts["Question 2 of 3"].waitForExistence(timeout: 2))

        let exportMethod = app.buttons["development (Recommended)"]
        XCTAssertTrue(makeHittable(exportMethod, byScrollingUpIn: nativeQuestionSheet))
        exportMethod.tap()
        XCTAssertEqual(exportMethod.value as? String, "Selected")
        attachScreenshot(named: "04-opencode-native-next-question", from: app)

        let secondNextButton = app.buttons["Next"]
        XCTAssertTrue(makeHittable(secondNextButton, byScrollingUpIn: nativeQuestionSheet))
        XCTAssertTrue(secondNextButton.isEnabled)
        secondNextButton.tap()
        XCTAssertTrue(app.staticTexts["Question 3 of 3"].waitForExistence(timeout: 2))

        let configuration = app.buttons["Debug (default)"]
        XCTAssertTrue(makeHittable(configuration, byScrollingUpIn: nativeQuestionSheet))
        configuration.tap()
        XCTAssertEqual(configuration.value as? String, "Selected")

        let reviewButton = app.buttons["Review answers"]
        XCTAssertTrue(makeHittable(reviewButton, byScrollingUpIn: nativeQuestionSheet))
        XCTAssertTrue(reviewButton.isEnabled)
        reviewButton.tap()

        XCTAssertTrue(app.staticTexts["Review answers"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Build from current branch (default)"].exists)
        XCTAssertTrue(app.staticTexts["development (Recommended)"].exists)
        XCTAssertTrue(app.staticTexts["Debug (default)"].exists)
        XCTAssertTrue(app.buttons["Submit"].exists)
        XCTAssertTrue(makeHittable(app.buttons["Submit"], byScrollingUpIn: nativeQuestionSheet))
        XCTAssertTrue(app.buttons["Submit"].isHittable)
        attachScreenshot(named: "05-opencode-native-review-submit", from: app)

        launchDemoSession("demo-workspace-2|demo-surface-2", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode terminal · Remote permission"].waitForExistence(timeout: 8))
        let fallbackPermissionSheet = interactionSheet(in: app)
        XCTAssertTrue(fallbackPermissionSheet.exists)
        let fallbackAllowOnce = app.buttons["Allow once"]
        let fallbackAllowAlways = app.buttons["Allow always"]
        let fallbackReject = app.buttons["Reject"]
        XCTAssertTrue(fallbackAllowOnce.exists)
        XCTAssertEqual(fallbackAllowOnce.value as? String, "Selected")
        XCTAssertTrue(makeHittable(fallbackAllowAlways, byScrollingUpIn: fallbackPermissionSheet))
        fallbackAllowAlways.tap()
        XCTAssertEqual(fallbackAllowOnce.value as? String, "Not selected")
        XCTAssertEqual(fallbackAllowAlways.value as? String, "Selected")
        XCTAssertTrue(makeHittable(fallbackReject, byScrollingUpIn: fallbackPermissionSheet))
        XCTAssertTrue(makeHittable(app.buttons["Confirm"], byScrollingUpIn: fallbackPermissionSheet))
        XCTAssertTrue(app.buttons["Dismiss"].exists)
        attachScreenshot(named: "06-opencode-tui-permission-rows", from: app)

        launchDemoSession("demo-workspace-3|demo-surface-3", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode question"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["OpenCode terminal · Remote questions"].exists)
        let fallbackQuestionSheet = interactionSheet(in: app)
        XCTAssertTrue(fallbackQuestionSheet.exists)

        let fallbackDefault = app.buttons["Evaluate"]
        XCTAssertTrue(makeHittable(fallbackDefault, byScrollingUpIn: fallbackQuestionSheet))
        XCTAssertEqual(fallbackDefault.value as? String, "Selected")

        let fallbackSkip = app.buttons["Skip"]
        let fallbackCustomAnswer = app.buttons["Type your own answer"]
        XCTAssertTrue(makeHittable(fallbackCustomAnswer, byScrollingUpIn: fallbackQuestionSheet))
        XCTAssertTrue(makeHittable(fallbackSkip, byScrollingUpIn: fallbackQuestionSheet))
        XCTAssertTrue(fallbackCustomAnswer.exists)
        XCTAssertEqual(fallbackSkip.value as? String, "Not selected")

        fallbackSkip.tap()
        XCTAssertEqual(fallbackDefault.value as? String, "Not selected")
        XCTAssertEqual(fallbackSkip.value as? String, "Selected")
        XCTAssertTrue(app.buttons["Next"].exists)
        XCTAssertTrue(makeHittable(app.buttons["Next"], byScrollingUpIn: fallbackQuestionSheet))
        XCTAssertTrue(app.buttons["Next"].isHittable)
        attachScreenshot(named: "07-opencode-tui-evaluate-skip-custom", from: app)

        launchDemoSession("demo-workspace-4|demo-surface-4", in: app)
        XCTAssertTrue(app.staticTexts["Review answers"].waitForExistence(timeout: 8))
        let fallbackReviewSheet = interactionSheet(in: app)
        XCTAssertTrue(fallbackReviewSheet.exists)
        XCTAssertTrue(app.staticTexts["Build method"].exists)
        XCTAssertTrue(app.staticTexts["Build from current branch (default)"].exists)
        XCTAssertTrue(app.staticTexts["Export method"].exists)
        XCTAssertTrue(app.staticTexts["development (Recommended)"].exists)
        XCTAssertTrue(app.staticTexts["Configuration"].exists)
        XCTAssertTrue(app.staticTexts["Debug (default)"].exists)
        XCTAssertTrue(app.buttons["Edit answers"].exists)
        XCTAssertTrue(makeHittable(app.buttons["Edit answers"], byScrollingUpIn: fallbackReviewSheet))
        XCTAssertTrue(app.buttons["Edit answers"].isHittable)
        XCTAssertTrue(app.buttons["Submit"].exists)
        XCTAssertTrue(app.buttons["Submit"].isHittable)
        attachScreenshot(named: "08-opencode-tui-review-submit", from: app)

        launchDemoSession("demo-workspace-5|demo-surface-5", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode question"].waitForExistence(timeout: 8))
        let longQuestionSheet = interactionSheet(in: app)
        XCTAssertTrue(longQuestionSheet.exists)
        XCTAssertTrue(app.buttons["Internal QA devices"].isHittable)

        let finalChoice = app.buttons["Tailnet-only emergency install"]
        XCTAssertTrue(makeHittable(finalChoice, byScrollingUpIn: longQuestionSheet, maximumSwipes: 10))
        finalChoice.tap()
        XCTAssertEqual(finalChoice.value as? String, "Selected")
        XCTAssertTrue(makeHittable(app.buttons["Review answers"], byScrollingUpIn: longQuestionSheet))
        XCTAssertTrue(app.buttons["Review answers"].isEnabled)
        attachScreenshot(named: "09-opencode-long-question-final-choice", from: app)

        launchDemoSession("demo-workspace-6|demo-surface-6", in: app)
        XCTAssertTrue(app.staticTexts["Select all that apply"].waitForExistence(timeout: 8))
        let multiSelectSheet = interactionSheet(in: app)
        XCTAssertTrue(multiSelectSheet.exists)
        let unitTests = app.buttons["Unit tests"]
        let uiTests = app.buttons["UI tests"]
        XCTAssertTrue(makeHittable(unitTests, byScrollingUpIn: multiSelectSheet))
        unitTests.tap()
        XCTAssertTrue(makeHittable(uiTests, byScrollingUpIn: multiSelectSheet))
        uiTests.tap()
        XCTAssertEqual(unitTests.value as? String, "Selected")
        XCTAssertEqual(uiTests.value as? String, "Selected")
        XCTAssertTrue(makeHittable(app.buttons["Review answers"], byScrollingUpIn: multiSelectSheet))
        XCTAssertTrue(app.buttons["Review answers"].isEnabled)
        attachScreenshot(named: "10-opencode-native-multi-select", from: app)

        launchDemoSession("demo-workspace-7|demo-surface-7", in: app)
        XCTAssertTrue(app.staticTexts["OpenCode question"].waitForExistence(timeout: 8))
        let freeformSheet = interactionSheet(in: app)
        XCTAssertTrue(freeformSheet.exists)
        let customAnswer = app.textFields["Custom answer"]
        XCTAssertTrue(makeHittable(customAnswer, byScrollingUpIn: freeformSheet))
        customAnswer.tap()
        customAnswer.typeText("Use the signed staging build")
        XCTAssertEqual(customAnswer.value as? String, "Use the signed staging build")
        XCTAssertTrue(app.buttons["Review answers"].isEnabled)
        attachScreenshot(named: "11-opencode-native-freeform", from: app)

        launchDemoSession("demo-workspace-8|demo-surface-8", in: app)
        XCTAssertTrue(app.staticTexts["Plan approval"].waitForExistence(timeout: 8))
        let planSheet = interactionSheet(in: app)
        XCTAssertTrue(planSheet.exists)
        XCTAssertTrue(app.buttons["Ultraplan"].exists)
        XCTAssertTrue(app.buttons["Bypass permissions"].exists)
        XCTAssertTrue(app.buttons["Auto accept edits"].exists)
        let keepManual = app.buttons["Keep manual"]
        XCTAssertTrue(makeHittable(keepManual, byScrollingUpIn: planSheet))
        XCTAssertEqual(keepManual.value as? String, "Selected")
        XCTAssertTrue(makeHittable(app.buttons["Reject"], byScrollingUpIn: planSheet))
        XCTAssertTrue(makeHittable(app.buttons["Confirm"], byScrollingUpIn: planSheet))
        attachScreenshot(named: "12-opencode-plan-modes", from: app)
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

    private func interactionSheet(in app: XCUIApplication) -> XCUIElement {
        let identifiedSheet = app.descendants(matching: .any)["workspace-interaction-sheet"]
        return identifiedSheet.exists ? identifiedSheet : app.sheets.firstMatch
    }

    @discardableResult
    private func makeHittable(
        _ element: XCUIElement,
        byScrollingUpIn container: XCUIElement,
        maximumSwipes: Int = 6
    ) -> Bool {
        for _ in 0..<maximumSwipes {
            if element.exists, element.isHittable {
                return true
            }
            container.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func waitForHeightIncrease(of element: XCUIElement, from initialHeight: CGFloat) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.frame.height > initialHeight + 40
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }

    @MainActor
    private func stableHeight(of element: XCUIElement, timeout: TimeInterval = 2) -> CGFloat {
        var lastHeight = element.frame.height
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let currentHeight = element.frame.height
            if abs(currentHeight - lastHeight) < 0.5 {
                if Date().timeIntervalSince(stableSince) >= 0.3 {
                    return currentHeight
                }
            } else {
                lastHeight = currentHeight
                stableSince = Date()
            }
        }
        return lastHeight
    }

    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
