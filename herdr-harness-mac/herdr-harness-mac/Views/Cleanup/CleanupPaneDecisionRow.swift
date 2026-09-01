import SwiftUI

struct CleanupPaneDecisionRow: View {
    let pane: CleanupPaneReport
    let isSelected: Bool
    let isIncludedByWorkspace: Bool
    let toggleSelection: () -> Void
    @State private var isShowingDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(decisionTone)
                .frame(width: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    selectionControl
                    Label(decisionLabel, systemImage: decisionSymbol)
                        .herdrFont(.caption, weight: .bold)
                        .foregroundStyle(decisionTone)
                    Label(pane.classification.label, systemImage: pane.classification.symbol)
                        .herdrFont(.caption, weight: .semibold)
                        .foregroundStyle(pane.classification.color)
                        .help(pane.classification.tooltip)
                    Text(pane.title ?? pane.paneID)
                        .herdrFont(.subheadline, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(2)
                        .help(pane.title ?? pane.paneID)
                    Spacer(minLength: 8)
                    if pane.piSession?.active == true {
                        Label("Active Pi", systemImage: "bolt.horizontal.fill")
                            .herdrFont(.caption, weight: .bold)
                            .foregroundStyle(HerdrTheme.working)
                    }
                    if let cost = pane.costUSD {
                        if pane.costOverThreshold {
                            Label(cost.formatted(.currency(code: "USD")), systemImage: "exclamationmark.triangle.fill")
                                .herdrFont(.caption, monospaced: true, weight: .bold)
                                .foregroundStyle(HerdrTheme.working)
                                .help("Known Pi spend is above the configured cleanup threshold")
                        } else {
                            Text(cost, format: .currency(code: "USD"))
                                .herdrFont(.caption, monospaced: true, weight: .bold)
                                .foregroundStyle(HerdrTheme.mist)
                        }
                    }
                }

                Text(primarySummary)
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.text)
                    .fixedSize(horizontal: false, vertical: true)

                if let usage = pane.usageSummary, !usage.isEmpty, usage != primarySummary {
                    Label(usage, systemImage: "terminal.fill")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let activity = pane.activitySummary, !activity.isEmpty {
                    Label(activity, systemImage: "waveform.path.ecg.rectangle")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }

                CleanupSignalFactsView(pane: pane)

                DisclosureGroup(isExpanded: $isShowingDetails) {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledContent("Judge rationale") {
                            Text(pane.reason)
                                .foregroundStyle(HerdrTheme.mist)
                                .textSelection(.enabled)
                        }
                        .herdrFont(.caption)

                        LabeledContent("Confidence") {
                            Text(pane.confidence, format: .percent.precision(.fractionLength(0)))
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.mist)
                        }

                        if !pane.evidenceCited.isEmpty {
                            LabeledContent("Evidence read") {
                                Text(pane.evidenceCited.joined(separator: ", "))
                                    .herdrFont(.caption, monospaced: true)
                                    .foregroundStyle(HerdrTheme.mist)
                                    .textSelection(.enabled)
                            }
                        }

                        if let session = pane.piSession {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Pi session association")
                                    .herdrFont(.caption, weight: .bold)
                                    .foregroundStyle(HerdrTheme.text)
                                if let id = session.sessionID {
                                    Text("Session \(id)")
                                        .herdrFont(.caption, monospaced: true)
                                        .textSelection(.enabled)
                                }
                                if let file = session.sessionFile {
                                    Text(file)
                                        .herdrFont(.caption, monospaced: true)
                                        .foregroundStyle(HerdrTheme.mist)
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if !pane.blockedBy.isEmpty {
                            CleanupRailChipsView(codes: pane.blockedBy)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Why this decision")
                        .herdrFont(.caption, weight: .bold)
                        .foregroundStyle(HerdrTheme.accent)
                }
            }
        }
        .padding(12)
        .background(HerdrTheme.elevated.opacity(0.44))
        .clipShape(.rect(cornerRadius: 11))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var selectionControl: some View {
        if isIncludedByWorkspace {
            Button(action: toggleSelection) {
                Image(systemName: "checkmark.square.fill")
                    .herdrHitTarget()
            }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.signal)
                .help("Included with the selected workspace. Select to keep this pane open.")
                .accessibilityLabel("Keep \(pane.title ?? pane.paneID) open")
                .accessibilityIdentifier("cleanup-pane-checkbox-\(pane.paneID)")
        } else if pane.safeToClose {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .herdrHitTarget()
            }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? HerdrTheme.signal : HerdrTheme.mist)
                .accessibilityLabel(isSelected ? "Keep \(pane.title ?? pane.paneID) open" : "Close \(pane.title ?? pane.paneID)")
                .accessibilityIdentifier("cleanup-pane-checkbox-\(pane.paneID)")
        } else {
            Label(
                pane.blockedBy.isEmpty ? "Judge recommends keeping open" : "Protected by safety checks",
                systemImage: pane.blockedBy.isEmpty ? "hand.raised.fill" : "lock.shield.fill"
            )
                .labelStyle(.iconOnly)
                .foregroundStyle(pane.blockedBy.isEmpty ? HerdrTheme.mist : HerdrTheme.working)
                .help(pane.blockedBy.isEmpty ? "The judge recommends keeping this pane open" : "Safety checks protect this pane from closing")
        }
    }

    private var primarySummary: String {
        pane.summary ?? pane.usageSummary ?? pane.reason
    }

    private var decisionLabel: String {
        if pane.safeToClose { return isSelected || isIncludedByWorkspace ? "Will close" : "Ready" }
        if pane.classification == .blocked || pane.classification == .needsHuman { return "Needs you" }
        if !pane.blockedBy.isEmpty { return "Protected" }
        return "Keep open"
    }

    private var decisionSymbol: String {
        if pane.safeToClose { return "checkmark.circle.fill" }
        if pane.classification == .blocked || pane.classification == .needsHuman { return "person.crop.circle.badge.exclamationmark" }
        return "shield.fill"
    }

    private var decisionTone: Color {
        if pane.safeToClose { return HerdrTheme.signal }
        if pane.classification == .blocked || pane.classification == .needsHuman { return HerdrTheme.alert }
        return HerdrTheme.working
    }
}
