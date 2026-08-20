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
                Text(language?.uppercased() ?? "CODE")
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(HerdrTheme.muted)
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
            .padding(.vertical, 8)
            .background(HerdrTheme.elevated.opacity(0.52))

            ScrollView(.horizontal) {
                Text(code)
                    .herdrFont(.callout, monospaced: true)
                    .foregroundStyle(HerdrTheme.text)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .scrollIndicators(.visible)
        }
        .background(HerdrTheme.ink.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(HerdrTheme.surface.opacity(0.72), lineWidth: 1)
        }
        .herdrHaptic(trigger: hapticPulse)
        .onHover { isHovering = $0 }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}
