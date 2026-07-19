import SwiftUI

struct OpenCodeTerminalFallbackCard: View {
    let interaction: OpenCodeTerminalInteraction
    let fallbackNote: String?
    let integrationStatus: OpenCodeIntegrationResponse?
    let isInstallingIntegration: Bool
    let sendKey: (HarnessKey) -> Void
    let sendKeys: ([HarnessKey]) -> Void
    let installIntegration: () -> Void

    @State private var selectedOptionIndex = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OpenCodeInteractionHeader(
                title: interaction.title,
                subtitle: interaction.kind == .permission
                    ? "OpenCode terminal · Manual controls"
                    : "OpenCode terminal · Remote questions",
                systemImage: headerSystemImage
            )

            interactionContent
        }
        .openCodeInteractionCardChrome()
        .onChange(of: interaction.promptID) {
            selectedOptionIndex = 0
        }
        .accessibilitySortPriority(1)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var interactionContent: some View {
        switch interaction.kind {
        case .permission:
            permissionContent
        case .question:
            questionContent
        case .questionReview:
            reviewContent
        }
    }

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            interactionDetail

            if !interaction.options.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Label("Choices", systemImage: "list.bullet")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(interaction.options.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Available choices: \(interaction.options.joined(separator: ", "))")
            }

            Text("Choose with Previous or Next, then confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            fallbackMessage
            integrationSetup
            manualActions(rejectLabel: "Reject")
        }
    }

    @ViewBuilder
    private var questionContent: some View {
        if fallbackNote != nil {
            VStack(alignment: .leading, spacing: 9) {
                interactionDetail
                Label(interaction.options.joined(separator: " · "), systemImage: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                fallbackMessage
                manualActions(rejectLabel: "Dismiss")
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                interactionDetail

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(interaction.options.enumerated()), id: \.offset) { index, option in
                            OpenCodeChoiceRow(
                                label: option,
                                detail: nil,
                                isSelected: selectedOptionIndex == index
                            ) {
                                HarnessHaptics.inputCTA()
                                selectedOptionIndex = index
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: choiceListMaxHeight)

                Text("Tap a choice, then tap Next. Your selection stays visible here while cmux advances OpenCode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                adaptiveActionLayout {
                    OpenCodeActionButton(
                        title: "Next",
                        systemImage: "chevron.right",
                        role: .primary,
                        fillsWidth: false,
                        action: submitSelectedOption
                    )
                    .disabled(!interaction.options.indices.contains(selectedOptionIndex))
                    .accessibilityHint("Selects this choice in OpenCode and advances to the next question")

                    OpenCodeActionButton(
                        title: "Dismiss",
                        systemImage: "xmark",
                        role: .destructive,
                        fillsWidth: false
                    ) {
                        sendKeyWithHaptic(.escape)
                    }
                }
            }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            interactionDetail

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(interaction.reviewItems) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Label(item.value, systemImage: "checkmark.circle.fill")
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
                    title: "Edit answers",
                    systemImage: "chevron.left",
                    role: .neutral,
                    fillsWidth: false
                ) {
                    sendKeyWithHaptic(.tab)
                }
                .accessibilityHint("Returns to the OpenCode question tabs")

                OpenCodeActionButton(
                    title: "Submit",
                    systemImage: "paperplane.fill",
                    role: .primary,
                    fillsWidth: false
                ) {
                    sendKeyWithHaptic(.enter)
                }
                .accessibilityHint("Submits all reviewed answers to OpenCode")

                OpenCodeActionButton(
                    title: "Dismiss",
                    systemImage: "xmark",
                    role: .destructive,
                    fillsWidth: false
                ) {
                    sendKeyWithHaptic(.escape)
                }
            }
        }
    }

    @ViewBuilder
    private var interactionDetail: some View {
        if !interaction.detail.isEmpty {
            Text(interaction.detail)
                .font(interaction.kind == .question ? .subheadline.bold() : .subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(interaction.kind == .question ? .isHeader : [])
        }
    }

    @ViewBuilder
    private var fallbackMessage: some View {
        if let fallbackNote, !fallbackNote.isEmpty {
            Label(fallbackNote, systemImage: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var integrationSetup: some View {
        if integrationStatus?.installed == true {
            Label(
                integrationStatus?.needsRestart == true
                    ? "Native controls enabled. Restart OpenCode to activate them."
                    : "Native controls installed. Restart OpenCode if this prompt stays visible.",
                systemImage: "checkmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if integrationStatus?.cmuxAvailable == true {
            OpenCodeActionButton(
                title: isInstallingIntegration ? "Enabling native controls…" : "Enable native controls",
                systemImage: isInstallingIntegration ? "hourglass" : "sparkles",
                role: .attention,
                fillsWidth: false,
                action: installIntegration
            )
            .disabled(isInstallingIntegration)
            .accessibilityHint("Installs the cmux OpenCode event bridge on your Mac. Restart active OpenCode sessions afterward.")
        } else if let summary = integrationStatus?.summary, !summary.isEmpty {
            Label(summary, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func manualActions(rejectLabel: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    keyButton("Previous", key: previousKey, role: .neutral, fillsWidth: false, showsTitle: false)
                    keyButton("Next", key: nextKey, role: .neutral, fillsWidth: false, showsTitle: false)
                    Spacer(minLength: 0)
                }
                keyButton("Confirm", key: .enter, role: .primary)
                keyButton(rejectLabel, key: .escape, role: .destructive)
            }
        } else {
            HStack(spacing: 6) {
                keyButton("Previous", key: previousKey, role: .neutral, fillsWidth: false, showsTitle: false)
                keyButton("Next", key: nextKey, role: .neutral, fillsWidth: false, showsTitle: false)
                Spacer(minLength: 0)
                keyButton("Confirm", key: .enter, role: .primary, fillsWidth: false)
                keyButton(rejectLabel, key: .escape, role: .destructive, fillsWidth: false)
            }
        }
    }

    private var headerSystemImage: String {
        switch interaction.kind {
        case .permission:
            "hand.raised.fill"
        case .question:
            "questionmark.bubble.fill"
        case .questionReview:
            "checkmark.circle.fill"
        }
    }

    private var previousKey: HarnessKey {
        interaction.navigationAxis == .horizontal ? .left : .up
    }

    private var nextKey: HarnessKey {
        interaction.navigationAxis == .horizontal ? .right : .down
    }

    private var adaptiveActionLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        } else {
            AnyLayout(HStackLayout(spacing: 7))
        }
    }

    private var choiceListMaxHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 280 : 210
    }

    private var reviewListMaxHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 300 : 230
    }

    private func submitSelectedOption() {
        guard interaction.options.indices.contains(selectedOptionIndex) else { return }
        HarnessHaptics.inputCTA()

        // Each OpenCode question opens on its first row. Moving down and back up
        // makes that starting point explicit, then the remaining downs choose the
        // locally checked row before Enter advances to the next question.
        let selectionKeys = [HarnessKey.down, .up]
            + Array(repeating: HarnessKey.down, count: selectedOptionIndex)
        sendKeys(selectionKeys + [.enter])
    }

    private func sendKeyWithHaptic(_ key: HarnessKey) {
        HarnessHaptics.inputCTA()
        sendKey(key)
    }

    private func keyButton(
        _ label: String,
        key: HarnessKey,
        role: OpenCodeActionButton.Role,
        fillsWidth: Bool = true,
        showsTitle: Bool = true
    ) -> some View {
        OpenCodeActionButton(
            title: label,
            systemImage: key.systemImage,
            role: role,
            fillsWidth: fillsWidth,
            showsTitle: showsTitle
        ) {
            sendKeyWithHaptic(key)
        }
        .accessibilityHint("Sends the \(key.label) key to OpenCode")
    }
}
