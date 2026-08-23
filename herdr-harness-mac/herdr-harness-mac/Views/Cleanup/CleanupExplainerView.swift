import SwiftUI

struct CleanupExplainerView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How this works")
                .herdrFont(.headline, weight: .bold)

            step(1, symbol: "doc.text.magnifyingglass", title: "Capture", detail: "Herdr captures local pane evidence into temporary files.")
            step(2, symbol: "brain.head.profile", title: "Judge", detail: "A read-only AI judge reviews the evidence and suggests what may be finished.")
            step(3, symbol: "shield.checkered", title: "Safety rails", detail: "Code blocks focused, active, starred, blocked, or unsafe work.")
            step(4, symbol: "hand.thumbsup", title: "You approve", detail: "Nothing closes until you review and explicitly choose it.")
        }
        .padding(16)
        .background(HerdrTheme.graphite)
        .clipShape(.rect(cornerRadius: 12))
    }

    private func step(_ number: Int, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.ink)
                .frame(width: 22, height: 22)
                .background(HerdrTheme.accent)
                .clipShape(.circle)
            Image(systemName: symbol)
                .foregroundStyle(HerdrTheme.signal)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .herdrFont(.subheadline, weight: .bold)
                Text(detail)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
    }
}
