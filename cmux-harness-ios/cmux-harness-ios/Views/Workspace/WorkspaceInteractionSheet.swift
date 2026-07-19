import SwiftUI

struct WorkspaceInteractionSheet: View {
    let presentation: WorkspaceInteractionPresentation
    let isSubmitting: Bool
    let errorMessage: String?
    let reply: (_ requestID: String, _ kind: String, _ action: String?, _ mode: String?, _ selections: [String]?) -> Void
    let sendKey: (HarnessKey) -> Void
    let sendKeys: ([HarnessKey]) -> Void
    let integrationStatus: OpenCodeIntegrationResponse?
    let isInstallingIntegration: Bool
    let installIntegration: () -> Void
    let clearError: () -> Void

    @State private var selectedDetent: PresentationDetent
    @State private var contentStep = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        presentation: WorkspaceInteractionPresentation,
        isSubmitting: Bool,
        errorMessage: String?,
        reply: @escaping (_ requestID: String, _ kind: String, _ action: String?, _ mode: String?, _ selections: [String]?) -> Void,
        sendKey: @escaping (HarnessKey) -> Void,
        sendKeys: @escaping ([HarnessKey]) -> Void,
        integrationStatus: OpenCodeIntegrationResponse?,
        isInstallingIntegration: Bool,
        installIntegration: @escaping () -> Void,
        clearError: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.reply = reply
        self.sendKey = sendKey
        self.sendKeys = sendKeys
        self.integrationStatus = integrationStatus
        self.isInstallingIntegration = isInstallingIntegration
        self.installIntegration = installIntegration
        self.clearError = clearError
        _selectedDetent = State(
            initialValue: presentation.prefersLargeDetent ? .large : .medium
        )
    }

    var body: some View {
        ZStack {
            SessionDetailBackground()

            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear
                        .frame(height: 0)
                        .id("interaction-sheet-top")

                    VStack(spacing: 10) {
                        if let errorMessage, !errorMessage.isEmpty {
                            ErrorBanner(message: errorMessage, action: clearError)
                                .padding(12)
                                .foregroundStyle(.white)
                                .background(
                                    Color.red.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .accessibilityIdentifier("interaction-error")
                        }

                        interactionCard
                    }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 700)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.visible)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: presentation.id) {
                    proxy.scrollTo("interaction-sheet-top", anchor: .top)
                    selectInitialDetent()
                }
                .onChange(of: contentStep) {
                    proxy.scrollTo("interaction-sheet-top", anchor: .top)
                }
                .onChange(of: errorMessage) { _, message in
                    guard message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                        return
                    }
                    proxy.scrollTo("interaction-sheet-top", anchor: .top)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .onAppear(perform: selectInitialDetent)
        .accessibilityIdentifier("workspace-interaction-sheet")
    }

    @ViewBuilder
    private var interactionCard: some View {
        switch presentation {
        case .feed(let item):
            FeedInteractionCard(
                item: item,
                isSubmitting: isSubmitting,
                reply: { action, mode, selections in
                    reply(item.requestID, item.kind, action, mode, selections)
                },
                sendKey: sendKey,
                onContentStepChanged: {
                    contentStep += 1
                }
            )
            .id(item.requestID)
        case .terminal(let interaction):
            OpenCodeTerminalFallbackCard(
                interaction: interaction,
                fallbackNote: nil,
                integrationStatus: integrationStatus,
                isInstallingIntegration: isInstallingIntegration,
                sendKey: sendKey,
                sendKeys: sendKeys,
                installIntegration: installIntegration
            )
            .id(interaction.promptID)
        }
    }

    private func selectInitialDetent() {
        selectedDetent = dynamicTypeSize.isAccessibilitySize || presentation.prefersLargeDetent
            ? .large
            : .medium
    }
}
