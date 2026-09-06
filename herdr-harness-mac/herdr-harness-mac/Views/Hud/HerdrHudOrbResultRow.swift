import SwiftUI

/// HUD run results belong to the orb. Pane outputs remain on their sessions.
struct HerdrHudOrbResultRow: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession
    let artifacts: [AgentResultArtifact]
    var attentionChipCount: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            if !artifacts.isEmpty {
                HerdrHudResultArtifactRailView(model: model, artifacts: artifacts)
            }

            ZStack(alignment: .topLeading) {
                HerdrHudOrbView(
                model: model,
                controller: controller,
                session: session,
                attentionChipCount: attentionChipCount
                )
                .frame(width: 56, height: 56)
                if let voice = controller.quickVoice, voice.isEnabled {
                    QuickVoicePanelView(controller: voice, session: voice.session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: HerdrHudPlacement.collapsedSize.width, height: HerdrHudPlacement.collapsedSize.height)
        }
    }
}
