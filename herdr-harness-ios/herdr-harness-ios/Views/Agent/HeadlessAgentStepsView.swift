import SwiftUI

/// The headless run's tool calls, collapsed behind one "Clanking…" row.
/// Collapsed by default because the answer is what the user came for; the
/// label carries a live summary so progress is legible without expanding.
///
/// Built on `PiDisclosureCard`, never `DisclosureGroup` — the sheet holds one
/// of these, but the card is what every other collapsible sub-output in the app
/// uses, and its measured layout cost is a fraction of a `DisclosureGroup`'s.
struct HeadlessAgentStepsView: View {
    let steps: [HeadlessAgentStepRow]
    let isTruncated: Bool
    let isLive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    private var hasFailure: Bool { steps.contains(where: \.isFailure) }
    private var failureCount: Int { steps.count(where: \.isFailure) }

    var body: some View {
        PiDisclosureCard(
            isExpanded: $isExpanded,
            chevronColor: hasFailure ? HerdrTheme.alert : HerdrTheme.mist
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { step in
                    stepRow(step)
                }
                if isTruncated {
                    Text("first 200 steps shown")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            .padding(.top, 10)
        } label: {
            label
        }
        .background(HerdrTheme.elevated.opacity(0.46), in: RoundedRectangle(cornerRadius: 11))
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: isLive)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        // A failed tool is never hidden behind a collapsed row.
        .onChange(of: hasFailure, initial: true) { _, failed in
            if failed { isExpanded = true }
        }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("agent-steps")
    }

    private var label: some View {
        HStack(spacing: 9) {
            ZStack {
                if isLive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.working)
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                } else {
                    Image(systemName: hasFailure ? "exclamationmark.triangle" : "gearshape.2")
                        .foregroundStyle(HerdrProse.dimmed(hasFailure ? HerdrTheme.alert : HerdrTheme.muted))
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)

            Text(isLive ? "Clanking…" : "Clanking")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.mist))
                .contentTransition(.opacity)

            Text(summary)
                .font(.caption)
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.muted))
                .lineLimit(1)
                .contentTransition(.opacity)

            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows the agent's tool activity")
    }

    private func stepRow(_ step: HeadlessAgentStepRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(step.title, systemImage: step.symbol)
                .font(.caption.weight(.semibold))
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(step.isFailure ? HerdrTheme.alert : HerdrTheme.mist)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// e.g. "3 steps · Command", "1 step", "2 steps · 1 failed".
    private var summary: String {
        var parts = ["\(steps.count) step\(steps.count == 1 ? "" : "s")"]
        if let latest = steps.last { parts.append(latest.title) }
        if failureCount > 0 { parts.append("\(failureCount) failed") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        (isLive ? "Clanking, " : "Clanked, ") + summary
    }
}
