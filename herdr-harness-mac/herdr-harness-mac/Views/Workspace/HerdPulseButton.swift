import SwiftUI

/// Start/stop Herd Pulse.
///
/// iOS drew this as a 48pt square in the workspace switcher's header. The Mac
/// has no such header — the switcher became the sidebar — so this is the
/// detail toolbar's pulse control, sized like a toolbar item and tinted by
/// whether Pulse is live. It is the visible twin of the View ▸ Start Herd Pulse
/// command; without one of them the menu-bar extra can never be inserted.
struct HerdPulseButton: View {
    @Environment(HerdPulseCoordinator.self) private var pulse

    var body: some View {
        Button(
            pulse.isRunning ? "Stop Herd Pulse" : "Start Herd Pulse",
            systemImage: "waveform.path.ecg"
        ) {
            Task { await pulse.toggle() }
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(pulse.isRunning ? HerdrTheme.signal : HerdrTheme.mist)
        .disabled(pulse.isBusy)
        .help(pulse.isRunning ? "Stop Herd Pulse" : "Start Herd Pulse")
        .accessibilityValue(pulse.statusText)
        .accessibilityHint(pulse.backgroundUpdatesText)
        .accessibilityIdentifier("herd-pulse-button")
    }
}
