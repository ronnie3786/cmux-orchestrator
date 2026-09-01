import Testing
@testable import herdr_harness_mac

@Suite("Pane references")
struct PaneReferenceTests {
    @Test("Bare pane IDs pass through unchanged")
    func barePaneID() {
        #expect(PaneReference.normalize("w1:p2") == "w1:p2")
    }

    @Test("Percent-encoded pane IDs decode once")
    func percentEncodedPaneIDs() {
        #expect(PaneReference.normalize("wK%3Ap1Z") == "wK:p1Z")
        #expect(PaneReference.normalize("wK%3ap1Z") == "wK:p1Z")
        #expect(PaneReference.normalize("wK%253Ap1Z") == "wK%3Ap1Z")
    }

    @Test("Whitespace and wrapping punctuation are removed")
    func trimsPasteArtifacts() {
        #expect(PaneReference.normalize("  \n w1:p2 \n  ") == "w1:p2")
        #expect(PaneReference.normalize("`wK:p1Z`") == "wK:p1Z")
        #expect(PaneReference.normalize("'w1:p2'") == "w1:p2")
        #expect(PaneReference.normalize("\"w1:p2\"") == "w1:p2")
        #expect(PaneReference.normalize("<w1:p2>") == "w1:p2")
    }

    @Test("Machine-scoped pane IDs pass through and split for routing")
    func machineScopedPaneID() {
        let reference = "rocketbot|w1:p2"

        #expect(PaneReference.normalize(reference) == reference)
        #expect(PaneReference.normalize("rocketbot%7Cw1%3Ap2") == reference)
        #expect(MachineScopedID.split(reference)?.machineID == "rocketbot")
        #expect(MachineScopedID.split(reference)?.rawID == "w1:p2")
    }

    @Test("Deep links delegate to the app URL grammar")
    func deepLinks() {
        #expect(PaneReference.normalize("herdr://pane?pane_id=w1:p2") == "w1:p2")
        #expect(PaneReference.normalize("herdr://pane/w1:p2") == "w1:p2")
        #expect(PaneReference.normalize("https://example.com/open/pane/w1:p2") == "w1:p2")
    }

    @Test("Unusable and ambiguous references are rejected")
    func rejectsUnusableReferences() {
        #expect(PaneReference.normalize("") == nil)
        #expect(PaneReference.normalize(" \n\t ") == nil)
        #expect(PaneReference.normalize("``") == nil)
        #expect(PaneReference.normalize("''") == nil)
        #expect(PaneReference.normalize("\"\"") == nil)
        #expect(PaneReference.normalize("w1: p2") == nil)
        #expect(PaneReference.normalize("not-a-route://pane") == nil)
    }
}
