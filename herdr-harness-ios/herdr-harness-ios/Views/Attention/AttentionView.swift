import SwiftUI

struct AttentionView: View {
    @Bindable var model: HerdrAppModel
    let selectPane: (HerdrPane, HerdrAlert?) -> Void

    var body: some View {
        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header

                    if !model.alerts.isEmpty {
                        sectionTitle("Recent signals", count: model.alerts.count)
                        ForEach(model.alerts) { alert in
                            if let pane = model.pane(id: alert.paneID) {
                                Button {
                                    selectPane(pane, alert)
                                } label: {
                                    AlertCardView(alert: alert, pane: pane)
                                }
                                .buttonStyle(.plain)
                            } else {
                                AlertCardView(alert: alert, pane: nil)
                                    .opacity(0.78)
                            }
                        }
                    }

                    sectionTitle("Live queue", count: model.attentionPanes.count)
                    if model.attentionPanes.isEmpty {
                        ContentUnavailableView(
                            "Nothing needs you",
                            systemImage: "checkmark.circle",
                            description: Text("Working agents will surface here when they finish or need a decision.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else {
                        ForEach(model.attentionPanes) { pane in
                            Button {
                                selectPane(pane, nil)
                            } label: {
                                AttentionPaneCard(model: model, pane: pane)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Attention")
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Attention deck", systemImage: "sparkle.magnifyingglass")
                .font(.largeTitle.bold())
                .fontDesign(.rounded)
            Text("Blocked first, then unseen completions. The queue stays quiet until there’s a decision worth making.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline.bold())
            Spacer()
            Text("\(count)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }
}
