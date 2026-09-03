import AppKit
import SwiftUI

/// The chat's shared copy affordance: put text on the pasteboard, then say so
/// for a beat.
///
/// Deliberately has no `.onHover` of its own. `PiChatChromeStyles` bans per-row
/// hover tracking in the timeline on measured evidence — up to
/// `PiTimelineWindow.defaultLimit` rows are mounted eagerly — so this stays
/// visible at a low opacity and lifts on press instead of on hover.
struct PiCopyButton: View {
    let text: String
    var label: String
    var accessibilityIdentifier: String?
    var restingOpacity: Double = 0.35

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .herdrFont(.caption)
                .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.mist)
                .herdrHitTarget(minWidth: 0)
        }
        .buttonStyle(.plain)
        .opacity(copied ? 1 : restingOpacity)
        .animation(PiChatChrome.hoverAnimation, value: copied)
        .help(label)
        .accessibilityLabel(copied ? "Copied" : label)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

extension View {
    /// Adds a copy control that floats over the message rather than beside it.
    ///
    /// An overlay because the user bubble is sized by a trailing-aligned frame
    /// specifically to avoid a stack size-probing it; an overlay does not
    /// participate in that sizing. Applied *outside* the row's
    /// `.accessibilityElement(children: .combine)` so the button stays a
    /// separate element for VoiceOver and XCUITest instead of being flattened
    /// into the message text.
    func piCopyAffordance(
        _ text: String,
        label: String,
        identifier: String,
        alignment: Alignment = .topTrailing,
        inset: CGFloat = 6,
        offset: CGSize = .zero,
        isEnabled: Bool = true
    ) -> some View {
        overlay(alignment: alignment) {
            if isEnabled {
                PiCopyButton(text: text, label: label, accessibilityIdentifier: identifier)
                    .padding(inset)
                    .offset(offset)
            }
        }
        .contextMenu {
            if isEnabled {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }
}
