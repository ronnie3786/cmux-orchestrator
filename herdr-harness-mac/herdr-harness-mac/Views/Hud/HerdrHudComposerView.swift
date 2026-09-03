import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HerdrHudComposerView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession

    @FocusState private var isComposerFocused: Bool
    @State private var quickVoiceCapture = HerdrQuickVoiceCapture()
    @State private var voiceErrorMessage: String?
    @State private var isShowingFilePicker = false

    /// A submission clears validation within a turn or two; the ceiling only
    /// exists so a failed submit cannot leave this polling forever.
    private static let runStartPollInterval = Duration.milliseconds(40)
    private static let runStartPollAttempts = 25

    var body: some View {
        VStack(spacing: 8) {
            if !session.pendingAttachments.isEmpty {
                attachmentChips
            }
            if let voiceErrorMessage, !voiceErrorMessage.isEmpty {
                Text(voiceErrorMessage)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                composerInput
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .herdrFont(.title3)
                        .foregroundStyle(HerdrTheme.accent)
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityLabel("Send HUD prompt")
                .accessibilityIdentifier("hud-send")
            }
            HStack(spacing: 8) {
                HerdrHudModelChip(
                    currentSelectionID: session.selectedModel,
                    availableModels: session.availableModels,
                    defaultModel: session.defaultModel,
                    isLoading: session.isLoadingModels,
                    errorMessage: session.modelsError,
                    selectModel: { session.setSelectedModel($0) },
                    retry: { Task { await session.loadModels(model: model) } }
                )

                Button(action: toggleVoiceCapture) {
                    Image(systemName: isVoiceCaptureActive ? "mic.fill" : "mic")
                        .foregroundStyle(isVoiceCaptureActive ? HerdrTheme.alert : HerdrTheme.mist)
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                .disabled(quickVoiceCapture.phase == .transcribing)
                .accessibilityLabel(voiceCaptureAccessibilityLabel)
                .accessibilityIdentifier("hud-mic")

                Button {
                    isShowingFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(HerdrTheme.mist)
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach file")
                .accessibilityIdentifier("hud-attach-file")

                if let thread = session.thread {
                    Label("Thread · \(thread.turnCount) turns", systemImage: "link")
                        .herdrFont(.caption2, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                }

                Spacer()
            }
        }
        .padding(12)
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.image, .pdf, .text, .sourceCode, .json, .commaSeparatedText, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                session.addAttachments(urls)
            case let .failure(error):
                session.reportAttachmentError(error.localizedDescription)
            }
        }
        .task(id: controller.focusRequest) {
            isComposerFocused = true
        }
        .onDisappear {
            quickVoiceCapture.cancel()
        }
        .onChange(of: quickVoiceCapture.recorderStatus) { _, status in
            if status == .finished, quickVoiceCapture.phase == .locked {
                finishVoiceCapture()
            }
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(session.pendingAttachments) { attachment in
                    HerdrHudAttachmentChipView(
                        attachment: attachment,
                        remove: { session.removeAttachment(attachment.id) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var composerInput: some View {
        Group {
            if isVoiceCaptureActive {
                HerdrVoiceWaveform(
                    samples: quickVoiceCapture.samples,
                    isRecording: true,
                    showsContainer: false
                )
                .padding(.horizontal, 10)
            } else if quickVoiceCapture.phase == .transcribing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.accent)
                    Text("Transcribing…")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }
                .frame(maxWidth: .infinity, minHeight: 42)
            } else {
                TextField(
                    session.thread == nil ? "Ask anything — or tell it what to do…" : "Reply — it remembers this thread",
                    text: $session.draft,
                    axis: .vertical
                )
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.text)
                    .focused($isComposerFocused)
                    .onSubmit(handleSubmit)
                    .onKeyPress(.return, phases: .down, action: handleReturnKey)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(isComposerFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }

    private var canSubmit: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isRunning
    }

    private var isVoiceCaptureActive: Bool {
        quickVoiceCapture.phase == .recording || quickVoiceCapture.phase == .locked
    }

    private var voiceCaptureAccessibilityLabel: String {
        switch quickVoiceCapture.phase {
        case .idle: "Start voice dictation"
        case .recording, .locked: "Stop voice dictation and transcribe"
        case .transcribing: "Voice dictation is transcribing"
        }
    }

    /// Shares `ComposerReturnKeyRouter` with the pane composer so the HUD and
    /// the chat composer never disagree about what Return does.
    private func handleReturnKey(_ press: KeyPress) -> KeyPress.Result {
        switch ComposerReturnKeyRouter.outcome(for: press, isSkillsPaletteVisible: false) {
        case .insertNewline:
            ComposerNewlineInserter.insertNewline(appendingTo: &session.draft)
            return .handled
        case .acceptSkill, .send:
            submit()
            return .handled
        }
    }

    private func handleSubmit() {
        if ComposerReturnKeyRouter.submitOutcome(isSkillsPaletteVisible: false) == .insertNewline {
            ComposerNewlineInserter.insertNewline(appendingTo: &session.draft)
            return
        }
        submit()
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            let startedBefore = session.runStartedRevision
            let submission = Task { await session.submit(model: model) }
            // Get out of the way for the length of the run, then come back with
            // the answer. Waiting for the run to actually start keeps a
            // validation failure — which never starts one — on screen.
            let didCollapse = await collapseOnceRunning(startedBefore: startedBefore)
            await submission.value
            if didCollapse { controller.endRunAutoCollapse() }
        }
    }

    private func collapseOnceRunning(startedBefore: Int) async -> Bool {
        for _ in 0..<Self.runStartPollAttempts {
            if session.runStartedRevision != startedBefore {
                return controller.beginRunAutoCollapse()
            }
            try? await Task.sleep(for: Self.runStartPollInterval)
        }
        return false
    }

    private func toggleVoiceCapture() {
        voiceErrorMessage = nil
        switch quickVoiceCapture.phase {
        case .idle:
            quickVoiceCapture.beginLocked()
        case .recording, .locked:
            finishVoiceCapture()
        case .transcribing:
            break
        }
    }

    private func finishVoiceCapture() {
        Task {
            let outcome = await quickVoiceCapture.endHold { url in
                try await model.transcribeVoiceNote(at: url)
            }
            handleVoiceCapture(outcome)
        }
    }

    private func handleVoiceCapture(_ outcome: HerdrQuickVoiceCapture.Outcome) {
        switch outcome {
        case .cancelled:
            break
        case .tooShort:
            voiceErrorMessage = "Hold the mic a little longer."
        case let .failure(message):
            voiceErrorMessage = message
        case let .transcript(transcript):
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            session.draft = session.draft.isEmpty ? text : "\(session.draft)\n\n\(text)"
        }
    }
}
