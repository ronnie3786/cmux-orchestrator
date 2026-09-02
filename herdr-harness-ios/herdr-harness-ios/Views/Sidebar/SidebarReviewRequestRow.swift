import SwiftUI

struct SidebarReviewRequestRow: View {
    let request: GitHubReviewRequest
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: openRequest) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(request.repository)
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(HerdrTheme.mauve)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("#\(request.number)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(HerdrTheme.mist)
                }

                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Label(request.author, systemImage: "person")
                        .labelStyle(.titleAndIcon)
                    if request.isDraft {
                        Text("draft")
                            .foregroundStyle(HerdrTheme.warning)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(HerdrTheme.muted)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(HerdrTheme.mauve)
                    .frame(width: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(request.browserURL == nil)
        .accessibilityIdentifier("sidebar-github-review-\(request.number)")
        .accessibilityLabel(
            "GitHub pull request \(request.number), \(request.title), "
                + "\(request.repository), by \(request.author)"
        )
        // The Mac says this in a `.help` tooltip. There is no pointer here, so
        // the hint is the only place the destination can be stated.
        .accessibilityHint("Opens the pull request in your browser")
    }

    private func openRequest() {
        guard let url = request.browserURL else { return }
        openURL(url)
    }
}
