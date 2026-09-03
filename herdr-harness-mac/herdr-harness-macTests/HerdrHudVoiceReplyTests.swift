import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
private final class FakeVoiceReplyGateway: HerdrHudVoiceReplyGateway {
    var pane: HerdrPane?
    var sendError: (any Error)?
    private(set) var sentPrompts: [String] = []
    private(set) var acknowledgedPaneIDs: [String] = []
    private(set) var dismissedChipIDs: [String] = []

    func transcribe(_ url: URL) async throws -> VoiceTranscription {
        VoiceTranscription(text: "unused", provider: .apple, language: nil, usedFallback: false)
    }

    func pane(id: String) -> HerdrPane? {
        pane?.id == id ? pane : nil
    }

    func sendPrompt(_ text: String, to pane: HerdrPane) async throws {
        if let sendError { throw sendError }
        sentPrompts.append(text)
    }

    func acknowledgeUnreadAlerts(for pane: HerdrPane) {
        acknowledgedPaneIDs.append(pane.id)
    }

    func dismissHudChip(_ paneID: String) {
        dismissedChipIDs.append(paneID)
    }
}

@MainActor
@Suite("Herdr HUD voice reply")
struct HerdrHudVoiceReplyTests {
    @Test("A sent reply marks the agent read on both read state machines")
    func sendAcknowledgesAndDismisses() async throws {
        let gateway = FakeVoiceReplyGateway()
        gateway.pane = try pane(id: "a")
        let reply = HerdrHudVoiceReply(dismissDelay: .milliseconds(1))
        reply.target(paneID: "m1|a")
        reply.enterEditingForTesting(transcript: "ship it")

        await reply.send(gateway: gateway)

        #expect(gateway.sentPrompts == ["ship it"])
        // The alert ack and the HUD chip are independent and neither cascades,
        // so a reply that never opens the main window has to do both itself.
        #expect(gateway.acknowledgedPaneIDs == ["m1|a"])
        #expect(gateway.dismissedChipIDs == ["m1|a"])
        #expect(reply.phase == .sent)
    }

    @Test("A failed send keeps the draft so the user can retry")
    func failedSendPreservesDraft() async throws {
        let gateway = FakeVoiceReplyGateway()
        gateway.pane = try pane(id: "a")
        gateway.sendError = APIError.invalidResponse
        let reply = HerdrHudVoiceReply()
        reply.target(paneID: "m1|a")
        reply.enterEditingForTesting(transcript: "keep me")

        await reply.send(gateway: gateway)

        guard case .failed = reply.phase else {
            Issue.record("expected a failed phase, got \(reply.phase)")
            return
        }
        #expect(reply.draft == "keep me")
        #expect(gateway.acknowledgedPaneIDs.isEmpty)
        #expect(gateway.dismissedChipIDs.isEmpty)
    }

    @Test("Sending needs a target, a transcript, and a live pane")
    func sendGuards() async throws {
        let gateway = FakeVoiceReplyGateway()
        let reply = HerdrHudVoiceReply()

        // No target at all.
        await reply.send(gateway: gateway)
        #expect(gateway.sentPrompts.isEmpty)

        // Targeted, but the transcript is only whitespace.
        reply.target(paneID: "m1|a")
        reply.enterEditingForTesting(transcript: "   ")
        #expect(!reply.canSend)
        await reply.send(gateway: gateway)
        #expect(gateway.sentPrompts.isEmpty)

        // Real transcript, but the pane went away while we were editing.
        reply.enterEditingForTesting(transcript: "hello")
        await reply.send(gateway: gateway)
        #expect(gateway.sentPrompts.isEmpty)
        guard case .failed = reply.phase else {
            Issue.record("expected a failed phase, got \(reply.phase)")
            return
        }
    }

    @Test("Retargeting is ignored while a reply is in flight")
    func retargetingDoesNotHijackAnInFlightReply() throws {
        let reply = HerdrHudVoiceReply()
        reply.target(paneID: "m1|a")
        reply.enterEditingForTesting(transcript: "for a")

        reply.target(paneID: "m1|b")

        // Sending a recording to the wrong agent would be worse than ignoring it.
        #expect(reply.paneID == "m1|a")
        #expect(reply.draft == "for a")
    }

    @Test("Cancel clears the target, which is what unmounts the strip")
    func cancelResets() throws {
        let reply = HerdrHudVoiceReply()
        reply.target(paneID: "m1|a")
        reply.enterEditingForTesting(transcript: "discard me")

        reply.cancel()

        #expect(reply.paneID == nil)
        #expect(reply.draft.isEmpty)
        #expect(reply.phase == .idle)
    }

    @Test("The chip's mic asks the composer to start recording, not just to open")
    func chipMicRequestsCapture() {
        let session = makeSession()

        // No target yet — nothing to reply to, so nothing is armed.
        session.requestVoiceReplyCapture()
        #expect(!session.pendingVoiceReplyCapture)
        #expect(!session.consumeVoiceReplyCaptureRequest())

        session.setVoiceReplyTargetForTesting("m1|a")
        session.requestVoiceReplyCapture()
        #expect(session.pendingVoiceReplyCapture)

        // The card consumes it exactly once as it mounts, so re-summoning later
        // does not start an unasked-for recording.
        #expect(session.consumeVoiceReplyCaptureRequest())
        #expect(!session.consumeVoiceReplyCaptureRequest())
    }

    @Test("Clearing the reply target disarms a pending capture")
    func clearingTargetDisarmsCapture() {
        let session = makeSession()
        session.setVoiceReplyTargetForTesting("m1|a")
        session.requestVoiceReplyCapture()

        session.clearVoiceReplyTarget()

        #expect(!session.pendingVoiceReplyCapture)
        #expect(!session.consumeVoiceReplyCaptureRequest())
    }

    private func makeSession() -> HerdrHudSession {
        let suiteName = "HerdrHudVoiceReplyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HerdrHudSession(
            userDefaults: defaults,
            agentSettings: AgentModelSettingsStore(defaults: defaults),
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-hud-thread.json")
        )
    }

    private func pane(id: String) throws -> HerdrPane {
        let payload: [String: Any] = [
            "pane_id": id,
            "workspace_id": "w1",
            "tab_id": "t1",
            "agent_status": AgentStatus.done.rawValue,
            "revision": 1,
            "pi_semantic": ["available": true, "protocol_version": 1],
        ]
        return try JSONDecoder().decode(
            HerdrPane.self,
            from: try JSONSerialization.data(withJSONObject: payload)
        )
        .stamped(machineID: "m1")
    }
}

@MainActor
@Suite("Response audio playback completion")
struct ResponseAudioCompletionTests {
    @Test("Only a natural finish reports a completed playback")
    func completionRevisionDistinguishesFinishFromStop() {
        let player = ResponseAudioPlayer()
        var completions = 0
        player.onPlaybackCompleted = { completions += 1 }

        // `stop()` sets exactly the same phase a natural finish does, which is
        // why the CTA needs its own signal rather than watching `phase`.
        player.stop()
        #expect(player.completedPlaybackRevision == 0)
        #expect(completions == 0)

        player.finishPlaybackForTesting()
        #expect(player.completedPlaybackRevision == 1)
        #expect(completions == 1)
    }
}
