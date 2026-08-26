import XCTest

/// Shared plumbing for the Mac UI suites.
///
/// The iOS suites could name one accessibility role per control, because UIKit
/// renders a SwiftUI `Button` as a button wherever it lands. On the Mac the same
/// declaration arrives as a button, a pop-up button, an `NSMenu` row, or a plain
/// group depending on whether it is drawn in a toolbar, a menu, or a sheet — so
/// the helpers here match on the *identifier or label* across every role. Those
/// are the parts the port contract actually pins (see `PORT_PLAN.md` §7).
class HerdrUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Every Mac suite launches the same way: the canned fleet, zero network,
    /// and a sidebar whose collapse state cannot leak in from a previous run.
    @MainActor
    func launchDemoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrResetSidebarState"]
        app.launch()
        return app
    }

    /// Polls a set of equivalent queries and returns whichever resolves first.
    ///
    /// Used where one SwiftUI control can legitimately surface under more than
    /// one Mac accessibility role; asserting a single role would pin AppKit's
    /// implementation detail rather than the app's behaviour.
    @MainActor
    @discardableResult
    func waitForFirst(
        of candidates: [XCUIElement],
        timeout: TimeInterval = 5
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = candidates.first(where: { $0.exists }) { return match }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return nil
    }

    /// Captures a goal screen. The disk copy mirrors the iOS suite's
    /// `/tmp/herdr-ios-goal-screens` habit but is best effort — the
    /// `XCTAttachment` is the durable artifact, and the runner is not
    /// guaranteed write access to `/tmp` on every host.
    @MainActor
    func saveScreenshot(_ name: String, app: XCUIApplication, directory: URL) {
        let screenshot = app.screenshot()
        try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(name).png"))

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIApplication {
    /// Any element carrying `identifier`, whatever role the Mac gave it.
    func control(identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Any element whose accessibility label — or identifier — is `name`.
    func control(named name: String) -> XCUIElement {
        descendants(matching: .any)[name].firstMatch
    }

    /// Any element whose label *contains* `fragment`. Views that fold their
    /// children with `accessibilityElement(children: .combine)` publish one
    /// concatenated label, so exact matching would pin the concatenation.
    func control(labelContaining fragment: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
            .firstMatch
    }

    /// Visible SwiftUI text. AppKit usually publishes `Text` through AXValue,
    /// while combined controls publish the same copy through AXLabel.
    func text(containing fragment: String) -> XCUIElement {
        staticTexts
            .matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                    fragment,
                    fragment
                )
            )
            .firstMatch
    }

    /// The shell window. `MenuBarExtra` content only becomes a window while its
    /// popover is open, so the first match is the document window.
    var shellWindow: XCUIElement {
        windows.firstMatch
    }

    /// The window whose title is `title` — the Mac stand-in for the iOS
    /// `app.navigationBars[...]` assertions, since the detail column's
    /// `navigationTitle` becomes the window title. Matched by predicate because
    /// AppKit publishes the title as `AXTitle`, which subscript lookup (identifier
    /// or label) does not always reach.
    func window(titled title: String) -> XCUIElement {
        windows
            .matching(NSPredicate(format: "title == %@ OR label == %@", title, title))
            .firstMatch
    }

    /// Opens `menu` in the app menu bar and returns the named item.
    func menuBarItem(_ menu: String, item: String) -> XCUIElement? {
        let bar = menuBars.menuBarItems[menu]
        guard bar.waitForExistence(timeout: 5) else { return nil }
        bar.click()

        let candidates = [menuBars.menuItems[item], menuItems[item]]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let match = candidates.first(where: { $0.exists }) { return match }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return nil
    }
}
