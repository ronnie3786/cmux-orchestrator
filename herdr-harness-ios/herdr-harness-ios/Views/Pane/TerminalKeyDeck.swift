import SwiftUI

struct TerminalKeyDeck: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let isExpanded: Bool

    var body: some View {
        VStack(spacing: 7) {
            keyRow(TerminalPresetKey.primaryRow)

            if isExpanded {
                keyRow(TerminalPresetKey.secondaryRow)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func keyRow(_ keys: [TerminalPresetKey]) -> some View {
        HStack(spacing: 7) {
            ForEach(keys) { key in
                Button {
                    Task { await model.sendKeys([key.rawValue], to: pane) }
                } label: {
                    Label(key.label, systemImage: key.systemImage)
                        .font(.caption.monospaced().bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .foregroundStyle(HerdrTheme.text)
                .background(HerdrTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .buttonStyle(.plain)
                .disabled(!model.canControl)
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
