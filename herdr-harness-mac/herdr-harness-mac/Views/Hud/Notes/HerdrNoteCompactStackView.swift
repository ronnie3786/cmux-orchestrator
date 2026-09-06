import SwiftUI

/// The collapsed notes stack: one row per note, carrying its title.
///
/// The bars used to be blank color capsules — enough to say "there are notes",
/// not enough to say *which*. Each row is a single line with trailing
/// truncation so the stack keeps its fixed width and predictable height, which
/// is what `HerdrHudPlacement.notesContentSize` sizes the panel from.
struct HerdrNoteCompactStackView: View {
    let notes: HerdrHudNotesState
    let count: Int
    var openNote: (UUID) -> Void = { _ in }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .trailing, spacing: HerdrHudPlacement.noteCompactBarSpacing) {
                ForEach(notes.notes) { note in
                    Button { openNote(note.id) } label: {
                        Text(note.displayTitle)
                        .herdrFont(.caption2, weight: .semibold)
                        .foregroundStyle(note.color.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 9)
                        .frame(
                            width: HerdrHudPlacement.noteCompactWidth,
                            height: HerdrHudPlacement.noteCompactBarHeight,
                            alignment: .leading
                        )
                        .background(note.color.fill, in: .capsule)
                        .shadow(color: HerdrTheme.ink.opacity(0.3), radius: 2, y: 1)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open note: \(note.displayTitle)")
                    .accessibilityIdentifier("hud-note-compact-\(note.id)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(
            width: HerdrHudPlacement.noteCompactWidth,
            height: HerdrHudPlacement.notesContentSize(.compact(count: count), isExpanded: false).height
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) notes")
    }
}
