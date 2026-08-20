import SwiftUI

struct FleetSummaryView: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        GlassCard {
            HStack(spacing: 0) {
                metric(value: model.workspaces.count, label: "spaces", symbol: "rectangle.3.group")
                divider
                metric(value: model.workingCount, label: "working", symbol: "waveform.path.ecg")
                divider
                metric(value: model.attentionPanes.count, label: "need you", symbol: "hand.raised.fill")
            }
            .padding(.vertical, 15)
        }
    }

    private func metric(value: Int, label: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Label("\(value)", systemImage: symbol)
                .herdrFont(.headline, weight: .bold)
                .foregroundStyle(value > 0 && label == "need you" ? HerdrTheme.alert : .primary)
            Text(label)
                .herdrFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 34)
    }
}
