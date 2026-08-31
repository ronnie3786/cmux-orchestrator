import SwiftUI

struct HerdrHudTranscriptRowView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var session: HerdrHudSession
    let exchange: HerdrHudExchange
    let showsAudioControls: Bool
    let openPaneInMainWindow: (String) -> Void
    let collapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            promptBubble
            answer
            if isCompletedResponse {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("hud-transcript-row-\(exchange.id)")
    }

    private var promptBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(exchange.prompt)
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
            if !exchange.attachmentFilenames.isEmpty {
                Label(exchange.attachmentFilenames.joined(separator: ", "), systemImage: "paperclip")
                    .herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(exchange.createdAt, format: .dateTime.hour().minute())
                .herdrFont(.caption2, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var answer: some View {
        if hasError {
            VStack(alignment: .leading, spacing: 7) {
                Text(exchange.error ?? exchange.status.label)
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.alert)
                Button("Retry", systemImage: "arrow.counterclockwise", action: retry)
                    .buttonStyle(.bordered)
                    .tint(HerdrTheme.accent)
                    .controlSize(.small)
                    .disabled(session.isRunning)
                    .accessibilityIdentifier("hud-retry-\(exchange.id)")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        } else if let response = exchange.response, !response.isEmpty {
            PiMarkdownMessageView(source: response, isStreaming: false, id: "hud-\(exchange.id)")
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        } else {
            Text("No response")
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.muted)
                .italic()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(exchange.modelLabel)
                .herdrFont(.caption2, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
            if let costUSD = exchange.costUSD {
                Text("$\(costUSD.formatted(.number.precision(.fractionLength(4))))")
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
            }
            Spacer()
            if showsAudioControls, let response = exchange.response {
                ResponseAudioControlsView(
                    player: session.responseAudioPlayer,
                    showsTitles: false,
                    activate: { action in
                        session.activateResponseAudio(action, text: response, model: model)
                    }
                )
            }
            promotionControl
        }
    }

    @ViewBuilder
    private var promotionControl: some View {
        if exchange.promotedPaneID != nil {
            Text("Opened as chat")
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
        } else {
            Button(action: promote) {
                HStack(spacing: 5) {
                    if isPromoting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Continue as chat")
                        .herdrFont(.caption, weight: .bold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.accent)
            .controlSize(.small)
            .disabled(isPromoting)
            .accessibilityIdentifier("hud-promote-\(exchange.id)")
        }
    }

    private var hasError: Bool {
        exchange.status == .failed || exchange.status == .cancelled || exchange.error != nil
    }

    private var isCompletedResponse: Bool {
        exchange.response?.isEmpty == false
            && (exchange.status == .completed || exchange.status == .promoted)
    }

    private var isPromoting: Bool {
        session.promotingExchangeIDs.contains(exchange.id)
    }

    private func retry() {
        Task { await session.retry(exchange, model: model) }
    }

    private func promote() {
        Task {
            guard let pane = await session.promote(exchange: exchange, model: model) else { return }
            collapse()
            openPaneInMainWindow(pane.id)
        }
    }
}
