import SwiftUI

/// Semantic run controls layered into the full Herdr composer while Pi works.
struct PiPromptComposerStatusBar: View {
    let disposition: PiPromptDisposition
    let availableDispositions: [PiPromptDisposition]
    let canSelectDisposition: Bool
    let canAbort: Bool
    let selectDisposition: (PiPromptDisposition) -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("Pi is working", systemImage: "sparkles")
                .herdrFont(.caption, weight: .medium)
                .foregroundStyle(HerdrTheme.working)

            Spacer(minLength: 4)

            Menu {
                ForEach(availableDispositions) { option in
                    Button {
                        selectDisposition(option)
                    } label: {
                        Label(
                            option.label,
                            systemImage: disposition == option
                                ? "checkmark.circle.fill"
                                : option.symbol
                        )
                    }
                }
            } label: {
                Label(disposition.shortLabel, systemImage: disposition.symbol)
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.accent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(HerdrTheme.elevated)
                    .clipShape(.capsule)
            }
            .piChipMenu()
            .disabled(!canSelectDisposition || availableDispositions.isEmpty)
            .accessibilityLabel("Prompt mode: \(disposition.label)")
            .accessibilityIdentifier("pi-chat-disposition")

            Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
                .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.alert, emphasis: .text))
                .herdrFont(.caption, weight: .semibold)
                .frame(minHeight: PiChatChrome.controlHeight)
                .disabled(!canAbort)
                .accessibilityIdentifier("pi-chat-stop")
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Compaction remains visible even while Pi reports an otherwise idle session.
/// There are intentionally no prompt controls here because accepting a model,
/// thinking, or message command during summary generation is unsafe.
struct PiCompactionStatusBar: View {
    let activity: PiCompactionActivity

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(HerdrTheme.working)
                .accessibilityHidden(true)

            Text(activity.statusMessage)
                .herdrFont(.caption, weight: .medium)
                .foregroundStyle(HerdrTheme.working)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.statusMessage)
        .accessibilityIdentifier("pi-chat-compacting")
    }
}
