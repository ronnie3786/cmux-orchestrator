import SwiftUI

struct FeedInteractionCard: View {
    let item: FeedItem
    let isSubmitting: Bool
    let reply: (_ action: String?, _ mode: String?, _ selections: [String]?) -> Void
    let sendKey: (HarnessKey) -> Void
    let onContentStepChanged: () -> Void

    @State private var questionIndex = 0
    @State private var selectedOptionIDs: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]
    @State private var selectedPermissionOptionID = ""
    @State private var selectedPlanMode = ""
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
        .onAppear {
            synchronizePermissionSelection()
            synchronizePlanSelection()
        }
        .onChange(of: item.requestID) {
            questionIndex = 0
            selectedOptionIDs = [:]
            customAnswers = [:]
            selectedPermissionOptionID = ""
            selectedPlanMode = ""
            isReviewingAnswers = false
            synchronizePermissionSelection()
            synchronizePlanSelection()
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

            LazyVStack(spacing: 6) {
                ForEach(permissionOptions) { option in
                    OpenCodeChoiceRow(
                        label: option.label,
                        detail: trimmed(option.description),
                        isSelected: selectedPermissionOptionID == option.id
                    ) {
                        selectedPermissionOptionID = option.id
                    }
                }
            }

            Text("Choose a permission response, then confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            adaptiveActionLayout {
                OpenCodeActionButton(
                    title: "Confirm",
                    systemImage: "return",
                    role: .primary,
                    fillsWidth: false
                ) {
                    submitPermissionSelection()
                }
                .disabled(!permissionOptions.contains(where: { $0.id == selectedPermissionOptionID }))
                .accessibilityHint("Sends the selected OpenCode permission response")
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
                TextField("Type your answer", text: customAnswerBinding(for: item.requestID), axis: .vertical)
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
                        let answer = customAnswers[item.requestID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        reply("answer", nil, answer.isEmpty ? nil : [answer])
                    }
                    .disabled((customAnswers[item.requestID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func questionAnswerForm(_ question: FeedItem.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if question.multiSelect {
                Label("Select all that apply", systemImage: "checklist")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            LazyVStack(spacing: 6) {
                ForEach(question.options) { option in
                    OpenCodeChoiceRow(
                        label: option.label,
                        detail: trimmed(option.description),
                        isSelected: isOptionSelected(option, for: question),
                        allowsMultipleSelection: question.multiSelect
                    ) {
                        select(option, for: question)
                    }
                }
            }

            if question.customAnswerAllowed {
                TextField(
                    question.options.isEmpty ? "Type your answer" : "Or type a custom answer",
                    text: customAnswerBinding(for: question.id),
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
            } else if question.options.isEmpty {
                Label("No response choices were provided.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            adaptiveActionLayout {
                if questionIndex > 0 {
                    OpenCodeActionButton(
                        title: "Back",
                        systemImage: "chevron.left",
                        role: .neutral,
                        fillsWidth: false
                    ) {
                        questionIndex -= 1
                        onContentStepChanged()
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
                        onContentStepChanged()
                    }
                    .disabled(!hasAnswer(for: question))
                } else {
                    OpenCodeActionButton(
                        title: "Review answers",
                        systemImage: "list.clipboard",
                        role: .primary,
                        fillsWidth: false
                    ) {
                        isReviewingAnswers = true
                        onContentStepChanged()
                    }
                    .disabled(!questions.allSatisfy { hasAnswer(for: $0) })
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
                        Label(answerText(for: question) ?? "No response", systemImage: "checkmark.circle.fill")
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

            adaptiveActionLayout {
                OpenCodeActionButton(
                    title: "Back",
                    systemImage: "chevron.left",
                    role: .neutral,
                    fillsWidth: false
                ) {
                    isReviewingAnswers = false
                    questionIndex = max(questions.count - 1, 0)
                    onContentStepChanged()
                }

                OpenCodeActionButton(
                    title: "Submit",
                    systemImage: "paperplane.fill",
                    role: .primary,
                    fillsWidth: false
                ) {
                    reply("answer", nil, questions.map { answerText(for: $0) ?? "" })
                }
            }
        }
    }

    private var planContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            detailText

            if let plan = trimmed(item.plan),
               plan != trimmed(item.planSummary),
               plan != item.summary {
                Text(plan)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
            }

            LazyVStack(spacing: 6) {
                ForEach(planOptions) { option in
                    OpenCodeChoiceRow(
                        label: option.label,
                        detail: trimmed(option.description),
                        isSelected: selectedPlanMode == option.id
                    ) {
                        selectedPlanMode = option.id
                    }
                }
            }

            Text("Choose how OpenCode should continue, then confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            adaptiveActionLayout {
                OpenCodeActionButton(
                    title: "Confirm",
                    systemImage: "return",
                    role: .primary,
                    fillsWidth: false
                ) {
                    submitPlanSelection()
                }
                .disabled(!planOptions.contains(where: { $0.id == selectedPlanMode }))
                .accessibilityHint("Sends the selected OpenCode plan response")
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

    private var permissionOptions: [FeedItem.Option] {
        let normalizedModes = (item.permissionModes ?? []).map { permissionMode in
            FeedItem.Option(
                id: permissionMode.mode,
                label: permissionMode.label,
                description: permissionDescription(for: permissionMode.mode)
            )
        }
        if !normalizedModes.isEmpty {
            return normalizedModes
        }
        let supplied = (item.options ?? []).enumerated().compactMap { index, label in
            permissionOption(label: label, index: index)
        }
        if !supplied.isEmpty {
            return supplied
        }
        return [
            FeedItem.Option(
                id: "once",
                label: "Allow once",
                description: "Approve only this request."
            ),
            FeedItem.Option(
                id: "always",
                label: "Allow always",
                description: "Approve future matching requests."
            ),
            FeedItem.Option(
                id: "deny",
                label: "Reject",
                description: "Deny this request."
            ),
        ]
    }

    private func permissionOption(label: String, index: Int) -> FeedItem.Option? {
        let value = label.lowercased()
        let mode: String
        let description: String
        if value.contains("bypass") {
            mode = "bypass"
            description = "Allow and request bypass mode for this session."
        } else if value.contains("all tool") || value == "all" {
            mode = "all"
            description = "Allow all supported tools for this session."
        } else if value.contains("always") {
            mode = "always"
            description = "Approve future matching requests."
        } else if value.contains("once") || value == "allow" || value == "approve" {
            mode = "once"
            description = "Approve only this request."
        } else if value.contains("deny") || value.contains("reject") {
            mode = "deny"
            description = "Deny this request."
        } else {
            return nil
        }
        return FeedItem.Option(
            id: mode,
            label: label.isEmpty ? "Option \(index + 1)" : label,
            description: description
        )
    }

    private func permissionDescription(for mode: String) -> String? {
        switch mode {
        case "once":
            "Approve only this request."
        case "always":
            "Approve future matching requests when supported."
        case "all":
            "Apply the agent's broader all-tools approval rule."
        case "bypass":
            "Request permission bypass for this session."
        case "deny":
            "Deny this request."
        default:
            nil
        }
    }

    private func submitPermissionSelection() {
        let mode = selectedPermissionOptionID
        guard permissionOptions.contains(where: { $0.id == mode }) else { return }
        reply(mode == "deny" ? "deny" : "approve", mode, nil)
    }

    private func synchronizePermissionSelection() {
        let options = permissionOptions
        guard !options.contains(where: { $0.id == selectedPermissionOptionID }) else { return }
        let requestedMode = trimmed(item.defaultMode)?.lowercased()
        selectedPermissionOptionID = options.first(where: {
            $0.id.lowercased() == requestedMode
        })?.id ?? options.first?.id ?? ""
    }

    private var planOptions: [FeedItem.Option] {
        let supplied = (item.options ?? []).enumerated().compactMap { index, label in
            planOption(label: label, index: index)
        }
        if !supplied.isEmpty {
            return supplied
        }
        return [
            FeedItem.Option(
                id: "ultraplan",
                label: "Ultraplan",
                description: "Continue with extended planning before implementation."
            ),
            FeedItem.Option(
                id: "bypassPermissions",
                label: "Bypass permissions",
                description: "Approve the plan and bypass supported permission prompts."
            ),
            FeedItem.Option(
                id: "autoAccept",
                label: "Auto accept edits",
                description: "Approve the plan and automatically accept edits."
            ),
            FeedItem.Option(
                id: "manual",
                label: "Keep manual",
                description: "Approve the plan while keeping manual controls."
            ),
            FeedItem.Option(
                id: "deny",
                label: "Reject",
                description: "Reject the proposed plan."
            ),
        ]
    }

    private func planOption(label: String, index: Int) -> FeedItem.Option? {
        let value = label.lowercased()
        let mode: String
        let description: String
        if value.contains("ultraplan") {
            mode = "ultraplan"
            description = "Continue with extended planning before implementation."
        } else if value.contains("bypass") {
            mode = "bypassPermissions"
            description = "Approve the plan and bypass supported permission prompts."
        } else if value.contains("manual") || value.contains("keep planning") {
            mode = "manual"
            description = "Approve the plan while keeping manual controls."
        } else if value.contains("deny") || value.contains("reject") {
            mode = "deny"
            description = "Reject the proposed plan."
        } else if value.contains("auto")
            || value.contains("accept")
            || value.contains("approve")
            || value.contains("build") {
            mode = "autoAccept"
            description = "Approve the plan and automatically accept edits."
        } else {
            return nil
        }
        return FeedItem.Option(
            id: mode,
            label: label.isEmpty ? "Option \(index + 1)" : label,
            description: description
        )
    }

    private func synchronizePlanSelection() {
        let options = planOptions
        guard !options.contains(where: { $0.id == selectedPlanMode }) else { return }
        let requestedMode = trimmed(item.defaultMode)
        selectedPlanMode = options.first(where: {
            $0.id.caseInsensitiveCompare(requestedMode ?? "") == .orderedSame
        })?.id
            ?? options.first(where: { $0.id == "manual" })?.id
            ?? options.first?.id
            ?? ""
    }

    private func submitPlanSelection() {
        let mode = selectedPlanMode
        guard planOptions.contains(where: { $0.id == mode }) else { return }
        let action = mode == "deny" ? "deny" : mode == "manual" ? "manual" : "approve"
        reply(action, mode, nil)
    }

    private func customAnswerBinding(for id: String) -> Binding<String> {
        Binding(
            get: { customAnswers[id] ?? "" },
            set: { value in
                customAnswers[id] = value
                if trimmed(value) != nil {
                    selectedOptionIDs[id] = []
                }
            }
        )
    }

    private func isOptionSelected(
        _ option: FeedItem.Option,
        for question: FeedItem.Question
    ) -> Bool {
        selectedOptionIDs[question.id]?.contains(option.id) == true
    }

    private func select(_ option: FeedItem.Option, for question: FeedItem.Question) {
        customAnswers[question.id] = ""
        var selected = selectedOptionIDs[question.id] ?? []
        if question.multiSelect {
            if selected.contains(option.id) {
                selected.remove(option.id)
            } else {
                selected.insert(option.id)
            }
        } else {
            selected = [option.id]
        }
        selectedOptionIDs[question.id] = selected
    }

    private func answerText(for question: FeedItem.Question) -> String? {
        if question.customAnswerAllowed,
           let customAnswer = trimmed(customAnswers[question.id]) {
            return customAnswer
        }
        let selected = selectedOptionIDs[question.id] ?? []
        let labels = question.options
            .filter { selected.contains($0.id) }
            .map(\.label)
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    private func hasAnswer(for question: FeedItem.Question) -> Bool {
        if answerText(for: question) != nil {
            return true
        }
        return question.options.isEmpty && !question.customAnswerAllowed
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
