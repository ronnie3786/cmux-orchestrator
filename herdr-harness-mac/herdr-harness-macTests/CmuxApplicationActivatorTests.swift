import AppKit
import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("cmux application activation")
struct CmuxApplicationActivatorTests {
    @Test("Resolves cmux and requests foreground activation")
    func activatesExistingApplication() async throws {
        let expectedURL = URL(fileURLWithPath: "/Applications/cmux.app")
        var resolvedBundleIdentifier: String?
        var openedURL: URL?
        var activates = false
        var addsToRecentItems = true

        try await CmuxApplicationActivator.activate(
            resolveApplicationURL: { bundleIdentifier in
                resolvedBundleIdentifier = bundleIdentifier
                return expectedURL
            },
            openApplication: { applicationURL, configuration in
                openedURL = applicationURL
                activates = configuration.activates
                addsToRecentItems = configuration.addsToRecentItems
            }
        )

        #expect(resolvedBundleIdentifier == "com.cmuxterm.app")
        #expect(openedURL == expectedURL)
        #expect(activates)
        #expect(!addsToRecentItems)
    }

    @Test("Reports when cmux is not installed")
    func reportsMissingApplication() async {
        do {
            try await CmuxApplicationActivator.activate(
                resolveApplicationURL: { _ in nil },
                openApplication: { _, _ in }
            )
            Issue.record("Expected cmux activation to fail")
        } catch let error as CmuxApplicationActivator.ActivationError {
            #expect(error == .applicationNotFound(bundleIdentifier: "com.cmuxterm.app"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
