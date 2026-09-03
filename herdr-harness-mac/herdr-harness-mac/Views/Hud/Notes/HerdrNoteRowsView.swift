import SwiftUI

struct HerdrNoteRowsView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let notes: HerdrHudNotesState

    private var rowCapacity: Int {
        HerdrHudPlacement.maxNoteRows(isExpanded: notes.isHudExpanded)
    }

    private var scrollHeight: CGFloat {
        let count = CGFloat(visibleRowCount)
        return count * HerdrHudPlacement.noteRowHeight
            + CGFloat(max(visibleRowCount - 1, 0)) * HerdrHudPlacement.noteRowSpacing
    }

    private var visibleRowCount: Int {
        min(notes.notes.count, rowCapacity)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.noteRowSpacing) {
            Button {
                controller.openNote(notes.createNote())
            } label: {
                Label("New note", systemImage: "plus")
                    .herdrFont(.caption2, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.crust)
                    .frame(width: HerdrHudPlacement.notesWidth, height: HerdrHudPlacement.noteCtaHeight)
                    .herdrHitTarget(
                        minWidth: HerdrHudPlacement.notesWidth,
                        minHeight: HerdrHudPlacement.noteCtaHeight
                    )
                    .background(HerdrNoteColor.yellow.fill, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hud-note-new")

            if visibleRowCount > 0 {
                rowsScrollView
            }
        }
    }

    @ViewBuilder
    private var rowsScrollView: some View {
        let scroll = ScrollView(.vertical) {
            LazyVStack(spacing: HerdrHudPlacement.noteRowSpacing) {
                ForEach(notes.notes) { note in
                    HerdrNoteRowView(model: model, controller: controller, notes: notes, note: note)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(width: HerdrHudPlacement.notesWidth, height: scrollHeight)

        if notes.notes.count > rowCapacity {
            scroll.mask {
                VStack(spacing: 0) {
                    Rectangle().fill(.white)
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                }
            }
        } else {
            scroll
        }
    }
}

struct HerdrNoteRowView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let notes: HerdrHudNotesState
    let note: HerdrNote

    var body: some View {
        Button {
            controller.openNote(note.id)
        } label: {
            HStack(spacing: 8) {
                Text(note.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(note.color.ink)
                Spacer(minLength: 0)
                trailingIndicator
            }
            .padding(.horizontal, 12)
            .frame(width: HerdrHudPlacement.notesWidth, height: HerdrHudPlacement.noteRowHeight)
            .herdrHitTarget(
                minWidth: HerdrHudPlacement.notesWidth,
                minHeight: HerdrHudPlacement.noteRowHeight
            )
            .background(note.color.fill, in: .capsule)
            .shadow(color: HerdrTheme.ink.opacity(0.3), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Color") {
                ForEach(HerdrNoteColor.allCases) { color in
                    Button {
                        notes.setColor(color, for: note.id)
                    } label: {
                        Label {
                            Text(color.label)
                        } icon: {
                            Circle().fill(color.fill).frame(width: 10, height: 10)
                        }
                    }
                }
            }
            Button("Delete note", systemImage: "trash", role: .destructive) {
                notes.deleteNote(note.id)
            }
        }
        .accessibilityIdentifier("hud-note-row-\(note.id)")
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if notes.isBusy(note.id) {
            ProgressView()
                .controlSize(.small)
                .tint(note.color.ink)
        } else if !note.links.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "link")
                Text("\(note.links.count)")
            }
            .herdrFont(.caption2, monospaced: true, weight: .semibold)
            .foregroundStyle(note.color.ink.opacity(0.7))
        } else if note.actions.contains(where: { $0.status == .ready }) {
            Image(systemName: "bolt.fill")
                .herdrFont(.caption)
                .foregroundStyle(note.color.ink)
        }
    }
}
