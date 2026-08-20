import SwiftUI
import UniformTypeIdentifiers

/// How the composer's tool row decides its fit.
///
/// The app always uses `.automatic`. `.pinnedWidest` exists for the offscreen
/// render tests: `ViewThatFits` measures every candidate, and a candidate that
/// loses the measurement can still leave its tools in an `NSHostingView`
/// snapshot — a screenshot showing two tool rows for a composer that only ever
/// mounts one.
enum ComposerToolRowFit: Equatable, Sendable {
    case automatic
    case pinnedWidest
}

/// The shared prompt composer, hosted by both the terminal pane and Pi chat.
///
/// Mac notes:
/// - The chevron latch is gone. It existed on iOS to trade the software
///   keyboard for the tool deck; a Mac has neither the keyboard to hide nor the
///   width problem that justified hiding anything. The auxiliary tools and the
///   terminal keys now share one always-visible row *above* the input, so the
///   thing you type into is the bottom-most, closest-to-hand element and the
///   tools never move.
/// - Return sends, Shift/Option+Return inserts a newline, Command+Return always
///   sends. `onKeyPress` owns that mapping; `onSubmit` stays as a backstop.
/// - Typing `$` at a token boundary raises `ComposerSkillsHUD` — the workspace's
///   skills, filtered as you type, accepted with Return/Tab. It is an
///   accelerator: it never takes focus, never blocks a send, and any signal
///   that you did not mean a skill (space, escape, no matches) makes it vanish
///   without touching the draft. All of its rules live in
///   `ComposerSkillsPalette`.
/// - Attachments come from one `fileImporter` (the Mac open panel already
///   browses Photos) plus drag-and-drop onto the composer.
struct PromptComposerView: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let workspace: HerdrWorkspace
    @Binding var draft: String
    @Binding var attachments: [TerminalAttachment]
    let focusRequest: Int
    let dismissFocusRequest: Int
    let piConfiguration: PiPromptComposerConfiguration?
    let toolRowFit: ComposerToolRowFit

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isFocused: Bool
    @State private var isShowingFileImporter = false
    @State private var isShowingVoiceRecorder = false
    @State private var isShowingFileSearch = false
    @State private var isShowingJira = false
    @State private var isDropTargeted = false
    @State private var disposition: PiPromptDisposition = .prompt
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var quickVoiceCapture = HerdrQuickVoiceCapture()
    @State private var isCTACapture = false
    @State private var draftContainsDictation = false
    @State private var isLockPulsing = false
    @State private var skillsPalette = ComposerSkillsPalette()
    @State private var didLoadSkills = false
    @State private var isLoadingSkills = false

    init(
        model: HerdrAppModel,
        pane: HerdrPane,
        workspace: HerdrWorkspace,
        draft: Binding<String>,
        attachments: Binding<[TerminalAttachment]>,
        focusRequest: Int,
        dismissFocusRequest: Int = 0,
        piConfiguration: PiPromptComposerConfiguration? = nil,
        toolRowFit: ComposerToolRowFit = .automatic
    ) {
        self.model = model
        self.pane = pane
        self.workspace = workspace
        _draft = draft
        _attachments = attachments
        self.focusRequest = focusRequest
        self.dismissFocusRequest = dismissFocusRequest
        self.piConfiguration = piConfiguration
        self.toolRowFit = toolRowFit
        _disposition = State(initialValue: piConfiguration?.preferredDisposition ?? .prompt)
    }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ComposerAttachmentTray(
                    attachments: attachments,
                    retry: retryAttachment,
                    remove: removeAttachment
                )
            }

            if let piConfiguration, piConfiguration.phase == .working {
                PiPromptComposerStatusBar(
                    disposition: effectiveDisposition,
                    availableDispositions: piConfiguration.availableDispositions,
                    canSelectDisposition: piConfiguration.isConnected,
                    canAbort: piConfiguration.canAbort,
                    selectDisposition: selectDisposition,
                    stop: stopPi
                )
                    .transition(semanticControlTransition)
            }

            if let piConfiguration,
               piConfiguration.currentModel != nil
               || piConfiguration.capabilities.listModels
               || piConfiguration.thinkingLevel != nil
               || piConfiguration.capabilities.setThinkingLevel {
                HStack {
                    PiModelPickerChip(
                        currentModel: piConfiguration.currentModel,
                        availableModels: piConfiguration.availableModels,
                        isLoading: piConfiguration.isLoadingModels,
                        isSetting: piConfiguration.isSettingModel,
                        isEnabled: piConfiguration.canSelectModel,
                        isInteractive: piConfiguration.supportsModelMenu,
                        errorMessage: piConfiguration.modelCatalogError,
                        selectModel: { candidate in
                            Task { _ = await piConfiguration.selectModel(candidate) }
                        },
                        retry: {
                            Task { await piConfiguration.retryLoadModels() }
                        }
                    )
                    PiThinkingLevelChip(
                        currentLevel: piConfiguration.thinkingLevel,
                        isSetting: piConfiguration.isSettingThinkingLevel,
                        isEnabled: piConfiguration.canSelectThinkingLevel,
                        isInteractive: piConfiguration.supportsThinkingMenu,
                        selectLevel: { level in
                            Task { _ = await piConfiguration.selectThinkingLevel(level) }
                        }
                    )
                    Spacer()
                }
            }

            if quickVoiceCapture.phase == .locked {
                Text("recording locked · tap mic to finish")
                    .herdrFont(.caption, monospaced: true, weight: .semibold)
                    .foregroundStyle(HerdrTheme.alert)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(HerdrTheme.alert.opacity(0.16))
                    .clipShape(.capsule)
                    .transition(semanticControlTransition)
            }

            composerToolRow

            composerRow
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: piConfiguration?.phase
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: quickVoiceCapture.phase)
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: skillsPalette.isVisible)
        .overlay(alignment: .topLeading) {
            if skillsPalette.isVisible {
                // Floats above the whole composer instead of pushing it down:
                // the draft must not move under the caret while the HUD is up.
                // Overriding the child's `.top` guide with its own bottom edge
                // is what lifts it clear of the stack.
                ComposerSkillsHUD(
                    matches: skillsPalette.matches,
                    totalCount: skillsPalette.skills.count,
                    highlightedIndex: skillsPalette.highlightedIndex,
                    query: skillsPalette.query,
                    visibleRowCount: skillsPalette.visibleRowCount,
                    select: acceptSkill(at:),
                    highlight: { index in skillsPalette.highlight(index) }
                )
                .alignmentGuide(.top) { dimensions in dimensions[.bottom] + 8 }
                .transition(semanticControlTransition)
            }
        }
        .herdrHaptic(trigger: hapticPulse)
        .onAppear {
            quickVoiceCapture.onLock = {
                hapticPulse.fire(.recordingLocked)
            }
            isLockPulsing = quickVoiceCapture.phase == .locked
        }
        .onDisappear {
            quickVoiceCapture.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                quickVoiceCapture.cancel()
            }
        }
        .onChange(of: quickVoiceCapture.phase) { _, phase in
            isLockPulsing = phase == .locked
            if phase == .idle {
                isCTACapture = false
            }
        }
        .onChange(of: quickVoiceCapture.recorderStatus) { _, status in
            if status == .finished, quickVoiceCapture.phase == .locked {
                finishLockedQuickVoiceCapture()
            }
        }
        .onChange(of: draft) { _, updatedDraft in
            if updatedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftContainsDictation = false
            }
            updateSkillsPalette()
        }
        .onChange(of: isFocused) { _, focused in
            // Leaving the field is as clear a "not now" as pressing escape.
            if !focused { skillsPalette.dismiss() }
        }
        .onChange(of: focusRequest) {
            isFocused = true
        }
        .onChange(of: dismissFocusRequest) {
            isFocused = false
        }
        .onChange(of: piConfiguration?.availableDispositions) { _, options in
            guard let options, !options.contains(disposition) else { return }
            disposition = options.first ?? .prompt
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                queueAttachments(urls, ownership: .userSelected)
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard canControl else { return false }
            queueAttachments(urls, ownership: .userSelected)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(HerdrTheme.accent, lineWidth: 1.5)
                    .padding(-6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $isShowingVoiceRecorder) {
            HerdrVoiceNoteRecorderSheet(
                save: { url in
                    isShowingVoiceRecorder = false
                    queueAttachments([url], ownership: .appTemporary)
                },
                transcribe: { url in
                    try await model.transcribeVoiceNote(at: url)
                },
                insertTranscript: { result in
                    isShowingVoiceRecorder = false
                    appendTranscript(result.text)
                    hapticPulse.fire(.transcriptionSucceeded)
                    model.toastMessage = result.usedFallback
                        ? "Parakeet unavailable · transcribed with Apple Speech"
                        : "Transcribed with \(result.provider.rawValue)"
                },
                cancel: { isShowingVoiceRecorder = false }
            )
        }
        .sheet(isPresented: $isShowingFileSearch) {
            WorkspaceFileSearchSheet(
                load: { query in
                    try await model.searchFiles(in: workspace, query: query)
                },
                select: { file in
                    appendToken("`\(file.path)`")
                }
            )
            .frame(minWidth: 560, minHeight: 480)
        }
        .sheet(isPresented: $isShowingJira) {
            JiraTicketPickerSheet(
                loadAssigned: { try await model.fetchAssignedJiraTickets() },
                lookup: { query in try await model.fetchJiraTicket(query: query) },
                select: { ticket in
                    appendJira(ticket)
                }
            )
            .frame(minWidth: 640, minHeight: 560)
        }
    }

    private var semanticControlTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            composerInput

            trailingComposerButton
        }
    }

    /// Tools left, terminal keys right, one hairline between them — always
    /// visible, in both chat and terminal modes, because the keys route through
    /// send-keys either way.
    ///
    /// The fit is decided for the row as a whole and degrades in that order:
    /// drop the tool titles, then the key labels, then fold the four
    /// second-tier keys into an overflow menu. Only the narrowest windows ever
    /// see the last step.
    private var composerToolRow: some View {
        Group {
            switch toolRowFit {
            case .automatic:
                ViewThatFits(in: .horizontal) {
                    toolRow(showsToolTitles: true, showsKeyLabels: true)
                    toolRow(showsToolTitles: false, showsKeyLabels: true)
                    toolRow(showsToolTitles: false, showsKeyLabels: false)
                    toolRow(
                        showsToolTitles: false,
                        showsKeyLabels: false,
                        keys: TerminalPresetKey.primaryRow,
                        overflow: TerminalPresetKey.secondaryRow
                    )
                }
            case .pinnedWidest:
                toolRow(showsToolTitles: true, showsKeyLabels: true)
            }
        }
        .accessibilityIdentifier("composer-tool-row")
    }

    private func toolRow(
        showsToolTitles: Bool,
        showsKeyLabels: Bool,
        keys: [TerminalPresetKey] = TerminalPresetKey.deckRow,
        overflow: [TerminalPresetKey] = []
    ) -> some View {
        HStack(spacing: 10) {
            ComposerAuxiliaryBar(
                attach: { isShowingFileImporter = true },
                recordVoice: { isShowingVoiceRecorder = true },
                searchFiles: { isShowingFileSearch = true },
                chooseJira: { isShowingJira = true },
                voicePhase: quickVoiceCapture.phase,
                beginVoiceHold: beginQuickVoiceCapture,
                endVoiceHold: finishQuickVoiceCapture,
                finishLockedVoiceCapture: finishLockedQuickVoiceCapture,
                showsTitles: showsToolTitles
            )
            .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(width: 1, height: ComposerDeckMetrics.controlHeight - 8)
                .accessibilityHidden(true)

            TerminalKeyDeck(
                model: model,
                pane: pane,
                keys: keys,
                overflow: overflow,
                showsLabels: showsKeyLabels
            )
        }
    }

    private var composerInput: some View {
        Group {
            if isCTALockedCapture {
                HerdrVoiceWaveform(
                    samples: quickVoiceCapture.samples,
                    isRecording: true,
                    showsContainer: false
                )
                .padding(.horizontal, 13)
            } else if isCTATranscribing {
                ProgressView()
                    .tint(HerdrTheme.alert)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .herdrFont(.body, monospaced: true)
                    .foregroundStyle(HerdrTheme.text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(send)
                    .onKeyPress(.return, phases: .down, action: handleReturnKey)
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        moveSkillsHighlight(by: -1)
                    }
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        moveSkillsHighlight(by: 1)
                    }
                    .onKeyPress(.tab, phases: .down) { _ in
                        guard skillsPalette.isVisible else { return .ignored }
                        acceptSkill()
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        // Leaves the typed text exactly where it is; only the
                        // HUD goes away, and this `$token` will not raise it
                        // again.
                        guard skillsPalette.isVisible else { return .ignored }
                        skillsPalette.dismiss()
                        return .handled
                    }
                    .onKeyPress(.space, phases: .down) { press in
                        // A space is the user saying "not a skill". The HUD
                        // leaves and the space types normally, so this handler
                        // deliberately reports `.ignored`.
                        guard skillsPalette.isVisible, press.modifiers.isEmpty else { return .ignored }
                        skillsPalette.dismiss()
                        return .ignored
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .disabled(isSubmitting || !canControl)
            }
        }
        .frame(minHeight: 48)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(composerInputBorder, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .shadow(
            color: quickVoiceCapture.phase == .locked
                ? HerdrTheme.alert.opacity(isLockPulsing && !reduceMotion ? 0.62 : 0.28)
                : .clear,
            radius: quickVoiceCapture.phase == .locked ? 8 : 0
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
        .accessibilityIdentifier("prompt-composer")
    }

    private var trailingComposerButton: some View {
        Button(action: handleTrailingComposerAction) {
            Group {
                if isCTACaptureInProgress {
                    Image(systemName: "stop.fill")
                } else if isCTAMicAvailable {
                    Image(systemName: "mic.fill")
                } else if isSubmitting {
                    ProgressView()
                        .tint(HerdrTheme.ink)
                } else {
                    Image(systemName: effectiveDisposition.symbol)
                }
            }
            .frame(width: 48, height: 48)
            .background(isCTALockedCapture ? HerdrTheme.alert : HerdrTheme.accent)
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .contentShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        }
        .herdrFont(.headline, weight: .bold)
        .foregroundStyle(HerdrTheme.ink)
        .scaleEffect(isCTALockedCapture && isLockPulsing && !reduceMotion ? 1.035 : 1)
        .opacity(trailingComposerOpacity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
        .buttonStyle(.plain)
        .disabled(isCTATranscribing || (!isCTAMicAvailable && !isCTALockedCapture && !canSend))
        .help(trailingComposerAccessibilityHint)
        .accessibilityLabel(trailingComposerAccessibilityLabel)
        .accessibilityHint(trailingComposerAccessibilityHint)
        .accessibilityIdentifier("prompt-send")
    }

    private var placeholder: String {
        if let piConfiguration {
            return piConfiguration.placeholder(for: effectiveDisposition)
        }
        return pane.agentStatus == .unknown
            ? "run or type into this shell"
            : "message \(pane.displayAgentName)"
    }

    private var canControl: Bool {
        piConfiguration?.isConnected ?? model.canControl
    }

    private var isSubmitting: Bool {
        piConfiguration?.isSubmitting ?? model.isSending
    }

    private var sendAccessibilityHint: String {
        guard piConfiguration != nil else { return "Sends the prompt to this terminal" }
        return "Sends using \(effectiveDisposition.label.lowercased()) mode"
    }

    private var effectiveDisposition: PiPromptDisposition {
        guard let piConfiguration else { return .prompt }
        return piConfiguration.availableDispositions.contains(disposition)
            ? disposition
            : piConfiguration.preferredDisposition
    }

    private var canSend: Bool {
        let hasText = hasDraftText
        let hasAttachment = hasUploadedAttachment
        let isUploading = attachments.contains { item in
            item.status == .uploading
        }
        let dispositionIsAvailable = piConfiguration?.availableDispositions.contains(effectiveDisposition) ?? true
        return (hasText || hasAttachment)
            && !isUploading
            && !isSubmitting
            && canControl
            && dispositionIsAvailable
    }

    private var hasDraftText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasUploadedAttachment: Bool {
        attachments.contains { item in
            item.status == .uploaded && item.uploadedPath != nil
        }
    }

    private var isEmptyInput: Bool {
        !hasDraftText && attachments.isEmpty
    }

    private var isCTALockedCapture: Bool {
        isCTACapture && quickVoiceCapture.phase == .locked
    }

    private var isCTATranscribing: Bool {
        isCTACapture && quickVoiceCapture.phase == .transcribing
    }

    private var isCTACaptureInProgress: Bool {
        isCTALockedCapture || isCTATranscribing
    }

    private var isCTAMicAvailable: Bool {
        isEmptyInput && quickVoiceCapture.phase == .idle && !isCTACapture
    }

    private var composerInputBorder: Color {
        quickVoiceCapture.phase == .locked
            ? HerdrTheme.alert
            : isFocused ? HerdrTheme.accent : HerdrTheme.surface
    }

    private var trailingComposerOpacity: Double {
        if isCTAMicAvailable || isCTALockedCapture { return 1 }
        if isCTATranscribing { return 0.45 }
        return canSend ? 1 : 0.45
    }

    private var trailingComposerAccessibilityLabel: String {
        if isCTALockedCapture { return "Stop voice dictation" }
        if isCTATranscribing { return "Transcribing voice dictation" }
        if isCTAMicAvailable { return "Start voice dictation" }
        return effectiveDisposition.label
    }

    private var trailingComposerAccessibilityHint: String {
        if isCTALockedCapture { return "Stops recording and transcribes the dictation" }
        if isCTATranscribing { return "Voice dictation is being transcribed" }
        if isCTAMicAvailable { return "Starts a locked voice dictation" }
        return sendAccessibilityHint
    }

    /// Return sends, Shift/Option+Return breaks the line, Command+Return sends
    /// from anywhere in the field. `onSubmit` still points at `send`, so a Mac
    /// that routes Return past this handler degrades to "Return sends" rather
    /// than to a composer that cannot submit.
    private func handleReturnKey(_ press: KeyPress) -> KeyPress.Result {
        // With the skills HUD up, Return commits the highlighted skill and
        // never the message — sending out from under a visible picker would be
        // the worst kind of surprise.
        if skillsPalette.isVisible,
           !press.modifiers.contains(.shift),
           !press.modifiers.contains(.option) {
            acceptSkill()
            return .handled
        }
        guard !press.modifiers.contains(.shift), !press.modifiers.contains(.option) else {
            // Hand the chord back to the field editor, which binds it to
            // `insertNewlineIgnoringFieldEditor:` — a line break at the caret,
            // and no submit. Appending here instead would drop the break at the
            // end of the draft no matter where the caret was.
            return .ignored
        }
        send()
        return .handled
    }

    // MARK: - `$` skills HUD

    /// Re-runs the palette against the current draft after every edit.
    ///
    /// `TextField` publishes no caret on macOS, so the caret is taken to be the
    /// end of the draft — true for typing, and the worst a mid-string edit can
    /// do is leave the HUD closed.
    private func updateSkillsPalette() {
        skillsPalette.textDidChange(draft, caret: draft.count)
        loadSkillsIfNeeded()
    }

    /// Fetches the workspace's skills the first time a `$` token appears, then
    /// re-filters — the HUD fills itself in mid-keystroke rather than making
    /// the first `$` of a session a dead one. Failures stay silent: this is an
    /// accelerator, and `WorkspaceSkillsView` is where skills errors belong.
    private func loadSkillsIfNeeded() {
        guard !didLoadSkills,
              !isLoadingSkills,
              ComposerSkillsPalette.tokenStart(in: Array(draft), caret: draft.count) != nil
        else { return }
        isLoadingSkills = true
        Task {
            defer { isLoadingSkills = false }
            guard let response = try? await model.fetchSkills(for: workspace) else { return }
            didLoadSkills = true
            skillsPalette.replaceSkills(
                response.resolvedProjectSkills + response.resolvedUserSkills
            )
        }
    }

    private func moveSkillsHighlight(by delta: Int) -> KeyPress.Result {
        guard skillsPalette.isVisible else { return .ignored }
        skillsPalette.moveHighlight(by: delta)
        return .handled
    }

    private func acceptSkill() {
        apply(skillsPalette.accept())
    }

    private func acceptSkill(at index: Int) {
        apply(skillsPalette.accept(at: index))
    }

    private func apply(_ acceptance: ComposerSkillsPalette.Acceptance?) {
        guard let acceptance else { return }
        draft = acceptance.text
        hapticPulse.fire(.selection)
        isFocused = true
    }

    private func appendToken(_ token: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? token : "\(trimmed) \(token)"
        isFocused = true
    }

    private func appendTranscript(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? cleaned : "\(existing)\n\n\(cleaned)"
        draftContainsDictation = true
        isFocused = true
    }

    private func beginQuickVoiceCapture() {
        guard !isShowingVoiceRecorder, quickVoiceCapture.phase == .idle else { return }
        hapticPulse.fire(.recordingStarted)
        quickVoiceCapture.beginHold()
    }

    private func finishQuickVoiceCapture() {
        guard quickVoiceCapture.phase != .locked else { return }
        completeQuickVoiceCapture()
    }

    private func finishLockedQuickVoiceCapture() {
        guard quickVoiceCapture.phase == .locked else { return }
        completeQuickVoiceCapture()
    }

    private func completeQuickVoiceCapture() {
        Task {
            hapticPulse.fire(.recordingStopped)
            let outcome = await quickVoiceCapture.endHold { url in
                try await model.transcribeVoiceNote(at: url)
            }
            switch outcome {
            case .cancelled:
                break
            case .tooShort:
                model.toastMessage = "Hold the mic to dictate"
            case let .transcript(result):
                appendTranscript(result.text)
                hapticPulse.fire(.transcriptionSucceeded)
                model.toastMessage = result.usedFallback
                    ? "Parakeet unavailable · transcribed with Apple Speech"
                    : "Transcribed with \(result.provider.rawValue)"
            case let .failure(message):
                hapticPulse.fire(.failed)
                model.errorMessage = message
            }
            isCTACapture = false
        }
    }

    private func handleTrailingComposerAction() {
        if isCTALockedCapture {
            finishLockedQuickVoiceCapture()
        } else if isCTAMicAvailable {
            isCTACapture = true
            quickVoiceCapture.beginLocked()
        } else {
            send()
        }
    }

    private func appendJira(_ ticket: JiraTicket) {
        let block = """
        Jira: \(ticket.key) · \(ticket.title)
        Status: \(ticket.status) · Priority: \(ticket.priority)
        \(ticket.url)
        """
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? block : "\(trimmed)\n\n\(block)"
        isFocused = true
    }

    private func queueAttachments(
        _ urls: [URL],
        ownership: AttachmentSourceOwnership
    ) {
        guard !urls.isEmpty else { return }
        do {
            let candidates = try urls.map {
                try AttachmentPolicy.candidate(for: $0, ownership: ownership)
            }
            try AttachmentPolicy.validate(
                existingAttachments: attachments,
                incomingCandidates: candidates
            )
            enqueue(candidates)
        } catch {
            removeTemporarySources(urls, ownership: ownership)
            model.errorMessage = error.localizedDescription
        }
    }

    private func enqueue(_ candidates: [AttachmentCandidate]) {
        let queued = candidates.map { candidate in
            TerminalAttachment(
                id: UUID(),
                filename: candidate.filename,
                sourceURL: candidate.sourceURL,
                byteCount: candidate.byteCount,
                sourceOwnership: candidate.ownership,
                status: .uploading,
                uploaded: nil,
                error: nil
            )
        }
        attachments.append(contentsOf: queued)
        queued.forEach(upload)
    }

    private func upload(_ item: TerminalAttachment) {
        let url = item.sourceURL
        Task {
            do {
                let uploaded = try await model.uploadAttachment(
                    from: url,
                    contentType: contentType(for: url),
                    to: workspace
                )
                updateAttachment(item.id) { current in
                    current.uploaded = uploaded
                    current.error = nil
                    current.status = .uploaded
                }
                item.removeSourceFileIfOwned()
            } catch {
                updateAttachment(item.id) { current in
                    current.error = error.localizedDescription
                    current.status = .failed
                }
            }
        }
    }

    private func retryAttachment(_ item: TerminalAttachment) {
        updateAttachment(item.id) {
            $0.error = nil
            $0.status = .uploading
        }
        upload(item)
    }

    private func removeAttachment(_ item: TerminalAttachment) {
        item.removeSourceFileIfOwned()
        attachments.removeAll { $0.id == item.id }
    }

    private func updateAttachment(
        _ id: UUID,
        update: (inout TerminalAttachment) -> Void
    ) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        update(&attachments[index])
    }

    private func contentType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private func removeTemporarySources(
        _ urls: [URL],
        ownership: AttachmentSourceOwnership
    ) {
        guard ownership == .appTemporary else { return }
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = attachments.compactMap(\.uploadedPath)
        let attachmentBlock = paths.isEmpty
            ? ""
            : paths.map { "Attachment: `\($0)`" }.joined(separator: "\n")
        var message = [text, attachmentBlock]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if draftContainsDictation,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += "\n\n(transcribed audio, please account for incorrect names or typos)"
        }
        let piConfiguration = self.piConfiguration
        let disposition = effectiveDisposition

        Task {
            let didSend = if let piConfiguration {
                await piConfiguration.submit(message, disposition)
            } else {
                await model.sendPrompt(message, to: pane)
            }

            if didSend {
                draft = ""
                draftContainsDictation = false
                attachments.forEach { $0.removeSourceFileIfOwned() }
                attachments = []
                hapticPulse.fire(.promptSent)
            } else if piConfiguration != nil {
                hapticPulse.fire(.failed)
            }
        }
    }

    private func selectDisposition(_ selection: PiPromptDisposition) {
        disposition = selection
        hapticPulse.fire(.selection)
    }

    private func stopPi() {
        guard let piConfiguration, piConfiguration.canAbort else { return }
        Task {
            let succeeded = await piConfiguration.abort()
            hapticPulse.fire(succeeded ? .stopped : .failed)
        }
    }
}
