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
        if let review = questionReviewInteraction(in: visibleLines) {
            return review
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
        guard let footerIndex = interactionFooterIndex(
            in: block,
            requiredTokens: ["select", "enter", "confirm"]
        ),
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
            .map { primaryColumn(in: $0) }
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

    private static func questionReviewInteraction(in lines: [String]) -> OpenCodeTerminalInteraction? {
        guard let anchorIndex = activeOpenCodeAnchorIndex(in: lines) else { return nil }
        let windowStart = max(
            activePromptWindowStart(in: lines, before: anchorIndex),
            anchorIndex - 32
        )
        let activeLines = Array(lines[windowStart...anchorIndex])
        let flattened = activeLines.map { normalized($0) }.joined(separator: " ").lowercased()
        guard flattened.contains("review"),
              flattened.contains("submit"),
              flattened.contains("dismiss") else {
            return nil
        }
        guard let footerIndex = interactionFooterIndex(
            in: activeLines,
            requiredTokens: ["tab", "enter", "submit", "dismiss"]
        ),
              isCurrentPromptTail(Array(activeLines[(footerIndex + 1)...])) else {
            return nil
        }

        let contentLines = Array(activeLines[..<footerIndex])
        guard let reviewIndex = contentLines.lastIndex(where: {
            primaryColumn(in: $0).localizedCaseInsensitiveCompare("Review") == .orderedSame
        }) else {
            return nil
        }
        let reviewItems = contentLines[(reviewIndex + 1)...]
            .compactMap { line in reviewItem(from: line) }
        guard !reviewItems.isEmpty else { return nil }

        return OpenCodeTerminalInteraction(
            kind: .questionReview,
            title: "Review answers",
            detail: "Confirm these choices before OpenCode continues.",
            options: [],
            navigationAxis: .horizontal,
            reviewItems: reviewItems
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
        guard let footerIndex = interactionFooterIndex(
            in: activeLines,
            requiredTokens: ["select", "enter", "dismiss"]
        ),
              isCurrentPromptTail(Array(activeLines[(footerIndex + 1)...])) else {
            return nil
        }

        let optionLines = Array(activeLines[..<footerIndex])
        let options = optionLines.compactMap { numberedOption(from: $0) }
        guard options.count >= 2 else { return nil }

        let firstOptionIndex = optionLines.firstIndex(where: { numberedOption(from: $0) != nil }) ?? optionLines.startIndex
        let question = optionLines[..<firstOptionIndex]
            .reversed()
            .map { primaryColumn(in: $0) }
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
        let value = primaryColumn(in: line)
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

    private static func reviewItem(from line: String) -> OpenCodeTerminalInteraction.ReviewItem? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmedLine.first,
              ["│", "┃", "|"].contains(first) else {
            return nil
        }

        let value = primaryColumn(in: line)
        guard let separator = value.firstIndex(of: ":") else { return nil }
        let label = value[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let answerStart = value.index(after: separator)
        let answer = value[answerStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !answer.isEmpty else { return nil }
        return OpenCodeTerminalInteraction.ReviewItem(label: label, value: answer)
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

    private static func interactionFooterIndex(
        in lines: [String],
        requiredTokens: [String]
    ) -> Int? {
        lines.indices.reversed().first { index in
            let current = normalized(lines[index]).lowercased()
            guard requiredTokens.contains(where: { containsControlToken($0, in: current) }) else {
                return false
            }
            let previous = index > lines.startIndex
                ? normalized(lines[index - 1]).lowercased()
                : ""
            let footer = requiredTokens.contains(current)
                ? previous + " " + current
                : current
            return requiredTokens.allSatisfy { containsControlToken($0, in: footer) }
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

    private static func primaryColumn(in line: String) -> String {
        let value = normalized(line)
        guard let separator = value.range(of: #"\s{3,}"#, options: .regularExpression) else {
            return value
        }
        return String(value[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
