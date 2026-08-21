import XCTest

/// The Mac rewrite of the iOS demo walkthrough.
///
/// Same scenario, same fixtures, same accessibility identifiers; only the way
/// you get to each screen changed. iOS drilled in (workspace card → pane card →
/// full-screen pane) and hid the tab bar on arrival. The Mac shell selects a
/// chat row in the permanent sidebar and swaps the detail column, so the walk
/// starts at `sidebar-pane-demo1|w1:p2` and every "full-screen cover" is a sheet.
///
/// The landscape + accessibility-text-size test has no Mac analogue (no
/// orientations, no `UIContentSizeCategory`); its job — proving the composer's
/// controls stay reachable when the layout is squeezed — is done here by
/// dragging the window down to its minimum size instead.
final class HerdrDemoNavigationUITests: HerdrUITestCase {
    private let screenshotDirectory = HerdrDemoNavigationUITests.resolvedScreenshotDirectory()

    /// The iOS suite dropped its goal screens straight into
    /// `/tmp/herdr-ios-goal-screens`. The Mac UI-test runner is sandboxed — its
    /// only filesystem exception is read-only — so `/tmp` is tried first (it
    /// works whenever the runner is signed without the sandbox) and the runner's
    /// own container is used otherwise. Either way `XCTAttachment` carries the
    /// screens into the test report, which is the artifact that matters.
    private static func resolvedScreenshotDirectory() -> URL {
        let preferred = URL(fileURLWithPath: "/tmp/herdr-mac-goal-screens", isDirectory: true)
        let fileManager = FileManager.default
        if (try? fileManager.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil {
            return preferred
        }

        let fallback = fileManager.temporaryDirectory.appending(path: "herdr-mac-goal-screens")
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    @MainActor
    func testPaneModesAndExpandableControls() throws {
        let app = launchDemoApp()

        let blockedPane = app.buttons["sidebar-pane-demo1|w1:p2"]
        XCTAssertTrue(
            blockedPane.waitForExistence(timeout: 10),
            "The demo fleet should populate the sidebar"
        )
        blockedPane.click()

        XCTAssertTrue(
            app.window(titled: "Auth reducer review").waitForExistence(timeout: 5),
            "The window title carries the pane title the iOS nav bar used to"
        )
        XCTAssertTrue(
            app.control(identifier: "prompt-composer").waitForExistence(timeout: 5),
            "The pane session should mount its composer"
        )
        XCTAssertEqual(
            app.tabBars.count, 0,
            "The Mac shell has no tab bar — the sidebar replaced it"
        )
        XCTAssertFalse(
            app.buttons["Yes, proceed"].exists,
            "Canned response chips should not consume pane space"
        )

        // The disclosure latch is gone: the tool row is always mounted, and at
        // this window size the whole key deck fits as buttons.
        for key in ["up", "down", "tab", "enter", "left", "right", "escape", "backspace"] {
            XCTAssertTrue(
                app.buttons["terminal-key-\(key)"].waitForExistence(timeout: 3),
                "The always-visible key deck should show every preset key"
            )
        }
        saveScreenshot("01-terminal-deck", app: app, directory: screenshotDirectory)

        try selectPaneMode(.git, in: app)
        XCTAssertTrue(
            app.control(identifier: "workspace-git").waitForExistence(timeout: 5),
            "The Git mode should replace the terminal in the detail column"
        )
        XCTAssertTrue(
            app.control(labelContaining: "staged").waitForExistence(timeout: 5),
            "Demo Git status carries staged and unstaged sections"
        )
        saveScreenshot("03-git-status", app: app, directory: screenshotDirectory)

        let diffButton = app.control(named: "View diff for herdr-harness-ios/Views/Pane/PaneSessionView.swift")
        XCTAssertTrue(diffButton.waitForExistence(timeout: 3))
        diffButton.click()
        XCTAssertTrue(
            app.control(identifier: "git-diff").waitForExistence(timeout: 5),
            "A file row should open the diff — a sheet on the Mac, a cover on iOS"
        )
        XCTAssertTrue(
            app.control(labelContaining: "diff --git").waitForExistence(timeout: 5),
            "The diff sheet should render the demo patch"
        )
        saveScreenshot("04-git-diff", app: app, directory: screenshotDirectory)
        app.buttons["Done"].click()

        try selectPaneMode(.skills, in: app)
        XCTAssertTrue(
            app.control(identifier: "workspace-skills").waitForExistence(timeout: 5),
            "The Skills mode should list this workspace's skills"
        )
        XCTAssertTrue(app.control(labelContaining: "workspace skills").waitForExistence(timeout: 5))
        saveScreenshot("05-skills", app: app, directory: screenshotDirectory)

        try selectPaneMode(.terminal, in: app)
        let fileTool = app.buttons["Insert a workspace file path"]
        XCTAssertTrue(fileTool.waitForExistence(timeout: 3))
        fileTool.click()

        guard let fileSearch = waitForFirst(
            of: [
                app.textFields["Search project files"],
                app.searchFields["Search project files"],
                app.textFields.matching(
                    NSPredicate(format: "placeholderValue == %@", "Search project files")
                ).firstMatch,
            ],
            timeout: 5
        ) else {
            return XCTFail("The file search sheet should expose its query field")
        }
        fileSearch.click()
        fileSearch.typeText("Pane")
        XCTAssertTrue(
            app.control(named: "Insert herdr-harness-ios/Views/Pane/PaneSessionView.swift")
                .waitForExistence(timeout: 5),
            "Demo file search should offer the matching project files"
        )
        saveScreenshot("06-file-search", app: app, directory: screenshotDirectory)
        app.buttons["Done"].click()

        let jiraTool = app.buttons["Insert Jira ticket context"]
        XCTAssertTrue(jiraTool.waitForExistence(timeout: 5))
        jiraTool.click()
        guard waitForFirst(
            of: [app.staticTexts["MOB-1842"], app.control(labelContaining: "MOB-1842")],
            timeout: 5
        ) != nil else {
            return XCTFail("The Jira sheet should list the demo ticket")
        }
        saveScreenshot("07-jira-context", app: app, directory: screenshotDirectory)
        app.buttons["Done"].click()

        // The voice control is a gesture surface, not a `Button` — a click opens
        // the recorder, a press-and-hold dictates — so it is matched by label
        // across roles rather than as `app.buttons`.
        let voiceTool = app.control(named: "Record a voice note")
        XCTAssertTrue(voiceTool.waitForExistence(timeout: 5))
        voiceTool.click()
        XCTAssertTrue(
            app.control(named: "Start recording").waitForExistence(timeout: 5),
            "The voice note sheet should open on click"
        )
        XCTAssertTrue(app.control(named: "Attach audio without transcribing").exists)
        XCTAssertTrue(app.control(named: "Transcribe").exists)
        saveScreenshot("08-voice-note", app: app, directory: screenshotDirectory)
        app.control(named: "Close").click()
        XCTAssertTrue(
            app.control(named: "Start recording").waitForNonExistence(timeout: 3),
            "Closing should dismiss the recorder sheet"
        )
    }

    /// Replaces `testVoiceActionsRemainReachableInLandscapeAccessibilityText`.
    /// The Mac squeeze is a window drag, and the shell's declared minimum
    /// (1000×680 content) is what keeps the composer usable.
    @MainActor
    func testComposerControlsStayReachableAtTheMinimumWindowSize() throws {
        let app = launchDemoApp()

        let blockedPane = app.buttons["sidebar-pane-demo1|w1:p2"]
        XCTAssertTrue(blockedPane.waitForExistence(timeout: 10))
        blockedPane.click()
        XCTAssertTrue(app.control(identifier: "prompt-composer").waitForExistence(timeout: 5))

        let window = app.shellWindow
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Ask for a window far smaller than the shell allows and let AppKit
        // clamp it: that clamp is the contract this test is protecting.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        let target = corner.withOffset(CGVector(dx: -900, dy: -600))
        corner.click(forDuration: 0.4, thenDragTo: target)

        XCTAssertGreaterThanOrEqual(
            window.frame.width, 900,
            "The window should refuse to shrink under the shell's minimum width"
        )
        XCTAssertGreaterThanOrEqual(
            window.frame.height, 600,
            "The window should refuse to shrink under the shell's minimum height"
        )

        // No latch to open — the tools ride the always-visible row, and the fit
        // ladder drops their titles rather than the buttons themselves.
        for label in [
            "Attach a file",
            "Record a voice note",
            "Insert a workspace file path",
            "Insert Jira ticket context",
        ] {
            let control = app.control(named: label)
            XCTAssertTrue(
                control.waitForExistence(timeout: 3),
                "\(label) should survive the squeeze"
            )
            XCTAssertTrue(control.isHittable, "\(label) should still be clickable")
        }

        XCTAssertTrue(app.control(identifier: "prompt-composer").isHittable)
        XCTAssertTrue(app.control(identifier: "prompt-send").isHittable)
        for key in ["up", "down", "tab", "enter"] {
            XCTAssertTrue(
                app.buttons["terminal-key-\(key)"].isHittable,
                "The key deck should stay usable at the minimum size"
            )
        }
    }

    // MARK: - Helpers

    /// The iOS "Pane actions" sheet is a toolbar `Menu` on the Mac. Its rows
    /// arrive as `NSMenu` items, which publish their title rather than the
    /// SwiftUI accessibility label, so both spellings are accepted.
    @MainActor
    private func selectPaneMode(_ mode: PaneMode, in app: XCUIApplication) throws {
        guard let menu = waitForFirst(
            of: [
                app.control(identifier: "pane-mode-toggle"),
                app.control(named: "Pane actions"),
            ],
            timeout: 5
        ) else {
            return XCTFail("The pane session should expose its actions menu")
        }
        menu.click()

        guard let modeButton = waitForFirst(
            of: [
                app.menuItems[mode.label],
                app.control(identifier: "pane-mode-\(mode.rawValue)"),
                app.control(named: "\(mode.label) view"),
            ],
            timeout: 5
        ) else {
            return XCTFail("The pane menu should expose \(mode.label)")
        }
        modeButton.click()
    }

    /// Mirrors the app's `PaneDetailMode` without importing the app module —
    /// UI tests only ever see it through identifiers and titles.
    private enum PaneMode: String {
        case terminal
        case git
        case skills

        var label: String {
            switch self {
            case .terminal: "Terminal"
            case .git: "Git"
            case .skills: "Skills"
            }
        }
    }
}
