import XCTest

/// End-to-end coverage for the Active Work entry point and its two projections.
///
/// The demo payload deliberately exercises the richer route relationships: an
/// untracked Jira candidate on the board, plus a tracked item whose current
/// phase owns both a Pi session and a Buzz thread. This test keeps those records
/// read-only while proving the toolbar scope picker and the board's own
/// projection switch drive the real shell.
final class HerdrActiveWorkUITests: HerdrUITestCase {
    private var extraLaunchArguments: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        extraLaunchArguments = ["-HerdrActiveWorkLegacy"]
    }

    @MainActor
    private func launchLegacyDemoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrResetSidebarState"] + extraLaunchArguments
        app.launch()
        return app
    }

    @MainActor
    func testScopePickerOpensBoardAndSwitchesToFocusRoute() throws {
        let app = launchLegacyDemoApp()

        XCTAssertTrue(
            app.control(identifier: "detail-scope-picker").waitForExistence(timeout: 10),
            "The detail toolbar should expose the scope picker that owns Active Work"
        )
        guard let activeWork = waitForFirst(
            of: [
                app.control(identifier: "detail-scope-picker").buttons["Active Work"],
                app.control(identifier: "detail-scope-picker").radioButtons["Active Work"],
                app.control(named: "Active Work"),
            ],
            timeout: 10
        ) else {
            return XCTFail("The scope picker should carry an Active Work segment")
        }
        activeWork.click()

        XCTAssertTrue(
            app.control(identifier: "active-work-container").waitForExistence(timeout: 5),
            "The Active Work segment should replace the detail column with Active Work"
        )
        XCTAssertTrue(
            app.control(identifier: "active-work-board").waitForExistence(timeout: 5),
            "Active Work should open in its board projection"
        )
        XCTAssertTrue(
            app.control(identifier: "active-work-card-work_mobile_guard").waitForExistence(timeout: 5),
            "The demo board should render its tracked pipeline item"
        )
        XCTAssertTrue(
            app.control(identifier: "active-work-jira-setup-HERD-219").waitForExistence(timeout: 5),
            "Assigned Jira work should remain an explicit one-click setup candidate"
        )

        XCTAssertTrue(
            app.control(identifier: "active-work-mode-picker").waitForExistence(timeout: 5),
            "The header should expose the Board and Focus Route projection switch"
        )
        guard let focusRouteSegment = waitForFirst(
            of: [
                app.buttons["Focus Route"],
                app.radioButtons["Focus Route"],
                app.control(identifier: "active-work-mode-picker").buttons["Focus Route"],
                app.control(identifier: "active-work-mode-picker").radioButtons["Focus Route"],
            ],
            timeout: 5
        ) else {
            return XCTFail("The Active Work mode picker should expose its Focus Route segment")
        }
        focusRouteSegment.click()

        XCTAssertTrue(
            app.control(identifier: "active-work-focus-route").waitForExistence(timeout: 5),
            "Focus Route should replace the board without changing its backing work data"
        )
        let mobileGuard = app.control(identifier: "active-work-focus-item-work_mobile_guard")
        XCTAssertTrue(
            mobileGuard.waitForExistence(timeout: 5),
            "The tracked board item should also be selectable in Focus Route"
        )
        mobileGuard.click()
        XCTAssertTrue(
            app.control(identifier: "active-work-stage-architect-code-review").waitForExistence(timeout: 5),
            "The selected item should expose its current architecture-review phase"
        )
        XCTAssertTrue(
            app.control(identifier: "active-work-open-pane-session_1").waitForExistence(timeout: 5),
            "The expanded current phase should expose its associated Pi session"
        )
        XCTAssertTrue(
            app.text(containing: "Architecture review discussion").waitForExistence(timeout: 5),
            "The expanded current phase should expose its associated Buzz thread"
        )
        XCTAssertTrue(
            app.control(identifier: "active-work-open-buzz-thread_1").waitForExistence(timeout: 5),
            "A rootless Buzz message link should render an Open control"
        )
    }
}
