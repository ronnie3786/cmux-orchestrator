import Foundation
import SwiftUI

struct TerminalGrid: Sendable {
    private struct Cell: Equatable, Sendable {
        var character: Character = " "
        var style = Style()
    }

    private struct Style: Equatable, Sendable {
        var foreground: TerminalColor?
        var background: TerminalColor?
        var bold = false
        var italic = false
        var underline = false
        var inverse = false
    }

    private struct TerminalColor: Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        var color: Color {
            Color(
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255
            )
        }
    }

    private(set) var columns: Int
    private(set) var rows: Int
    private var cells: [Cell]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var cursorVisible = true
    private var wrapPending = false
    private var style = Style()
    private var lastSequence = 0

    init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        cells = Array(repeating: Cell(), count: max(1, columns) * max(1, rows))
    }

    var plainText: String {
        visibleRows().map { row in
            String(row.map(\.character)).trimmingTrailingSpaces()
        }
        .joined(separator: "\n")
        .trimmingTrailingNewlines()
    }

    var attributedText: AttributedString {
        let visible = visibleRows(includeCursor: true)
        guard !visible.isEmpty else { return AttributedString("") }

        var result = AttributedString()
        for rowIndex in visible.indices {
            let row = visible[rowIndex]
            var run = ""
            var runStyle: Style?

            func appendRun() {
                guard !run.isEmpty, let runStyle else { return }
                var value = AttributedString(run)
                let colors = resolvedColors(for: runStyle)
                value.foregroundColor = colors.foreground
                if let background = colors.background {
                    value.backgroundColor = background
                }
                var font = Font.system(
                    size: 12,
                    weight: runStyle.bold ? .semibold : .regular,
                    design: .monospaced
                )
                if runStyle.italic { font = font.italic() }
                value.font = font
                if runStyle.underline { value.underlineStyle = .single }
                result.append(value)
            }

            for columnIndex in row.indices {
                var cell = row[columnIndex]
                if cursorVisible, rowIndex == cursorRow, columnIndex == cursorColumn {
                    cell.style.inverse.toggle()
                }
                if let runStyle, runStyle != cell.style {
                    appendRun()
                    run = ""
                }
                runStyle = cell.style
                run.append(cell.character)
            }
            appendRun()
            if rowIndex < visible.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    mutating func apply(_ frame: TerminalFrame) -> Bool {
        guard frame.type == "terminal.frame",
              frame.width > 0,
              frame.height > 0,
              let data = Data(base64Encoded: frame.bytes),
              let payload = String(data: data, encoding: .utf8)
        else { return false }

        if frame.full {
            columns = frame.width
            rows = frame.height
            reset()
        } else {
            guard frame.sequence > lastSequence else { return true }
            resize(columns: frame.width, rows: frame.height)
        }
        lastSequence = frame.sequence
        parse(payload)
        return true
    }

    private mutating func reset() {
        cells = Array(repeating: Cell(), count: columns * rows)
        cursorRow = 0
        cursorColumn = 0
        cursorVisible = true
        wrapPending = false
        style = Style()
    }

    private mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let targetColumns = max(1, newColumns)
        let targetRows = max(1, newRows)
        guard targetColumns != columns || targetRows != rows else { return }
        var resized = Array(repeating: Cell(), count: targetColumns * targetRows)
        for row in 0..<min(rows, targetRows) {
            for column in 0..<min(columns, targetColumns) {
                resized[row * targetColumns + column] = cells[row * columns + column]
            }
        }
        columns = targetColumns
        rows = targetRows
        cells = resized
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        wrapPending = false
    }

    private mutating func parse(_ payload: String) {
        let characters = Array(payload)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\u{001B}" {
                index = consumeEscape(in: characters, from: index)
                continue
            }
            switch character {
            case "\r":
                cursorColumn = 0
                wrapPending = false
            case "\n":
                lineFeed()
                wrapPending = false
            case "\u{0008}":
                cursorColumn = max(0, cursorColumn - 1)
                wrapPending = false
            case "\t":
                cursorColumn = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
                wrapPending = false
            default:
                if !character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                    put(character)
                }
            }
            index += 1
        }
    }

    private mutating func consumeEscape(in characters: [Character], from start: Int) -> Int {
        guard start + 1 < characters.count else { return start + 1 }
        let introducer = characters[start + 1]
        if introducer == "[" {
            var end = start + 2
            while end < characters.count {
                guard let scalar = characters[end].unicodeScalars.first else {
                    end += 1
                    continue
                }
                if (0x40...0x7E).contains(scalar.value) {
                    let parameters = String(characters[(start + 2)..<end])
                    applyCSI(final: characters[end], parameters: parameters)
                    return end + 1
                }
                end += 1
            }
            return characters.count
        }
        if introducer == "]" {
            var end = start + 2
            while end < characters.count {
                if characters[end] == "\u{0007}" { return end + 1 }
                if characters[end] == "\u{001B}", end + 1 < characters.count, characters[end + 1] == "\\" {
                    return end + 2
                }
                end += 1
            }
            return characters.count
        }
        return min(start + 2, characters.count)
    }

    private mutating func applyCSI(final: Character, parameters rawParameters: String) {
        let isPrivate = rawParameters.first == "?"
        let cleaned = rawParameters.trimmingCharacters(in: CharacterSet(charactersIn: "?>!"))
        let values = cleaned.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = values.first ?? 0
        wrapPending = false

        if isPrivate, final == "h" || final == "l" {
            if values.contains(25) { cursorVisible = final == "h" }
            return
        }

        switch final {
        case "H", "f":
            cursorRow = clamped((values[safe: 0] ?? 1) - 1, upperBound: rows)
            cursorColumn = clamped((values[safe: 1] ?? 1) - 1, upperBound: columns)
        case "A": cursorRow = max(0, cursorRow - max(1, first))
        case "B": cursorRow = min(rows - 1, cursorRow + max(1, first))
        case "C": cursorColumn = min(columns - 1, cursorColumn + max(1, first))
        case "D": cursorColumn = max(0, cursorColumn - max(1, first))
        case "G": cursorColumn = clamped(max(1, first) - 1, upperBound: columns)
        case "d": cursorRow = clamped(max(1, first) - 1, upperBound: rows)
        case "J": eraseDisplay(mode: first)
        case "K": eraseLine(mode: first)
        case "m": applySGR(values.isEmpty ? [0] : values)
        default: break
        }
    }

    private mutating func applySGR(_ values: [Int]) {
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: break
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = indexedColor(code - 30)
            case 39: style.foreground = nil
            case 40...47: style.background = indexedColor(code - 40)
            case 90...97: style.foreground = indexedColor(code - 90 + 8)
            case 100...107: style.background = indexedColor(code - 100 + 8)
            case 49: style.background = nil
            case 38, 48:
                let isForeground = code == 38
                if values[safe: index + 1] == 2,
                   let red = values[safe: index + 2],
                   let green = values[safe: index + 3],
                   let blue = values[safe: index + 4] {
                    let color = TerminalColor(
                        red: UInt8(clamping: red),
                        green: UInt8(clamping: green),
                        blue: UInt8(clamping: blue)
                    )
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 4
                } else if values[safe: index + 1] == 5, let colorIndex = values[safe: index + 2] {
                    let color = indexedColor(colorIndex)
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 2
                }
            default: break
            }
            index += 1
        }
    }

    private mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 2, 3:
            cells = Array(repeating: Cell(), count: columns * rows)
        case 1:
            let end = cursorRow * columns + cursorColumn
            if end >= 0 {
                for index in 0...min(end, cells.count - 1) { cells[index] = Cell() }
            }
        default:
            let start = cursorRow * columns + cursorColumn
            if start < cells.count {
                for index in start..<cells.count { cells[index] = Cell() }
            }
        }
    }

    private mutating func eraseLine(mode: Int) {
        let rowStart = cursorRow * columns
        switch mode {
        case 1:
            for column in 0...cursorColumn { cells[rowStart + column] = Cell() }
        case 2:
            for column in 0..<columns { cells[rowStart + column] = Cell() }
        default:
            for column in cursorColumn..<columns { cells[rowStart + column] = Cell() }
        }
    }

    private mutating func put(_ character: Character) {
        if wrapPending {
            cursorColumn = 0
            lineFeed()
            wrapPending = false
        }
        cells[cursorRow * columns + cursorColumn] = Cell(character: character, style: style)
        if cursorColumn == columns - 1 {
            wrapPending = true
        } else {
            cursorColumn += 1
        }
    }

    private mutating func lineFeed() {
        if cursorRow == rows - 1 {
            cells.removeFirst(columns)
            cells.append(contentsOf: Array(repeating: Cell(), count: columns))
        } else {
            cursorRow += 1
        }
    }

    private func visibleRows(includeCursor: Bool = false) -> [[Cell]] {
        guard !cells.isEmpty else { return [] }
        var lastRow = -1
        for row in 0..<rows {
            let range = (row * columns)..<((row + 1) * columns)
            if cells[range].contains(where: { $0.character != " " }) {
                lastRow = row
            }
        }
        if includeCursor, cursorVisible { lastRow = max(lastRow, cursorRow) }
        guard lastRow >= 0 else { return [] }

        return (0...lastRow).map { row in
            let range = (row * columns)..<((row + 1) * columns)
            let values = Array(cells[range])
            var lastColumn = values.lastIndex(where: { $0.character != " " }) ?? -1
            if includeCursor, cursorVisible, row == cursorRow {
                lastColumn = max(lastColumn, cursorColumn)
            }
            return lastColumn >= 0 ? Array(values[0...lastColumn]) : []
        }
    }

    private func resolvedColors(for style: Style) -> (foreground: Color, background: Color?) {
        let defaultForeground = Color(red: 0.84, green: 0.87, blue: 0.90)
        let foreground = style.foreground?.color ?? defaultForeground
        let background = style.background?.color
        if style.inverse {
            return (background ?? Color.black, foreground)
        }
        return (foreground, background)
    }

    private func indexedColor(_ index: Int) -> TerminalColor {
        let base: [TerminalColor] = [
            .init(red: 0, green: 0, blue: 0), .init(red: 205, green: 49, blue: 49),
            .init(red: 13, green: 188, blue: 121), .init(red: 229, green: 229, blue: 16),
            .init(red: 36, green: 114, blue: 200), .init(red: 188, green: 63, blue: 188),
            .init(red: 17, green: 168, blue: 205), .init(red: 229, green: 229, blue: 229),
            .init(red: 102, green: 102, blue: 102), .init(red: 241, green: 76, blue: 76),
            .init(red: 35, green: 209, blue: 139), .init(red: 245, green: 245, blue: 67),
            .init(red: 59, green: 142, blue: 234), .init(red: 214, green: 112, blue: 214),
            .init(red: 41, green: 184, blue: 219), .init(red: 255, green: 255, blue: 255),
        ]
        let clampedIndex = min(max(index, 0), 255)
        if clampedIndex < 16 { return base[clampedIndex] }
        if clampedIndex < 232 {
            let value = clampedIndex - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return TerminalColor(
                red: levels[value / 36],
                green: levels[(value / 6) % 6],
                blue: levels[value % 6]
            )
        }
        let gray = UInt8(8 + (clampedIndex - 232) * 10)
        return TerminalColor(red: gray, green: gray, blue: gray)
    }

    private func clamped(_ value: Int, upperBound: Int) -> Int {
        min(max(0, value), max(0, upperBound - 1))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        String(reversed().drop(while: { $0 == " " }).reversed())
    }

    func trimmingTrailingNewlines() -> String {
        String(reversed().drop(while: { $0 == "\n" }).reversed())
    }
}
