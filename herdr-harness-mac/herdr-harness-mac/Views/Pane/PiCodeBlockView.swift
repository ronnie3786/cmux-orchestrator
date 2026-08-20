import AppKit
import SwiftUI

struct PiCodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false
    @State private var isHovering = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((language ?? "code").lowercased())
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(HerdrTheme.code.opacity(0.75))
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyCode()
                    copied = true
                    hapticPulse.fire(.completed)
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                }
                .herdrFont(.caption)
                .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.accent)
                .buttonStyle(.plain)
                .frame(minHeight: 22)
                .opacity(isHovering || copied ? 1 : 0)
                .animation(PiChatChrome.hoverAnimation, value: isHovering)
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
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
        .onHover { isHovering = $0 }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}
