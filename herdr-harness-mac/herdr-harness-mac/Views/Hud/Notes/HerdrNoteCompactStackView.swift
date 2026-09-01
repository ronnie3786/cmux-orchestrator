import SwiftUI

struct HerdrNoteCompactStackView: View {
    let notes: HerdrHudNotesState
    let count: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.noteCompactBarSpacing) {
            ForEach(Array(notes.notes.prefix(min(count, HerdrHudPlacement.maxCompactNotes)))) { note in
                Capsule()
                    .fill(note.color.fill)
                    .frame(
                        width: HerdrHudPlacement.chipWidth,
                        height: HerdrHudPlacement.noteCompactBarHeight
                    )
                    .shadow(color: HerdrTheme.ink.opacity(0.3), radius: 2, y: 1)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("\(count) notes")
    }
}
