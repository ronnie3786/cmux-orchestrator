import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PromptComposerView: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let workspace: HerdrWorkspace
    @Binding var draft: String
    @Binding var attachments: [TerminalAttachment]
    let focusRequest: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isExpanded = false
    @State private var isShowingAttachOptions = false
    @State private var isShowingFileImporter = false
    @State private var isShowingPhotoPicker = false
    @State private var isShowingVoiceRecorder = false
    @State private var isShowingFileSearch = false
    @State private var isShowingJira = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var sendFeedback = 0

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ComposerAttachmentTray(
                    attachments: attachments,
                    retry: retryAttachment,
                    remove: removeAttachment
                )
            }

            if isExpanded {
                ComposerAuxiliaryBar(
                    attach: { isShowingAttachOptions = true },
                    recordVoice: { isShowingVoiceRecorder = true },
                    searchFiles: { isShowingFileSearch = true },
                    chooseJira: { isShowingJira = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            composerRow

            TerminalKeyDeck(model: model, pane: pane, isExpanded: isExpanded)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isExpanded)
        .sensoryFeedback(.success, trigger: sendFeedback)
        .onChange(of: isFocused) { _, focused in
            if focused { isExpanded = false }
        }
        .onChange(of: focusRequest) {
            isFocused = true
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .confirmationDialog("Attach", isPresented: $isShowingAttachOptions) {
            Button("Photo Library", systemImage: "photo") {
                isShowingPhotoPicker = true
            }
            Button("Files", systemImage: "folder") {
                isShowingFileImporter = true
            }
            Button("Cancel", role: .cancel) { }
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: AttachmentPolicy.maximumCount,
            matching: .images
        )
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
        .sheet(isPresented: $isShowingVoiceRecorder) {
            HerdrVoiceNoteRecorderSheet(
                save: { url in
                    isShowingVoiceRecorder = false
                    queueAttachments([url], ownership: .appTemporary)
                },
                cancel: { isShowingVoiceRecorder = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
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
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingJira) {
            JiraTicketPickerSheet(
                loadAssigned: { try await model.fetchAssignedJiraTickets() },
                lookup: { query in try await model.fetchJiraTicket(query: query) },
                select: { ticket in
                    appendJira(ticket)
                }
            )
        }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                isFocused = false
                isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.headline.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .foregroundStyle(isExpanded ? HerdrTheme.ink : HerdrTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(isExpanded ? HerdrTheme.accent : HerdrTheme.elevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                            .strokeBorder(isExpanded ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
                    }
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse terminal controls" : "Expand terminal controls")
            .accessibilityIdentifier("terminal-controls-toggle")

            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.body.monospaced())
                .foregroundStyle(HerdrTheme.text)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .background(HerdrTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(isFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .accessibilityIdentifier("prompt-composer")
                .disabled(model.isSending || !model.canControl)

            Button(action: send) {
                if model.isSending {
                    ProgressView()
                        .tint(HerdrTheme.ink)
                } else {
                    Image(systemName: "arrow.up")
                }
            }
            .font(.headline.bold())
            .foregroundStyle(HerdrTheme.ink)
            .frame(width: 48, height: 48)
            .background(HerdrTheme.accent)
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .buttonStyle(.plain)
            .opacity(canSend ? 1 : 0.45)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("prompt-send")
        }
    }

    private var placeholder: String {
        pane.agentStatus == .unknown ? "run or type into this shell" : "message \(pane.displayAgentName)"
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachment = attachments.contains { item in
            if item.status == .uploaded { return item.uploadedPath != nil }
            return false
        }
        let isUploading = attachments.contains { item in
            item.status == .uploading
        }
        return (hasText || hasAttachment) && !isUploading && !model.isSending && model.canControl
    }

    private func appendToken(_ token: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? token : "\(trimmed) \(token)"
        isFocused = true
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

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotos = [] }
        guard !items.isEmpty else { return }

        var candidates: [AttachmentCandidate] = []
        do {
            try AttachmentPolicy.validateCount(
                existingCount: attachments.count,
                incomingCount: items.count
            )

            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw APIError.invalidResponse
                }
                let type = item.supportedContentTypes.first ?? .jpeg
                let fileExtension = type.preferredFilenameExtension ?? "jpg"
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "herdr-photo-\(UUID().uuidString).\(fileExtension)")
                let candidate = AttachmentCandidate(
                    sourceURL: url,
                    filename: url.lastPathComponent,
                    byteCount: Int64(data.count),
                    ownership: .appTemporary
                )
                try AttachmentPolicy.validateFile(
                    named: candidate.filename,
                    byteCount: candidate.byteCount
                )
                try AttachmentPolicy.validate(
                    existingAttachments: attachments,
                    incomingCandidates: candidates + [candidate]
                )
                try data.write(to: url, options: .atomic)
                candidates.append(candidate)
            }

            try AttachmentPolicy.validate(
                existingAttachments: attachments,
                incomingCandidates: candidates
            )
            enqueue(candidates)
        } catch {
            removeTemporarySources(
                candidates.map(\.sourceURL),
                ownership: .appTemporary
            )
            model.errorMessage = "A selected photo could not be attached: \(error.localizedDescription)"
        }
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
        let message = [text, attachmentBlock]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        Task {
            if await model.sendPrompt(message, to: pane) {
                draft = ""
                attachments.forEach { $0.removeSourceFileIfOwned() }
                attachments = []
                sendFeedback &+= 1
            }
        }
    }
}
