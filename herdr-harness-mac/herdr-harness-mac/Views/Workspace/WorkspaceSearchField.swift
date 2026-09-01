import SwiftUI

struct WorkspaceSearchField: View {
    @Binding var text: String
    var placeholder: String = "filter spaces"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isFocused ? HerdrTheme.accent : HerdrTheme.mist)

            TextField(placeholder, text: $text)
                // Plain style, or AppKit draws its own bezel inside our chrome.
                .textFieldStyle(.plain)
                .herdrFont(.body)
                .foregroundStyle(HerdrTheme.text)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.done)
                .accessibilityLabel("Filter spaces")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .herdrHitTarget(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mist)
                .help("Clear filter")
                .accessibilityLabel("Clear workspace filter")
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, text.isEmpty ? 13 : 3)
        .frame(minHeight: 48)
        .background(HerdrTheme.graphite)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(isFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }
}
