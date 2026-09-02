import XCTest

final class HerdrSidebarUITests: XCTestCase {
    @MainActor
    func testSidebarNavigatesBetweenPanesAcrossWorkspaces() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrResetSidebarState"]
        app.launch()

        app.buttons["sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["sidebar-workspace-demo1|w1"].waitForExistence(timeout: 5))

        app.buttons["sidebar-pane-demo1|w1:p2"].tap()
        XCTAssertTrue(app.navigationBars["Auth reducer review"].waitForExistence(timeout: 3))

        app.buttons["sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w2:p1"].waitForExistence(timeout: 3))
        app.buttons["sidebar-pane-demo1|w2:p1"].tap()
        XCTAssertTrue(app.navigationBars["Pagination contract"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSidebarProjectRowCollapsesAndExpands() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrResetSidebarState"]
        app.launch()

        app.buttons["sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 5))

        app.buttons["sidebar-workspace-demo1|w1"].tap()
        XCTAssertFalse(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 2))

        app.buttons["sidebar-workspace-demo1|w1"].tap()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testWorkInboxStaysCollapsedUntilTappedThenListsWork() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrResetSidebarState"]
        // A landscape drawer is only ~400pt tall, which puts the second
        // provider row under the home indicator. Device orientation survives
        // between tests, so pin it rather than inherit whatever ran last.
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        app.buttons["sidebar-toggle"].tap()
        let toggle = app.buttons["sidebar-my-work-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sidebar-my-work-github"].exists)

        toggle.tap()
        XCTAssertTrue(app.buttons["sidebar-my-work-github"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["sidebar-github-review-11856"].waitForExistence(timeout: 3))

        app.buttons["sidebar-my-work-jira"].tap()
        XCTAssertTrue(app.buttons["sidebar-jira-ticket-MOB-1842"].waitForExistence(timeout: 3))
    }
}
