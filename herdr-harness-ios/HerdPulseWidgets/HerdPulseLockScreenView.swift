import SwiftUI
import WidgetKit

struct HerdPulseLockScreenView: View {
    let context: ActivityViewContext<HerdPulseAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if !context.state.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(context.state.sessions.prefix(4).enumerated()), id: \.element.id) { index, session in
                        row(session, index: index)
                    }
                    let overflow = context.state.sessionOverflow + max(0, context.state.sessions.count - 4)
                    if overflow > 0 {
                        Text("+\(overflow) more")
                            .font(.caption2.monospaced())
                            .foregroundStyle(HerdPulseTheme.mist)
                    }
                }
            }
        }
        .padding()
        .activityBackgroundTint(HerdPulseTheme.graphite)
        .activitySystemActionForegroundColor(HerdPulseTheme.text)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func row(_ session: HerdPulseAttributes.ContentState.Session, index: Int) -> some View {
        if session.id != "s\(index + 1)", let url = URL(string: "herdr://pane/\(session.id)") {
            Link(destination: url) {
                HerdPulseSessionRow(session: session)
            }
        } else {
            HerdPulseSessionRow(session: session)
        }
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
