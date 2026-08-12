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
                .strokeBorder(source == .stream ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .padding(.horizontal, 12)
        .accessibilityIdentifier("terminal-\(pane.id)")
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
                .font(.caption.monospaced().bold())
                .foregroundStyle(source.color)
                .symbolEffect(.pulse, options: .repeating, isActive: source == .connecting)

            Text(metadata)
                .font(.caption.monospaced())
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(isFollowing ? "Pause follow" : "Resume follow", systemImage: isFollowing ? "pause" : "arrow.down") {
                isFollowing.toggle()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(isFollowing ? HerdrTheme.success : HerdrTheme.working)
            .frame(minWidth: 44, minHeight: 44)

            Button("Refresh output", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .foregroundStyle(HerdrTheme.mist)
                .frame(minWidth: 44, minHeight: 44)
                .symbolEffect(.rotate, options: .repeating, isActive: isRefreshing)
                .disabled(isRefreshing)
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
                                .font(.footnote.monospaced())
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
