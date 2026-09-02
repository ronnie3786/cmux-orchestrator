import SwiftUI

struct PiToolCardView: View {
    let tool: PiToolInvocation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        let presentation = PiToolPresentation(tool: tool)
        PiDisclosureCard(isExpanded: $isExpanded, chevronColor: presentation.tint) {
            detail
        } label: {
            label(presentation)
        }
        // This padding sits outside the header button, so that band is deliberately not clickable.
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HerdrTheme.graphite.opacity(0.76), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(presentation.tint.opacity(0.15), lineWidth: 1)
        }
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: tool.status)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .herdrHaptic(trigger: hapticPulse)
        .frame(minHeight: 44)
        .accessibilityIdentifier("pi-tool-\(tool.callID)")
    }

    private func label(_ presentation: PiToolPresentation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: presentation.symbol)
                .frame(width: 18)
                .foregroundStyle(HerdrProse.dimmed(presentation.tint))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrProse.dimmed(HerdrTheme.text))
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrProse.dimmed(HerdrTheme.mist))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                statusLabel
                    .herdrFont(.caption, weight: .semibold)
                    .id(statusMotionKey)
                    .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                if let elapsedDuration {
                    Text(elapsedDuration)
                        .herdrFont(.caption, monospacedDigit: true)
                        .foregroundStyle(HerdrProse.dimmed(HerdrTheme.muted))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(statusAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let argumentsDisplayString = tool.argumentsDisplayString {
                toolSection("Input", text: argumentsDisplayString)
                    .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
            }
            if let resultDisplayString = tool.resultDisplayString {
                toolSection(tool.status == .failed ? "Error" : "Result", text: resultDisplayString)
                    .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
            }
            if tool.arguments == nil, tool.result == nil {
                Text("Waiting for tool details…")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .transition(.opacity)
            }
        }
        .padding(.top, 10)
        .animation(
            PiChatMotion.structuralAnimation(reduceMotion: reduceMotion),
            value: detailStructure
        )
    }

    private func toolSection(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.muted)
            Text(text)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch tool.status {
        case .waiting:
            Text("QUEUED")
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.muted))
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("RUNNING")
            }
            .foregroundStyle(HerdrProse.dimmed(HerdrTheme.working))
        case .succeeded:
            Label("DONE", systemImage: "checkmark")
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.success))
        case .failed:
            Label("FAILED", systemImage: "exclamationmark")
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.alert))
        }
    }

    private var elapsedDuration: String? {
        guard let startedAt = tool.startedAt else { return nil }
        let end = tool.finishedAt ?? .now
        let seconds = max(0, end.timeIntervalSince(startedAt))
        return seconds < 10 ? String(format: "%.1fs", seconds) : "\(Int(seconds))s"
    }

    private var statusAccessibilityLabel: String {
        let status: String
        switch tool.status {
        case .waiting: status = "Queued"
        case .running: status = "Running"
        case .succeeded: status = "Completed"
        case .failed: status = "Failed"
        }
        if let elapsedDuration { return "\(status), \(elapsedDuration)" }
        return status
    }

    private var statusMotionKey: Int {
        switch tool.status {
        case .waiting: 0
        case .running: 1
        case .succeeded: 2
        case .failed: 3
        }
    }

    private var detailStructure: Int {
        (tool.arguments == nil ? 0 : 1) | (tool.result == nil ? 0 : 2)
    }
}
