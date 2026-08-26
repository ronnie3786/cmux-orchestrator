import SwiftUI

struct SidebarWorkProviderHeader: View {
    let provider: WorkInboxProvider
    let count: Int
    let isExpanded: Bool
    let hasError: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .herdrFont(.caption, weight: .bold)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(HerdrTheme.mist)
                    .accessibilityHidden(true)

                Image(systemName: symbolName)
                    .foregroundStyle(tone)
                    .accessibilityHidden(true)

                Text(title)
                    .herdrFont(.subheadline, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)

                Spacer(minLength: 8)

                if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HerdrTheme.warning)
                        .accessibilityHidden(true)
                }

                Text("\(count)")
                    .herdrFont(.caption, monospaced: true, weight: .bold, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tone, in: .capsule)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-my-work-\(provider.rawValue)")
        .accessibilityLabel("\(accessibilityTitle), \(count)")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Shows or hides these work items")
    }

    private var title: String {
        switch provider {
        case .github: "github reviews"
        case .jira: "jira tickets"
        }
    }

    private var accessibilityTitle: String {
        switch provider {
        case .github: "GitHub review requests"
        case .jira: "Assigned Jira tickets"
        }
    }

    private var symbolName: String {
        switch provider {
        case .github: "arrow.triangle.pull"
        case .jira: "checkmark.square"
        }
    }

    private var tone: Color {
        switch provider {
        case .github: HerdrTheme.mauve
        case .jira: HerdrTheme.accent
        }
    }
}
