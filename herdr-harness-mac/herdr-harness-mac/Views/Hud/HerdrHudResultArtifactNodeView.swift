import SwiftUI

/// One tactile result node. Its compact state reads as a floating file glyph;
/// pointer hover or keyboard focus exposes the filename without moving the
/// HUD's right-hand anchor.
struct HerdrHudResultArtifactNodeView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.herdrFontScale) private var fontScale

    @Bindable var model: HerdrAppModel
    let artifact: AgentResultArtifact
    let hiddenArtifactCount: Int
    @Binding var hoveredArtifactID: String?

    @FocusState private var isFocused: Bool

    private var isHovered: Bool {
        hoveredArtifactID == artifact.id
    }

    private var category: HerdrHudResultArtifactCategory {
        HerdrHudResultArtifactCategory(artifact: artifact)
    }

    private var phase: AgentResultArtifactPhase {
        model.resultArtifactPhase(id: artifact.id)
    }

    private var presentedTitle: String {
        model.showSessionTitles ? artifact.displayTitle : category.privacyLabel
    }

    private var disclosedLinkHost: String? {
        guard model.showSessionTitles, artifact.kind == .link else { return nil }
        guard let host = artifact.url?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else { return nil }
        return host
    }

    private var isConfirmationVisible: Bool {
        if case .opened = phase { return true }
        return false
    }

    private var isExpanded: Bool {
        // The success confirmation stays compact. This lets its mint check
        // coexist with a neighboring hover without ever overflowing the fixed
        // result lane during the brief retirement window.
        isHovered || (isFocused && hoveredArtifactID == nil)
    }

    var body: some View {
        Button(action: openArtifact) {
            nodeContent
                .frame(
                    width: isExpanded
                        ? HerdrHudPlacement.resultNodeExpandedWidth
                        : HerdrHudPlacement.resultNodeSize,
                    height: HerdrHudPlacement.resultNodeSize,
                    alignment: .leading
                )
                .background(nodeBackground)
                .overlay(nodeBorder)
                .overlay(alignment: .topLeading) {
                    if hiddenArtifactCount > 0 && !isExpanded {
                        overflowBadge
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .disabled(phase.isBusyOrOpened)
        .contextMenu {
            Button("Dismiss Result", systemImage: "xmark") {
                dismissArtifact()
            }
            .disabled(phase.isBusyOrOpened)
        }
        .onHover { hovering in
            if hovering {
                hoveredArtifactID = artifact.id
            } else if hoveredArtifactID == artifact.id {
                hoveredArtifactID = nil
            }
        }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens this result in its default Mac app")
        .accessibilityIdentifier("hud-result-artifact-\(artifact.id)")
        .accessibilityAction(named: "Dismiss result") {
            dismissArtifact()
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isExpanded)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.12), value: phase.animationKey)
    }

    private var nodeContent: some View {
        HStack(spacing: 7) {
            statusGlyph
                .frame(width: HerdrHudPlacement.resultNodeSize, height: HerdrHudPlacement.resultNodeSize)
                .accessibilityHidden(true)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Text(primaryLabel)
                        .font(.custom("Inter-SemiBold", size: 10 * fontScale.rawValue))
                        .foregroundStyle(isConfirmationVisible ? HerdrTheme.success : HerdrTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(secondaryLabel)
                        .font(.system(size: 7 * fontScale.rawValue, weight: .bold, design: .monospaced))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch phase {
        case .available:
            Image(systemName: category.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(category.tint)
                .symbolRenderingMode(.hierarchical)
        case .opening, .downloading:
            ProgressView()
                .controlSize(.mini)
                .tint(category.tint)
        case .opened:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(HerdrTheme.success)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(HerdrTheme.alert)
        }
    }

    private var nodeBackground: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        HerdrTheme.graphite.opacity(0.98),
                        HerdrTheme.ink.opacity(0.96),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: activeTint.opacity(isExpanded || isConfirmationVisible ? 0.62 : 0.34), radius: 7)
            .shadow(color: HerdrTheme.ink.opacity(0.7), radius: 5, y: 3)
    }

    private var nodeBorder: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        activeTint.opacity(0.92),
                        HerdrTheme.mauve.opacity(isConfirmationVisible ? 0 : 0.46),
                        HerdrTheme.surface.opacity(0.52),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: differentiateWithoutColor || isExpanded ? 1.5 : 1
            )
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    .padding(2)
            }
    }

    private var overflowBadge: some View {
        Text("+\(hiddenArtifactCount)")
            .font(.system(size: 7, weight: .black, design: .monospaced))
            .foregroundStyle(HerdrTheme.ink)
            .padding(.horizontal, 3)
            .frame(minHeight: 11)
            .background(HerdrTheme.mauve, in: .capsule)
            .offset(x: -5, y: -6)
            .accessibilityHidden(true)
    }

    private var activeTint: Color {
        switch phase {
        case .opened: HerdrTheme.success
        case .failed: HerdrTheme.alert
        case .available, .opening, .downloading: category.tint
        }
    }

    private var primaryLabel: String {
        switch phase {
        case .opened: "Opened"
        case .opening: "Opening result"
        case .downloading: "Fetching result"
        case .failed: "Try again"
        case .available: presentedTitle
        }
    }

    private var secondaryLabel: String {
        switch phase {
        case .opened: "VIEWED"
        case .opening: "LAUNCHING"
        case .downloading: "SECURE TRANSFER"
        case .failed: "OPEN FAILED"
        case .available: disclosedLinkHost ?? category.compactLabel
        }
    }

    private var secondaryColor: Color {
        switch phase {
        case .opened: HerdrTheme.success.opacity(0.8)
        case .failed: HerdrTheme.alert.opacity(0.8)
        case .available, .opening, .downloading: category.tint.opacity(0.78)
        }
    }

    private var helpText: String {
        var text = "Open \(presentedTitle)"
        if let disclosedLinkHost {
            text += " at \(disclosedLinkHost)"
        }
        if let byteSize = artifact.byteSize {
            text += " (\(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)))"
        }
        if hiddenArtifactCount > 0 {
            text += ". \(hiddenArtifactCount) more result\(hiddenArtifactCount == 1 ? "" : "s") waiting"
        }
        if case let .failed(message) = phase {
            if let detail = HerdrHudResultArtifactPrivacy.visibleFailureDetail(
                message,
                revealsSensitiveDetails: model.showSessionTitles
            ) {
                text += ". Last attempt failed: \(detail)"
            } else {
                text += ". Last attempt failed."
            }
        }
        return text
    }

    private var accessibilityLabel: String {
        var label = "Open result, \(presentedTitle), \(category.compactLabel.lowercased())"
        if let disclosedLinkHost {
            label += ", destination \(disclosedLinkHost)"
        }
        return label
    }

    private var accessibilityValue: String {
        switch phase {
        case .available: "Unviewed"
        case .opening: "Opening"
        case .downloading: "Downloading"
        case .opened: "Opened"
        case let .failed(message):
            if let detail = HerdrHudResultArtifactPrivacy.visibleFailureDetail(
                message,
                revealsSensitiveDetails: model.showSessionTitles
            ) {
                "Open failed, \(detail)"
            } else {
                "Open failed"
            }
        }
    }

    private func openArtifact() {
        Task { await model.openResultArtifact(artifact) }
    }

    private func dismissArtifact() {
        model.dismissResultArtifact(artifact)
    }
}

private extension AgentResultArtifactPhase {
    var isBusyOrOpened: Bool {
        switch self {
        case .opening, .downloading, .opened: true
        case .available, .failed: false
        }
    }

    var animationKey: String {
        switch self {
        case .available: "available"
        case .opening: "opening"
        case .downloading: "downloading"
        case .opened: "opened"
        case .failed: "failed"
        }
    }
}
