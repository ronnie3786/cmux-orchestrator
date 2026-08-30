import SwiftUI

struct HerdrHudRunningRowView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var session: HerdrHudSession

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(HerdrTheme.accent)
            Text("Thinking… \(session.elapsedSeconds)s")
                .herdrFont(.caption, monospacedDigit: true)
                .foregroundStyle(HerdrTheme.mist)
            Spacer()
            Button("Stop", action: stop)
                .buttonStyle(.bordered)
                .tint(HerdrTheme.alert)
                .controlSize(.small)
        }
    }

    private func stop() {
        Task { await session.stop(model: model) }
    }
}
