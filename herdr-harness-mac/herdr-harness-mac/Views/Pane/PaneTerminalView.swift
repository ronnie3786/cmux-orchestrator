import SwiftUI

struct PaneTerminalView: View {
    let pane: HerdrPane
    let output: String
    let attributedOutput: AttributedString?
    let revision: Int
    let dimensions: String?
    let source: TerminalSource
    @Binding var isFollowing: Bool
    let isRefreshing: Bool
    /// Drawn as the accent focus ring: this pane is taking real keyboard input.
    var isKeyboardFocused = false
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TerminalToolbar(
                pane: pane,
                revision: revision,
                dimensions: dimensions,
                source: source,
                isFollowing: $isFollowing,
                isRefreshing: isRefreshing,
                refresh: refresh
            )
            TerminalOutputView(
                output: output,
                attributedOutput: attributedOutput,
                revision: revision,
                isFollowing: $isFollowing
            )
        }
        .background(HerdrTheme.graphite)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(borderColor, lineWidth: isKeyboardFocused ? 2 : 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        // Outside the clip so the focus glow actually escapes the terminal box.
        .shadow(color: HerdrTheme.accent.opacity(isKeyboardFocused ? 0.35 : 0), radius: 6)
        .padding(.horizontal, 12)
        .accessibilityIdentifier("terminal-\(pane.id)")
    }

    private var borderColor: Color {
        if isKeyboardFocused || source == .stream { HerdrTheme.accent } else { HerdrTheme.surface }
    }
}

private struct TerminalToolbar: View {
    let pane: HerdrPane
    let revision: Int
    let dimensions: String?
    let source: TerminalSource
    @Binding var isFollowing: Bool
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HerdrStatusDot(status: pane.agentStatus)

            Label(source.label, systemImage: source.symbol)
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .foregroundStyle(source.color)
                .symbolEffect(.pulse, options: .repeating, isActive: source == .connecting)

            Text(metadata)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(isFollowing ? "Pause follow" : "Resume follow", systemImage: isFollowing ? "pause" : "arrow.down") {
                isFollowing.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(isFollowing ? HerdrTheme.success : HerdrTheme.working)
            .frame(width: 28, height: 30)
            .contentShape(.rect)
            .help(isFollowing ? "Pause following new output" : "Follow new output")

            Button("Refresh output", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mist)
                .frame(width: 28, height: 30)
                .contentShape(.rect)
                .symbolEffect(.rotate, options: .repeating, isActive: isRefreshing)
                .disabled(isRefreshing)
                .help("Refresh the snapshot now")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .background(HerdrTheme.elevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HerdrTheme.surface).frame(height: 1)
        }
    }

    private var metadata: String {
        if let dimensions { "\(dimensions) · f\(revision)" } else { "r\(revision)" }
    }
}

private struct TerminalOutputView: View {
    let output: String
    let attributedOutput: AttributedString?
    let revision: Int
    @Binding var isFollowing: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if let attributedOutput {
                            Text(attributedOutput)
                        } else {
                            Text(output)
                                .herdrFont(.footnote, monospaced: true)
                                .foregroundStyle(HerdrTheme.text)
                        }
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                }
                .padding(14)
                .frame(
                    minWidth: geometry.size.width,
                    minHeight: geometry.size.height,
                    alignment: .bottomLeading
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scrollIndicators(.visible)
            .defaultScrollAnchor(.bottomLeading)
            .scrollPosition($scrollPosition)
            .task(id: "follow:\(revision):\(isFollowing)") {
                guard isFollowing else { return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                scrollPosition.scrollTo(edge: .bottom)
            }
            .onChange(of: isFollowing) { _, shouldFollow in
                guard shouldFollow else { return }
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }
}
