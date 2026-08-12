import SwiftUI

private struct HerdrHapticModifier: ViewModifier {
    let trigger: HerdrHapticPulse
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: trigger) { oldValue, newValue in
            guard isEnabled,
                  oldValue.sequence != newValue.sequence
            else { return nil }

            return newValue.event.feedback
        }
    }
}

extension View {
    /// Plays feedback only when `fire(_:)` advances the pulse. This makes
    /// repeated events reliable without coupling haptics to incidental state.
    func herdrHaptic(
        trigger: HerdrHapticPulse,
        isEnabled: Bool = true
    ) -> some View {
        modifier(HerdrHapticModifier(trigger: trigger, isEnabled: isEnabled))
    }
}
