import SwiftUI

struct HerdrHudCardView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession

    var body: some View {
        VStack(spacing: 0) {
            HerdrHudHeaderView(model: model, controller: controller, session: session)
            Divider().overlay { HerdrTheme.surface }
            HerdrHudTranscriptView(
                model: model,
                session: session,
                openPaneInMainWindow: openPaneInMainWindow,
                collapse: controller.collapse
            )
            HerdrHudAttentionStripView(
                model: model,
                openPaneInMainWindow: openPaneInMainWindow,
                collapse: controller.collapse
            )
            Divider().overlay { HerdrTheme.surface }
            HerdrHudComposerView(model: model, controller: controller, session: session)
        }
        .frame(width: HerdrHudPlacement.expandedSize.width, height: HerdrHudPlacement.expandedSize.height)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .shadow(color: HerdrTheme.ink.opacity(0.7), radius: 28, y: 12)
        .task(id: session.selectedMachineID) {
            updateResponseAudioAvailability()
            session.responseAudioPlayer.stop()
            await session.loadAudioCapabilities(model: model)
        }
        .onChange(of: session.exchanges) { _, _ in
            updateResponseAudioAvailability()
        }
    }

    private func updateResponseAudioAvailability() {
        let hasResponse = session.exchanges.last(where: { exchange in
            exchange.response?.isEmpty == false
                && (exchange.status == .completed || exchange.status == .promoted)
        }) != nil
        session.responseAudioPlayer.responseDidChange(hasResponse: hasResponse)
    }

    private func openPaneInMainWindow(_ paneID: String) {
        HerdrMacAppDelegate.openPaneURLWithFallback(paneID)
    }
}
