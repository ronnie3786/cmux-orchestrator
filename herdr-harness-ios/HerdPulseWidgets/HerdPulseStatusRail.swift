import SwiftUI

struct HerdPulseStatusRail: View {
    let state: HerdPulseAttributes.ContentState
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            statusDot(color: HerdPulseTheme.alert, active: state.attentionCount > 0)
            statusDot(color: HerdPulseTheme.signal, active: state.readyCount > 0)
            statusDot(color: HerdPulseTheme.working, active: state.workingCount > 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func statusDot(color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : HerdPulseTheme.elevated)
            .frame(width: compact ? 5 : 8, height: compact ? 5 : 8)
            .overlay {
                if active {
                    Circle().strokeBorder(color.opacity(0.45), lineWidth: compact ? 1 : 2)
                        .scaleEffect(1.65)
                }
            }
    }

    private var accessibilitySummary: String {
        "\(state.attentionCount) need attention, \(state.readyCount) ready, \(state.workingCount) working"
    }
}
