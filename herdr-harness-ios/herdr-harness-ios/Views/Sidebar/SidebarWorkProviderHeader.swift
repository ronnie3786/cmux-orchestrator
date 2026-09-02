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
                    .font(.caption2.bold())
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)
                    .foregroundStyle(HerdrTheme.mist)
                    .accessibilityHidden(true)

                Image(systemName: symbolName)
                    .font(.caption)
                    .foregroundStyle(tone)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(HerdrTheme.text)

                Spacer(minLength: 8)

                if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.warning)
                        .accessibilityHidden(true)
                }

                Text("\(count)")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(HerdrTheme.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tone, in: Capsule())
            }
            .padding(.horizontal, 9)
            // The Mac's 32pt row is a pointer target; touch needs 44.
            .frame(minHeight: 44)
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
