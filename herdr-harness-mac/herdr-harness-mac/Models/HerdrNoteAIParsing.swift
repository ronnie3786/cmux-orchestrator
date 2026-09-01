import Foundation

enum HerdrNoteAIParsing {
    struct Cleanup: Equatable { let title: String?; let body: String }
    struct SmartActionItem: Equatable { let title: String; let prompt: String }
    struct SmartActions: Equatable { let summary: String?; let actions: [SmartActionItem] }

    static func stripFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2,
              lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```") ,
              lines[lines.count - 1] == "```"
        else { return trimmed }
        return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanup(_ response: String) -> Cleanup? {
        let stripped = stripFence(response.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = stripped.components(separatedBy: .newlines)
        guard let firstLine = lines.first else { return nil }

        let title: String?
        let body: String
        let firstTrimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let headingTitle = headingTitle(from: firstTrimmed) {
            title = String(headingTitle.prefix(80))
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !firstTrimmed.isEmpty,
                  firstTrimmed.count <= 80,
                  lines.count > 1,
                  lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = firstTrimmed
            body = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = nil
            body = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let transformed = collapseBlankLines(in: body.components(separatedBy: .newlines).map(transformLine))
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transformed.isEmpty else { return nil }
        return Cleanup(title: title, body: transformed)
    }

    static func smartActions(_ response: String) -> SmartActions? {
        guard let firstBrace = response.firstIndex(of: "{"),
              let lastBrace = response.lastIndex(of: "}"),
              firstBrace <= lastBrace
        else { return nil }
        let objectText = String(response[firstBrace...lastBrace])
        guard let data = objectText.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let summary = (dictionary["summary"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        var actions: [SmartActionItem] = []
        for item in dictionary["actions"] as? [Any] ?? [] {
            guard let action = item as? [String: Any],
                  let title = action["title"] as? String,
                  let prompt = action["prompt"] as? String
            else { continue }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty, !trimmedPrompt.isEmpty else { continue }
            actions.append(
                SmartActionItem(
                    title: String(trimmedTitle.prefix(60)),
                    prompt: String(trimmedPrompt.prefix(4000))
                )
            )
            if actions.count == 4 { break }
        }
        return SmartActions(summary: summary, actions: actions)
    }

    private static func headingTitle(from line: String) -> String? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" { index = line.index(after: index) }
        guard index > line.startIndex,
              index < line.endIndex,
              line[index].isWhitespace
        else { return nil }
        return line[index...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transformLine(_ line: String) -> String {
        let leadingTrimmed = line.drop { $0 == " " || $0 == "\t" }
        let content: Substring
        if leadingTrimmed.hasPrefix("- ") || leadingTrimmed.hasPrefix("* ") {
            content = leadingTrimmed.dropFirst(2)
        } else {
            content = leadingTrimmed
        }
        if content.hasPrefix("[ ]") {
            return "☐ " + content.dropFirst(3).trimmingCharacters(in: .whitespaces)
        }
        if content.hasPrefix("[x]") || content.hasPrefix("[X]") {
            return "☑ " + content.dropFirst(3).trimmingCharacters(in: .whitespaces)
        }
        if leadingTrimmed.hasPrefix("- ") || leadingTrimmed.hasPrefix("* ") {
            return "• " + content
        }
        return line
    }

    private static func collapseBlankLines(in lines: [String]) -> [String] {
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blankCount += 1
                if blankCount <= 2 { result.append(line) }
            } else {
                blankCount = 0
                result.append(line)
            }
        }
        return result
    }
}
