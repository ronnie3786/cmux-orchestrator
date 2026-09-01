import SwiftUI

struct HerdPulseSessionRow: View {
    let session: HerdPulseAttributes.ContentState.Session

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(HerdPulseTheme.color(for: session.state))
                .frame(width: 6, height: 6)
            Text(session.title)
                .font(.caption.monospaced().bold())
                .foregroundStyle(HerdPulseTheme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(session.agent.isEmpty ? stateWord : "\(session.agent) · \(stateWord)")
                .font(.caption.monospaced())
                .foregroundStyle(HerdPulseTheme.mist)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var stateWord: String {
        switch session.state {
        case .blocked: "needs you"
        case .done: "ready"
        case .working: "working"
        }
    }
}
