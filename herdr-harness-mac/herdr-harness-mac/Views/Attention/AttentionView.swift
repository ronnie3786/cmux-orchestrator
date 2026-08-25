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

                    if model.unreadAlertCount > 0 {
                        HStack {
                            Text("Recent signals").herdrFont(.headline, weight: .bold)
                            Spacer()
                            if model.unreadAlertCount > 0 {
                                Button("Mark all read") {
                                    Task { await model.markAllAlertsRead() }
                                }
                                .herdrFont(.caption, monospaced: true, weight: .bold)
                                .foregroundStyle(HerdrTheme.accent)
                                .accessibilityIdentifier("attention-mark-all-read")
                            }
                            Text("\(model.unreadAlertCount)")
                                .herdrFont(.caption, weight: .bold)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.alerts.filter { !$0.isRead }) { alert in
                            AttentionAlertRow(
                                model: model,
                                alert: alert,
                                pane: model.pane(id: alert.scopedPaneID),
                                selectPane: selectPane
                            )
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
                .frame(maxWidth: Self.contentWidth, alignment: .leading)
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Attention")
    }

    /// The deck fills the detail column of a wide Mac window; capping the
    /// reading column keeps alert cards from stretching into billboards.
    private static let contentWidth = 760.0

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label("Attention deck", systemImage: "sparkle.magnifyingglass")
                    .herdrFont(.largeTitle, weight: .bold)
                    .fontDesign(.rounded)
                Spacer(minLength: 12)
                refreshButton
            }
            Text("Blocked first, then unseen completions. The queue stays quiet until there’s a decision worth making.")
                .herdrFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `.refreshable` has no pull gesture on macOS, so the deck carries its own
    /// refresh affordance — same square-icon recipe the iOS workspace header used.
    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await model.refresh() }
        }
        .labelStyle(.iconOnly)
        .herdrFont(.headline, weight: .bold)
        .foregroundStyle(HerdrTheme.accent)
        .frame(width: 44, height: 44)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .buttonStyle(.plain)
        .disabled(model.isRefreshing)
        .help("Refresh")
        .accessibilityIdentifier("attention-refresh")
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).herdrFont(.headline, weight: .bold)
            Spacer()
            Text("\(count)")
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(.secondary)
        }
    }
}
