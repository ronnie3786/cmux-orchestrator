import AppKit
import SwiftUI

/// Keeps the HUD's always-mounted orb informative without pinning SwiftUI's
/// display link at animation rate. The timeline cadence is deliberately capped
/// because this is a 56-point status affordance, not a content surface.
enum HerdrHudOrbMotion {
    enum State: Equatable {
        case idle
        case attention
        case working
        case thinking
    }

    static let timelineCadence: TimeInterval = 1.0 / 12.0
    static let workingPeriod: TimeInterval = 1.4
    static let thinkingPeriod: TimeInterval = 1.2
    static let workingRestOpacity = 0.5
    static let workingPeakOpacity = 1.0

    static func state(sessionIsRunning: Bool, workingCount: Int, attentionCount: Int = 0) -> State {
        if sessionIsRunning { return .thinking }
        if attentionCount > 0 { return .attention }
        if workingCount > 0 { return .working }
        return .idle
    }

    static func usesTimeline(for state: State, reduceMotion: Bool) -> Bool {
        !reduceMotion && (state == .working || state == .thinking)
    }

    static func phase(at date: Date, period: TimeInterval) -> Double {
        guard period > 0 else { return 0 }
        let remainder = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return remainder >= 0 ? remainder / period : (remainder + period) / period
    }

    static func workingOpacity(at date: Date) -> Double {
        let phase = phase(at: date, period: workingPeriod)
        let envelope = (1 - cos(phase * 2 * .pi)) / 2
        return workingRestOpacity + (workingPeakOpacity - workingRestOpacity) * envelope
    }

    static func thinkingRotation(at date: Date) -> Double {
        phase(at: date, period: thinkingPeriod) * 360
    }
}

struct HerdrHudOrbView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var lastTranslation: CGSize = .zero

    private let orbSize: CGFloat = 56
    /// How far the pointer may slide before a press stops counting as a click.
    /// Small enough that a deliberate drag is caught immediately, large enough
    /// to survive the shake in an ordinary click.
    private static let dragThreshold: CGFloat = 4

    var body: some View {
        orb
            .contentShape(Circle())
            // A plain Button fires on mouse-up wherever the pointer ended, so
            // dragging the HUD by its orb expanded it on release. A press that
            // travelled is a move; only a press that stayed put summons.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        if !isDragging, distance > Self.dragThreshold {
                            isDragging = true
                            // Absorb the pre-threshold slop so the panel does
                            // not jump by it on the first move.
                            lastTranslation = value.translation
                        }
                        guard isDragging else { return }
                        controller.moveOrb(
                            by: CGSize(
                                width: value.translation.width - lastTranslation.width,
                                height: value.translation.height - lastTranslation.height
                            )
                        )
                        lastTranslation = value.translation
                    }
                    .onEnded { _ in
                        let didDrag = isDragging
                        isDragging = false
                        lastTranslation = .zero
                        if didDrag {
                            controller.endOrbDrag()
                        } else {
                            controller.summon()
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { controller.summon() }
            .onHover { isHovered = $0 }
            .accessibilityIdentifier("hud-orb")
            .accessibilityLabel("Herdr HUD")
            .accessibilityValue(accessibilityValue)
    }

    private var orb: some View {
        Group {
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
    }

    @ViewBuilder
    private var stateRing: some View {
        let state = HerdrHudOrbMotion.state(
            sessionIsRunning: session.isRunning,
            workingCount: model.workingCount,
            attentionCount: attentionCount
        )
        if HerdrHudOrbMotion.usesTimeline(for: state, reduceMotion: reduceMotion) {
            HerdrHudOrbAnimatedRing(state: state)
        } else {
            staticStateRing(for: state)
        }
    }

    @ViewBuilder
    private func staticStateRing(for state: HerdrHudOrbMotion.State) -> some View {
        switch state {
        case .attention:
            Circle()
                .strokeBorder(HerdrTheme.alert, lineWidth: 2.5)
                .padding(2)
        case .thinking:
            Circle()
                .strokeBorder(HerdrTheme.accent, lineWidth: 2.5)
                .padding(2)
        case .working:
            Circle()
                .strokeBorder(HerdrTheme.working, lineWidth: 2.5)
                .padding(2)
        case .idle:
            if model.connectionState == .live || model.isDemoMode {
                Circle()
                    .strokeBorder(HerdrTheme.signal.opacity(0.4), lineWidth: 2.5)
                    .padding(2)
            } else {
                Circle()
                    .strokeBorder(HerdrTheme.muted.opacity(0.18), lineWidth: 2.5)
                    .padding(2)
            }
        }
    }

    private var attentionCount: Int {
        filteredUnreadAlertCount > 0 ? filteredUnreadAlertCount : filteredAttentionPanes.count
    }

    private var filteredAttentionPanes: [HerdrPane] {
        HerdrHudNotificationFilter.panes(model.attentionPanes)
    }

    private var filteredUnreadAlertCount: Int {
        HerdrHudNotificationFilter.alerts(model.alerts, panes: model.workspaces.flatMap(\.panes))
            .count(where: { !$0.isRead })
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
}

private struct HerdrHudOrbAnimatedRing: View {
    let state: HerdrHudOrbMotion.State

    var body: some View {
        TimelineView(.periodic(from: .now, by: HerdrHudOrbMotion.timelineCadence)) { context in
            Canvas { graphics, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let lineWidth: CGFloat = 2.5
                let inset: CGFloat = state == .thinking ? 3.25 : 2
                let radius = max(0, min(size.width, size.height) / 2 - inset - lineWidth / 2)

                switch state {
                case .thinking:
                    let start = HerdrHudOrbMotion.thinkingRotation(at: context.date)
                    var path = Path()
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(start + 360 * 0.08),
                        endAngle: .degrees(start + 360 * 0.72),
                        clockwise: false
                    )
                    graphics.stroke(
                        path,
                        with: .color(HerdrTheme.accent),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                case .working:
                    var path = Path()
                    path.addEllipse(
                        in: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    )
                    graphics.opacity = HerdrHudOrbMotion.workingOpacity(at: context.date)
                    graphics.stroke(path, with: .color(HerdrTheme.working), lineWidth: lineWidth)
                case .attention:
                    break
                case .idle:
                    break
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
