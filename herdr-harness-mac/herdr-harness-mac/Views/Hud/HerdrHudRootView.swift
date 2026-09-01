import SwiftUI

struct HerdrHudRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession
    let notes: HerdrHudNotesState
    let fontScale: HerdrFontScaleStore

    private var sessionChips: (chips: [HerdrHudSessionChips.Chip], overflow: Int) {
        HerdrHudSessionChips.chips(
            panes: model.workspaces.flatMap(\.panes),
            mutedPaneIDs: model.mutedHudSessionIDs,
            dismissedStatuses: model.dismissedHudChipStatuses,
            revealTitles: model.showSessionTitles
        )
    }

    var body: some View {
        let chipState = sessionChips
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
                    Group {
                        if chipState.chips.isEmpty {
                            HerdrHudOrbView(model: model, controller: controller, session: session)
                        } else {
                            VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
                                HerdrHudOrbView(model: model, controller: controller, session: session)
                                    .frame(
                                        width: HerdrHudPlacement.collapsedSize.width,
                                        height: HerdrHudPlacement.collapsedSize.height
                                    )
                                HerdrHudSessionChipsView(
                                    model: model,
                                    chips: chipState.chips,
                                    overflow: chipState.overflow
                                )
                            }
                        }
                    }
                    .onChange(of: chipState.chips.count, initial: true) { _, count in
                        controller.setCollapsedChipCount(count)
                    }
                }
            }
            HerdrHudNotesStripView(model: model, controller: controller, notes: notes)
        }
        .contentShape(Rectangle())
        .onHover { notes.setHovering($0) }
        .onChange(of: notes.layout, initial: true) { _, _ in controller.notesLayoutDidChange() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: controller.isExpanded)
        .environment(\.herdrFontScale, fontScale.scale)
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
    }
}
