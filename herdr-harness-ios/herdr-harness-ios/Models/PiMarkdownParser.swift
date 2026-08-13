import Foundation

enum PiMarkdownParser {
    static func parse(_ source: String) -> [PiMarkdownBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [PiMarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var language: String?
        var inFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(id: blocks.count, text: text)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(id: blocks.count, language: language, code: code.joined(separator: "\n")))
            code.removeAll(keepingCapacity: true)
            language = nil
        }

        for line in lines {
            if line.hasPrefix("```") {
                if inFence {
                    flushCode()
                    inFence = false
                } else {
                    flushParagraph()
                    let label = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    language = label.isEmpty ? nil : label
                    inFence = true
                }
                continue
            }
            if inFence {
                code.append(line)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(id: blocks.count, text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(id: blocks.count, text: String(trimmed.dropFirst(2))))
            } else if let match = numberedLine(trimmed) {
                flushParagraph()
                blocks.append(.numbered(id: blocks.count, number: match.number, text: match.text))
            } else {
                paragraph.append(line)
            }
        }
        if inFence { flushCode() } else { flushParagraph() }
        return blocks
    }

    private static func numberedLine(_ line: String) -> (number: String, text: String)? {
        guard let separator = line.firstIndex(of: "."), separator != line.startIndex else { return nil }
        let number = line[..<separator]
        guard number.allSatisfy(\.isNumber) else { return nil }
        let textStart = line.index(after: separator)
        guard textStart < line.endIndex, line[textStart] == " " else { return nil }
        return (String(number), String(line[line.index(after: textStart)...]))
    }
}
