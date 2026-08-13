import SwiftUI
import Testing
@testable import herdr_harness_ios

@Suite("Herdr haptic language")
struct HerdrHapticTests {
    @Test("Each workflow maps to a stable semantic feedback")
    func mapsWorkflowFeedback() {
        #expect(HerdrHaptic.selection.feedback == .selection)
        #expect(HerdrHaptic.terminalKey.feedback == .press(.buttonIconOnly))
        #expect(HerdrHaptic.controlsExpanded.feedback == .selection(.on))
        #expect(HerdrHaptic.controlsCollapsed.feedback == .selection(.off))
        #expect(HerdrHaptic.promptSent.feedback == .success)
        #expect(HerdrHaptic.gitStaged.feedback == .increase)
        #expect(HerdrHaptic.gitUnstaged.feedback == .decrease)
        #expect(HerdrHaptic.recordingStarted.feedback == .start)
        #expect(HerdrHaptic.recordingStopped.feedback == .stop)
        #expect(HerdrHaptic.transcriptionStarted.feedback == .start)
        #expect(HerdrHaptic.transcriptionSucceeded.feedback == .success)
        #expect(HerdrHaptic.attention.feedback == .warning)
        #expect(HerdrHaptic.stopped.feedback == .stop)
        #expect(HerdrHaptic.completed.feedback == .success)
        #expect(HerdrHaptic.failed.feedback == .error)
    }

    @Test("Repeated feedback events always advance the pulse")
    func advancesRepeatedEvents() {
        var pulse = HerdrHapticPulse()

        pulse.fire(.terminalKey)
        let first = pulse
        pulse.fire(.terminalKey)

        #expect(first.event == .terminalKey)
        #expect(pulse.event == .terminalKey)
        #expect(pulse.sequence == first.sequence + 1)
        #expect(pulse != first)
    }

    @Test("Agent transitions alert once without buzzing for the first snapshot")
    func tracksAgentStatusTransitions() {
        var tracker = AgentStatusHapticTracker()
        tracker.setSceneActive(true, isDemoMode: true, statuses: ["pane": .working])

        #expect(tracker.observe(["pane": .working]) == nil)
        #expect(tracker.observe(["pane": .blocked]) == .attention)
        #expect(tracker.observe(["pane": .blocked]) == nil)
        #expect(tracker.observe(["pane": .done]) == .completed)
        #expect(tracker.observe(["pane": .idle]) == nil)
    }

    @Test("Foreground catch-up can replace the baseline without feedback")
    func resetsAgentStatusBaseline() {
        var tracker = AgentStatusHapticTracker()
        tracker.setSceneActive(true, isDemoMode: false, statuses: ["pane": .working])

        #expect(tracker.observe(["pane": .blocked]) == nil)
        tracker.recordRefresh(statuses: ["pane": .blocked])

        #expect(tracker.observe(["pane": .blocked]) == nil)
        #expect(tracker.observe(["pane": .done]) == .completed)
    }

    @Test("Ordinary refreshes do not erase an active status transition")
    func preservesTransitionsAcrossOrdinaryRefresh() {
        var tracker = AgentStatusHapticTracker()
        tracker.setSceneActive(true, isDemoMode: true, statuses: ["pane": .working])

        tracker.recordRefresh(statuses: ["pane": .blocked])

        #expect(tracker.observe(["pane": .blocked]) == .attention)
    }

    @Test("Blocked takes priority when several agents change together")
    func prioritizesBlockedAgentTransition() {
        var tracker = AgentStatusHapticTracker()
        tracker.setSceneActive(
            true,
            isDemoMode: true,
            statuses: ["one": .working, "two": .working]
        )

        #expect(tracker.observe(["one": .done, "two": .blocked]) == .attention)
    }
}
