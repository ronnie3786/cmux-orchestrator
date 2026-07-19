import Foundation

enum OpenCodeTerminalInteractionDetector {
    static func detect(in rawText: String) -> OpenCodeTerminalInteraction? {
        let plainText = TerminalTextStyler.plainText(for: rawText)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let visibleLines = Array(plainText.split(separator: "\n", omittingEmptySubsequences: false).suffix(48))
            .map(String.init)

        if let permission = permissionInteraction(in: visibleLines) {
            return permission
        }
        return questionInteraction(in: visibleLines)
    }

    private static func permissionInteraction(in lines: [String]) -> OpenCodeTerminalInteraction? {
        guard let anchorIndex = activeOpenCodeAnchorIndex(in: lines) else { return nil }
        let windowStart = activePromptWindowStart(in: lines, before: anchorIndex)
        let promptWindow = lines[windowStart...anchorIndex]
        guard let headerIndex = promptWindow.lastIndex(where: {
            normalized($0).localizedCaseInsensitiveContains("permission required")
        }) else {
            return nil
        }

        let block = Array(lines[headerIndex...anchorIndex])
        let flattened = block.map { normalized($0) }.joined(separator: " ").lowercased()
        let optionLabels = ["Allow once", "Allow always", "Reject"]
        guard optionLabels.allSatisfy({ flattened.contains($0.lowercased()) }),
              flattened.contains("enter"),
              flattened.contains("confirm") else {
            return nil
        }
        guard let footerIndex = interactionFooterIndex(in: block, completion: "confirm"),
              isCurrentPromptTail(Array(block[(footerIndex + 1)...])) else {
            return nil
        }

        let detailLines = block
            .dropFirst()
            .prefix { line in
                let value = normalized(line).lowercased()
                return !value.contains("allow once")
                    && !value.contains("allow always")
                    && !value.contains("reject")
                    && !value.contains("select")
                    && !value.contains("confirm")
            }
            .map { normalized($0) }
            .filter { value in
                !value.isEmpty && value.lowercased() != "patterns"
            }

        return OpenCodeTerminalInteraction(
            kind: .permission,
            title: "Permission required",
            detail: detailLines.joined(separator: "\n"),
            options: optionLabels,
            navigationAxis: .horizontal
        )
    }

    private static func questionInteraction(in lines: [String]) -> OpenCodeTerminalInteraction? {
        guard let anchorIndex = activeOpenCodeAnchorIndex(in: lines) else { return nil }
        let windowStart = max(
            activePromptWindowStart(in: lines, before: anchorIndex),
            anchorIndex - 24
        )
        let activeLines = Array(lines[windowStart...anchorIndex])

        let flattened = activeLines.map { normalized($0) }.joined(separator: " ").lowercased()
        guard flattened.contains("select"),
              flattened.contains("enter"),
              flattened.contains("dismiss") else {
            return nil
        }
        guard let footerIndex = interactionFooterIndex(in: activeLines, completion: "dismiss"),
              isCurrentPromptTail(Array(activeLines[(footerIndex + 1)...])) else {
            return nil
        }

        let optionLines = Array(activeLines[..<footerIndex])
        let options = optionLines.compactMap { numberedOption(from: $0) }
        guard options.count >= 2 else { return nil }

        let firstOptionIndex = optionLines.firstIndex(where: { numberedOption(from: $0) != nil }) ?? optionLines.startIndex
        let question = optionLines[..<firstOptionIndex]
            .reversed()
            .map { normalized($0) }
            .first { value in
                !value.isEmpty
                    && !value.lowercased().contains("opencode ")
                    && !value.lowercased().contains("select")
            } ?? "OpenCode needs your answer"

        return OpenCodeTerminalInteraction(
            kind: .question,
            title: "OpenCode question",
            detail: question,
            options: options,
            navigationAxis: .vertical
        )
    }

    private static func numberedOption(from line: String) -> String? {
        let value = normalized(line)
        guard !value.isEmpty,
              value.first?.isNumber == true,
              !value.localizedCaseInsensitiveContains("OpenCode") else {
            return nil
        }

        var index = value.startIndex
        let numberStart = index
        while index < value.endIndex, value[index].isNumber {
            index = value.index(after: index)
        }
        guard numberStart != index,
              index < value.endIndex,
              value[index] == "." || value[index] == ")" else {
            return nil
        }

        index = value.index(after: index)
        while index < value.endIndex, value[index].isWhitespace {
            index = value.index(after: index)
        }
        guard index < value.endIndex else { return nil }
        return String(value[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func activeOpenCodeAnchorIndex(in lines: [String]) -> Int? {
        let lastMeaningfulIndex = lines.indices.last { !normalized(lines[$0]).isEmpty }
        guard let lastMeaningfulIndex,
              isOpenCodeAnchor(lines[lastMeaningfulIndex]) else {
            return nil
        }
        return lastMeaningfulIndex
    }

    private static func isOpenCodeAnchor(_ line: String) -> Bool {
        normalized(line).range(
            of: #"^opencode\s+\d+\.\d+(?:\.\d+)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isCurrentPromptTail(_ lines: [String]) -> Bool {
        lines.allSatisfy { line in
            normalized(line).isEmpty || isOpenCodeAnchor(line)
        }
    }

    private static func activePromptWindowStart(in lines: [String], before anchorIndex: Int) -> Int {
        guard anchorIndex > lines.startIndex else { return lines.startIndex }
        let precedingRange = lines.startIndex..<anchorIndex
        guard let previousAnchorIndex = precedingRange.reversed().first(where: {
            isOpenCodeAnchor(lines[$0])
        }) else {
            return lines.startIndex
        }
        return lines.index(after: previousAnchorIndex)
    }

    private static func interactionFooterIndex(in lines: [String], completion: String) -> Int? {
        lines.indices.reversed().first { index in
            let current = normalized(lines[index]).lowercased()
            guard containsControlToken(completion, in: current) else { return false }
            let previous = index > lines.startIndex
                ? normalized(lines[index - 1]).lowercased()
                : ""
            let footer = current == completion
                ? previous + " " + current
                : current
            return containsControlToken("select", in: footer)
                && containsControlToken("enter", in: footer)
                && containsOpenCodeControlHint(footer)
        }
    }

    private static func containsControlToken(_ token: String, in value: String) -> Bool {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains(token.lowercased())
    }

    private static func containsOpenCodeControlHint(_ footer: String) -> Bool {
        ["⇆", "↑", "↓", "ctrl+", "⌃", "↵", "⏎"].contains(where: footer.contains)
    }

    private static func normalized(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let borderCharacters: Set<Character> = ["│", "┃", "|", "△", "←", "›", "❯", "•"]
        while let first = value.first, borderCharacters.contains(first) || first.isWhitespace {
            value.removeFirst()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
