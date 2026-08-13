import Foundation

enum PiMarkdownParser {
    static func parse(_ source: String) -> [PiMarkdownBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [PiMarkdownBlock] = []
        var index = 0

        func append(_ block: (Int) -> PiMarkdownBlock) {
            blocks.append(block(blocks.count))
        }

        while index < lines.count {
            if isBlank(lines[index]) {
                index += 1
                continue
            }

            if let fence = fenceOpening(in: lines[index]) {
                let parsed = parseFence(lines: lines, openingIndex: index, fence: fence)
                append { .code(id: $0, language: parsed.language, code: parsed.code) }
                index = parsed.nextIndex
                continue
            }

            if let heading = atxHeading(in: lines[index]) {
                append { .heading(id: $0, level: heading.level, text: heading.text) }
                index += 1
                continue
            }

            if let table = parseTable(lines: lines, headerIndex: index) {
                append { .table(id: $0, table: table.table) }
                index = table.nextIndex
                continue
            }

            if index + 1 < lines.count,
               let level = setextHeadingLevel(in: lines[index + 1]),
               !isBlank(lines[index]) {
                append {
                    .heading(
                        id: $0,
                        level: level,
                        text: lines[index].trimmingCharacters(in: .whitespaces)
                    )
                }
                index += 2
                continue
            }

            if isThematicBreak(lines[index]) {
                append { .thematicBreak(id: $0) }
                index += 1
                continue
            }

            if quoteText(in: lines[index]) != nil {
                var quoteLines: [String] = []
                while index < lines.count, let quote = quoteText(in: lines[index]) {
                    quoteLines.append(quote)
                    index += 1
                }
                append { .quote(id: $0, text: quoteLines.joined(separator: "\n")) }
                continue
            }

            if listItem(in: lines[index]) != nil {
                let parsed = parseList(lines: lines, startIndex: index)
                append { .list(id: $0, items: parsed.items) }
                index = parsed.nextIndex
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count, !isBlank(lines[index]) {
                if !paragraphLines.isEmpty, startsBlock(lines: lines, at: index) {
                    break
                }
                paragraphLines.append(lines[index])
                index += 1
            }
            let text = paragraphLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                append { .paragraph(id: $0, text: text) }
            }
        }

        return blocks
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let info: String
    }

    private struct ParsedFence {
        let language: String?
        let code: String
        let nextIndex: Int
    }

    private static func parseFence(lines: [String], openingIndex: Int, fence: Fence) -> ParsedFence {
        var codeLines: [String] = []
        var index = openingIndex + 1
        while index < lines.count {
            if isFenceClosing(lines[index], matching: fence) {
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }
        let language = fence.info
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        return ParsedFence(language: language, code: codeLines.joined(separator: "\n"), nextIndex: index)
    }

    private static func fenceOpening(in line: String) -> Fence? {
        let content = dropUpToThreeLeadingSpaces(from: line)
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let count = content.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = content.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return Fence(marker: marker, count: count, info: info)
    }

    private static func isFenceClosing(_ line: String, matching fence: Fence) -> Bool {
        let content = dropUpToThreeLeadingSpaces(from: line)
        let count = content.prefix(while: { $0 == fence.marker }).count
        guard count >= fence.count else { return false }
        return content.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    private static func atxHeading(in line: String) -> (level: Int, text: String)? {
        let content = dropUpToThreeLeadingSpaces(from: line)
        let level = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let remainder = content.dropFirst(level)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }

        var text = remainder.trimmingCharacters(in: .whitespaces)
        if let hashes = text.lastIndex(where: { $0 != "#" }) {
            let trailingHashes = text[text.index(after: hashes)...]
            if !trailingHashes.isEmpty, text[hashes].isWhitespace {
                text = String(text[..<hashes]).trimmingCharacters(in: .whitespaces)
            }
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return (level, text)
    }

    private static func setextHeadingLevel(in line: String) -> Int? {
        let content = line.trimmingCharacters(in: .whitespaces)
        guard content.count >= 1 else { return nil }
        if content.allSatisfy({ $0 == "=" }) { return 1 }
        if content.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let content = line.filter { !$0.isWhitespace }
        guard content.count >= 3, let marker = content.first, "*-_".contains(marker) else { return false }
        return content.allSatisfy { $0 == marker }
    }

    private static func quoteText(in line: String) -> String? {
        let content = dropUpToThreeLeadingSpaces(from: line)
        guard content.first == ">" else { return nil }
        var quote = content.dropFirst()
        if quote.first == " " { quote = quote.dropFirst() }
        return String(quote)
    }

    private struct ParsedListItem {
        let marker: PiMarkdownListItem.Marker
        let text: String
        let indentation: Int
    }

    private static func listItem(in line: String) -> ParsedListItem? {
        let indentation = indentationWidth(of: line)
        let content = line.drop(while: \.isWhitespace)
        guard !content.isEmpty else { return nil }

        if let marker = content.first, "-+*".contains(marker) {
            let remainder = content.dropFirst()
            guard remainder.first?.isWhitespace == true else { return nil }
            return taskOrListItem(
                text: String(remainder.drop(while: \.isWhitespace)),
                defaultMarker: .bullet,
                indentation: indentation
            )
        }

        let digits = content.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let suffix = content.dropFirst(digits.count)
        guard let delimiter = suffix.first, delimiter == "." || delimiter == ")" else { return nil }
        let remainder = suffix.dropFirst()
        guard remainder.first?.isWhitespace == true else { return nil }
        return taskOrListItem(
            text: String(remainder.drop(while: \.isWhitespace)),
            defaultMarker: .number(String(digits)),
            indentation: indentation
        )
    }

    private static func taskOrListItem(
        text: String,
        defaultMarker: PiMarkdownListItem.Marker,
        indentation: Int
    ) -> ParsedListItem {
        let marker: PiMarkdownListItem.Marker
        let itemText: String
        if text.count >= 3,
           text.first == "[",
           text.dropFirst(2).first == "]",
           let state = text.dropFirst().first,
           state == " " || state == "x" || state == "X" {
            marker = .task(isCompleted: state == "x" || state == "X")
            itemText = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else {
            marker = defaultMarker
            itemText = text
        }
        return ParsedListItem(
            marker: marker,
            text: itemText,
            indentation: indentation
        )
    }

    private static func parseList(lines: [String], startIndex: Int) -> (items: [PiMarkdownListItem], nextIndex: Int) {
        var items: [PiMarkdownListItem] = []
        var itemIndentations: [Int] = []
        var indentationLevels: [Int] = []
        var index = startIndex

        while index < lines.count {
            if let parsed = listItem(in: lines[index]) {
                while let last = indentationLevels.last, last > parsed.indentation {
                    indentationLevels.removeLast()
                }
                if indentationLevels.last != parsed.indentation {
                    indentationLevels.append(parsed.indentation)
                }
                let depth = max(0, indentationLevels.count - 1)
                items.append(PiMarkdownListItem(marker: parsed.marker, text: parsed.text, depth: depth))
                itemIndentations.append(parsed.indentation)
                index += 1
                continue
            }

            guard !items.isEmpty,
                  !isBlank(lines[index]),
                  indentationWidth(of: lines[index]) > (itemIndentations.last ?? 0) else {
                break
            }
            let continuation = lines[index].trimmingCharacters(in: .whitespaces)
            let previous = items.removeLast()
            items.append(
                PiMarkdownListItem(
                    marker: previous.marker,
                    text: previous.text + "\n" + continuation,
                    depth: previous.depth
                )
            )
            index += 1
        }

        return (items, index)
    }

    private static func parseTable(
        lines: [String],
        headerIndex: Int
    ) -> (table: PiMarkdownTable, nextIndex: Int)? {
        guard headerIndex + 1 < lines.count,
              containsUnescapedPipe(lines[headerIndex]) else { return nil }

        let headers = splitTableRow(lines[headerIndex])
        let delimiters = splitTableRow(lines[headerIndex + 1])
        guard !headers.isEmpty,
              headers.count == delimiters.count else { return nil }

        let alignments = delimiters.compactMap(tableAlignment)
        guard alignments.count == delimiters.count else { return nil }

        var rows: [[String]] = []
        var index = headerIndex + 2
        while index < lines.count,
              !isBlank(lines[index]),
              containsUnescapedPipe(lines[index]) {
            var cells = splitTableRow(lines[index])
            if cells.count < headers.count {
                cells.append(contentsOf: repeatElement("", count: headers.count - cells.count))
            } else if cells.count > headers.count {
                cells = Array(cells.prefix(headers.count))
            }
            rows.append(cells)
            index += 1
        }

        return (
            PiMarkdownTable(headers: headers, alignments: alignments, rows: rows),
            index
        )
    }

    private static func tableAlignment(_ source: String) -> PiMarkdownTable.ColumnAlignment? {
        let content = source.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        let leadingColon = content.first == ":"
        let trailingColon = content.last == ":"
        let dashes = content.drop(while: { $0 == ":" }).dropLast(trailingColon ? 1 : 0)
        guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        if leadingColon, trailingColon { return .center }
        if trailingColon { return .trailing }
        return .leading
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.first == "|" { content.removeFirst() }
        if content.last == "|", !isEscapedPipe(at: content.index(before: content.endIndex), in: content) {
            content.removeLast()
        }

        var cells: [String] = []
        var cell = ""
        var isEscaped = false
        var inCodeSpan = false
        for character in content {
            if isEscaped {
                cell.append(character)
                isEscaped = false
            } else if character == "\\" {
                cell.append(character)
                isEscaped = true
            } else if character == "`" {
                cell.append(character)
                inCodeSpan.toggle()
            } else if character == "|", !inCodeSpan {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func containsUnescapedPipe(_ line: String) -> Bool {
        var isEscaped = false
        var inCodeSpan = false
        for character in line {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "`" {
                inCodeSpan.toggle()
            } else if character == "|", !inCodeSpan {
                return true
            }
        }
        return false
    }

    private static func isEscapedPipe(at index: String.Index, in source: String) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > source.startIndex {
            cursor = source.index(before: cursor)
            guard source[cursor] == "\\" else { break }
            slashes += 1
        }
        return slashes.isMultiple(of: 2) == false
    }

    private static func startsBlock(lines: [String], at index: Int) -> Bool {
        fenceOpening(in: lines[index]) != nil
            || parseTable(lines: lines, headerIndex: index) != nil
            || atxHeading(in: lines[index]) != nil
            || isThematicBreak(lines[index])
            || quoteText(in: lines[index]) != nil
            || listItem(in: lines[index]) != nil
    }

    private static func indentationWidth(of line: String) -> Int {
        line.prefix(while: \.isWhitespace).reduce(into: 0) { width, character in
            width += character == "\t" ? 4 : 1
        }
    }

    private static func dropUpToThreeLeadingSpaces(from line: String) -> Substring {
        var content = line[...]
        var dropped = 0
        while dropped < 3, content.first == " " {
            content = content.dropFirst()
            dropped += 1
        }
        return content
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }
}
