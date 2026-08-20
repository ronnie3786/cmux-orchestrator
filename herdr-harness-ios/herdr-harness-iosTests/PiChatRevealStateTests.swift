import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Pi chat reveal state")
struct PiChatRevealStateTests {
    @Test("Empty content keeps the timeline hidden")
    func emptyContentKeepsTimelineHidden() {
        var state = PiChatRevealState()
        state.structureDidChange(
            hadContent: false,
            hasContent: false,
            structureChanged: false,
            isNearBottom: true,
            reduceMotion: false
        )

        #expect(state.phase == .hidden)

        state.structureDidChange(
            hadContent: false,
            hasContent: true,
            structureChanged: true,
            isNearBottom: true,
            reduceMotion: false
        )
        state.structureDidChange(
            hadContent: true,
            hasContent: false,
            structureChanged: true,
            isNearBottom: true,
            reduceMotion: false
        )

        #expect(state.phase == .hidden)
    }

    @Test("First population starts measuring")
    func firstPopulationStartsMeasuring() {
        var state = PiChatRevealState()

        state.structureDidChange(
            hadContent: false,
            hasContent: true,
            structureChanged: true,
            isNearBottom: true,
            reduceMotion: false
        )

        #expect(state.phase == .measuring)
    }

    @Test("Settled first population reveals after scrolling to bottom")
    func settledFirstPopulationRevealsAfterScrollingToBottom() {
        var state = measuringState()

        let action = state.settledHeightDidChange(contentHeight: 600, containerHeight: 400)

        #expect(state.phase == .revealed)
        #expect(action == .revealAfterScrollingToBottom)
    }

    @Test("Settled structural changes scroll with the motion setting")
    func settledStructuralChangesScrollWithMotionSetting() {
        var animatedState = revealedState()
        animatedState.structureDidChange(
            hadContent: true,
            hasContent: true,
            structureChanged: true,
            isNearBottom: true,
            reduceMotion: false
        )

        #expect(
            animatedState.settledHeightDidChange(contentHeight: 700, containerHeight: 400)
                == .scrollToBottom(animated: true)
        )

        var reducedMotionState = revealedState()
        reducedMotionState.structureDidChange(
            hadContent: true,
            hasContent: true,
            structureChanged: true,
            isNearBottom: true,
            reduceMotion: true
        )

        #expect(
            reducedMotionState.settledHeightDidChange(contentHeight: 700, containerHeight: 400)
                == .scrollToBottom(animated: false)
        )
    }

    @Test("Structural changes away from the bottom do not scroll")
    func structuralChangesAwayFromBottomDoNotScroll() {
        var state = revealedState()
        state.structureDidChange(
            hadContent: true,
            hasContent: true,
            structureChanged: true,
            isNearBottom: false,
            reduceMotion: false
        )

        #expect(state.settledHeightDidChange(contentHeight: 700, containerHeight: 400) == .none)
    }

    @Test("Reset returns to hidden and a later population measures again")
    func resetThenRepopulationMeasuresAgain() {
        var state = revealedState()
        state.structureDidChange(
            hadContent: true,
            hasContent: false,
            structureChanged: true,
            isNearBottom: true,
            reduceMotion: false
        )

        #expect(state.phase == .hidden)

        state.structureDidChange(
            hadContent: false,
            hasContent: true,
            structureChanged: true,
            isNearBottom: true,
            reduceMotion: false
        )

        #expect(state.phase == .measuring)
    }

    @Test("Settled geometry while hidden does nothing")
    func settledGeometryWhileHiddenDoesNothing() {
        var state = PiChatRevealState()

        #expect(state.settledHeightDidChange(contentHeight: 600, containerHeight: 400) == .none)
        #expect(state.phase == .hidden)
    }

    private func measuringState() -> PiChatRevealState {
        var state = PiChatRevealState()
        state.structureDidChange(
            hadContent: false,
            hasContent: true,
            structureChanged: true,
            isNearBottom: true,
            reduceMotion: false
        )
        return state
    }

    private func revealedState() -> PiChatRevealState {
        var state = measuringState()
        _ = state.settledHeightDidChange(contentHeight: 600, containerHeight: 400)
        return state
    }
}
