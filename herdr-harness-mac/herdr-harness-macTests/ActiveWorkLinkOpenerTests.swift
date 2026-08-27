import AppKit
import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Active Work link opener")
struct ActiveWorkLinkOpenerTests {
    private let buzzURL = URL(
        string: "buzz://message?channel=89a5bbb0-7a26-438f-81fb-ceb65d82b683&id=d7f719aaed94d298ba9f5b151f3247ade3a2ca3d0c22c544afadd1c80f3ea452"
    )!

    @Test("Targets Buzz directly when Launch Services has no scheme handler")
    func fallsBackToInstalledBuzzApplication() async {
        let expectedApplicationURL = URL(fileURLWithPath: "/Applications/Buzz.app")
        var openedURLs: [URL] = []
        var openedApplicationURL: URL?
        var activates = false
        var addsToRecentItems = true
        var createsNewInstance = true
        var allowsSubstitution = true

        let route = await ActiveWorkLinkOpener.open(
            buzzURL,
            resolveBuzzApplication: { expectedApplicationURL },
            openNormally: { _ in
                Issue.record("The missing-handler path should target Buzz directly")
                return false
            },
            openWithApplication: { urls, applicationURL, configuration in
                openedURLs = urls
                openedApplicationURL = applicationURL
                activates = configuration.activates
                addsToRecentItems = configuration.addsToRecentItems
                createsNewInstance = configuration.createsNewApplicationInstance
                allowsSubstitution = configuration.allowsRunningApplicationSubstitution
            }
        )

        #expect(route == .explicitBuzzApplication)
        #expect(openedURLs == [buzzURL])
        #expect(openedApplicationURL == expectedApplicationURL)
        #expect(activates)
        #expect(!addsToRecentItems)
        #expect(!createsNewInstance)
        #expect(!allowsSubstitution)
    }

    @Test("Targets verified Buzz instead of an arbitrary registered wrapper")
    func bypassesRegisteredSchemeWrapper() async {
        let expectedApplicationURL = URL(fileURLWithPath: "/Applications/Buzz.app")
        var normallyOpenedURL: URL?
        var targetedApplicationURL: URL?

        let route = await ActiveWorkLinkOpener.open(
            buzzURL,
            resolveBuzzApplication: { expectedApplicationURL },
            openNormally: { url in
                normallyOpenedURL = url
                return true
            },
            openWithApplication: { _, applicationURL, _ in
                targetedApplicationURL = applicationURL
            }
        )

        #expect(route == .explicitBuzzApplication)
        #expect(normallyOpenedURL == nil)
        #expect(targetedApplicationURL == expectedApplicationURL)
    }

    @Test("Rejects an unvalidated custom URL before opening an application")
    func rejectsUnvalidatedCustomURL() async {
        let malformedURL = URL(string: "buzz://message?channel=channel-1")!
        var attemptedOpen = false

        let route = await ActiveWorkLinkOpener.open(
            malformedURL,
            resolveBuzzApplication: {
                attemptedOpen = true
                return nil
            },
            openNormally: { _ in
                attemptedOpen = true
                return false
            },
            openWithApplication: { _, _, _ in attemptedOpen = true }
        )

        #expect(route == .rejected)
        #expect(!attemptedOpen)
    }

    @Test("Reports targeted Buzz launch failures as unavailable")
    func reportsTargetedLaunchFailure() async {
        struct TestFailure: Error { }

        let route = await ActiveWorkLinkOpener.open(
            buzzURL,
            resolveBuzzApplication: { URL(fileURLWithPath: "/Applications/Buzz.app") },
            openNormally: { _ in false },
            openWithApplication: { _, _, _ in throw TestFailure() }
        )

        #expect(route == .unavailable)
    }

    @Test("Does not fall back to an unverified Buzz scheme handler")
    func rejectsUnverifiedSchemeHandler() async {
        var normallyOpened = false

        let route = await ActiveWorkLinkOpener.open(
            buzzURL,
            resolveBuzzApplication: { nil },
            openNormally: { _ in
                normallyOpened = true
                return true
            },
            openWithApplication: { _, _, _ in }
        )

        #expect(route == .unavailable)
        #expect(!normallyOpened)
    }
}
