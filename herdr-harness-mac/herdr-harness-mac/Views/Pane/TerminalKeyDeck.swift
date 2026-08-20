import SwiftUI

/// Shared metrics for the composer's tool row, so the auxiliary controls and
/// the key deck sitting next to them line up to the pixel.
enum ComposerDeckMetrics {
    static let controlHeight: CGFloat = 30
    static let spacing: CGFloat = 7
}

/// The on-screen key strip.
///
/// A Mac has a real keyboard — `TerminalKeyboardRouter` sends these same wire
/// names when the terminal is focused. The deck stays anyway: it is the only
/// place these keys are *discoverable*, and it works while focus is in the
/// composer, which is exactly when you cannot reach the terminal's own key
/// routing.
///
/// Mac layout: one row, not two. The composer no longer hides half these keys
/// behind a latch, so the caller passes whichever keys fit and pushes the rest
/// into `overflow`, where they become a compact menu.
struct TerminalKeyDeck: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    /// Keys drawn as buttons, left to right.
    var keys: [TerminalPresetKey] = TerminalPresetKey.deckRow
    /// Keys folded into the trailing overflow menu when the row is too narrow
    /// to draw them all. Empty in every window wide enough to avoid it.
    var overflow: [TerminalPresetKey] = []
    /// Icon-only keys are the first thing to give when space runs out; the
    /// label lives on in the tooltip and the accessibility label.
    var showsLabels = true

    @State private var hapticPulse = HerdrHapticPulse()
    @State private var hoveredKey: TerminalPresetKey?

    var body: some View {
        HStack(spacing: ComposerDeckMetrics.spacing) {
            ForEach(keys) { key in
                keyButton(key)
            }

            if !overflow.isEmpty {
                overflowMenu
            }
        }
        .accessibilityElement(children: .contain)
        .herdrHaptic(trigger: hapticPulse)
    }

    private func keyButton(_ key: TerminalPresetKey) -> some View {
        Button {
            send(key)
        } label: {
            Group {
                if showsLabels {
                    Label(key.label, systemImage: key.systemImage)
                } else {
                    Image(systemName: key.systemImage)
                }
            }
            .herdrFont(.caption, monospaced: true, weight: .bold)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity, minHeight: ComposerDeckMetrics.controlHeight)
            .padding(.horizontal, showsLabels ? 6 : 10)
            .contentShape(.rect)
        }
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(
                    hoveredKey == key ? HerdrTheme.accent.opacity(0.5) : HerdrTheme.surface,
                    lineWidth: 1
                )
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .buttonStyle(.plain)
        .disabled(!model.canControl)
        .onHover { isHovering in
            if isHovering {
                hoveredKey = key
            } else if hoveredKey == key {
                hoveredKey = nil
            }
        }
        .help("Send \(key.label) to this pane")
        .accessibilityLabel("Send \(key.label) key")
        .accessibilityInputLabels([key.label, "\(key.label) key"])
        .accessibilityIdentifier("terminal-key-\(key.rawValue)")
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(overflow) { key in
                Button {
                    send(key)
                } label: {
                    Label(key.label, systemImage: key.systemImage)
                }
                .accessibilityIdentifier("terminal-key-\(key.rawValue)")
            }
        } label: {
            Image(systemName: "ellipsis")
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .frame(minWidth: 26, minHeight: ComposerDeckMetrics.controlHeight)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .disabled(!model.canControl)
        .help("More keys")
        .accessibilityLabel("More terminal keys")
        .accessibilityIdentifier("terminal-key-overflow")
    }

    private func send(_ key: TerminalPresetKey) {
        hapticPulse.fire(.terminalKey)
        Task { await model.sendKeys([key.rawValue], to: pane) }
    }
}

enum TerminalPresetKey: String, CaseIterable, Identifiable, Sendable {
    case up
    case down
    case tab
    case enter
    case left
    case right
    case escape
    case backspace

    var id: String { rawValue }

    /// The full single-row deck, in reach order.
    static let deckRow: [Self] = allCases
    /// The four keys that survive in the narrowest window; the rest overflow.
    static let primaryRow: [Self] = [.up, .down, .tab, .enter]
    static let secondaryRow: [Self] = [.left, .right, .escape, .backspace]

    var label: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .tab: "Tab"
        case .enter: "Enter"
        case .left: "Left"
        case .right: "Right"
        case .escape: "Esc"
        case .backspace: "Bkspc"
        }
    }

    var systemImage: String {
        switch self {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .tab: "arrow.right.to.line"
        case .enter: "return"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .escape: "x.square"
        case .backspace: "delete.left"
        }
    }
}
