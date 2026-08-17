import SwiftUI
import UIKit

struct SidebarDrawer: View {
    @Bindable var model: HerdrAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset = 0.0

    var body: some View {
        Group {
            if model.isSidebarPresented {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Color.black
                            .opacity(0.45)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismiss)
                            .transition(.opacity)

                        HerdrSidebarView(model: model)
                            .frame(width: min(340, proxy.size.width * 0.86), height: proxy.size.height)
                            .background(HerdrTheme.ink.ignoresSafeArea())
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(HerdrTheme.surface.opacity(0.65))
                                    .frame(width: 1)
                            }
                            .offset(x: dragOffset)
                            .gesture(dragGesture)
                            .transition(reduceMotion ? .opacity : .move(edge: .leading))
                            .accessibilityIdentifier("herdr-sidebar")
                            .accessibilityAddTraits(.isModal)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: model.isSidebarPresented)
        .onChange(of: model.isSidebarPresented) { _, isPresented in
            guard isPresented else { return }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                withAnimation(.snappy) {
                    if value.translation.width < -44 {
                        model.isSidebarPresented = false
                    }
                    dragOffset = 0
                }
            }
    }

    private func dismiss() {
        withAnimation(.snappy) {
            model.isSidebarPresented = false
        }
    }
}
