import Foundation

/// One place the detail column can be, addressed by identity rather than by
/// the (`detailScope`, `selectedPaneID`) pair the shell actually stores.
///
/// `.session` with no pane is deliberately absent: `resolvedScope(for:)`
/// degrades that to the workspace overview or the attention deck, so it is
/// not a place the user was ever standing and must never enter the history.
///
/// Note: the pane's sub-mode (chat/terminal/git/skills) is NOT captured —
/// going Back to a pane lands on whatever mode that pane's session view
/// auto-selects, not the one you left. See PaneDetailMode; this is a
/// deliberate scope cut, not an oversight.
enum HerdrDestination: Hashable, Sendable {
    case pane(String)        // scoped pane id — MachineScopedID.compose
    case workspace(String)   // scoped workspace id
    case activeWork
    case fleet
    case attention
    case activity
}

/// Browser-shaped back/forward over `HerdrDestination`.
///
/// Pure and value-typed so the semantics — dedupe, forward-stack
/// invalidation, the cap, and skipping destinations the fleet has since
/// dropped — are testable without a `HerdrAppModel` or a running window.
struct NavigationHistory: Equatable, Sendable {
    /// Deep enough to cover a long working session, shallow enough that a
    /// linear liveness sweep on every fleet revision is free.
    static let capacity = 50

    private(set) var backward: [HerdrDestination] = []   // oldest -> newest
    private(set) var current: HerdrDestination?
    private(set) var forward: [HerdrDestination] = []    // nearest -> furthest

    var canGoBack: Bool { !backward.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    mutating func record(_ destination: HerdrDestination) {
        guard destination != current else { return }

        if let current {
            backward.append(current)
        }
        current = destination
        forward.removeAll()
        trimBackward()
    }

    mutating func goBack(isAlive: (HerdrDestination) -> Bool) -> HerdrDestination? {
        while let destination = backward.popLast() {
            guard isAlive(destination) else { continue }

            if let current, isAlive(current) {
                forward.insert(current, at: 0)
            }
            current = destination
            return destination
        }
        return nil
    }

    mutating func goForward(isAlive: (HerdrDestination) -> Bool) -> HerdrDestination? {
        while !forward.isEmpty {
            let destination = forward.removeFirst()
            guard isAlive(destination) else { continue }

            if let current, isAlive(current) {
                backward.append(current)
                trimBackward()
            }
            current = destination
            return destination
        }
        return nil
    }

    mutating func prune(isAlive: (HerdrDestination) -> Bool) {
        let prunedBackward = backward.filter(isAlive)
        let prunedForward = forward.filter(isAlive)
        guard prunedBackward.count != backward.count || prunedForward.count != forward.count else { return }
        backward = prunedBackward
        forward = prunedForward
    }

    /// Changes the selected history entry while replaying a Back or Forward
    /// destination, without giving that replay the semantics of a new visit.
    mutating func setCurrent(_ destination: HerdrDestination) {
        current = destination
    }

    private mutating func trimBackward() {
        while backward.count > Self.capacity {
            backward.removeFirst()
        }
    }
}
