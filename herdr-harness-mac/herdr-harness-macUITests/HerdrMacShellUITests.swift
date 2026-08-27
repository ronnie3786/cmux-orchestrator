import XCTest

/// Mac-only shell coverage: the menu bar and the detail-scope control that
/// replaced the iOS tab bar.
///
/// iOS had nothing to port here — a phone has no menu bar, and `AppTab` was a
/// `TabView`. `PORT_PLAN.md` makes these commands part of the contract, so they
/// get the same treatment the tab bar used to: assert they exist, are enabled in
/// demo mode, and actually move the detail column.
final class HerdrMacShellUITests: HerdrUITestCase {
    @MainActor
    func testViewMenuMovesTheDetailScope() throws {
        let app = launchDemoApp()
        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10),
            "The demo fleet should be loaded before driving the menus"
        )

        guard let attention = app.menuBarItem("View", item: "Go to Attention") else {
            return XCTFail("View ▸ Go to Attention should exist")
        }
        XCTAssertTrue(attention.isEnabled)
        attention.click()

        XCTAssertTrue(
            app.control(identifier: "attention-refresh").waitForExistence(timeout: 5),
            "Go to Attention should show the attention deck"
        )

        guard let overview = app.menuBarItem("View", item: "Workspace Overview") else {
            return XCTFail("View ▸ Workspace Overview should exist")
        }
        overview.click()
        XCTAssertTrue(
            app.control(identifier: "pane-demo1|w1:p1").waitForExistence(timeout: 5),
            "Workspace Overview should show the selected workspace's pane cards"
        )
    }

    @MainActor
    func testNavigateMenuStepsThroughPanes() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10))

        guard let nextPane = app.menuBarItem("Navigate", item: "Next Pane") else {
            return XCTFail("Navigate ▸ Next Pane should exist")
        }
        XCTAssertTrue(nextPane.isEnabled)
        nextPane.click()

        // Nothing was selected, so the first pane in sidebar order wins.
        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w1:p1").waitForExistence(timeout: 5),
            "Next Pane should open a pane session in the detail column"
        )

        guard let previousPane = app.menuBarItem("Navigate", item: "Previous Pane") else {
            return XCTFail("Navigate ▸ Previous Pane should exist")
        }
        previousPane.click()
        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w3:p1").waitForExistence(timeout: 5),
            "Stepping back from the first pane should wrap to the last one"
        )
    }

    @MainActor
    func testCommandOneReachesTheAttentionDeckFromTheKeyboard() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p2"].waitForExistence(timeout: 10))
        app.buttons["sidebar-pane-demo1|w1:p2"].click()
        XCTAssertTrue(app.control(identifier: "terminal-demo1|w1:p2").waitForExistence(timeout: 5))

        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(
            app.control(identifier: "attention-refresh").waitForExistence(timeout: 5),
            "⌘1 should reach the attention deck without touching the menu"
        )
    }

    @MainActor
    func testCommandKSearchesAndOpensAChat() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)

        let palette = app.control(identifier: "command-palette")
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "⌘K should present the global chat palette")
        let search = app.control(identifier: "command-palette-search")
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("pagination")

        let result = app.control(identifier: "command-palette-row-demo1|w2:p1")
        XCTAssertTrue(result.waitForExistence(timeout: 3), "Pane-title search should find the matching chat")
        result.click()

        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w2:p1").waitForExistence(timeout: 5),
            "Opening a palette result should route through the normal pane session"
        )
        XCTAssertTrue(palette.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testCommandPaletteEscapeDismissesWithoutRouting() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        let palette = app.control(identifier: "command-palette")
        XCTAssertTrue(palette.waitForExistence(timeout: 5))

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCTAssertTrue(palette.waitForNonExistence(timeout: 3), "Escape should close the palette")
    }

    @MainActor
    func testFileMenuOffersNewWorkspaceInDemoMode() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-workspace-demo1|w1"].waitForExistence(timeout: 10))

        guard let newWorkspace = app.menuBarItem("File", item: "New Workspace") else {
            return XCTFail("File ▸ New Workspace should exist")
        }
        // Demo mode is controllable, so the command must not be greyed out.
        XCTAssertTrue(newWorkspace.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    @MainActor
    func testDetailToolbarExposesTheScopePicker() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-workspace-demo1|w1"].waitForExistence(timeout: 10))

        XCTAssertTrue(
            app.control(identifier: "detail-scope-picker").waitForExistence(timeout: 5),
            "The detail toolbar should carry the session/workspace/attention picker"
        )
        XCTAssertTrue(
            app.shellWindow.exists,
            "The shell should run in a single document window"
        )
    }

    @MainActor
    func testPaneHeaderExposesWorkingFolderButton() throws {
        let app = launchDemoApp()
        let pane = app.buttons["sidebar-pane-demo1|w1:p2"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))

        pane.click()

        XCTAssertTrue(
            app.buttons["pane-path-button"].waitForExistence(timeout: 5),
            "A selected pane should expose its working folder as a Finder button"
        )
    }
}
