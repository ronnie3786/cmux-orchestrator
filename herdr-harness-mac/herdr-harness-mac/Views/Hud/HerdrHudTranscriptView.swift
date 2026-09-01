import SwiftUI

struct HerdrHudTranscriptView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var session: HerdrHudSession
    let openPaneInMainWindow: (String) -> Void
    let collapse: () -> Void

    var body: some View {
        if session.exchanges.isEmpty && !session.isRunning {
            HerdrHudTranscriptEmptyView(
                errorMessage: session.errorMessage ?? session.validationError,
                promoteErrorMessage: session.promoteErrorMessage,
                audioErrorMessage: session.audioErrorMessage
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
                        ForEach(session.exchanges.indices, id: \.self) { index in
                            let exchange = session.exchanges[index]
                            if index > session.exchanges.startIndex,
                               session.exchanges[index - 1].machineID != exchange.machineID {
                                Text("New thread · \(machineName(for: exchange.machineID))")
                                    .herdrFont(.caption2, monospaced: true)
                                    .foregroundStyle(HerdrTheme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HerdrHudTranscriptRowView(
                                model: model,
                                session: session,
                                exchange: exchange,
                                showsAudioControls: exchange.id == latestCompletedExchangeID,
                                allowsPromote: session.thread == nil || exchange.id == latestPromotableExchangeID,
                                openPaneInMainWindow: openPaneInMainWindow,
                                collapse: collapse
                            )
                            .id(exchange.id)
                        }

                        if session.isRunning {
                            HerdrHudRunningRowView(model: model, session: session)
                                .id("hud-running")
                        }

                        HerdrHudTranscriptErrorsView(
                            errorMessage: session.isRunning ? nil : (session.errorMessage ?? session.validationError),
                            promoteErrorMessage: session.promoteErrorMessage,
                            audioErrorMessage: session.audioErrorMessage
                        )
                    }
                    .padding(HerdrTheme.cardPadding)
                }
                .scrollIndicators(.hidden)
                .onChange(of: session.exchanges.last) { _, _ in
                    scrollToLatest(using: proxy)
                }
                .onChange(of: session.isRunning) { _, isRunning in
                    if isRunning {
                        proxy.scrollTo("hud-running", anchor: .bottom)
                    }
                }
                .task {
                    scrollToLatest(using: proxy)
                }
            }
        }
    }

    private var latestCompletedExchangeID: String? {
        session.exchanges.last(where: { exchange in
            exchange.response?.isEmpty == false
                && (exchange.status == .completed || exchange.status == .promoted)
        })?.id
    }

    private var latestPromotableExchangeID: String? {
        session.latestPromotableExchangeID
    }

    private func machineName(for machineID: String) -> String {
        model.machines.first(where: { $0.id == machineID })?.name ?? machineID
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        if session.isRunning {
            proxy.scrollTo("hud-running", anchor: .bottom)
        } else if let lastID = session.exchanges.last?.id {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}
