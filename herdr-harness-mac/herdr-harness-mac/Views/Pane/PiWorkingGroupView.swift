import SwiftUI

/// Collapses a contiguous run of Pi's sub-process activity, thinking and
/// tool/command invocations, behind one "Clanking…" row, so consecutive
/// assistant messages read as a conversation instead of a machine log.
/// Collapsed by default; the individual `PiThinkingDisclosureView` /
/// `PiToolCardView` cards inside keep their own per-card disclosure.
struct PiWorkingGroupView: View {
    let group: PiWorkingGroup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(group.items) { item in
                    PiConversationItemView(item: item)
                        .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.top, 10)
        } label: {
            label
        }
        .disclosureGroupStyle(PiDisclosureGroupStyle())
        .tint(group.hasFailure ? HerdrTheme.alert : HerdrTheme.mist)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HerdrTheme.graphite.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: group.isLive)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        // A failed tool is never hidden behind a collapsed row.
        .onChange(of: group.hasFailure, initial: true) { _, failed in
            if failed { isExpanded = true }
        }
        .herdrHaptic(trigger: hapticPulse)
        .frame(minHeight: 44)
        .accessibilityIdentifier("pi-working-\(group.id)")
        .opacity(HerdrProse.subOutputOpacity)
    }

    private var label: some View {
        HStack(spacing: 9) {
            ZStack {
                if group.isLive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.working)
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                } else {
                    Image(systemName: group.hasFailure ? "exclamationmark.triangle" : "gearshape.2")
                        .foregroundStyle(group.hasFailure ? HerdrTheme.alert : HerdrTheme.muted)
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)

            Text(group.isLive ? "Clanking…" : "Clanking")
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)
                .contentTransition(.opacity)

            Text(summary)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .lineLimit(1)
                .contentTransition(.opacity)

            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows Pi's thinking and tool activity")
    }

    /// e.g. "3 steps · Command", "1 step", "2 steps · 1 failed".
    private var summary: String {
        var parts = ["\(group.stepCount) step\(group.stepCount == 1 ? "" : "s")"]
        if let latestToolTitle = group.latestToolTitle { parts.append(latestToolTitle) }
        if group.failureCount > 0 { parts.append("\(group.failureCount) failed") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        (group.isLive ? "Clanking, " : "Clanked, ") + summary
    }
}
