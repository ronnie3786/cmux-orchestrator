import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TerminalScrollView: View {
    let workspaceID: String
    let text: String
    private let bottomID = "terminal-bottom"
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 0
    @State private var scrollRevision = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(TerminalTextStyler.attributedString(for: text, colorScheme: colorScheme))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                    Color.clear
                        .frame(height: 8)
                        .id(bottomID)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: TerminalContentHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                }
            }
            .background(TerminalTextStyler.terminalBackground(for: colorScheme))
            .defaultScrollAnchor(.bottom)
            .onAppear {
                requestBottomScroll()
            }
            .onChange(of: workspaceID) {
                requestBottomScroll()
            }
            .onChange(of: text) {
                requestBottomScroll()
            }
            .onPreferenceChange(TerminalContentHeightKey.self) { height in
                guard contentHeight != height else { return }
                contentHeight = height
                requestBottomScroll()
            }
            .task(id: scrollRevision) {
                await scrollToBottom(proxy)
            }
        }
    }

    private func requestBottomScroll() {
        scrollRevision &+= 1
    }

    @MainActor
    private func scrollToBottom(_ proxy: ScrollViewProxy) async {
        await Task.yield()
        scroll(proxy)

        for delay in [50_000_000, 150_000_000, 300_000_000] as [UInt64] {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            scroll(proxy)
        }
    }

    @MainActor
    private func scroll(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

struct TerminalContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
