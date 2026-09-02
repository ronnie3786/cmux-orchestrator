import SwiftUI

/// macOS chrome for the Pi chat surface.
///
/// AppKit's stock controls would punch straight through the flat Catppuccin
/// cards these views draw for themselves: `DisclosureGroup` puts a triangle on
/// the leading edge and indents the label away from the card's icon column,
/// `Menu` wraps the capsule chip in a bordered pull-down, and a plain `Button`
/// is an Aqua push button. Every Pi control opts into one of the styles below
/// so the iOS look survives the port. Behaviour, roles, animation and
/// accessibility identifiers are untouched — only the chrome is redrawn.
enum PiChatChrome {
    /// Mac replacement for the iOS 44pt touch target on Pi *controls*.
    /// Cards keep their iOS min-heights; only controls shrink.
    static let controlHeight = 30.0

    /// Hover cross-fade. Deliberately faster than `PiChatMotion.stateAnimation`
    /// so pointer feedback feels instant next to the chat's own motion.
    static let hoverAnimation = Animation.easeOut(duration: 0.12)
}

/// The collapsible card every Pi sub-output uses (thinking, tool calls,
/// working groups): a full-width header button with a trailing chevron, and
/// the content below it only while expanded.
///
/// This is deliberately NOT a `DisclosureGroup`. Measured on macOS 26 with the
/// offscreen probe (`HangReproTests.rowKindCosts`): 40 collapsed
/// `DisclosureGroup` cards took 12–21 s to lay out (300–500 ms each, growing
/// superlinearly with the count), while this plain stack of the same chrome
/// takes ~5 ms per card. A transcript holds a hundred of these, so the
/// difference is the whole main-thread budget.
///
/// The chevron rotation is animated by the caller's existing
/// `.animation(PiChatMotion.disclosureAnimation(…), value: isExpanded)`, so the
/// card adds no motion of its own beyond the hover cross-fade.
struct PiDisclosureCard<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PiDisclosureHeader(isExpanded: $isExpanded, label: label)

            if isExpanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PiDisclosureHeader<Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(.tint)
                    .opacity(isHovering ? 1 : 0.62)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PiChatChrome.hoverAnimation, value: isHovering)
    }
}

/// Flat Herdr stand-ins for `.bordered`, `.borderedProminent` and the default
/// macOS push button, with pointer hover and press feedback.
struct PiChatButtonStyle: ButtonStyle {
    enum Emphasis {
        /// Tinted wash + hairline, matching iOS `.bordered` with a tint.
        case soft
        /// Solid tint with ink text, matching iOS `.borderedProminent`.
        case prominent
        /// Bare label — the caller owns padding and background.
        case text
    }

    var tint: Color = HerdrTheme.accent
    var emphasis: Emphasis = .soft

    func makeBody(configuration: Configuration) -> some View {
        PiChatButtonBody(configuration: configuration, tint: tint, emphasis: emphasis)
    }
}

private struct PiChatButtonBody: View {
    let configuration: PiChatButtonStyle.Configuration
    let tint: Color
    let emphasis: PiChatButtonStyle.Emphasis
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, emphasis == .text ? 0 : 14)
            .padding(.vertical, emphasis == .text ? 0 : 7)
            .frame(minHeight: PiChatChrome.controlHeight)
            .background(fill, in: shape)
            .overlay { shape.stroke(stroke, lineWidth: 1) }
            .contentShape(shape)
            .opacity(opacity)
            .onHover { isHovering = $0 }
            .animation(PiChatChrome.hoverAnimation, value: isHovering)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
    }

    private var foreground: Color {
        switch emphasis {
        case .soft, .text: tint
        case .prominent: HerdrTheme.ink
        }
    }

    private var fill: Color {
        switch emphasis {
        case .soft: tint.opacity(isHovering && isEnabled ? 0.24 : 0.16)
        case .prominent: tint.opacity(isHovering && isEnabled ? 1 : 0.9)
        case .text: .clear
        }
    }

    private var stroke: Color {
        switch emphasis {
        case .soft: tint.opacity(0.34)
        case .prominent, .text: .clear
        }
    }

    private var opacity: Double {
        guard isEnabled else { return 0.42 }
        if configuration.isPressed { return 0.7 }
        return emphasis == .text && !isHovering ? 0.84 : 1
    }
}

extension View {
    /// Keeps a `Menu` looking like the flat Herdr capsule chip. Without this,
    /// macOS wraps the label in a bordered pull-down button and adds a second
    /// indicator next to the chip's own `chevron.up.chevron.down`.
    func piChipMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}
