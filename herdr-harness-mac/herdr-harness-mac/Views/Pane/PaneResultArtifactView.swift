import SwiftUI

/// Results stay available in their chat after reading clears the HUD indicator.
struct PaneResultArtifactView: View {
    let model: HerdrAppModel
    let artifact: AgentResultArtifact

    private var phase: AgentResultArtifactPhase { model.resultArtifactPhase(id: artifact.id) }
    private var isBusy: Bool { phase == .opening || phase == .downloading }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: artifact.kind == .link ? "link" : "doc")
                            .foregroundStyle(HerdrTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(artifact.displayTitle)
                            .herdrFont(.body, weight: .semibold)
                            .lineLimit(2)
                        if let detail = artifact.url?.absoluteString ?? artifact.filename {
                            Text(detail)
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.mist)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(HerdrTheme.mist)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help("Open \(artifact.displayTitle)")
            .accessibilityIdentifier("pane-result-artifact-\(artifact.id)")

            if case let .failed(message) = phase {
                Text(message)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
            }
        }
    }

    private func open() {
        Task { await model.openResultArtifact(artifact) }
    }
}
