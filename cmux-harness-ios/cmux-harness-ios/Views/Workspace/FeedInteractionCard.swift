import SwiftUI

struct FeedInteractionCard: View {
    let item: FeedItem
    let isSubmitting: Bool
    let reply: (_ action: String?, _ mode: String?, _ selections: [String]?) -> Void
    let sendKey: (HarnessKey) -> Void

    @State private var questionIndex = 0
    @State private var answers: [String: String] = [:]
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
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
            return "OpenCode question"
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
        if let currentQuestion {
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
            ForEach(question.options) { option in
                Button {
                    answers[question.id] = option.label
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: answers[question.id] == option.label ? "checkmark.circle.fill" : "circle")
                            .font(.callout)
                            .foregroundStyle(answers[question.id] == option.label ? Color.blue : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            if let description = trimmed(option.description) {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        answers[question.id] == option.label ? Color.blue.opacity(0.12) : Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(
                                answers[question.id] == option.label
                                    ? Color.blue.opacity(differentiateWithoutColor ? 0.95 : 0.5)
                                    : Color.white.opacity(differentiateWithoutColor ? 0.28 : 0.08),
                                lineWidth: differentiateWithoutColor ? 1.5 : 1
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityValue(answers[question.id] == option.label ? "Selected" : "Not selected")
                .accessibilityHint(trimmed(option.description) ?? "Selects this answer")
                .accessibilityAddTraits(answers[question.id] == option.label ? .isSelected : [])
            }

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

            HStack(spacing: 6) {
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

                Spacer(minLength: 0)

                if questionIndex < questions.count - 1 {
                    OpenCodeActionButton(
                        title: "Next question",
                        systemImage: "chevron.right",
                        role: .primary,
                        fillsWidth: false
                    ) {
                        questionIndex += 1
                    }
                    .disabled(!hasAnswer(for: question.id))
                } else {
                    OpenCodeActionButton(
                        title: "Send answer",
                        systemImage: "paperplane.fill",
                        role: .primary,
                        fillsWidth: false
                    ) {
                        reply("answer", nil, questions.compactMap { question in
                            trimmed(answers[question.id])
                        })
                    }
                    .disabled(!questions.allSatisfy { hasAnswer(for: $0.id) })
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
        case "question": "questionmark.bubble.fill"
        case "plan": "doc.text.fill"
        default: "exclamationmark.bubble.fill"
        }
    }

    private var sourceLabel: String {
        let rawAgent = trimmed(item.agent) ?? "OpenCode"
        let agent = rawAgent.lowercased() == "opencode" ? "OpenCode" : rawAgent
        return "\(agent) · Awaiting response"
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
}
