import SwiftUI

struct OpenCodeTerminalFallbackCard: View {
    let interaction: OpenCodeTerminalInteraction
    let fallbackNote: String?
    let integrationStatus: OpenCodeIntegrationResponse?
    let isInstallingIntegration: Bool
    let sendKey: (HarnessKey) -> Void
    let installIntegration: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OpenCodeInteractionHeader(
                title: interaction.title,
                subtitle: "OpenCode terminal · Manual controls",
                systemImage: interaction.kind == .permission ? "hand.raised.fill" : "questionmark.bubble.fill"
            )

            if !interaction.detail.isEmpty {
                Text(interaction.detail)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !interaction.options.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Label("Choices", systemImage: "list.bullet")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(interaction.options.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Available choices: \(interaction.options.joined(separator: ", "))")
            }

            Text("Choose with Previous or Next, then confirm. cmux sends one key at a time and never assumes the current selection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let fallbackNote, !fallbackNote.isEmpty {
                Label(fallbackNote, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            integrationSetup

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        keyButton("Previous", key: previousKey, role: .neutral, fillsWidth: false, showsTitle: false)
                        keyButton("Next", key: nextKey, role: .neutral, fillsWidth: false, showsTitle: false)
                        Spacer(minLength: 0)
                    }
                    keyButton("Confirm", key: .enter, role: .primary)
                    keyButton(
                        interaction.kind == .permission ? "Reject" : "Dismiss",
                        key: .escape,
                        role: .destructive
                    )
                }
            } else {
                HStack(spacing: 6) {
                    keyButton("Previous", key: previousKey, role: .neutral, fillsWidth: false, showsTitle: false)
                    keyButton("Next", key: nextKey, role: .neutral, fillsWidth: false, showsTitle: false)
                    Spacer(minLength: 0)
                    keyButton("Confirm", key: .enter, role: .primary, fillsWidth: false)
                    keyButton(
                        interaction.kind == .permission ? "Reject" : "Dismiss",
                        key: .escape,
                        role: .destructive,
                        fillsWidth: false
                    )
                }
            }
        }
        .openCodeInteractionCardChrome()
        .accessibilitySortPriority(1)
        .accessibilityElement(children: .contain)
    }

    private var previousKey: HarnessKey {
        interaction.navigationAxis == .horizontal ? .left : .up
    }

    @ViewBuilder
    private var integrationSetup: some View {
        if integrationStatus?.installed == true {
            Label(
                integrationStatus?.needsRestart == true
                    ? "Native controls enabled. Restart OpenCode to activate them."
                    : "Native controls installed. Restart OpenCode if this prompt stays visible.",
                systemImage: "checkmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if integrationStatus?.cmuxAvailable == true {
            OpenCodeActionButton(
                title: isInstallingIntegration ? "Enabling native controls…" : "Enable native controls",
                systemImage: isInstallingIntegration ? "hourglass" : "sparkles",
                role: .attention,
                fillsWidth: false
            ) {
                installIntegration()
            }
            .disabled(isInstallingIntegration)
            .accessibilityHint("Installs the cmux OpenCode event bridge on your Mac. Restart active OpenCode sessions afterward.")
        } else if let summary = integrationStatus?.summary, !summary.isEmpty {
            Label(summary, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nextKey: HarnessKey {
        interaction.navigationAxis == .horizontal ? .right : .down
    }

    private func keyButton(
        _ label: String,
        key: HarnessKey,
        role: OpenCodeActionButton.Role,
        fillsWidth: Bool = true,
        showsTitle: Bool = true
    ) -> some View {
        OpenCodeActionButton(
            title: label,
            systemImage: key.systemImage,
            role: role,
            fillsWidth: fillsWidth,
            showsTitle: showsTitle
        ) {
            HarnessHaptics.inputCTA()
            sendKey(key)
        }
        .accessibilityHint("Sends the \(key.label) key to OpenCode")
    }
}
