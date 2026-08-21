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
}
