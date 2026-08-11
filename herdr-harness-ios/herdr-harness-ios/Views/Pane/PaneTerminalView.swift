import SwiftUI

struct PaneTerminalView: View {
    let pane: HerdrPane
    let output: String
    let attributedOutput: AttributedString?
    let revision: Int
    let dimensions: String?
    @Binding var isFollowing: Bool

    var body: some View {
        VStack(spacing: 0) {
            terminalChrome
            terminalOutput
        }
        .background(Color.black.opacity(0.88))
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .accessibilityIdentifier("terminal-\(pane.id)")
    }

    private var terminalChrome: some View {
        HStack(spacing: 7) {
            Circle().fill(HerdrTheme.alert.opacity(0.75)).frame(width: 8, height: 8)
            Circle().fill(HerdrTheme.accent.opacity(0.75)).frame(width: 8, height: 8)
            Circle().fill(HerdrTheme.signal.opacity(0.75)).frame(width: 8, height: 8)

            Text(pane.id)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
            Spacer()
            Text(metadata)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)

            Button(isFollowing ? "Pause follow" : "Resume follow", systemImage: isFollowing ? "pause.circle" : "arrow.down.circle") {
                isFollowing.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(isFollowing ? HerdrTheme.signal : HerdrTheme.mist)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .frame(minHeight: 44)
        .background(HerdrTheme.graphite.opacity(0.58))
    }

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if let attributedOutput {
                            Text(attributedOutput)
                        } else {
                            Text(output)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Color(red: 0.84, green: 0.87, blue: 0.90))
                        }
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)

                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(bottomAnchorID)
                }
                .padding(14)
            }
            .scrollIndicators(.visible)
            .defaultScrollAnchor(.bottomLeading)
            .onChange(of: revision) { _, _ in
                guard isFollowing else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(bottomAnchorID, anchor: .bottomLeading)
                }
            }
            .onChange(of: isFollowing) { _, shouldFollow in
                guard shouldFollow else { return }
                proxy.scrollTo(bottomAnchorID, anchor: .bottomLeading)
            }
        }
    }

    private var bottomAnchorID: String { "terminal-bottom-\(pane.id)" }

    private var metadata: String {
        if let dimensions { return "\(dimensions) · f\(revision)" }
        return "r\(revision)"
    }
}
