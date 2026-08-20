import CoreGraphics

/// Reveal/scroll-anchor phase for the Pi chat timeline. Pure state machine:
/// no view code, no timers, no async. `PiChatTimelineView` feeds it two kinds
/// of discrete events and performs the actions returned.
enum PiChatRevealPhase: Equatable {
    /// No content to show yet, or the store was just reset (reconnect,
    /// session switch, pane switch). Timeline stays invisible.
    case hidden
    /// Content exists but no settled, laid-out geometry reading has been seen
    /// yet. Timeline stays invisible (opacity 0, unanimated).
    case measuring
    /// Geometry has settled at least once. Timeline is visible and behaves
    /// normally (pinned-to-bottom autoscroll, jump-to-latest).
    case revealed
}

enum PiChatRevealAction: Equatable {
    /// No-op.
    case none
    /// Perform an unanimated scrollTo(edge: .bottom) and reveal the timeline.
    /// Fired exactly once, the first time geometry settles after content first
    /// populates.
    case revealAfterScrollingToBottom
    /// Timeline is already visible. Re-anchor to bottom now that newly
    /// appended content's real height is known.
    case scrollToBottom(animated: Bool)
}

struct PiChatRevealState: Equatable {
    private(set) var phase: PiChatRevealPhase = .hidden
    private var pendingScroll = false
    private var pendingScrollAnimated = false

    /// Feed on every timeline structure change.
    mutating func structureDidChange(
        hadContent: Bool,
        hasContent: Bool,
        structureChanged: Bool,
        isNearBottom: Bool,
        reduceMotion: Bool
    ) {
        guard hasContent else {
            phase = .hidden
            pendingScroll = false
            pendingScrollAnimated = false
            return
        }

        if !hadContent {
            phase = .measuring
            pendingScroll = false
            pendingScrollAnimated = false
            return
        }

        guard phase == .revealed, isNearBottom, structureChanged else { return }
        pendingScroll = true
        pendingScrollAnimated = !reduceMotion
    }

    /// Feed only once the view has confirmed that content height has settled.
    mutating func settledHeightDidChange(
        contentHeight: CGFloat,
        containerHeight: CGFloat
    ) -> PiChatRevealAction {
        switch phase {
        case .hidden:
            return .none
        case .measuring:
            phase = .revealed
            pendingScroll = false
            pendingScrollAnimated = false
            return .revealAfterScrollingToBottom
        case .revealed:
            guard pendingScroll else { return .none }
            pendingScroll = false
            let animated = pendingScrollAnimated
            pendingScrollAnimated = false
            return .scrollToBottom(animated: animated)
        }
    }
}

struct PiChatScrollMetrics: Equatable {
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}
