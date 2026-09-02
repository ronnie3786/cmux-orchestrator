import SwiftUI

struct WorkspaceSearchField: View {
    @Binding var text: String
    var placeholder: String = "filter spaces"
    /// Defaults to the workspace wording so every existing call site keeps
    /// its current VoiceOver label; Fleet passes its own.
    var accessibilityLabel: String = "Filter spaces"
    /// Spelled out rather than derived from `accessibilityLabel`: composing it
    /// produced "Clear filter spaces".
    var clearAccessibilityLabel: String = "Clear workspace filter"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isFocused ? HerdrTheme.accent : HerdrTheme.mist)

            TextField(placeholder, text: $text)
                .font(.body.monospaced())
                .foregroundStyle(HerdrTheme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.done)
                .accessibilityLabel(accessibilityLabel)

            if !text.isEmpty {
                Button(clearAccessibilityLabel, systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(HerdrTheme.mist)
                .frame(minWidth: 44, minHeight: 44)
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
