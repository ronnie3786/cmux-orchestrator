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
            revealTitles: model.showSessionTitles,
            limit: controller.isShowingAllChips
                ? HerdrHudPlacement.maxExpandedChips
                : HerdrHudPlacement.maxChips
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
                                    session: session,
                                    chips: chipState.chips,
                                    overflow: chipState.overflow,
                                    showAll: controller.showAllChips
                                )
                                .onHover { controller.setHoveringChips($0) }
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
}
