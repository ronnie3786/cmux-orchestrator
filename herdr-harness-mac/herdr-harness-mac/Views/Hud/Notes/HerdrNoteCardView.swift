import SwiftUI

struct HerdrNoteCardView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let notes: HerdrHudNotesState
    let noteID: UUID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isBodyFocused: Bool
    @State private var isDeleteArmed = false
    @State private var deleteArmTask: Task<Void, Never>?

    var body: some View {
        if let note = notes.note(id: noteID) {
            card(note)
        } else {
            Color.clear.task { controller.closeNote() }
        }
    }

    private func card(_ note: HerdrNote) -> some View {
        let isCleaning = notes.activities[note.id] == .cleaning
        return ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                ZStack(alignment: .top) {
                    VStack(spacing: 8) {
                        header(note)
                        editor(note, isCleaning: isCleaning)
                    }
                    .id(notes.revealRevision[note.id] ?? 0)
                    .transition(HerdrNoteReveal.transition(reduceMotion))
                }
                .frame(maxHeight: .infinity)
                details(note)
                footer(note)
            }
            .padding(12)

            if isCleaning {
                HerdrNoteShimmerOverlay(color: note.color.ink)
            }
            if notes.celebratingNoteID == note.id {
                HerdrSparkleBurstView()
                    .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
                    .offset(x: -82, y: 0)
            }
        }
        .frame(width: HerdrHudPlacement.noteCardSize.width, height: HerdrHudPlacement.noteCardSize.height)
        .foregroundStyle(note.color.ink)
        .tint(note.color.ink)
        .background(note.color.fill, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: HerdrTheme.ink.opacity(0.45), radius: 16, y: 8)
        .clipShape(.rect(cornerRadius: 12))
        .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: notes.revealRevision[note.id] ?? 0)
        .task(id: controller.noteFocusRequest) { isBodyFocused = true }
        .onChange(of: notes.revealRevision[note.id]) { _, _ in isBodyFocused = true }
        .onChange(of: notes.isBusy(note.id)) { wasBusy, isBusy in
            if wasBusy && !isBusy { isBodyFocused = true }
        }
        .onKeyPress(.escape) {
            controller.closeNote()
            return .handled
        }
        .onDisappear { deleteArmTask?.cancel() }
    }

    private func header(_ note: HerdrNote) -> some View {
        HStack(spacing: 6) {
            TextField("Title", text: titleBinding(for: note))
                .textFieldStyle(.plain)
                .herdrFont(.subheadline, weight: .bold)
                .foregroundStyle(note.color.ink)
            Spacer(minLength: 0)
            headerButton(symbol: "sparkles", help: "Tidy with AI", identifier: "hud-note-ai", note: note) {
                Task { await notes.cleanUp(note.id, model: model) }
            }
            headerButton(symbol: "bolt.fill", help: "Take action", identifier: "hud-note-act", note: note) {
                Task { await notes.planActions(note.id, model: model) }
            }
            Button {
                controller.closeNote()
            } label: {
                Image(systemName: "xmark")
                    .herdrFont(.caption, weight: .bold)
                    .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
                    .herdrHitTarget()
                    .background(note.color.ink.opacity(0.08), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Close note")
            .accessibilityIdentifier("hud-note-close")
        }
        .frame(height: HerdrTheme.minHitTarget)
    }

    private func headerButton(
        symbol: String,
        help: String,
        identifier: String,
        note: HerdrNote,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if notes.isBusy(note.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).herdrFont(.caption, weight: .bold)
                }
            }
            .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
            .herdrHitTarget()
            .background(note.color.ink.opacity(0.08), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(notes.isBusy(note.id))
        .help(help)
        .accessibilityIdentifier(identifier)
    }

    private func editor(_ note: HerdrNote, isCleaning: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Jot anything — the AI can tidy it later.")
                    .herdrFont(.callout)
                    .foregroundStyle(note.color.ink.opacity(0.45))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: bodyBinding(for: note))
                .scrollContentBackground(.hidden)
                .herdrFont(.callout)
                .foregroundStyle(note.color.ink)
                .focused($isBodyFocused)
                .allowsHitTesting(!isCleaning)
                .padding(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(note.color.ink.opacity(0.045), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private func details(_ note: HerdrNote) -> some View {
        let standaloneLinks = note.links.filter { link in
            !note.actions.contains { $0.linkID == link.id }
        }
        if statusText(for: note) != nil || note.aiSummary != nil || !note.actions.isEmpty || !standaloneLinks.isEmpty {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 7) {
                    if let status = statusText(for: note) {
                        statusLine(status, for: note)
                    }
                    if note.aiSummary != nil || !note.actions.isEmpty {
                        smartActions(note)
                    }
                    if !standaloneLinks.isEmpty {
                        links(standaloneLinks, note: note)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 140)
        }
    }

    private func statusText(for note: HerdrNote) -> (text: String, isError: Bool)? {
        if let activity = notes.activities[note.id] {
            switch activity {
            case .cleaning: return ("Tidying…", false)
            case .planning: return ("Thinking about what to do…", false)
            case .starting: return ("Spinning up a session…", false)
            }
        }
        if let status = notes.noteStatus[note.id], !status.isEmpty { return (status, false) }
        if let error = notes.noteErrors[note.id], !error.isEmpty { return (error, true) }
        return nil
    }

    private func statusLine(_ status: (text: String, isError: Bool), for note: HerdrNote) -> some View {
        HStack(spacing: 5) {
            Text(status.text)
                .herdrFont(.caption)
                .foregroundStyle(status.isError ? Color(red: 0.6, green: 0.1, blue: 0.15) : note.color.ink.opacity(0.7))
            if notes.isBusy(note.id) {
                Button { notes.cancelActivity(note.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .herdrFont(size: 14, weight: .bold, relativeTo: .caption)
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop note activity")
                .accessibilityIdentifier("hud-note-stop")
            }
        }
    }

    private func smartActions(_ note: HerdrNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Smart actions")
                    .herdrFont(.caption2, monospaced: true, weight: .bold)
                    .foregroundStyle(note.color.ink.opacity(0.7))
                Spacer()
                Button { Task { await notes.planActions(note.id, model: model) } } label: {
                    Text("Re-plan")
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .foregroundStyle(note.color.ink)
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                    .disabled(notes.isBusy(note.id))
            }
            if note.actions.isEmpty, let summary = note.aiSummary {
                Text(summary)
                    .herdrFont(.caption)
                    .italic()
                    .foregroundStyle(note.color.ink.opacity(0.75))
            } else {
                ForEach(note.actions) { action in
                    HerdrNoteActionRow(model: model, notes: notes, note: note, action: action)
                }
            }
        }
    }

    private func links(_ links: [HerdrNoteLink], note: HerdrNote) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(links) { link in
                let isAlive = model.pane(id: link.paneID) != nil
                Button {
                    guard isAlive else { return }
                    HerdrMacAppDelegate.openPaneURLWithFallback(link.paneID)
                } label: {
                    Label(link.title, systemImage: isAlive ? "link" : "link.slash")
                        .lineLimit(1)
                        .herdrFont(.caption2, monospaced: true, weight: .semibold)
                        .foregroundStyle(note.color.ink.opacity(isAlive ? 0.85 : 0.42))
                        .padding(.horizontal, 6)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .herdrHitTarget()
                        .background(note.color.ink.opacity(0.08), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(!isAlive)
                .help(isAlive ? "Open session" : "This session is gone")
            }
        }
    }

    private func footer(_ note: HerdrNote) -> some View {
        HStack(spacing: 5) {
            ForEach(HerdrNoteColor.allCases) { color in
                Button { notes.setColor(color, for: note.id) } label: {
                    Circle()
                        .fill(color.fill)
                        .frame(width: 14, height: 14)
                        .overlay {
                            if color == note.color {
                                Circle().strokeBorder(note.color.ink, lineWidth: 2)
                            }
                        }
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set note color to \(color.label)")
            }
            Spacer(minLength: 0)
            if note.previousVersion != nil {
                Button { notes.undoAI(note.id) } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .herdrFont(.caption, weight: .bold)
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                .help("Restore your original text")
            }
            deleteButton(note)
            Text(note.updatedAt, format: .relative(presentation: .named))
                .herdrFont(.caption2)
                .foregroundStyle(note.color.ink.opacity(0.6))
        }
        .frame(minHeight: HerdrTheme.minHitTarget)
    }

    private func deleteButton(_ note: HerdrNote) -> some View {
        Button {
            if note.isEmpty || isDeleteArmed {
                deleteArmTask?.cancel()
                notes.deleteNote(note.id)
            } else {
                armDelete()
            }
        } label: {
            Group {
                if isDeleteArmed {
                    Text("Delete?")
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .padding(.horizontal, 7)
                        .foregroundStyle(Color(red: 0.6, green: 0.1, blue: 0.15))
                        .background(Color(red: 0.6, green: 0.1, blue: 0.15).opacity(0.12), in: .capsule)
                } else {
                    Image(systemName: "trash")
                        .herdrFont(.caption, weight: .bold)
                }
            }
            .herdrHitTarget()
        }
        .buttonStyle(.plain)
        .help(note.isEmpty ? "Delete note" : "Delete note (tap again to confirm)")
        .accessibilityIdentifier(isDeleteArmed ? "hud-note-delete-confirm" : "hud-note-delete")
    }

    private func titleBinding(for note: HerdrNote) -> Binding<String> {
        Binding(
            get: { notes.note(id: note.id)?.title ?? "" },
            set: { notes.updateTitle($0, for: note.id) }
        )
    }

    private func bodyBinding(for note: HerdrNote) -> Binding<String> {
        Binding(
            get: { notes.note(id: note.id)?.body ?? "" },
            set: { notes.updateBody($0, for: note.id) }
        )
    }

    private func armDelete() {
        deleteArmTask?.cancel()
        isDeleteArmed = true
        deleteArmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isDeleteArmed = false
        }
    }
}

private struct HerdrNoteActionRow: View {
    @Bindable var model: HerdrAppModel
    let notes: HerdrHudNotesState
    let note: HerdrNote
    let action: HerdrNoteAction

    private var linkedNote: HerdrNoteLink? {
        action.linkID.flatMap { linkID in note.links.first { $0.id == linkID } }
    }

    private var isStartedLinkAlive: Bool {
        guard let linkedNote else { return false }
        return model.pane(id: linkedNote.paneID) != nil
    }

    private var isDisabled: Bool {
        switch action.status {
        case .starting: return true
        case .started: return !isStartedLinkAlive
        case .ready, .failed: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: tap) {
                HStack(spacing: 6) {
                    glyph
                    Text(action.title)
                        .lineLimit(1)
                        .herdrFont(.caption, weight: .semibold)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isDisabled ? note.color.ink.opacity(0.42) : note.color.ink)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: HerdrTheme.minHitTarget, alignment: .leading)
                .herdrHitTarget()
                .background(note.color.ink.opacity(0.08), in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(action.status == .started && !isStartedLinkAlive ? "This session is gone" : action.title)
            .accessibilityIdentifier("hud-note-action-\(action.id)")
            if let error = action.error, !error.isEmpty {
                Text(error)
                    .herdrFont(.caption2)
                    .foregroundStyle(Color(red: 0.6, green: 0.1, blue: 0.15))
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch action.status {
        case .ready:
            Image(systemName: "play.circle.fill").herdrFont(.caption)
        case .starting:
            ProgressView().controlSize(.small)
        case .started:
            Image(systemName: isStartedLinkAlive ? "arrow.up.right.square" : "link.slash")
                .herdrFont(.caption)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .herdrFont(.caption)
        }
    }

    private func tap() {
        switch action.status {
        case .ready, .failed:
            Task { await notes.runAction(action.id, in: note.id, model: model) }
        case .started:
            if let linkedNote, isStartedLinkAlive {
                HerdrMacAppDelegate.openPaneURLWithFallback(linkedNote.paneID)
            }
        case .starting:
            break
        }
    }
}

/// A compact wrapping layout keeps link chips readable without allowing the
/// note card's fixed frame to grow horizontally.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + size.width > width {
                cursorX = 0
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: cursorY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
