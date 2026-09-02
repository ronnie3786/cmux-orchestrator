import SwiftUI

/// The collapsible card every Pi sub-output uses (thinking, tool calls,
/// working groups): a full-width header button with a trailing chevron, and
/// the content below it only while expanded.
///
/// This is deliberately NOT a `DisclosureGroup`. Measured on the Mac twin with
/// an offscreen layout probe: 40 collapsed `DisclosureGroup` cards took 12–21 s
/// to lay out (300–500 ms each, growing superlinearly with the count), while
/// this plain stack of the same chrome takes ~5 ms per card. A transcript holds
/// a hundred of these, so the difference is the whole main-thread budget.
///
/// Unlike the Mac twin, the card's inset lives INSIDE the header button: on
/// touch, a padding band that looks like part of the card but swallows taps is
/// a trap, so the whole drawn card face is one 44pt hit target. Callers supply
/// the background and nothing else.
///
/// The chevron rotation is animated by the caller's existing
/// `.animation(PiChatMotion.disclosureAnimation(…), value: isExpanded)`; the
/// card adds no motion of its own. The chevron colour is passed in rather than
/// read from `.tint`: with a hundred cards mounted, per-card tint resolution
/// was a measurable slice of every layout pass.
struct PiDisclosureCard<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    let chevronColor: Color
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    /// Card inset. `static` on purpose: a `private` *stored* property would
    /// drop the memberwise initialiser to `private` and break every call site.
    private static var horizontalInset: CGFloat { 12 }
    private static var verticalInset: CGFloat { 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    label()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(chevronColor.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Self.horizontalInset)
                .padding(.vertical, Self.verticalInset)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // `DisclosureGroup` published the expanded state to VoiceOver for
            // free; a plain button does not, so say it out loud.
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.bottom, Self.verticalInset)
            }
        }
    }
}
