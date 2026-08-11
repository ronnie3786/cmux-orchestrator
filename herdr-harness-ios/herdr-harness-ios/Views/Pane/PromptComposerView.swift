import SwiftUI

struct PromptComposerView: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 9) {
            quickPrompts
            keyDeck
            composer
        }
    }

    private var quickPrompts: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        draft = suggestion
                        isFocused = true
                    }
                    .font(.caption.bold())
                    .foregroundStyle(HerdrTheme.mist)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(.white.opacity(0.07), in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityHint("Fills the message field")
                }
            }
            .padding(.trailing, 16)
        }
        .scrollIndicators(.hidden)
        .frame(height: 48)
    }

    private var keyDeck: some View {
        HStack(spacing: 8) {
            keyButton("Esc", keys: ["esc"], accessibilityLabel: "Send Escape immediately")
            keyButton("↑", keys: ["up"], accessibilityLabel: "Send Up Arrow immediately")
            keyButton("↓", keys: ["down"], accessibilityLabel: "Send Down Arrow immediately")
            keyButton("Tab", keys: ["tab"], accessibilityLabel: "Send Tab immediately")
            keyButton(
                "⌃C",
                keys: ["ctrl+c"],
                accessibilityLabel: "Send Control C immediately",
                role: .destructive
            )
            Spacer(minLength: 0)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField(
                pane.agentStatus == .unknown ? "Run or type into this shell" : "Message \(pane.displayAgentName)",
                text: $draft,
                axis: .vertical
            )
            .lineLimit(1...5)
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            }
            .accessibilityIdentifier("prompt-composer")
            .disabled(model.isSending || !model.canControl)

            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSending
                        || !model.canControl
                )
                .accessibilityIdentifier("prompt-send")
        }
    }

    private func keyButton(
        _ title: String,
        keys: [String],
        accessibilityLabel: String,
        role: ButtonRole? = nil
    ) -> some View {
        Button(title, role: role) {
            Task { await model.sendKeys(keys, to: pane) }
        }
        .font(.caption.bold())
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!model.canControl)
        .accessibilityLabel(accessibilityLabel)
    }

    private func send() {
        guard !model.isSending, model.canControl else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task {
            if await model.sendPrompt(message, to: pane) {
                draft = ""
            }
        }
    }

    private var suggestions: [String] {
        switch pane.agentStatus {
        case .blocked:
            ["Yes, proceed", "Explain the risk first", "Choose the safest option"]
        case .done:
            ["Summarize the changes", "Run the focused tests", "What should I review first?"]
        case .working:
            ["Give me a quick status", "What remains?", "Stop after the current step"]
        case .idle:
            ["Continue with the next step", "Review the current diff", "Run the tests"]
        case .unknown:
            ["git status", "pwd", "clear"]
        }
    }
}
