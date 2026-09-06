import SwiftUI

struct HerdrHudRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession
    let notes: HerdrHudNotesState
    let fontScale: HerdrFontScaleStore

    @State private var voiceReply = HerdrHudVoiceReply()

    private var sessionChips: (
        chips: [HerdrHudSessionChips.Chip],
        overflow: Int,
        detachedArtifacts: [AgentResultArtifact]
    ) {
        QuickVoiceHudProjection.chips(
            panes: model.workspaces.flatMap(\.panes),
            notes: controller.quickVoice?.session.notes ?? [],
            mutedPaneIDs: model.mutedHudSessionIDs,
            dismissed: model.dismissedHudChips,
            revealTitles: model.showSessionTitles,
            artifacts: model.unopenedResultArtifacts,
            showAll: controller.isShowingAllChips
        )
    }

    /// What the orb badges: the chips this projection is willing to show that
    /// actually need attention, plus whatever is folded under `+N`. Counting
    /// only `needsAttention` chips keeps a `.working` pane driving the orb's
    /// working state rather than flipping it to attention.
    private func attentionChipCount(
        _ state: (chips: [HerdrHudSessionChips.Chip], overflow: Int, detachedArtifacts: [AgentResultArtifact])
    ) -> Int {
        state.chips.count(where: { $0.status.needsAttention }) + state.overflow
    }

    /// Recomputed whenever the target pane reports new work, which is the cue
    /// that the answer the reply offer belongs to has been superseded.
    private var replyTargetActivity: Date? {
        session.voiceReplyTarget.flatMap { model.pane(id: $0) }?.lastActivityAt
    }

    var body: some View {
        let chipState = sessionChips
        let collapsedRowCount = chipState.chips.count + (chipState.overflow > 0 ? 1 : 0)
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.notesGap) {
            Group {
                if controller.isExpanded {
                    HerdrHudCardView(model: model, controller: controller, session: session)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity),
                                    removal: .scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity)
                                )
                        )
                } else {
                    VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
                        HerdrHudOrbResultRow(
                            model: model,
                            controller: controller,
                            session: session,
                            artifacts: chipState.detachedArtifacts,
                            attentionChipCount: attentionChipCount(chipState)
                        )

                        if let voice = controller.quickVoice, voice.isExpanded {
                            QuickVoiceDetailsView(controller: voice, session: voice.session, model: model)
                        }

                        if !chipState.chips.isEmpty || chipState.overflow > 0 {
                            HerdrHudSessionChipsView(
                                model: model,
                                session: session,
                                chips: chipState.chips,
                                overflow: chipState.overflow,
                                showAll: controller.showAllChips,
                                summon: controller.summon,
                                voiceReply: voiceReply,
                                openVoiceRequest: { controller.quickVoice?.showDetails(noteID: $0) }
                            )
                            .onHover { controller.setHoveringChips($0) }
                        }
                    }
                    .onChange(of: collapsedRowCount, initial: true) { _, count in
                        controller.setCollapsedChipCount(count)
                    }
                    .onChange(of: hasResultRail(chipState), initial: true) { _, isVisible in
                        controller.setCollapsedResultRailVisible(isVisible)
                    }
                }
            }
            if voiceReply.showsCard {
                HerdrHudVoiceReplyCardView(model: model, voiceReply: voiceReply)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing))
                    )
            }
            HerdrHudNotesStripView(model: model, controller: controller, notes: notes)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: voiceReply.showsCard)
        .onChange(of: voiceReply.showsCard, initial: true) { _, isVisible in
            controller.setVoiceReplyCardVisible(isVisible)
        }
        .onChange(of: controller.quickVoice?.session.recorder.status) { _, _ in
            controller.quickVoice?.session.recordingStateChanged()
        }
        .onChange(of: controller.quickVoice?.session.recorder.errorMessage) { _, _ in
            controller.quickVoice?.session.recordingStateChanged()
        }
        .onChange(of: controller.quickVoice?.session.phase) { _, phase in
            if phase == .recording {
                voiceReply.cancel()
                session.responseAudioPlayer.stop()
            }
        }
        .onChange(of: session.voiceReplyTarget, initial: true) { _, target in
            // A new answer finishing retargets the reply; losing the target
            // means the session it belonged to is gone.
            if target == nil { voiceReply.cancel() }
        }
        // Sending or dismissing ends the reply. Without this the offer stayed
        // pinned to the chip forever, so the speaker never came back for the
        // next answer.
        .onChange(of: voiceReply.paneID) { previous, current in
            if previous != nil, current == nil { session.clearVoiceReplyTarget() }
        }
        .onChange(of: replyTargetActivity, initial: true) { _, _ in
            session.expireVoiceReplyTargetIfStale(
                pane: session.voiceReplyTarget.flatMap { model.pane(id: $0) },
                isReplyInFlight: voiceReply.paneID != nil
            )
        }
        .contentShape(Rectangle())
        .onHover { notes.setHovering($0) }
        .onChange(of: notes.layout, initial: true) { _, _ in controller.notesLayoutDidChange() }
        .background(
            HerdrHudWindowDragHandle(
                onDragBegan: controller.beginPanelDrag,
                onDragEnded: controller.endPanelDrag
            )
        )
        // The panel is placed by its top-right corner and grows downward, so the
        // content must be pinned there too. Centering (the default) let content
        // that had already taken its final size overflow above the screen for
        // the whole of every frame animation, which read as the HUD jumping
        // off-screen and sliding back in.
        .padding(HerdrHudPlacement.shadowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: controller.isExpanded)
        .environment(\.herdrFontScale, fontScale.scale)
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
    }

    private func hasResultRail(
        _ chipState: (
            chips: [HerdrHudSessionChips.Chip],
            overflow: Int,
            detachedArtifacts: [AgentResultArtifact]
        )
    ) -> Bool {
        !chipState.detachedArtifacts.isEmpty || chipState.chips.contains { !$0.artifacts.isEmpty }
    }
}
