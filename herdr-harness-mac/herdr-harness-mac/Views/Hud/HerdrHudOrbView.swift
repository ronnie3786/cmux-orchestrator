import AppKit
import SwiftUI

struct HerdrHudOrbView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isAnimating = false

    private let orbSize: CGFloat = 56

    var body: some View {
        Button(action: controller.summon) {
            ZStack {
                Circle()
                    .fill(HerdrTheme.graphite)
                    .overlay {
                        Circle()
                            .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                    }
                    .shadow(color: HerdrTheme.ink.opacity(0.5), radius: 10, y: 4)

                stateRing

                Group {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .foregroundStyle(glyphColor)
                .accessibilityHidden(true)

                if attentionCount > 0 {
                    Text("\(attentionCount)")
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.ink)
                        .padding(5)
                        .background(HerdrTheme.alert, in: Capsule())
                        .offset(x: 20, y: -20)
                        .accessibilityHidden(true)
                }

                if session.hasUnseenAnswer {
                    Circle()
                        .fill(HerdrTheme.accent)
                        .frame(width: 10, height: 10)
                        .shadow(color: HerdrTheme.accent, radius: 5)
                        .offset(x: 20, y: 20)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: orbSize, height: orbSize)
            .scaleEffect(isHovered ? 1.06 : 1)
            .brightness(isHovered ? 0.04 : 0)
            .animation(.snappy(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onAppear { updateAnimation() }
        .onChange(of: reduceMotion, initial: true) { _, _ in updateAnimation() }
        .onChange(of: session.isRunning) { _, _ in updateAnimation() }
        .onChange(of: model.workingCount) { _, _ in updateAnimation() }
        .accessibilityIdentifier("hud-orb")
        .accessibilityLabel("Herdr HUD")
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var stateRing: some View {
        if session.isRunning {
            if reduceMotion {
                Circle()
                    .strokeBorder(HerdrTheme.accent.opacity(isAnimating ? 1 : 0.5), lineWidth: 2.5)
                    .padding(2)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isAnimating)
            } else {
                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(HerdrTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(3.25)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: isAnimating)
            }
        } else if attentionCount > 0 {
            Circle()
                .strokeBorder(HerdrTheme.alert, lineWidth: 2.5)
                .padding(2)
        } else if model.workingCount > 0 {
            Circle()
                .strokeBorder(HerdrTheme.working.opacity(reduceMotion ? 1 : (isAnimating ? 1 : 0.5)), lineWidth: 2.5)
                .padding(2)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: isAnimating)
        } else if model.connectionState == .live || model.isDemoMode {
            Circle()
                .strokeBorder(HerdrTheme.signal.opacity(0.4), lineWidth: 2.5)
                .padding(2)
        } else {
            Circle()
                .strokeBorder(HerdrTheme.muted.opacity(0.18), lineWidth: 2.5)
                .padding(2)
        }
    }

    private var attentionCount: Int {
        model.unreadAlertCount > 0 ? model.unreadAlertCount : model.attentionPanes.count
    }

    private var glyphColor: Color {
        model.connectionState == .live || model.isDemoMode ? HerdrTheme.text : HerdrTheme.muted
    }

    private var accessibilityValue: String {
        if session.isRunning { return "Thinking" }
        if attentionCount > 0 { return "\(attentionCount) need attention" }
        if model.workingCount > 0 { return "Working" }
        if model.connectionState == .live || model.isDemoMode { return "Idle" }
        return "Offline"
    }

    private func updateAnimation() {
        isAnimating = session.isRunning || (!reduceMotion && model.workingCount > 0)
    }
}
