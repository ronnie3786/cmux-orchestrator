import SwiftUI

struct HerdrHudRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession
    let fontScale: HerdrFontScaleStore

    var body: some View {
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
                HerdrHudOrbView(model: model, controller: controller, session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: controller.isExpanded)
        .environment(\.herdrFontScale, fontScale.scale)
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
    }
}
