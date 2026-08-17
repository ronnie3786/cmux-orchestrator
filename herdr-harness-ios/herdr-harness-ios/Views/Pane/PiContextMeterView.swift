import SwiftUI

/// A compact, always-visible meter for the active model's context usage.
/// Hides itself when the bridge predates context reporting or when Pi has
/// not produced a reading yet (for example right after compaction).
struct PiContextMeterView: View {
    let usage: PiContextUsage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let usage, let fraction = usage.fraction {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(barColor)
                    .accessibilityHidden(true)

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
                    .font(.caption2.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)

                Text(usage.percentText ?? "…")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(barColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(HerdrTheme.graphite.opacity(0.5))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary(for: usage))
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
}
