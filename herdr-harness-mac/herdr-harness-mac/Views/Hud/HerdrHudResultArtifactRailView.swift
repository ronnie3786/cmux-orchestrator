import SwiftUI

/// A fixed-width docking lane for result nodes. Three compact nodes plus one
/// expanded node fit inside the lane, so hover never resizes or repositions the
/// AppKit HUD panel.
struct HerdrHudResultArtifactRailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var model: HerdrAppModel
    let artifacts: [AgentResultArtifact]
    @State private var hoveredArtifactID: String? = nil

    private var sortedArtifacts: [AgentResultArtifact] {
        artifacts.sorted { left, right in
            let leftDate = left.createdDate ?? .distantPast
            let rightDate = right.createdDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.id > right.id
        }
    }

    private var visibleArtifacts: [AgentResultArtifact] {
        Array(sortedArtifacts.prefix(HerdrHudPlacement.maxVisibleResults))
    }

    private var hiddenArtifactCount: Int {
        max(0, sortedArtifacts.count - visibleArtifacts.count)
    }

    var body: some View {
        HStack(spacing: HerdrHudPlacement.resultNodeSpacing) {
            ForEach(Array(visibleArtifacts.reversed())) { artifact in
                HerdrHudResultArtifactNodeView(
                    model: model,
                    artifact: artifact,
                    hiddenArtifactCount: artifact.id == visibleArtifacts.last?.id
                        ? hiddenArtifactCount
                        : 0,
                    hoveredArtifactID: $hoveredArtifactID
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .scale(scale: 0.74, anchor: .trailing).combined(with: .opacity),
                            removal: .scale(scale: 0.5, anchor: .trailing).combined(with: .opacity)
                        )
                )
            }

            connector
        }
        .frame(width: HerdrHudPlacement.resultRailWidth, alignment: .trailing)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.12),
            value: visibleArtifacts.map(\.id)
        )
        .onChange(of: visibleArtifacts.map(\.id)) { _, visibleIDs in
            if let hoveredArtifactID, !visibleIDs.contains(hoveredArtifactID) {
                self.hoveredArtifactID = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unviewed results")
        .accessibilityValue(accessibilitySummary)
    }

    private var connector: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(HerdrTheme.mauve.opacity(0.78))
                .frame(width: 3, height: 3)
                .shadow(color: HerdrTheme.mauve.opacity(0.7), radius: 3)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [HerdrTheme.mauve.opacity(0.72), HerdrTheme.accent.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .frame(width: HerdrHudPlacement.resultConnectorWidth)
        .accessibilityHidden(true)
    }

    private var accessibilitySummary: String {
        if hiddenArtifactCount > 0 {
            return "\(visibleArtifacts.count) shown, \(hiddenArtifactCount) more waiting"
        }
        return "\(visibleArtifacts.count) waiting"
    }
}
