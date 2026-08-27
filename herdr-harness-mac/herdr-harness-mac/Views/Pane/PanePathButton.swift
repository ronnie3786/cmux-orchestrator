import AppKit
import SwiftUI

struct PanePathButton: View {
    let path: String
    let reportFailure: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: openInFinder) {
            HStack(spacing: 4) {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "folder")
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .herdrFont(.caption, monospaced: true)
            .foregroundStyle(isHovering ? HerdrTheme.text : HerdrTheme.mist)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                isHovering ? HerdrTheme.elevated.opacity(0.72) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(path) in Finder")
        .accessibilityLabel("Open \(path) in Finder")
        .accessibilityHint("Opens this session's working folder")
        .accessibilityIdentifier("pane-path-button")
    }

    private func openInFinder() {
        guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) else {
            reportFailure()
            return
        }
    }
}
