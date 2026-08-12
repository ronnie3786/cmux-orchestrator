import SwiftUI
import WidgetKit

struct HerdPulseLockScreenView: View {
    let context: ActivityViewContext<HerdPulseAttributes>

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    HerdPulseStatusRail(state: context.state)
                    Text("HERD PULSE")
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(HerdPulseTheme.mist)
                }

                Text(context.isStale ? "Last known herd" : title)
                    .font(.headline.monospaced().bold())
                    .foregroundStyle(HerdPulseTheme.text)

                Text(detail)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(HerdPulseTheme.mist)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(context.state.paneCount)")
                    .font(.title.monospaced().bold())
                    .foregroundStyle(HerdPulseTheme.color(for: context.state.phase))
                Text("panes")
                    .font(.caption.monospaced())
                    .foregroundStyle(HerdPulseTheme.mist)
            }
            .accessibilityElement(children: .combine)
        }
        .padding()
        .activityBackgroundTint(HerdPulseTheme.graphite)
        .activitySystemActionForegroundColor(HerdPulseTheme.text)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch context.state.phase {
        case .attention: "Needs you"
        case .ready: "Ready to review"
        case .working: "Herd working"
        case .resting: "All quiet"
        case .offline: "Herd offline"
        }
    }

    private var detail: String {
        if context.state.attentionCount > 0 {
            return "\(context.state.attentionCount) blocked · \(context.state.workingCount) working"
        }
        if context.state.readyCount > 0 {
            return "\(context.state.readyCount) ready · \(context.state.workingCount) working"
        }
        return "\(context.state.workspaceCount) spaces · \(context.state.workingCount) working"
    }
}
