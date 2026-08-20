import SwiftUI

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
        .font(.headline.bold())
        .foregroundStyle(pulse.isRunning ? HerdrTheme.signal : HerdrTheme.mist)
        .frame(width: 48, height: 48)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(
                    pulse.isRunning ? HerdrTheme.signal.opacity(0.5) : HerdrTheme.surface,
                    lineWidth: 1
                )
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(pulse.isRunning ? HerdrTheme.signal : HerdrTheme.muted)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle().strokeBorder(HerdrTheme.graphite, lineWidth: 1)
                }
                .padding(7)
                .accessibilityHidden(true)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .buttonStyle(.plain)
        .disabled(pulse.isBusy)
        .help(pulse.isRunning ? "Stop Herd Pulse" : "Start Herd Pulse")
        .accessibilityValue(pulse.statusText)
        .accessibilityHint(pulse.backgroundUpdatesText)
    }
}
