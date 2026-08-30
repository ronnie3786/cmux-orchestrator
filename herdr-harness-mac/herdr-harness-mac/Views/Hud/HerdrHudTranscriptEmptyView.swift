import SwiftUI

struct HerdrHudTranscriptEmptyView: View {
    let errorMessage: String?
    let promoteErrorMessage: String?
    let audioErrorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .herdrFont(.title2)
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityHidden(true)
            Text("Ask anything, anywhere")
                .herdrFont(.headline, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
            Text("⌥Space summons the HUD · Do mode runs real commands")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .multilineTextAlignment(.center)
            Spacer()
            HerdrHudTranscriptErrorsView(
                errorMessage: errorMessage,
                promoteErrorMessage: promoteErrorMessage,
                audioErrorMessage: audioErrorMessage
            )
        }
        .padding(HerdrTheme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
