import AppKit
import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Pane folder opening")
struct PanePathOpenerTests {
    @Test("External volume paths are passed to Finder as directory URLs")
    func opensExternalVolumeFolder() async throws {
        var openedURL: URL?
        var activates = false
        var addsToRecentItems = true

        try await PanePathOpener.open(path: "/Volumes/PROJECTS/cmux-harness") { url, configuration in
            openedURL = url
            activates = configuration.activates
            addsToRecentItems = configuration.addsToRecentItems
        }

        #expect(openedURL?.isFileURL == true)
        #expect(openedURL?.path(percentEncoded: false) == "/Volumes/PROJECTS/cmux-harness/")
        #expect(activates)
        #expect(!addsToRecentItems)
    }

    @Test("Relative paths are rejected before asking Finder to open them")
    func rejectsRelativePath() async {
        var attemptedOpen = false

        do {
            try await PanePathOpener.open(path: "Volumes/PROJECTS/cmux-harness") { _, _ in
                attemptedOpen = true
            }
            Issue.record("Expected a relative path to be rejected")
        } catch let error as PanePathOpener.OpenError {
            #expect(error == .invalidPath)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!attemptedOpen)
    }

    @Test("Legal trailing whitespace remains part of the folder name")
    func preservesPathWhitespace() throws {
        let url = try PanePathOpener.folderURL(for: "/tmp/Project ")

        #expect(url.path(percentEncoded: false) == "/tmp/Project /")
    }

    @Test("Dot segments remain intact for Finder to resolve through symlinks")
    func preservesDotSegments() throws {
        let url = try PanePathOpener.folderURL(for: "/tmp/project-link/../Sources")

        #expect(url.path(percentEncoded: false) == "/tmp/project-link/../Sources/")
    }

    @Test("Finder failures have a useful mounted-volume recovery message")
    func reportsFinderFailure() async {
        struct TestFailure: Error { }

        do {
            try await PanePathOpener.open(path: "/Volumes/PROJECTS/cmux-harness") { _, _ in
                throw TestFailure()
            }
            Issue.record("Expected the Finder request to fail")
        } catch let error as PanePathOpener.OpenError {
            #expect(error == .finderRejected(path: "/Volumes/PROJECTS/cmux-harness/"))
            #expect(error.localizedDescription.contains("volume is mounted"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
