import SwiftUI

struct OpenCodeInteractionCardChrome: ViewModifier {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 13)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.075), Color.white.opacity(0.045)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(differentiateWithoutColor ? 0.24 : 0.11), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.24), radius: 8, y: 3)
    }
}

extension View {
    func openCodeInteractionCardChrome() -> some View {
        modifier(OpenCodeInteractionCardChrome())
    }
}
