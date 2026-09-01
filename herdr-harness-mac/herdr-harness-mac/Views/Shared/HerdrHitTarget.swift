import SwiftUI

extension View {
    /// Guarantees a pointer target of at least `HerdrTheme.minHitTarget` on a
    /// side and makes the whole rectangle clickable.
    ///
    /// Apply INSIDE a `Button`/`Menu` label, never to the button itself: with
    /// `.buttonStyle(.plain)` the interactive region is the label's own bounds,
    /// so a frame added from the outside only centres a 10pt chevron inside 28pt
    /// of dead space. Order matters — `contentShape` must follow `frame`, which
    /// is why this exists rather than the two modifiers hand-rolled per site.
    func herdrHitTarget(
        minWidth: CGFloat = HerdrTheme.minHitTarget,
        minHeight: CGFloat = HerdrTheme.minHitTarget
    ) -> some View {
        frame(minWidth: minWidth, minHeight: minHeight)
            .contentShape(Rectangle())
    }
}
