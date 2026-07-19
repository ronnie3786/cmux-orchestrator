import Foundation

enum WorkspaceInteractionPresentation: Equatable, Identifiable {
    case feed(FeedItem)
    case terminal(OpenCodeTerminalInteraction)

    var id: String {
        switch self {
        case .feed(let item):
            return "feed:\(item.requestID)"
        case .terminal(let interaction):
            return "terminal:\(interaction.promptID)"
        }
    }

    var prefersLargeDetent: Bool {
        switch self {
        case .feed(let item):
            return feedItemPrefersLargeDetent(item)
        case .terminal(let interaction):
            return terminalInteractionPrefersLargeDetent(interaction)
        }
    }

    private func feedItemPrefersLargeDetent(_ item: FeedItem) -> Bool {
        switch item.kind {
        case "permission":
            let patternLength = (item.patterns ?? []).reduce(0) { $0 + $1.count }
            return (item.patterns?.count ?? 0) > 1
                || patternLength > 40
                || item.summary.count > 80
                || (item.permissionModes?.count ?? 0) > 3
                || (item.options?.count ?? 0) > 3
        case "question":
            guard let questions = item.questions, !questions.isEmpty else {
                return (item.options?.count ?? 0) >= 3 || item.summary.count > 120
            }
            let hasRichOptions = questions.contains { question in
                question.multiSelect
                    || question.options.count >= 3
                    || question.options.contains { $0.description?.isEmpty == false }
            }
            let characterCount = questions.reduce(0) { count, question in
                count
                    + question.question.count
                    + question.options.reduce(0) { $0 + $1.label.count + ($1.description?.count ?? 0) }
            }
            return questions.count > 1 || hasRichOptions || characterCount > 220
        case "plan":
            return true
        default:
            return item.summary.count > 180
        }
    }

    private func terminalInteractionPrefersLargeDetent(
        _ interaction: OpenCodeTerminalInteraction
    ) -> Bool {
        switch interaction.kind {
        case .permission:
            return interaction.options.count > 3 || interaction.detail.count > 180
        case .question:
            return interaction.options.count >= 3 || interaction.detail.count > 120
        case .questionReview:
            return interaction.reviewItems.count >= 3
        }
    }
}
