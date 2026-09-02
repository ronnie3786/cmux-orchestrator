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
                .font(.caption.weight(.medium))
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HerdrTheme.accent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(HerdrTheme.elevated)
                    .clipShape(.capsule)
            }
            .disabled(!canSelectDisposition || availableDispositions.isEmpty)
            .accessibilityLabel("Prompt mode: \(disposition.label)")
            .accessibilityIdentifier("pi-chat-disposition")

            Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
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
                .font(.caption.weight(.medium))
                .foregroundStyle(HerdrTheme.working)
                // "Compacting context after overflow, then retrying…" runs long.
                // Let it wrap rather than truncate at accessibility text sizes.
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 4)
        // Matches the height the working bar gets from its 44pt Stop button so
        // swapping between the two does not jog the composer under the thumb.
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.statusMessage)
        .accessibilityIdentifier("pi-chat-compacting")
    }
}
