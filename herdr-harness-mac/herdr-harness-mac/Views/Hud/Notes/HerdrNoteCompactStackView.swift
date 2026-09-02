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

    var body: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.noteCompactBarSpacing) {
            ForEach(Array(notes.notes.prefix(min(count, HerdrHudPlacement.maxCompactNotes)))) { note in
                Text(note.displayTitle)
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(note.color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9)
                    .frame(
                        width: HerdrHudPlacement.chipWidth,
                        height: HerdrHudPlacement.noteCompactBarHeight,
                        alignment: .leading
                    )
                    .background(note.color.fill, in: .capsule)
                    .shadow(color: HerdrTheme.ink.opacity(0.3), radius: 2, y: 1)
                    .accessibilityLabel(note.displayTitle)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) notes")
    }
}
