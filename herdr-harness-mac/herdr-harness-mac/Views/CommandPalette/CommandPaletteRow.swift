import SwiftUI

struct CommandPaletteRow: View {
    let entry: CommandPaletteEntry
    let isHighlighted: Bool
    let action: () -> Void
    let highlight: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: entry.status.symbol)
                    .herdrFont(.body, weight: .bold)
                    .foregroundStyle(entry.status.labelColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .herdrFont(.body, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)

                    Text(entry.contextLine)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(entry.machineName)
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)

                    Text(entry.status.compactTitle.lowercased())
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(entry.status.labelColor)
                        .lineLimit(1)
                }

                Image(systemName: "return")
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(isHighlighted ? HerdrTheme.accent : HerdrTheme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(.rect)
            .background(isHighlighted ? HerdrTheme.accent.opacity(0.14) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isHighlighted ? HerdrTheme.accent : .clear)
                    .frame(width: 3)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { highlight() }
        }
        .accessibilityLabel(entry.accessibilitySummary)
        .accessibilityValue(isHighlighted ? "Selected" : "")
        .accessibilityInputLabels([entry.title, "Open \(entry.title)"])
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("command-palette-row-\(entry.id)")
    }
}
