import SwiftUI

struct PiMarkdownListView: View {
    let items: [PiMarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    marker(for: item.marker)
                        .frame(width: 24, alignment: .trailing)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    PiMarkdownText(
                        item.text,
                        font: HerdrProse.font(.listItem),
                        inlineCodeFont: HerdrProse.inlineCodeFont(.listItem),
                        inlineCodeColor: HerdrProse.inlineCodeColor
                    )
                        .lineSpacing(HerdrProse.lineSpacing(.listItem))
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
                .font(.body.weight(.bold))
                .foregroundStyle(HerdrTheme.muted)
        case let .number(number):
            Text("\(number).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(HerdrTheme.muted)
        case let .task(isCompleted):
            Image(systemName: isCompleted ? "checkmark.square.fill" : "square")
                .font(.callout.weight(.semibold))
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
