import SwiftUI

/// The on-screen key strip.
///
/// A Mac has a real keyboard — `TerminalKeyboardRouter` sends these same wire
/// names when the terminal is focused. The deck stays anyway: it is the only
/// place these keys are *discoverable*, and it works while focus is in the
/// composer. Mac-sized (26 pt rows, hover feedback) instead of touch-sized.
struct TerminalKeyDeck: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let isExpanded: Bool
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var hoveredKey: TerminalPresetKey?

    var body: some View {
        VStack(spacing: 7) {
            keyRow(TerminalPresetKey.primaryRow)

            if isExpanded {
                keyRow(TerminalPresetKey.secondaryRow)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: isExpanded) { _, isExpanded in
            hapticPulse.fire(isExpanded ? .controlsExpanded : .controlsCollapsed)
        }
        .herdrHaptic(trigger: hapticPulse)
    }

    private func keyRow(_ keys: [TerminalPresetKey]) -> some View {
        HStack(spacing: 7) {
            ForEach(keys) { key in
                Button {
                    hapticPulse.fire(.terminalKey)
                    Task { await model.sendKeys([key.rawValue], to: pane) }
                } label: {
                    Label(key.label, systemImage: key.systemImage)
                        .font(.caption.monospaced().bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, minHeight: 26)
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
        }
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
