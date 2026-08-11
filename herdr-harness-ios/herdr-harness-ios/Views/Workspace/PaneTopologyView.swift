import SwiftUI

struct PaneTopologyView: View {
    let layout: HerdrLayout?
    var highlightedPaneID: String?

    var body: some View {
        Canvas { context, size in
            guard let layout, layout.area.width > 0, layout.area.height > 0 else {
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(HerdrTheme.muted.opacity(0.45)))
                return
            }

            let scaleX = size.width / Double(layout.area.width)
            let scaleY = size.height / Double(layout.area.height)
            for pane in layout.panes {
                let rect = CGRect(
                    x: Double(pane.rect.x - layout.area.x) * scaleX + 1.5,
                    y: Double(pane.rect.y - layout.area.y) * scaleY + 1.5,
                    width: max(2, Double(pane.rect.width) * scaleX - 3),
                    height: max(2, Double(pane.rect.height) * scaleY - 3)
                )
                let path = Path(roundedRect: rect, cornerRadius: 4)
                let isHighlighted = pane.paneID == highlightedPaneID || (highlightedPaneID == nil && pane.focused)
                context.fill(path, with: .color(isHighlighted ? HerdrTheme.accent.opacity(0.32) : HerdrTheme.mist.opacity(0.10)))
                context.stroke(
                    path,
                    with: .color(isHighlighted ? HerdrTheme.accent : HerdrTheme.mist.opacity(0.38)),
                    lineWidth: isHighlighted ? 1.5 : 1
                )
            }
        }
        .accessibilityHidden(true)
    }
}
