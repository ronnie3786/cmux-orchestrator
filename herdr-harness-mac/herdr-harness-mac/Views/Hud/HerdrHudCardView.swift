import SwiftUI
import UniformTypeIdentifiers

struct HerdrHudCardView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

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
            Divider().overlay { HerdrTheme.surface }
            HerdrHudComposerView(model: model, controller: controller, session: session)
        }
        .frame(width: HerdrHudPlacement.expandedSize.width, height: HerdrHudPlacement.expandedSize.height)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.accent, lineWidth: 2)
            }
        }
        .shadow(color: HerdrTheme.ink.opacity(0.7), radius: 28, y: 12)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            session.acceptAttachmentDrop(providers)
        }
        .task(id: session.selectedMachineID) {
            updateResponseAudioAvailability()
            session.responseAudioPlayer.stop()
            await session.loadAudioCapabilities(model: model)
            await session.loadModels(model: model)
        }
        .onChange(of: session.exchangesRevision) { _, _ in
            updateResponseAudioAvailability()
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: model.unopenedResultArtifacts.map(\.id)
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: isDropTargeted)
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
