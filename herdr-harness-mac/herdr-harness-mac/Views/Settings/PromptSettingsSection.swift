import SwiftUI

struct PromptSettingsSectionView: View {
    let promptSettings: HerdrPromptSettingsStore

    var body: some View {
        let _ = promptSettings.revision

        Section {
            ForEach(HerdrPromptID.allCases) { id in
                let currentText = promptSettings.hasOverride(id)
                    ? (promptSettings.storedOverrideText(for: id) ?? "")
                    : promptSettings.text(for: id)

                DisclosureGroup {
                    Text(id.summary)
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)

                    TextEditor(text: Binding(
                        get: { currentText },
                        set: { promptSettings.setText($0, for: id) }
                    ))
                    .herdrFont(.caption, monospaced: true)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .background(
                        HerdrTheme.elevated,
                        in: .rect(cornerRadius: HerdrTheme.compactRadius)
                    )

                    if currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Empty — the default is used until you type.")
                            .herdrFont(.caption2)
                            .foregroundStyle(HerdrTheme.muted)
                    }

                    HStack {
                        if id.isHarnessBacked && promptSettings.harnessSupportsOverrides == false {
                            Label(
                                "This machine's harness can't accept custom instructions yet",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.warning)
                        }

                        Spacer()

                        Button("Reset to default") {
                            promptSettings.reset(id)
                        }
                        .disabled(!promptSettings.hasOverride(id))
                        .accessibilityIdentifier("settings-prompt-reset-\(id.rawValue)")
                    }
                } label: {
                    HStack {
                        Text(id.title)

                        if promptSettings.isCustomized(id) {
                            Text("custom")
                                .herdrFont(.caption2, monospaced: true)
                                .padding(.horizontal, 6)
                                .background(HerdrTheme.accent.opacity(0.25), in: .capsule)
                                .foregroundStyle(HerdrTheme.accent)
                        }

                        if id.isHarnessBacked {
                            Text("harness")
                                .herdrFont(.caption2, monospaced: true)
                                .padding(.horizontal, 6)
                                .background(HerdrTheme.muted.opacity(0.2), in: .capsule)
                                .foregroundStyle(HerdrTheme.muted)
                        }

                        Spacer()
                    }
                }
                .accessibilityIdentifier("settings-prompt-\(id.rawValue)")
            }
        } header: {
            Text("Prompts")
        } footer: {
            Text("These are the exact instructions Herdr sends to Pi. Edit them here to tune behaviour without a new build; Reset restores the built-in text. {{note}} and {{action}} are filled in when a prompt runs. Rows marked ‘harness’ apply on machines running an updated harness.")
        }
    }
}
