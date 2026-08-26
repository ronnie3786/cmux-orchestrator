import SwiftUI

struct SidebarReviewRequestRow: View {
    let request: GitHubReviewRequest
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        Button(action: openRequest) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(request.repository)
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.mauve)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("#\(request.number)")
                        .herdrFont(.caption, monospaced: true, weight: .bold, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.mist)
                }

                Text(request.title)
                    .herdrFont(.subheadline)
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
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(isHovering ? HerdrTheme.elevated.opacity(0.68) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(HerdrTheme.mauve)
                    .frame(width: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(request.browserURL == nil)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("sidebar-github-review-\(request.number)")
        .help("Open \(request.repository) pull request #\(request.number) on GitHub")
        .accessibilityLabel(
            "GitHub pull request \(request.number), \(request.title), "
                + "\(request.repository), by \(request.author)"
        )
    }

    private func openRequest() {
        guard let url = request.browserURL else { return }
        openURL(url)
    }
}
