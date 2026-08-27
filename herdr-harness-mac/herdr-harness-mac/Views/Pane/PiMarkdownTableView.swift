import SwiftUI

struct PiMarkdownTableView: View {
    let table: PiMarkdownTable
    @Environment(\.herdrFontScale) private var fontScale
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        let layout = PiMarkdownTableLayout(
            viewportWidth: viewportWidth,
            columnCount: table.headers.count,
            fontScale: fontScale
        )

        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(
                    table.headers,
                    rowIndex: nil,
                    columnWidth: layout.columnWidth,
                    isLastRow: table.rows.isEmpty
                )
                ForEach(table.rows.indices, id: \.self) { rowIndex in
                    tableRow(
                        table.rows[rowIndex],
                        rowIndex: rowIndex,
                        columnWidth: layout.columnWidth,
                        isLastRow: rowIndex == table.rows.indices.last
                    )
                }
            }
            .frame(minWidth: layout.contentWidth, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.graphite.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(HerdrTheme.surface.opacity(0.78), lineWidth: 1)
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { newWidth in
            viewportWidth = newWidth
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Table with \(table.headers.count) columns and \(table.rows.count) rows"
        )
    }

    private func tableRow(
        _ cells: [String],
        rowIndex: Int?,
        columnWidth: CGFloat,
        isLastRow: Bool
    ) -> some View {
        GridRow {
            ForEach(cells.indices, id: \.self) { columnIndex in
                let role: HerdrProse.Role = rowIndex == nil ? .tableHeader : .tableCell
                PiMarkdownText(
                    cells[columnIndex],
                    font: HerdrProse.font(role, scale: fontScale),
                    inlineCodeFont: HerdrProse.inlineCodeFont(role, scale: fontScale),
                    inlineCodeColor: HerdrProse.inlineCodeColor
                )
                .multilineTextAlignment(textAlignment(for: columnIndex))
                .padding(.horizontal, 12)
                .padding(.vertical, rowIndex == nil ? 10 : 9)
                .frame(width: columnWidth, alignment: frameAlignment(for: columnIndex))
                .overlay(alignment: .trailing) {
                    if columnIndex < cells.count - 1 {
                        Rectangle()
                            .fill(HerdrTheme.surface.opacity(0.34))
                            .frame(width: 1)
                    }
                }
                .accessibilityLabel(
                    accessibilityLabel(
                        cell: cells[columnIndex],
                        columnIndex: columnIndex,
                        rowIndex: rowIndex
                    )
                )
            }
        }
        .background(rowBackground(rowIndex: rowIndex))
        .overlay(alignment: .bottom) {
            if !isLastRow {
                Rectangle()
                    .fill(rowDivider(rowIndex: rowIndex))
                    .frame(height: 1)
            }
        }
    }

    private func rowBackground(rowIndex: Int?) -> Color {
        guard let rowIndex else { return HerdrTheme.elevated.opacity(0.88) }
        return rowIndex.isMultiple(of: 2)
            ? HerdrTheme.graphite.opacity(0.78)
            : HerdrTheme.ink.opacity(0.52)
    }

    private func rowDivider(rowIndex: Int?) -> Color {
        rowIndex == nil
            ? HerdrTheme.accent.opacity(0.44)
            : HerdrTheme.surface.opacity(0.56)
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
