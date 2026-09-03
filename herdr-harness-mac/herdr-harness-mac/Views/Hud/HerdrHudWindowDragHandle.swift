import AppKit
import SwiftUI

@MainActor
final class HerdrHudDragHandleView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else {
            onDragBegan?()
            window?.performDrag(with: event)
            onDragEnded?()
            return
        }
        guard let window else {
            onClick()
            return
        }

        let mouseDownLocation = window.convertPoint(toScreen: event.locationInWindow)
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self] trackedEvent, stop in
            guard let self else {
                stop.pointee = true
                return
            }
            guard let trackedEvent else {
                stop.pointee = true
                return
            }
            switch trackedEvent.type {
            case .leftMouseDragged:
                let location = window.convertPoint(toScreen: trackedEvent.locationInWindow)
                let distance = hypot(location.x - mouseDownLocation.x, location.y - mouseDownLocation.y)
                guard distance > 4 else { return }
                stop.pointee = true
                self.onDragBegan?()
                window.performDrag(with: event)
                self.onDragEnded?()
            case .leftMouseUp:
                stop.pointee = true
                self.onClick?()
            default:
                break
            }
        }
    }
}

@MainActor
struct HerdrHudWindowDragHandle: NSViewRepresentable {
    var onDragBegan: (() -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    var onClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> HerdrHudDragHandleView {
        HerdrHudDragHandleView()
    }

    func updateNSView(_ view: HerdrHudDragHandleView, context: Context) {
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.onClick = onClick
    }
}
