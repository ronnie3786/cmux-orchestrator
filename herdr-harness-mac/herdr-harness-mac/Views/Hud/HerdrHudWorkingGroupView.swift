import SwiftUI

struct HerdrHudWorkingGroupView: View {
    let exchange: HerdrHudExchange
    @State private var isExpanded = false

    private var steps: [HerdrHudStep] { exchange.steps }
    private var hasFailure: Bool { steps.contains(where: \.isFailure) }
    private var failureCount: Int { steps.count(where: \.isFailure) }

    var body: some View {
        PiDisclosureCard(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps) { step in
                    HerdrHudWorkingStepRow(step: step)
                }
                if exchange.stepsTruncated {
                    Text("first 200 steps shown")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            .padding(.top, 10)
        } label: {
            label
        }
        .tint(hasFailure ? HerdrTheme.alert : HerdrTheme.mist)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HerdrTheme.graphite.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
        .onChange(of: hasFailure, initial: true) { _, failed in
            if failed { isExpanded = true }
        }
        .accessibilityIdentifier("hud-clanking-\(exchange.id)")
    }

    private var label: some View {
        HStack(spacing: 9) {
            Image(systemName: hasFailure ? "exclamationmark.triangle" : "gearshape.2")
                .foregroundStyle(hasFailure ? HerdrTheme.alert : HerdrTheme.muted)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            Text("Clanking")
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)

            Text(summary)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Clanking, \(summary)")
        .accessibilityHint("Shows agent tool activity")
    }

    private var summary: String {
        var parts = ["\(steps.count) step\(steps.count == 1 ? "" : "s")"]
        if let latest = steps.last { parts.append(latest.title) }
        if failureCount > 0 { parts.append("\(failureCount) failed") }
        return parts.joined(separator: " · ")
    }
}

private struct HerdrHudWorkingStepRow: View {
    let step: HerdrHudStep

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(step.title, systemImage: step.symbol)
                .herdrFont(.caption, weight: .semibold)
            if !step.detail.isEmpty {
                Text(step.detail)
                    .herdrFont(.caption, monospaced: true)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(step.isFailure ? HerdrTheme.alert : HerdrTheme.mist)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
