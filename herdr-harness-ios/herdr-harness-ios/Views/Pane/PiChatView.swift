import SwiftUI

struct PiChatView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: PiConversationStore
    let pane: HerdrPane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        VStack(spacing: 0) {
            PiConnectionBanner(connection: store.connection, message: store.lastError)

            PiChatTimelineView(
                store: store,
                isConnected: store.canSendCommands
                    && (pane.piSemantic?.capabilities.interactionResponse ?? false)
            ) { interaction, response in
                await store.respond(to: interaction, response: response, model: model, pane: pane)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let notice = store.commandNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.signal)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(.opacity)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        store.clearCommandNotice()
                    }
            }

            PiChatComposerView(
                store: store,
                capabilities: pane.piSemantic?.capabilities ?? .unavailable,
                isConnected: store.canSendCommands,
                submit: { text, disposition in
                    await store.submit(
                        text: text,
                        disposition: disposition,
                        model: model,
                        pane: pane
                    )
                },
                abort: {
                    await store.abort(model: model, pane: pane)
                }
            )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.turns.count)
        .onChange(of: store.phase) { oldPhase, newPhase in
            if oldPhase == .working, newPhase == .idle {
                hapticPulse.fire(.completed)
            } else if newPhase == .failed {
                hapticPulse.fire(.failed)
            }
        }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("pi-chat-view")
    }
}
