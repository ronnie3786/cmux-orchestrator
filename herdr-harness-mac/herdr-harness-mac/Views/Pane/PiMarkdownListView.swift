import SwiftUI

struct PiMarkdownListView: View {
    let items: [PiMarkdownListItem]
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    marker(for: item.marker)
                        .frame(width: 24, alignment: .trailing)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    PiMarkdownText(item.text, font: HerdrTheme.scaled(.body, scale: fontScale))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(min(item.depth, 6)) * 17)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: item))
            }
        }
    }

    @ViewBuilder
    private func marker(for marker: PiMarkdownListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
                .herdrFont(.body, weight: .bold)
                .foregroundStyle(HerdrTheme.accent)
        case let .number(number):
            Text("\(number).")
                .herdrFont(.callout, monospacedDigit: true)
                .foregroundStyle(HerdrTheme.accent)
        case let .task(isCompleted):
            Image(systemName: isCompleted ? "checkmark.square.fill" : "square")
                .herdrFont(.callout, weight: .semibold)
                .foregroundStyle(isCompleted ? HerdrTheme.success : HerdrTheme.muted)
        }
    }

    private func accessibilityLabel(for item: PiMarkdownListItem) -> String {
        switch item.marker {
        case .bullet:
            "Bullet, \(item.text)"
        case let .number(number):
            "Item \(number), \(item.text)"
        case let .task(isCompleted):
            "\(isCompleted ? "Completed" : "Incomplete") task, \(item.text)"
        }
    }
}
