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
                HerdrNoteCompactStackView(notes: notes, count: count, openNote: controller.openNote)
                    .transition(fadeTransition)
            case .rows:
                HerdrNoteRowsView(model: model, controller: controller, notes: notes)
                    .transition(fadeTransition)
            case .card:
                if let noteID = notes.openNoteID {
                    HerdrNoteCardView(model: model, controller: controller, notes: notes, noteID: noteID)
                        .transition(cardTransition)
                }
            }
        }
    }

    /// Attach animation to each transition instead of the enclosing ZStack.
    /// A container-level animation also interpolates the stack's changing size
    /// and placement, which makes an opacity transition visibly slide.
    private var fadeTransition: AnyTransition {
        AnyTransition.opacity.animation(transitionAnimation)
    }

    private var cardTransition: AnyTransition {
        AnyTransition
            .scale(scale: 0.92, anchor: .topTrailing)
            .combined(with: .opacity)
            .animation(transitionAnimation)
    }

    private var transitionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.18)
    }
}
