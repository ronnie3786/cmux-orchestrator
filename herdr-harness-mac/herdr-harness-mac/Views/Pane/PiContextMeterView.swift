import SwiftUI

/// A compact, always-visible meter for the active model's context usage.
/// Hides itself when the bridge predates context reporting or when Pi has
/// not produced a reading yet (for example right after compaction).
struct PiContextMeterView: View {
    let usage: PiContextUsage?
    let cost: PiSessionCost?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if usage?.fraction != nil || cost?.summary != nil {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(barColor)
                    .accessibilityHidden(true)

                if let usage, let fraction = usage.fraction {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(HerdrTheme.surface.opacity(0.45))
                            Capsule()
                                .fill(barColor)
                                .frame(width: max(6, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 4)

                    Text(usage.summary ?? "…")
                        .herdrFont(.caption2, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)

                    Text(usage.percentText ?? "…")
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .foregroundStyle(barColor)
                        .lineLimit(1)

                    if let costText = cost?.summary {
                        Text("·")
                            .herdrFont(.caption2)
                            .foregroundStyle(HerdrTheme.muted)
                        Text(costText)
                            .herdrFont(.caption2, monospaced: true)
                            .foregroundStyle(HerdrTheme.mist)
                            .lineLimit(1)
                            .accessibilityIdentifier("pi-session-cost")
                    }
                } else if let costText = cost?.summary {
                    Spacer()
                    Text(costText)
                        .herdrFont(.caption2, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)
                        .accessibilityIdentifier("pi-session-cost")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(HerdrTheme.graphite.opacity(0.5))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: usage?.fraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("pi-context-meter")
        }
    }

    private var barColor: Color {
        guard let fraction = usage?.fraction else { return HerdrTheme.accent }
        switch fraction {
        case ..<0.6:
            return HerdrTheme.accent
        case ..<0.85:
            return HerdrTheme.working
        default:
            return HerdrTheme.alert
        }
    }

    private func accessibilitySummary(for usage: PiContextUsage) -> String {
        if let tokens = usage.tokens, let window = usage.contextWindow {
            return "Context usage: \(tokens.formatted()) of \(window.formatted()) tokens"
        }
        return "Context usage: \(usage.summary ?? "unknown")"
    }

    private var accessibilityLabel: String {
        if let usage {
            let usageSummary = accessibilitySummary(for: usage)
            if let costSummary = cost?.summary {
                return "\(usageSummary), session cost \(costSummary)"
            }
            return usageSummary
        }
        if let costSummary = cost?.summary {
            return "Session cost \(costSummary)"
        }
        return ""
    }
}
