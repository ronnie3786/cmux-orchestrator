import SwiftUI

struct HerdrHudNotesStripView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let notes: HerdrHudNotesState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch notes.layout {
            case .hidden:
                EmptyView()
            case let .compact(count):
                HerdrNoteCompactStackView(notes: notes, count: count)
                    .transition(.opacity)
            case .rows:
                HerdrNoteRowsView(model: model, controller: controller, notes: notes)
                    .transition(.opacity)
            case .card:
                if let noteID = notes.openNoteID {
                    HerdrNoteCardView(model: model, controller: controller, notes: notes, noteID: noteID)
                        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: notes.layout)
    }
}
