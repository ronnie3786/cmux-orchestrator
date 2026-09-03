import SwiftUI

/// Results from HUD runs, or from panes that have since disappeared, dock to
/// the orb so an unviewed artifact can never be stranded without an owner.
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

            HerdrHudOrbView(
                model: model,
                controller: controller,
                session: session,
                attentionChipCount: attentionChipCount
            )
                .frame(
                    width: HerdrHudPlacement.collapsedSize.width,
                    height: HerdrHudPlacement.collapsedSize.height
                )
        }
    }
}
