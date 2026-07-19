import SwiftUI

struct FeedInteractionCard: View {
    let item: FeedItem
    let isSubmitting: Bool
    let reply: (_ action: String?, _ mode: String?, _ selections: [String]?) -> Void
    let sendKey: (HarnessKey) -> Void

    @State private var questionIndex = 0
    @State private var answers: [String: String] = [:]
    @State private var isReviewingAnswers = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            OpenCodeInteractionHeader(
                title: cardTitle,
                subtitle: sourceLabel,
                systemImage: headerSymbol,
                isBusy: isSubmitting
            )

            switch item.kind {
            case "permission":
                permissionContent
            case "question":
                questionContent
            case "plan":
                planContent
            default:
                genericContent
            }
        }
        .openCodeInteractionCardChrome()
        .disabled(isSubmitting)
        .opacity(isSubmitting ? 0.74 : 1)
        .onChange(of: item.requestID) {
            questionIndex = 0
            answers = [:]
            isReviewingAnswers = false
        }
        .accessibilitySortPriority(1)
        .accessibilityElement(children: .contain)
    }

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            detailText

            if let patterns = item.patterns, !patterns.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label(permissionScopeLabel, systemImage: permissionScopeSymbol)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(patterns, id: \.self) { pattern in
                        Text(pattern)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
            } else if let permissionType = trimmed(item.permissionType) {
                Label(humanized(permissionType), systemImage: "lock.shield")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
            }

            adaptiveActionLayout {
                OpenCodeActionButton(
                    title: "Allow once",
                    systemImage: "checkmark",
                    role: .primary,
                    fillsWidth: false
                ) {
                    reply("approve", "once", nil)
                }
                .accessibilityHint("Allows only this OpenCode request")

                OpenCodeActionButton(
                    title: "Always",
                    systemImage: "checkmark.shield",
                    role: .secondary,
                    fillsWidth: false
                ) {
                    reply("approve", "always", nil)
                }
                .accessibilityLabel("Always allow")
                .accessibilityHint("Allows this and future matching OpenCode requests")

                OpenCodeActionButton(
                    title: "Reject",
                    systemImage: "xmark",
                    role: .destructive,
                    fillsWidth: false
                ) {
                    reply("deny", "deny", nil)
                }
                .accessibilityHint("Rejects this OpenCode permission request")
            }
        }
    }

    private var cardTitle: String {
        switch item.kind {
        case "permission":
            return "Permission required"
        case "question":
            return isReviewingAnswers ? "Review answers" : "OpenCode question"
        default:
            return item.displayTitle
        }
    }

    private func humanized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private var permissionScopeLabel: String {
        if let permissionType = trimmed(item.permissionType) {
            return humanized(permissionType)
        }
        return "Requested scope"
    }

    private var permissionScopeSymbol: String {
        switch item.permissionType?.lowercased() {
        case "bash": "terminal"
        case "edit": "doc.badge.ellipsis"
        case "external_directory": "folder.badge.questionmark"
        default: "key.horizontal"
        }
    }

    @ViewBuilder
    private var questionContent: some View {
        if isReviewingAnswers {
            questionReviewContent
        } else if let currentQuestion {
            VStack(alignment: .leading, spacing: 9) {
                if questions.count > 1 {
                    Text("Question \(questionIndex + 1) of \(questions.count)")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }

                if let header = trimmed(currentQuestion.header) {
                    Text(header)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                Text(currentQuestion.question)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                questionAnswerForm(currentQuestion)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                detailText
                TextField("Type your answer", text: answerBinding(for: item.requestID), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(minHeight: 44)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .accessibilityLabel("Answer to OpenCode")

                HStack {
                    Spacer(minLength: 0)
                    OpenCodeActionButton(
                        title: "Send answer",
                        systemImage: "paperplane.fill",
                        role: .primary,
                        fillsWidth: false
                    ) {
                        let answer = answers[item.requestID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        reply("answer", nil, answer.isEmpty ? nil : [answer])
                    }
                    .disabled((answers[item.requestID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func questionAnswerForm(_ question: FeedItem.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(question.options) { option in
                        OpenCodeChoiceRow(
                            label: option.label,
                            detail: trimmed(option.description),
                            isSelected: answers[question.id] == option.label
                        ) {
                            answers[question.id] = option.label
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: choiceListMaxHeight)

            TextField(
                "Or type a custom answer",
                text: customAnswerBinding(for: question),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .font(.subheadline)
                .lineLimit(1...3)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(minHeight: 44)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
                .accessibilityLabel("Custom answer")

            adaptiveActionLayout {
                if questionIndex > 0 {
                    OpenCodeActionButton(
                        title: "Back",
                        systemImage: "chevron.left",
                        role: .neutral,
                        fillsWidth: false
                    ) {
                        questionIndex -= 1
                    }
                }

                if questionIndex < questions.count - 1 {
                    OpenCodeActionButton(
                        title: "Next",
                        systemImage: "chevron.right",
                        role: .primary,
                        fillsWidth: false
                    ) {
                        questionIndex += 1
                    }
                    .disabled(!hasAnswer(for: question.id))
                } else {
                    OpenCodeActionButton(
                        title: "Review answers",
                        systemImage: "list.clipboard",
                        role: .primary,
                        fillsWidth: false
                    ) {
                        isReviewingAnswers = true
                    }
                    .disabled(!questions.allSatisfy { hasAnswer(for: $0.id) })
                }
            }
        }
    }

    private var questionReviewContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Confirm these choices before OpenCode continues.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(trimmed(question.header) ?? question.question)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            if trimmed(question.header) != nil {
                                Text(question.question)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Label(answers[question.id] ?? "", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: reviewListMaxHeight)

            adaptiveActionLayout {
                OpenCodeActionButton(
                    title: "Back",
                    systemImage: "chevron.left",
                    role: .neutral,
                    fillsWidth: false
                ) {
                    isReviewingAnswers = false
                    questionIndex = max(questions.count - 1, 0)
                }

                OpenCodeActionButton(
                    title: "Submit",
                    systemImage: "paperplane.fill",
                    role: .primary,
                    fillsWidth: false
                ) {
                    reply("answer", nil, questions.compactMap { question in
                        trimmed(answers[question.id])
                    })
                }
            }
        }
    }

    private var planContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            detailText
            adaptiveActionLayout {
                OpenCodeActionButton(title: "Approve plan", systemImage: "checkmark", role: .primary) {
                    reply("approve", "autoAccept", nil)
                }
                OpenCodeActionButton(title: "Keep manual", systemImage: "hand.raised", role: .secondary) {
                    reply("manual", "manual", nil)
                }
                OpenCodeActionButton(title: "Reject", systemImage: "xmark", role: .destructive) {
                    reply("deny", "deny", nil)
                }
            }
        }
    }

    private var genericContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            detailText
            terminalNavigation(axis: .vertical, rejectLabel: "Dismiss")
        }
    }

    @ViewBuilder
    private var detailText: some View {
        let summary = item.summary
        if !summary.isEmpty, summary != item.displayTitle {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let command = trimmed(item.command), command != summary {
            Text(command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func terminalNavigation(
        axis: OpenCodeTerminalInteraction.NavigationAxis,
        rejectLabel: String
    ) -> some View {
        adaptiveActionLayout {
            OpenCodeActionButton(title: "Previous", systemImage: axis == .horizontal ? "arrow.left" : "arrow.up", role: .neutral) {
                sendKey(axis == .horizontal ? .left : .up)
            }
            OpenCodeActionButton(title: "Next", systemImage: axis == .horizontal ? "arrow.right" : "arrow.down", role: .neutral) {
                sendKey(axis == .horizontal ? .right : .down)
            }
            OpenCodeActionButton(title: "Confirm", systemImage: "return", role: .primary) {
                sendKey(.enter)
            }
            OpenCodeActionButton(title: rejectLabel, systemImage: "xmark", role: .destructive) {
                sendKey(.escape)
            }
        }
    }

    private var questions: [FeedItem.Question] {
        if let questions = item.questions, !questions.isEmpty {
            return questions
        }
        guard let options = item.options, !options.isEmpty else { return [] }
        return [
            FeedItem.Question(
                id: item.requestID,
                header: nil,
                question: item.summary,
                multiSelect: false,
                options: options.enumerated().map { index, label in
                    FeedItem.Option(id: "option-\(index)", label: label, description: nil)
                }
            )
        ]
    }

    private var currentQuestion: FeedItem.Question? {
        guard questions.indices.contains(questionIndex) else { return nil }
        return questions[questionIndex]
    }

    private var headerSymbol: String {
        switch item.kind {
        case "permission": "hand.raised.fill"
        case "question": isReviewingAnswers ? "checkmark.circle.fill" : "questionmark.bubble.fill"
        case "plan": "doc.text.fill"
        default: "exclamationmark.bubble.fill"
        }
    }

    private var sourceLabel: String {
        let rawAgent = trimmed(item.agent) ?? "OpenCode"
        let agent = rawAgent.lowercased() == "opencode" ? "OpenCode" : rawAgent
        return isReviewingAnswers
            ? "\(agent) · Ready to submit"
            : "\(agent) · Awaiting response"
    }

    private func answerBinding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id] ?? "" },
            set: { answers[id] = $0 }
        )
    }

    private func customAnswerBinding(for question: FeedItem.Question) -> Binding<String> {
        Binding(
            get: {
                let answer = answers[question.id] ?? ""
                return question.options.contains(where: { $0.label == answer }) ? "" : answer
            },
            set: { answers[question.id] = $0 }
        )
    }

    private func hasAnswer(for id: String) -> Bool {
        trimmed(answers[id]) != nil
    }

    private func trimmed(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var adaptiveActionLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        } else {
            AnyLayout(HStackLayout(spacing: 7))
        }
    }

    private var choiceListMaxHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 260 : 190
    }

    private var reviewListMaxHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 280 : 220
    }
}
