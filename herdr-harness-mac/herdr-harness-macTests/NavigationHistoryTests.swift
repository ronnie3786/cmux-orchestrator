import Testing
@testable import herdr_harness_mac

@Suite("Navigation history")
struct NavigationHistoryTests {
    @Test("Recording the current destination again is a no-op")
    func recordingCurrentDestinationIsNoOp() {
        var history = NavigationHistory()

        history.record(.pane("a"))
        history.record(.pane("a"))

        #expect(history.current == .pane("a"))
        #expect(history.backward.isEmpty)
        #expect(!history.canGoBack)
    }

    @Test("Back and forward walk the recorded trail")
    func backAndForwardWalkTrail() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))

        #expect(history.goBack(isAlive: alive) == .pane("b"))
        #expect(history.goBack(isAlive: alive) == .pane("a"))
        #expect(history.current == .pane("a"))
        #expect(history.forward == [.pane("b"), .pane("c")])
        #expect(history.goForward(isAlive: alive) == .pane("b"))
    }

    @Test("A new destination clears the forward stack")
    func newDestinationClearsForwardStack() {
        var history = trail(.pane("a"), .pane("b"))
        _ = history.goBack(isAlive: alive)

        history.record(.attention)

        #expect(!history.canGoForward)
        #expect(history.backward == [.pane("a")])
    }

    @Test("Mixed scope and pane destinations round-trip")
    func mixedDestinationsRoundTrip() {
        let destinations: [HerdrDestination] = [
            .pane("a"), .activeWork, .workspace("w1"), .activity,
        ]
        var history = trail(destinations)

        #expect(history.goBack(isAlive: alive) == .workspace("w1"))
        #expect(history.goBack(isAlive: alive) == .activeWork)
        #expect(history.goBack(isAlive: alive) == .pane("a"))
        #expect(history.goForward(isAlive: alive) == .activeWork)
        #expect(history.goForward(isAlive: alive) == .workspace("w1"))
        #expect(history.goForward(isAlive: alive) == .activity)
    }

    @Test("The stack is capped and drops the oldest")
    func stackCapDropsOldestDestination() {
        var history = NavigationHistory()
        for index in 0..<(NavigationHistory.capacity + 10) {
            history.record(.pane("pane-\(index)"))
        }

        #expect(history.backward.count == NavigationHistory.capacity)
        #expect(history.backward.first == .pane("pane-9"))
        #expect(history.current == .pane("pane-59"))
    }

    @Test("Back skips destinations the fleet has dropped")
    func backSkipsDroppedDestinations() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))

        #expect(history.goBack(isAlive: { $0 != .pane("b") }) == .pane("a"))
        #expect(history.current == .pane("a"))
        #expect(!history.forward.contains(.pane("b")))
        #expect(history.forward == [.pane("c")])
    }

    @Test("Back returns nil and leaves the current destination alone when nothing survives")
    func backWithNoSurvivingDestinationsLeavesCurrentAlone() {
        var history = trail(.pane("a"), .pane("b"))

        #expect(history.goBack(isAlive: { _ in false }) == nil)
        #expect(history.current == .pane("b"))
        history.prune(isAlive: { _ in false })
        #expect(!history.canGoBack)
    }

    @Test("Pruning drops dead entries from both stacks and keeps the current one")
    func pruningDropsDeadEntriesButKeepsCurrent() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))
        _ = history.goBack(isAlive: alive)

        history.prune(isAlive: { $0 == .pane("b") })

        #expect(history.current == .pane("b"))
        #expect(history.backward.isEmpty)
        #expect(history.forward.isEmpty)
    }

    @Test("Forward mirrors back")
    func forwardSkipsDroppedDestinationsAndLeavesCurrentWhenNoneSurvive() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))
        _ = history.goBack(isAlive: alive)
        _ = history.goBack(isAlive: alive)

        #expect(history.goForward(isAlive: { $0 != .pane("b") }) == .pane("c"))
        #expect(history.current == .pane("c"))
        #expect(history.backward == [.pane("a")])

        var noSurvivors = trail(.pane("a"), .pane("b"))
        _ = noSurvivors.goBack(isAlive: alive)
        #expect(noSurvivors.goForward(isAlive: { _ in false }) == nil)
        #expect(noSurvivors.current == .pane("a"))
    }

    @Test("An empty history reports neither direction")
    func emptyHistoryReportsNeitherDirection() {
        var history = NavigationHistory()

        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.goBack(isAlive: alive) == nil)
        #expect(history.goForward(isAlive: alive) == nil)
    }

    private func trail(_ destinations: HerdrDestination...) -> NavigationHistory {
        trail(destinations)
    }

    private func trail(_ destinations: [HerdrDestination]) -> NavigationHistory {
        var history = NavigationHistory()
        destinations.forEach { history.record($0) }
        return history
    }

    private func alive(_ destination: HerdrDestination) -> Bool {
        _ = destination
        return true
    }
}
