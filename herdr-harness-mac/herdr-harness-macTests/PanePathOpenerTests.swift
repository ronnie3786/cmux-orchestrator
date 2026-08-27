import AppKit
import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Pane folder opening")
struct PanePathOpenerTests {
    @Test("External volume paths are delegated directly to Finder")
    func opensExternalVolumeFolder() async throws {
        var revealedURLs: [URL] = []

        try await PanePathOpener.open(path: "/Volumes/PROJECTS/cmux-harness") { urls in
            revealedURLs = urls
        }

        #expect(revealedURLs.count == 1)
        #expect(revealedURLs.first?.path(percentEncoded: false) == "/Volumes/PROJECTS/cmux-harness/")
    }

    @Test("Relative paths are rejected before asking Finder to open them")
    func rejectsRelativePath() async {
        var attemptedOpen = false

        do {
            try await PanePathOpener.open(path: "Volumes/PROJECTS/cmux-harness") { _ in
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
        let path = try PanePathOpener.validatedPath("/tmp/Project ")

        #expect(path == "/tmp/Project ")
    }

    @Test("Dot segments remain intact for Finder to resolve through symlinks")
    func preservesDotSegments() throws {
        let path = try PanePathOpener.validatedPath("/tmp/project-link/../Sources")

        #expect(path == "/tmp/project-link/../Sources")
    }

    @Test("Finder failures have a useful mounted-volume recovery message")
    func reportsFinderFailure() async {
        struct TestFailure: Error { }

        do {
            try await PanePathOpener.open(path: "/Volumes/PROJECTS/cmux-harness") { _ in
                throw TestFailure()
            }
            Issue.record("Expected the Finder request to fail")
        } catch let error as PanePathOpener.OpenError {
            #expect(error == .finderRejected(path: "/Volumes/PROJECTS/cmux-harness"))
            #expect(error.localizedDescription.contains("volume is mounted"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
