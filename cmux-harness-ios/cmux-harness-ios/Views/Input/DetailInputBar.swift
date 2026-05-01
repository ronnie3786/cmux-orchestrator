import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum HarnessHaptics {
    static func inputCTA() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
    }

    static func sendCTA() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
    }
}

enum AttachmentInputSheet: String, Identifiable {
    case photoLibrary
    case voiceRecorder

    var id: String { rawValue }
}

struct DetailInputBar: View {
    private static let inputActionVisualSize: CGFloat = 44
    private static let inputActionHitSlop: CGFloat = 10

    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace
    let isInputFocused: FocusState<Bool>.Binding
    @State private var inputSelection: TextSelection?
    @State private var dismissedSkillAutocompleteSignature: String?
    @State private var isActionMenuExpanded = true
    @State private var isShowingAttachmentOptions = false
    @State private var activeAttachmentSheet: AttachmentInputSheet?
    @State private var isShowingFileImporter = false

    var body: some View {
        VStack(spacing: 10) {
            if let context = skillAutocompleteContext,
               dismissedSkillAutocompleteSignature != context.signature,
               !filteredSkillSuggestions(for: context).isEmpty {
                SkillAutocompletePanel(
                    suggestions: filteredSkillSuggestions(for: context),
                    cancelAction: {
                        dismissedSkillAutocompleteSignature = context.signature
                    },
                    selectAction: { skill in
                        replaceSkillToken(context, with: skill)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !attachments.isEmpty {
                AttachmentTray(
                    attachments: attachments,
                    removeAction: { attachment in
                        store.send(.removeAttachment(workspaceID: workspace.id, attachmentID: attachment.id))
                    },
                    retryAction: { attachment in
                        store.send(.retryAttachment(workspaceID: workspace.id, attachmentID: attachment.id))
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isActionMenuExpanded {
                HStack(spacing: 10) {
                    inputActionButton(
                        systemImage: "paperclip",
                        accessibilityLabel: "Attach file"
                    ) {
                        isShowingAttachmentOptions = true
                    }
                    .confirmationDialog("Attach", isPresented: $isShowingAttachmentOptions) {
                        Button {
                            HarnessHaptics.inputCTA()
                            isShowingAttachmentOptions = false
                            Task {
                                await Task.yield()
                                activeAttachmentSheet = .photoLibrary
                            }
                        } label: {
                            Label("Photo Library", systemImage: "photo")
                        }
                        Button {
                            HarnessHaptics.inputCTA()
                            isShowingAttachmentOptions = false
                            Task {
                                await Task.yield()
                                isShowingFileImporter = true
                            }
                        } label: {
                            Label("Files", systemImage: "folder")
                        }
                        Button("Cancel", role: .cancel) {}
                    }

                    inputActionButton(
                        systemImage: "mic.fill",
                        accessibilityLabel: "Record voice note"
                    ) {
                        activeAttachmentSheet = .voiceRecorder
                    }

                    inputActionButton(
                        accessibilityLabel: "Add file path"
                    ) {
                        Text("@")
                            .font(.headline.monospaced().weight(.bold))
                    } action: {
                        store.send(.fileSearchTapped)
                    }

                    inputActionButton(
                        systemImage: "ticket",
                        accessibilityLabel: "Add Jira ticket"
                    ) {
                        store.send(.jiraTicketsTapped)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 10) {
                inputActionButton(
                    accessibilityLabel: isActionMenuExpanded ? "Hide input actions" : "Show input actions"
                ) {
                    Image(systemName: "chevron.up")
                        .font(.headline.weight(.semibold))
                        .rotationEffect(.degrees(isActionMenuExpanded ? 180 : 0))
                } action: {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        isActionMenuExpanded.toggle()
                    }
                }

                TextField(
                    "Type a message or instruction...",
                    text: $store.detailDraft,
                    selection: $inputSelection,
                    axis: .vertical
                )
                    .font(.subheadline)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    }
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .submitLabel(.return)
                    .focused(isInputFocused)
                    .onChange(of: store.detailDraft) {
                        dismissedSkillAutocompleteSignature = nil
                        loadSkillsIfNeededForAutocomplete()
                    }
                    .onChange(of: inputSelection) {
                        loadSkillsIfNeededForAutocomplete()
                    }

                Button {
                    sendDetailDraftWithHaptic()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? .white : .white.opacity(0.46))
                .background(canSend ? Color.accentColor : Color.white.opacity(0.10), in: Circle())
                .disabled(!canSend)
            }

            HStack(spacing: 10) {
                ForEach(HarnessKey.allCases) { key in
                    Button {
                        HarnessHaptics.inputCTA()
                        store.send(.sendKey(workspaceID: workspace.id, key))
                    } label: {
                        Label(key.label, systemImage: key.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.92))
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .animation(.easeInOut(duration: 0.16), value: skillAutocompleteContext?.signature)
        .animation(.easeInOut(duration: 0.16), value: attachments)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isActionMenuExpanded)
        .onChange(of: isInputFocused.wrappedValue) { _, isFocused in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                isActionMenuExpanded = !isFocused
            }
        }
        .sheet(item: $activeAttachmentSheet) { sheet in
            switch sheet {
            case .photoLibrary:
                PhotoLibraryPicker(maxSelectionCount: 10) { summary in
                    activeAttachmentSheet = nil
                    handlePhotoImport(summary)
                }
                .ignoresSafeArea()

            case .voiceRecorder:
                VoiceNoteRecorderSheet(
                    saveAction: { url in
                        store.send(.attachmentFilesPicked(workspaceID: workspace.id, [url]))
                        activeAttachmentSheet = nil
                    },
                    discardAction: {
                        activeAttachmentSheet = nil
                    }
                )
                .presentationDetents([.height(540)])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                store.send(.attachmentFilesPicked(workspaceID: workspace.id, urls))
            case let .failure(error):
                store.send(.attachmentPickerFailed(error.localizedDescription))
            }
        }
        .task(id: store.detailInputFocusRequest) {
            let request = store.detailInputFocusRequest
            guard request > 0 else { return }
            await focusInputAtEnd()
            guard !Task.isCancelled else { return }
            store.send(.detailInputFocusHandled(request))
        }
    }

    private var attachments: [TerminalAttachment] {
        store.terminalAttachments[workspace.id] ?? []
    }

    private var isUploadingAttachment: Bool {
        attachments.contains { $0.status == .uploading }
    }

    private var canSend: Bool {
        guard !isUploadingAttachment else { return false }
        let hasMessage = !store.detailDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUploadedAttachment = attachments.contains { $0.status == .uploaded && $0.uploadedPath != nil }
        return hasMessage || hasUploadedAttachment
    }

    private func sendDetailDraftWithHaptic() {
        guard canSend else { return }
        HarnessHaptics.sendCTA()
        store.send(.sendDetailDraft)
    }

    private func handlePhotoImport(_ summary: PhotoImportSummary) {
        if !summary.urls.isEmpty {
            store.send(.attachmentFilesPicked(workspaceID: workspace.id, summary.urls))
        }
        if let message = summary.warningMessage {
            store.send(.attachmentPickerFailed(message))
        }
    }

    private func inputActionButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        inputActionButton(
            accessibilityLabel: accessibilityLabel
        ) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
        } action: {
            action()
        }
    }

    private func inputActionButton<Label: View>(
        accessibilityLabel: String,
        @ViewBuilder label: @escaping () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HarnessHaptics.inputCTA()
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)

                Circle()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)

                label()
                    .frame(width: Self.inputActionVisualSize, height: Self.inputActionVisualSize)
            }
            .frame(width: Self.inputActionVisualSize, height: Self.inputActionVisualSize)
            .padding(Self.inputActionHitSlop)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.92))
        .padding(-Self.inputActionHitSlop)
        .accessibilityLabel(accessibilityLabel)
    }

    @MainActor
    private func focusInputAtEnd() async {
        await Task.yield()
        isInputFocused.wrappedValue = true
        inputSelection = TextSelection(insertionPoint: store.detailDraft.endIndex)

        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else { return }
        isInputFocused.wrappedValue = true
        inputSelection = TextSelection(insertionPoint: store.detailDraft.endIndex)
    }

    private var skillAutocompleteContext: SkillAutocompleteContext? {
        SkillAutocompleteContext(draft: store.detailDraft, selection: inputSelection)
    }

    private var allSkills: [ProjectSkill] {
        store.projectSkills + store.userSkills
    }

    private func filteredSkillSuggestions(for context: SkillAutocompleteContext) -> [ProjectSkill] {
        allSkills
            .filter { skill in
                context.query.isEmpty || skill.name.localizedCaseInsensitiveContains(context.query)
            }
            .prefix(3)
            .map { $0 }
    }

    private func loadSkillsIfNeededForAutocomplete() {
        guard skillAutocompleteContext != nil,
              !store.hasSkills,
              !store.isLoadingSkills else {
            return
        }
        store.send(.loadSkills)
    }

    private func replaceSkillToken(_ context: SkillAutocompleteContext, with skill: ProjectSkill) {
        let replacement = "/\(skill.name)"
        var draft = store.detailDraft
        let cursorOffset = draft.distance(from: draft.startIndex, to: context.range.lowerBound) + replacement.count
        draft.replaceSubrange(context.range, with: replacement)
        store.detailDraft = draft
        dismissedSkillAutocompleteSignature = nil

        let cursorIndex = draft.index(draft.startIndex, offsetBy: cursorOffset)
        inputSelection = TextSelection(insertionPoint: cursorIndex)
        isInputFocused.wrappedValue = true
    }
}
