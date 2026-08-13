import SwiftUI

struct PiMarkdownTableView: View {
    let table: PiMarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(table.headers, rowIndex: nil)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, cells in
                    tableRow(cells, rowIndex: rowIndex)
                }
            }
        }
        .scrollIndicators(.visible)
        .background(HerdrTheme.ink.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(HerdrTheme.surface.opacity(0.78), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Table with \(table.headers.count) columns and \(table.rows.count) rows"
        )
    }

    private func tableRow(_ cells: [String], rowIndex: Int?) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { columnIndex, cell in
                PiMarkdownText(
                    cell,
                    font: rowIndex == nil ? .callout.weight(.semibold) : .callout
                )
                .multilineTextAlignment(textAlignment(for: columnIndex))
                .frame(
                    minWidth: 112,
                    idealWidth: 152,
                    maxWidth: 232,
                    alignment: frameAlignment(for: columnIndex)
                )
                .padding(.horizontal, 11)
                .padding(.vertical, rowIndex == nil ? 10 : 9)
                .background(cellBackground(rowIndex: rowIndex))
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(HerdrTheme.surface.opacity(0.48))
                        .frame(width: 1)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(HerdrTheme.surface.opacity(0.48))
                        .frame(height: 1)
                }
                .accessibilityLabel(
                    accessibilityLabel(cell: cell, columnIndex: columnIndex, rowIndex: rowIndex)
                )
            }
        }
    }

    private func cellBackground(rowIndex: Int?) -> Color {
        guard let rowIndex else { return HerdrTheme.elevated.opacity(0.72) }
        return rowIndex.isMultiple(of: 2)
            ? HerdrTheme.graphite.opacity(0.6)
            : HerdrTheme.ink.opacity(0.35)
    }

    private func frameAlignment(for column: Int) -> Alignment {
        switch alignment(for: column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(for column: Int) -> TextAlignment {
        switch alignment(for: column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func alignment(for column: Int) -> PiMarkdownTable.ColumnAlignment {
        guard table.alignments.indices.contains(column) else { return .leading }
        return table.alignments[column]
    }

    private func accessibilityLabel(cell: String, columnIndex: Int, rowIndex: Int?) -> String {
        if rowIndex == nil {
            return "Column \(columnIndex + 1), \(cell)"
        }
        let header = table.headers.indices.contains(columnIndex)
            ? table.headers[columnIndex]
            : "Column \(columnIndex + 1)"
        return "\(header), \(cell)"
    }
}
