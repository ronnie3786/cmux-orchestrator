import SwiftUI

struct HerdrHudInlineResultArtifactsView: View {
    let model: HerdrAppModel
    let exchange: HerdrHudExchange

    private var artifacts: [AgentResultArtifact] {
        model.resultArtifacts.filter {
            $0.machineID == exchange.machineID && $0.originType == .agentRun && $0.originID == exchange.id
        }
    }

    var body: some View {
        ForEach(artifacts) { artifact in
            Button {
                Task { await model.openResultArtifact(artifact) }
            } label: {
                Label(artifact.displayTitle, systemImage: artifact.kind == .link ? "link" : "doc")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.accent)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open result: \(artifact.displayTitle)")
            .onAppear { model.dismissResultArtifact(artifact) }
        }
    }
}
