import SwiftUI

struct PiConnectionBanner: View {
    let connection: PiConversationConnection
    let message: String?

    var body: some View {
        if let content {
            HStack(spacing: 9) {
                if content.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(content.tint)
                } else {
                    Image(systemName: content.symbol)
                        .foregroundStyle(content.tint)
                }
                Text(message ?? content.text)
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(content.tint.opacity(0.09))
            .accessibilityElement(children: .combine)
        }
    }

    private var content: PiConnectionBannerContent? {
        if connection == .connected, let message, !message.isEmpty {
            return PiConnectionBannerContent(
                text: message,
                symbol: "exclamationmark.triangle.fill",
                tint: HerdrTheme.alert,
                showsProgress: false
            )
        }
        switch connection {
        case .loading:
            return PiConnectionBannerContent(text: "Loading native transcript…", symbol: "arrow.triangle.2.circlepath", tint: HerdrTheme.accent, showsProgress: true)
        case .connected:
            return nil
        case .bridgeOffline:
            return PiConnectionBannerContent(text: "Pi is offline. Transcript preserved.", symbol: "bolt.slash", tint: HerdrTheme.warning, showsProgress: false)
        case .reconnecting:
            return PiConnectionBannerContent(text: "Reconnecting to Pi…", symbol: "wifi.exclamationmark", tint: HerdrTheme.warning, showsProgress: true)
        case .unavailable:
            return PiConnectionBannerContent(text: "Native transcript unavailable", symbol: "terminal", tint: HerdrTheme.warning, showsProgress: false)
        }
    }
}
