import XCTest

/// The Mac rewrite of the iOS sidebar suite.
///
/// iOS drove a drawer: `sidebar-toggle` opened it, a tap navigated, and the
/// drawer had to be reopened before the next hop. The Mac shell keeps the
/// navigator as a permanent `NavigationSplitView` column, so the toggle is gone
/// and every row is on screen for the whole session. The identifiers
/// (`sidebar-workspace-<id>`, `sidebar-pane-<id>`) and the demo topology they
/// address are unchanged — that is the point of the port contract.
final class HerdrSidebarUITests: HerdrUITestCase {
    @MainActor
    func testSidebarNavigatesBetweenPanesAcrossWorkspaces() throws {
        let app = launchDemoApp()

        // No drawer to open: the navigator is a column, present from launch.
        XCTAssertTrue(
            app.buttons["sidebar-workspace-demo1|w1"].waitForExistence(timeout: 10),
            "The persistent sidebar should list demo workspaces at launch"
        )
        XCTAssertTrue(
            app.buttons["sidebar-workspace-demo1|w2"].exists,
            "Every workspace stays visible — the Mac sidebar never closes"
        )

        app.buttons["sidebar-pane-demo1|w1:p2"].click()
        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w1:p2").waitForExistence(timeout: 5),
            "Selecting a chat row should mount that pane's session in the detail column"
        )
        // The Mac replacement for the iOS navigation-bar title assertion: the
        // detail's `navigationTitle` is the window title.
        XCTAssertTrue(
            app.window(titled: "Auth reducer review").waitForExistence(timeout: 5),
            "The window title should follow the selected pane"
        )

        // Cross-workspace hop — on iOS this needed a second `sidebar-toggle` tap.
        app.buttons["sidebar-pane-demo1|w2:p1"].click()
        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w2:p1").waitForExistence(timeout: 5),
            "A pane in another workspace should replace the detail column in place"
        )
        XCTAssertTrue(
            app.window(titled: "Pagination contract").waitForExistence(timeout: 5),
            "The window title should follow across workspaces too"
        )
    }

    @MainActor
    func testSidebarProjectRowCollapsesAndExpands() throws {
        let app = launchDemoApp()

        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10),
            "-HerdrResetSidebarState should leave every workspace expanded"
        )

        app.buttons["sidebar-workspace-demo1|w1"].click()
        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForNonExistence(timeout: 3),
            "Clicking the workspace row should collapse its chats"
        )

        app.buttons["sidebar-workspace-demo1|w1"].click()
        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 3),
            "Clicking it again should restore them"
        )
    }

    /// Mac-only: the phone had no room for a persistent filter field, so this
    /// pins `SidebarTree`'s query behaviour through the real control — a pane
    /// title match narrows the tree to the one workspace that owns it.
    @MainActor
    func testSidebarFilterNarrowsTheTreeToMatchingChats() throws {
        let app = launchDemoApp()

        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10),
            "The demo fleet should be listed before filtering"
        )

        guard let filter = waitForFirst(
            of: [
                app.textFields["Filter spaces"],
                app.searchFields["Filter spaces"],
                app.textFields["filter chats"],
            ],
            timeout: 5
        ) else {
            return XCTFail("The sidebar should expose its filter field")
        }

        filter.click()
        filter.typeText("pagination")

        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w2:p1"].waitForExistence(timeout: 3),
            "A pane-title match should survive the filter"
        )
        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForNonExistence(timeout: 3),
            "Workspaces with no match should drop out of the tree"
        )
        XCTAssertFalse(
            app.buttons["sidebar-workspace-demo1|w3"].exists,
            "Release Train has nothing matching 'pagination'"
        )

        app.control(named: "Clear workspace filter").click()
        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 3),
            "Clearing the filter should restore the whole tree"
        )
    }
}
