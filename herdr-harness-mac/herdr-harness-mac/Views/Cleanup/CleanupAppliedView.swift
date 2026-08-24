import AppKit
import SwiftUI

struct CleanupAppliedView: View {
    let response: CleanupApplyResponse
    let envelope: CleanupRunEnvelope

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label(resultTitle, systemImage: resultSymbol)
                        .herdrFont(.title2, weight: .bold)
                        .foregroundStyle(isPartial ? HerdrTheme.alert : HerdrTheme.signal)
                    Spacer()
                    Text(resultHeadline)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                }

                if isPartial {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Partial cleanup result", systemImage: "exclamationmark.triangle.fill")
                            .herdrFont(.headline, weight: .bold)
                            .foregroundStyle(HerdrTheme.alert)
                        Text(applyError ?? "The server reported that cleanup did not fully complete.")
                            .herdrFont(.body)
                            .foregroundStyle(HerdrTheme.text)
                            .textSelection(.enabled)
                        Text("The outcomes below are confirmed. Any selection without a recorded outcome may still be open or have an unknown result.")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(HerdrTheme.alert.opacity(0.09))
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("cleanup-apply-error")
                }

                if let piSessions = response.piSessions, piSessions.ended > 0 || piSessions.failed > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Pi sessions", systemImage: "bubble.left.and.bubble.right.fill")
                            .herdrFont(.headline, weight: .bold)
                        Text("\(piSessions.ended) ended cleanly · \(piSessions.failed) failed")
                            .herdrFont(.body)
                            .foregroundStyle(piSessions.failed == 0 ? HerdrTheme.signal : HerdrTheme.alert)
                        ForEach(piSessions.results.filter { $0.wasActive || $0.quitAttempted }) { result in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: piResultSymbol(result))
                                    .foregroundStyle(piResultTone(result))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(paneTitle(for: result.paneID)) · \(piResultStatus(result))")
                                        .herdrFont(.caption, weight: .bold)
                                        .foregroundStyle(piResultTone(result))
                                    Text(piResultDetail(result))
                                        .herdrFont(.caption, monospaced: true)
                                        .foregroundStyle(HerdrTheme.mist)
                                        .textSelection(.enabled)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(HerdrTheme.graphite)
                    .clipShape(.rect(cornerRadius: 12))
                }

                if !response.applied.workspaces.isEmpty || !response.applied.panes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Closed")
                            .herdrFont(.headline, weight: .bold)
                        ForEach(response.applied.workspaces, id: \.self) { id in
                            Label(workspaceTitle(for: id), systemImage: "rectangle.3.group.fill")
                                .herdrFont(.body)
                        }
                        ForEach(response.applied.panes, id: \.self) { id in
                            Label(paneTitle(for: id), systemImage: "rectangle.fill.on.rectangle.fill")
                                .herdrFont(.body)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(HerdrTheme.graphite)
                    .clipShape(.rect(cornerRadius: 12))
                }

                if !response.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kept open")
                            .herdrFont(.headline, weight: .bold)
                            .foregroundStyle(HerdrTheme.alert)
                        ForEach(response.skipped) { item in
                            Label("\(displayTitle(for: item.id)): \(item.reasonLabel)", systemImage: "shield.fill")
                                .herdrFont(.body)
                                .foregroundStyle(HerdrTheme.alert)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(HerdrTheme.alert.opacity(0.09))
                    .clipShape(.rect(cornerRadius: 12))
                }

                if let ledger = response.ledger {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Closure ledger updated", systemImage: "doc.text.magnifyingglass")
                            .herdrFont(.headline, weight: .bold)
                            .foregroundStyle(HerdrTheme.accent)
                        Text("Saved \(count(ledger.recordsAppended, singular: "pane/session association record")) on the cleaned machine.")
                            .herdrFont(.body)
                            .foregroundStyle(HerdrTheme.mist)
                        HStack(spacing: 8) {
                            Text(ledger.path)
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.text)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy path", systemImage: "doc.on.doc", action: { copy(ledger.path) })
                                .accessibilityIdentifier("cleanup-copy-ledger-path")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(HerdrTheme.graphite)
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("cleanup-applied")
    }

    private var workspaces: [CleanupWorkspaceReport] { envelope.workspaces ?? [] }
    private var applyError: String? {
        guard let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty else {
            return nil
        }
        return error
    }
    private var isPartial: Bool { applyError != nil || response.complete == false }
    private var resultTitle: String { isPartial ? "Cleanup stopped early" : "Cleanup complete" }
    private var resultSymbol: String { isPartial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill" }
    private var resultHeadline: String {
        let total = response.applied.panes.count + response.applied.workspaces.count
        return "\(total) closed · \(response.skipped.count) kept"
    }

    private func workspaceTitle(for id: String) -> String {
        guard let workspace = workspaces.first(where: { $0.workspaceID == id }) else { return id }
        return workspace.title ?? workspace.label ?? workspace.workspaceID
    }

    private func paneTitle(for id: String) -> String {
        workspaces.flatMap(\.panes).first(where: { $0.paneID == id })?.title ?? id
    }

    private func displayTitle(for id: String) -> String {
        if workspaces.contains(where: { $0.workspaceID == id }) { return workspaceTitle(for: id) }
        return paneTitle(for: id)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func piResultStatus(_ result: CleanupPiSessionApplyResult) -> String {
        if result.quitSucceeded { return "Ended cleanly" }
        if result.quitAttempted { return "Could not end" }
        return "Not attempted"
    }

    private func piResultSymbol(_ result: CleanupPiSessionApplyResult) -> String {
        if result.quitSucceeded { return "checkmark.circle.fill" }
        if result.quitAttempted { return "xmark.circle.fill" }
        return "pause.circle.fill"
    }

    private func piResultTone(_ result: CleanupPiSessionApplyResult) -> Color {
        result.quitSucceeded ? HerdrTheme.signal : HerdrTheme.alert
    }

    private func piResultDetail(_ result: CleanupPiSessionApplyResult) -> String {
        var parts = [result.sessionID ?? "unknown session"]
        if let reason = result.reason, !reason.isEmpty {
            parts.append(CleanupRail.label(for: reason))
        }
        parts.append("pane \(result.closeOutcome)")
        return parts.joined(separator: " · ")
    }

    private func count(_ value: Int, singular: String) -> String {
        "\(value) \(value == 1 ? singular : singular + "s")"
    }
}
