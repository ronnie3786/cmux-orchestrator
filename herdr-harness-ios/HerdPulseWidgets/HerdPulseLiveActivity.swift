import ActivityKit
import SwiftUI
import WidgetKit

struct HerdPulseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HerdPulseAttributes.self) { context in
            HerdPulseLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("herdr")
                            .font(.headline.monospaced().bold())
                        HerdPulseStatusRail(state: context.state)
                    }
                    .foregroundStyle(HerdPulseTheme.text)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.paneCount)")
                            .font(.title2.monospaced().bold())
                            .foregroundStyle(HerdPulseTheme.color(for: context.state.phase))
                        Text("panes")
                            .font(.caption.monospaced())
                            .foregroundStyle(HerdPulseTheme.mist)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        metric("needs you", value: context.state.attentionCount, color: HerdPulseTheme.alert)
                        Spacer()
                        metric("ready", value: context.state.readyCount, color: HerdPulseTheme.signal)
                        Spacer()
                        metric("working", value: context.state.workingCount, color: HerdPulseTheme.working)
                    }
                    .padding(.top, 5)
                }
            } compactLeading: {
                HerdPulseStatusRail(state: context.state, compact: true)
            } compactTrailing: {
                Text("\(primaryCount(for: context.state))")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(HerdPulseTheme.color(for: context.state.phase))
                    .accessibilityLabel(compactAccessibilityLabel(for: context.state))
            } minimal: {
                Circle()
                    .fill(HerdPulseTheme.color(for: context.state.phase))
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .strokeBorder(HerdPulseTheme.color(for: context.state.phase).opacity(0.45), lineWidth: 2)
                            .scaleEffect(1.6)
                    }
                    .accessibilityLabel(compactAccessibilityLabel(for: context.state))
            }
            .keylineTint(HerdPulseTheme.color(for: context.state.phase))
        }
    }

    private func metric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.headline.monospaced().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(HerdPulseTheme.mist)
        }
        .accessibilityElement(children: .combine)
    }

    private func primaryCount(for state: HerdPulseAttributes.ContentState) -> Int {
        if state.attentionCount > 0 { return state.attentionCount }
        if state.readyCount > 0 { return state.readyCount }
        return state.workingCount
    }

    private func compactAccessibilityLabel(for state: HerdPulseAttributes.ContentState) -> String {
        switch state.phase {
        case .attention: "\(state.attentionCount) agents need you"
        case .ready: "\(state.readyCount) agents ready"
        case .working: "\(state.workingCount) agents working"
        case .resting: "All agents quiet"
        case .offline: "Herd Pulse offline"
        }
    }
}
