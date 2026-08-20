import SwiftUI

struct PiCodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((language ?? "code").lowercased())
                    .font(.caption.weight(.bold))
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
                .font(.caption)
                .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.accent)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
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
                    .font(.system(size: 13, design: .monospaced))
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
        UIPasteboard.general.string = code
    }
}
