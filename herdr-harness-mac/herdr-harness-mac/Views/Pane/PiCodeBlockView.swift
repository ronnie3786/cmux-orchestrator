import AppKit
import SwiftUI

struct PiCodeBlockView: View {
    let language: String?
    let code: String
    /// Composed into the copy control's identifier. `PiMarkdownBlock.id` is only
    /// the block's index within its own message, so it collides across the
    /// timeline without the owning message's id.
    var ownerID: String = ""
    var blockID: Int = 0
    @State private var copied = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((language ?? "code").lowercased())
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(HerdrTheme.code.opacity(0.75))
                Spacer()
                Button {
                    copyCode()
                    copied = true
                    hapticPulse.fire(.completed)
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .herdrHitTarget(minWidth: 0)
                }
                .herdrFont(.caption)
                .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.accent)
                .buttonStyle(.plain)
                // Was hidden until hover, which made it read as missing. It now
                // rests at a low opacity — which also drops one tracking area
                // per code block from the timeline.
                .opacity(copied ? 1 : 0.55)
                .animation(PiChatChrome.hoverAnimation, value: copied)
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
                .accessibilityIdentifier("pi-code-copy-\(ownerID)-\(blockID)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(HerdrTheme.ink.opacity(0.85))

            Rectangle()
                .fill(HerdrTheme.surface.opacity(0.5))
                .frame(height: 1)

            ScrollView(.horizontal) {
                Text(code)
                    .herdrFont(size: 13, monospaced: true)
                    .foregroundStyle(HerdrTheme.text)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(12)
            }
            .scrollIndicators(.visible)
        }
        .background(HerdrTheme.crust, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(HerdrTheme.surface.opacity(0.5), lineWidth: 1)
        }
        .herdrHaptic(trigger: hapticPulse)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}
