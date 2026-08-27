import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Lifecycle cancellation")
struct HerdrCancellationTests {
    @Test("Boxed URLSession cancellation is lifecycle state")
    func boxedURLCancellation() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        #expect(HerdrCancellation.isCancellation(error))
    }

    @Test("Nested URLSession cancellation is lifecycle state")
    func nestedURLCancellation() {
        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let wrapper = NSError(
            domain: "HerdrTransport",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: cancellation]
        )

        #expect(HerdrCancellation.isCancellation(wrapper))
    }

    @Test("Aggregate URLSession cancellation is lifecycle state")
    func aggregateURLCancellation() {
        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let wrapper = NSError(
            domain: "HerdrTransport",
            code: 2,
            userInfo: [NSMultipleUnderlyingErrorsKey: [cancellation]]
        )

        #expect(HerdrCancellation.isCancellation(wrapper))
    }

    @Test("Navigation cancellation never becomes a terminal banner")
    func navigationCancellationIsNotPresented() {
        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        #expect(!TerminalRefreshPolicy.shouldPresentSnapshotFailure(
            cancellation,
            requestSequence: 4,
            currentRequestSequence: 4,
            requestedPaneID: "pane-a",
            currentPaneID: "pane-a"
        ))
    }

    @Test("A stale pane failure never becomes a terminal banner")
    func stalePaneFailureIsNotPresented() {
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)

        #expect(!TerminalRefreshPolicy.shouldPresentSnapshotFailure(
            failure,
            requestSequence: 4,
            currentRequestSequence: 5,
            requestedPaneID: "pane-a",
            currentPaneID: "pane-b"
        ))
        #expect(TerminalRefreshPolicy.shouldPresentSnapshotFailure(
            failure,
            requestSequence: 5,
            currentRequestSequence: 5,
            requestedPaneID: "pane-b",
            currentPaneID: "pane-b"
        ))
    }
}
