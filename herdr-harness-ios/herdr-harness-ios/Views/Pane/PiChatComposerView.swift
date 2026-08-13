import SwiftUI

struct PiChatComposerView: View {
    @Bindable var store: PiConversationStore
    let capabilities: PiSemanticCapabilities
    let isConnected: Bool
    let submit: (String, PiPromptDisposition) async -> Bool
    let abort: () async -> Bool
    @FocusState private var isFocused: Bool
    @State private var draft = ""
    @State private var disposition: PiPromptDisposition = .prompt
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        VStack(spacing: 8) {
            if store.phase == .working {
                runningControls
            }

            HStack(alignment: .bottom, spacing: 9) {
                dispositionMenu

                TextField(placeholder, text: $draft, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(1...6)
                    .font(.body)
                    .foregroundStyle(HerdrTheme.text)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(HerdrTheme.elevated.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                    .disabled(!isConnected)
                    .accessibilityIdentifier("pi-chat-composer")

                Button("Send", systemImage: "arrow.up") { send() }
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(width: 46, height: 46)
                    .foregroundStyle(HerdrTheme.ink)
                    .background(canSend ? HerdrTheme.accent : HerdrTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                    .disabled(!canSend)
                    .accessibilityHint("Sends using \(disposition.label.lowercased()) mode")
                    .accessibilityIdentifier("pi-chat-send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(HerdrTheme.surface.opacity(0.55)).frame(height: 1)
        }
        .onChange(of: store.phase) { _, phase in
            disposition = preferredDisposition(for: phase)
        }
        .herdrHaptic(trigger: hapticPulse)
    }

    private var runningControls: some View {
        HStack(spacing: 8) {
            Label("Pi is working", systemImage: "sparkles")
                .font(.caption.weight(.medium))
                .foregroundStyle(HerdrTheme.working)
            Spacer()
            Button("Stop", systemImage: "stop.fill", role: .destructive) {
                Task {
                    let succeeded = await abort()
                    hapticPulse.fire(succeeded ? .stopped : .failed)
                }
            }
            .font(.caption.weight(.semibold))
            .frame(minHeight: 44)
            .disabled(!isConnected || !capabilities.abort || store.isAborting)
            .accessibilityIdentifier("pi-chat-stop")
        }
    }

    private var dispositionMenu: some View {
        Menu {
            ForEach(availableDispositions) { option in
                Button {
                    disposition = option
                    hapticPulse.fire(.selection)
                } label: {
                    Label(option.label, systemImage: disposition == option ? "checkmark.circle.fill" : option.symbol)
                }
            }
        } label: {
            Image(systemName: disposition.symbol)
                .font(.headline)
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 46, height: 46)
                .background(HerdrTheme.elevated.opacity(0.8), in: RoundedRectangle(cornerRadius: 13))
        }
        .accessibilityLabel("Prompt mode: \(disposition.label)")
        .accessibilityIdentifier("pi-chat-disposition")
        .disabled(!isConnected)
    }

    private var availableDispositions: [PiPromptDisposition] {
        if store.phase != .working { return capabilities.prompt ? [.prompt] : [] }
        var values: [PiPromptDisposition] = []
        if capabilities.steer { values.append(.steer) }
        if capabilities.followUp { values.append(.followUp) }
        return values.isEmpty && capabilities.prompt ? [.prompt] : values
    }

    private var canSend: Bool {
        isConnected
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.isSubmitting
            && availableDispositions.contains(disposition)
    }

    private var placeholder: String {
        if !isConnected { return "Pi is offline" }
        switch disposition {
        case .prompt: return "Message Pi"
        case .steer: return "Steer this turn"
        case .followUp: return "Queue a follow-up"
        }
    }

    private func preferredDisposition(for phase: PiConversationPhase) -> PiPromptDisposition {
        guard phase == .working else { return .prompt }
        if capabilities.steer { return .steer }
        if capabilities.followUp { return .followUp }
        return .prompt
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        Task {
            if await submit(message, disposition) {
                draft = ""
                hapticPulse.fire(.promptSent)
            } else {
                hapticPulse.fire(.failed)
            }
        }
    }
}
