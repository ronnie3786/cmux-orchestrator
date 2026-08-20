import SwiftUI

struct PiToolCardView: View {
    let tool: PiToolInvocation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        let presentation = PiToolPresentation(tool: tool)
        DisclosureGroup(isExpanded: $isExpanded) {
            detail
        } label: {
            label(presentation)
        }
        .disclosureGroupStyle(PiDisclosureGroupStyle())
        .tint(presentation.tint)
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
        .contentShape(Rectangle())
        .frame(minHeight: 44)
        .accessibilityIdentifier("pi-tool-\(tool.callID)")
    }

    private func label(_ presentation: PiToolPresentation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: presentation.symbol)
                .frame(width: 18)
                .foregroundStyle(presentation.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HerdrTheme.text)
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                statusLabel
                    .font(.caption.weight(.semibold))
                    .id(statusMotionKey)
                    .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                if let elapsedDuration {
                    Text(elapsedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(statusAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let arguments = tool.arguments {
                toolSection("Input", value: arguments)
                    .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
            }
            if let result = tool.result {
                toolSection(tool.status == .failed ? "Error" : "Result", value: result)
                    .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
            }
            if tool.arguments == nil, tool.result == nil {
                Text("Waiting for tool details…")
                    .font(.caption)
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

    private func toolSection(_ label: String, value: PiJSONValue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(HerdrTheme.muted)
            Text(value.displayString)
                .font(.caption.monospaced())
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
                .foregroundStyle(HerdrTheme.muted)
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("RUNNING")
            }
            .foregroundStyle(HerdrTheme.working)
        case .succeeded:
            Label("DONE", systemImage: "checkmark")
                .foregroundStyle(HerdrTheme.success)
        case .failed:
            Label("FAILED", systemImage: "exclamationmark")
                .foregroundStyle(HerdrTheme.alert)
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
