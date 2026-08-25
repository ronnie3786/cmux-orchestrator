import SwiftUI

struct AttentionAlertRow: View {
    @Bindable var model: HerdrAppModel
    let alert: HerdrAlert
    let pane: HerdrPane?
    let selectPane: (HerdrPane, HerdrAlert?) -> Void
    @State private var isHovering = false

    var body: some View {
        Group {
            if let pane {
                Button {
                    selectPane(pane, alert)
                } label: {
                    AlertCardView(alert: alert, pane: pane)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    if isHovering { clearButton }
                }
                .onHover { isHovering = $0 }
            } else {
                AlertCardView(alert: alert, pane: nil)
                    .opacity(0.78)
                    .overlay(alignment: .topTrailing) {
                        clearButton
                    }
            }
        }
        .contextMenu {
            Button("Clear notification", systemImage: "xmark.circle") {
                clear()
            }
        }
    }

    private var clearButton: some View {
        Button {
            clear()
        } label: {
            Image(systemName: "xmark")
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.mist)
                .frame(width: 24, height: 24)
                .background(HerdrTheme.elevated, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .help("Clear notification")
        .accessibilityLabel("Clear notification")
    }

    private func clear() {
        Task { await model.markAlertRead(alert) }
    }
}
