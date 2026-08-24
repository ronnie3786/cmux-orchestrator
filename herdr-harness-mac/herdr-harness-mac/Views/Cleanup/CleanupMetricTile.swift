import SwiftUI

struct CleanupMetricTile: View {
    let title: String
    let value: String
    let symbol: String
    let tone: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tone)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .herdrFont(.headline, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                Text(title)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(HerdrTheme.elevated.opacity(0.72))
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
