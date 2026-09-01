import SwiftUI

struct PiInteractionCardView: View {
    let interaction: PiPendingInteraction
    let isConnected: Bool
    let respond: (PiInteractionResponseBody) async -> Bool
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(interaction.title, systemImage: "person.crop.circle.badge.questionmark")
                .herdrFont(.headline)
                .foregroundStyle(HerdrTheme.text)

            if let message = interaction.message {
                Text(message)
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.mist)
            }

            controls

            Button("Cancel", role: .cancel) {
                submit(.cancelled)
            }
            .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.mist, emphasis: .text))
            .herdrFont(.caption)
            .disabled(isSubmitting)
        }
        .padding(14)
        .background(HerdrTheme.elevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(HerdrTheme.working.opacity(0.28), lineWidth: 1)
        }
        .herdrHaptic(trigger: hapticPulse)
        .disabled(!isConnected)
        .accessibilityIdentifier("pi-interaction-\(interaction.id)")
    }

    @ViewBuilder
    private var controls: some View {
        switch interaction.kind {
        case .select:
            ForEach(interaction.options, id: \.self) { option in
                Button(option) { submit(.selection(option)) }
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.accent, emphasis: .soft))
                    .disabled(isSubmitting)
            }
        case .confirm:
            HStack {
                Button("No") { submit(.confirmation(false)) }
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.mist, emphasis: .soft))
                Button("Yes") { submit(.confirmation(true)) }
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.accent, emphasis: .prominent))
            }
            .disabled(isSubmitting)
        case .input, .editor, .unknown:
            HStack(alignment: .bottom, spacing: 8) {
                TextField(interaction.placeholder ?? "Response", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(HerdrTheme.graphite, in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(submitText)
                Button("Submit", systemImage: "arrow.up.circle.fill", action: submitText)
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.accent, emphasis: .text))
                    .labelStyle(.iconOnly)
                    .herdrFont(.title2)
                    .disabled(trimmedText.isEmpty || isSubmitting)
            }
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return in the field submits, matching the Mac idiom. Guarded so an empty
    /// field (or an in-flight response) can't post a blank answer.
    private func submitText() {
        guard !trimmedText.isEmpty, !isSubmitting else { return }
        submit(.text(trimmedText))
    }

    private func submit(_ response: PiInteractionResponseBody) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let succeeded = await respond(response)
            hapticPulse.fire(succeeded ? .completed : .failed)
            isSubmitting = false
        }
    }
}
