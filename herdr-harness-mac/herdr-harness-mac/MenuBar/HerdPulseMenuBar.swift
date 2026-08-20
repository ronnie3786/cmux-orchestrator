import AppKit
import SwiftUI

/// Herd Pulse for Mac — the menu-bar fleet pulse that replaces the iOS Live
/// Activity. Mount it from the root `App`:
///
/// ```swift
/// var body: some Scene {
///     WindowGroup { ... }
///     HerdPulseMenuBar.scene(pulse: herdPulse)
/// }
/// ```
///
/// PRIVACY INVARIANT: everything this file renders is aggregate-only — counts,
/// phase, and connection. Never workspace labels, pane titles, cwds, or session
/// IDs. The menu bar is visible in screen shares, recordings, and screenshots.
/// `HerdPulseMenuBarPrivacyTests` pins it.
enum HerdPulseMenuBar {
    static func scene(pulse: HerdPulseCoordinator) -> some Scene {
        HerdPulseMenuBarScene(pulse: pulse)
    }
}

struct HerdPulseMenuBarScene: Scene {
    let pulse: HerdPulseCoordinator

    var body: some Scene {
        @Bindable var pulse = pulse
        MenuBarExtra(isInserted: $pulse.isMenuBarInserted) {
            HerdPulseMenuBarCard(pulse: pulse)
        } label: {
            HerdPulseMenuBarLabel(state: pulse.contentState)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar label

/// The system renders menu bar labels as monochrome template images, so this is
/// deliberately symbol + count only — phase color lives in the window content.
struct HerdPulseMenuBarLabel: View {
    let state: HerdPulseContentState?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform.path.ecg")
            if let count = HerdPulseMenuBarPresentation.badgeCount(for: state) {
                Text("\(count)")
                    .herdrFont(.caption, monospaced: true, weight: .bold)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HerdPulseMenuBarPresentation.labelAccessibility(for: state))
        .accessibilityIdentifier("herd-pulse-menubar-label")
    }
}

// MARK: - Menu bar window content

struct HerdPulseMenuBarCard: View {
    let pulse: HerdPulseCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            titleBlock
            separator
            metrics
            separator
            footer
            actions
        }
        .padding(14)
        .frame(width: 280)
        .background(HerdPulseTheme.graphite)
        .animation(reduceMotion ? nil : .snappy, value: state)
        .accessibilityIdentifier("herd-pulse-menubar-card")
    }

    private var state: HerdPulseContentState? { pulse.contentState }

    /// Staleness is a statement about the *feed*, not about how long the fleet
    /// has been quiet. `updatedAt` only moves when the aggregate changes, so an
    /// idle-but-healthy herd would otherwise start claiming "Last known" after
    /// 15 minutes while the footer still reads "Live".
    private var isStale: Bool {
        switch state?.connection {
        case .live, .demo:
            false
        case .reconnecting:
            // Reconnecting is not yet a lie — it becomes one once the numbers
            // have had time to move on without us.
            Date.now.timeIntervalSince1970 - Double(state?.updatedAt ?? 0) > 15 * 60
        case .offline, nil:
            true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 8) {
                if let state {
                    HerdPulseStatusRail(state: state)
                }
                Text("HERD PULSE")
                    .herdrFont(.caption, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdPulseTheme.mist)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(state?.paneCount ?? 0)")
                    .herdrFont(.title, monospaced: true, weight: .bold)
                    .foregroundStyle(phaseColor)
                Text("panes")
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdPulseTheme.mist)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HerdPulseMenuBarPresentation.title(for: state, isStale: isStale))
                .herdrFont(.headline, monospaced: true, weight: .bold)
                .foregroundStyle(isStale ? HerdPulseTheme.mist : HerdPulseTheme.text)

            Text(HerdPulseMenuBarPresentation.detail(for: state))
                .herdrFont(.subheadline, monospaced: true)
                .foregroundStyle(HerdPulseTheme.mist)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        HStack(alignment: .top) {
            metric("needs you", value: state?.attentionCount ?? 0, color: HerdPulseTheme.alert)
            Spacer(minLength: 8)
            metric("ready", value: state?.readyCount ?? 0, color: HerdPulseTheme.signal)
            Spacer(minLength: 8)
            metric("working", value: state?.workingCount ?? 0, color: HerdPulseTheme.working)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(HerdPulseMenuBarPresentation.connectionColor(for: state?.connection))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(HerdPulseMenuBarPresentation.connectionTitle(for: state?.connection))
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .foregroundStyle(HerdPulseMenuBarPresentation.connectionColor(for: state?.connection))

            Text(HerdPulseMenuBarPresentation.workspaceSummary(for: state))
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdPulseTheme.mist)

            Spacer(minLength: 6)

            if let state, state.updatedAt > 0 {
                updatedLabel(at: Date(timeIntervalSince1970: Double(state.updatedAt)))
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(pulse.isRunning ? "Stop Pulse" : "Start Pulse") {
                Task { await pulse.toggle() }
            }
            .buttonStyle(HerdPulseMenuBarButtonStyle(isProminent: !pulse.isRunning))
            .disabled(pulse.isBusy)
            .help(pulse.isRunning ? "Stop Herd Pulse" : "Start Herd Pulse")
            .accessibilityValue(pulse.statusText)
            .accessibilityHint(pulse.backgroundUpdatesText)
            .accessibilityIdentifier("herd-pulse-toggle")

            Button("Open Herdr", action: openHerdr)
                .buttonStyle(HerdPulseMenuBarButtonStyle(isProminent: false))
                .help("Bring the Herdr window to the front")
                .accessibilityIdentifier("herd-pulse-open-herdr")
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(HerdPulseTheme.elevated)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var phaseColor: Color {
        HerdPulseTheme.color(for: state?.phase ?? .offline)
    }

    private func metric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .herdrFont(.headline, monospaced: true, weight: .bold)
                .foregroundStyle(color)
            Text(label)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdPulseTheme.mist)
        }
        .accessibilityElement(children: .combine)
    }

    private func updatedLabel(at date: Date) -> some View {
        Text("updated \(date, style: .relative) ago")
            .herdrFont(.caption, monospaced: true)
            .foregroundStyle(HerdPulseTheme.mist)
            .lineLimit(1)
    }

    private func openHerdr() {
        dismiss()
        NSApp.activate()
        // Must be `openWindow`, not a scan of `NSApp.windows`: SwiftUI destroys
        // the window's `NSWindow` on close, which is exactly when this button
        // matters — there would be nothing left to bring forward.
        openWindow(id: HerdrWindowID.main)
    }
}

// MARK: - Button style

private struct HerdPulseMenuBarButtonStyle: ButtonStyle {
    let isProminent: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .herdrFont(.caption, monospaced: true, weight: .bold)
            .foregroundStyle(isProminent ? HerdPulseTheme.accent : HerdPulseTheme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(HerdPulseTheme.elevated)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isProminent
                            ? HerdPulseTheme.accent.opacity(0.5)
                            : HerdPulseTheme.elevated,
                        lineWidth: 1
                    )
            }
            .clipShape(.rect(cornerRadius: 10))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

// MARK: - Presentation (pure, aggregate-only)

/// Every string the menu bar can render, derived from counts alone. Kept
/// separate from the views so the privacy invariant is unit-testable.
enum HerdPulseMenuBarPresentation {
    /// Same priority the iOS Dynamic Island used for its compact trailing count.
    static func primaryCount(for state: HerdPulseContentState) -> Int {
        if state.attentionCount > 0 { return state.attentionCount }
        if state.readyCount > 0 { return state.readyCount }
        return state.workingCount
    }

    /// Count shown next to the menu bar symbol, or `nil` when there is nothing
    /// worth a number (a lone "0" in the menu bar is noise).
    static func badgeCount(for state: HerdPulseContentState?) -> Int? {
        guard let state else { return nil }
        let count = primaryCount(for: state)
        return count > 0 ? count : nil
    }

    static func title(for state: HerdPulseContentState?, isStale: Bool) -> String {
        guard let state else { return "Pulse off" }
        if isStale { return "Last known herd" }
        return switch state.phase {
        case .attention: "Needs you"
        case .ready: "Ready to review"
        case .working: "Herd working"
        case .resting: "All quiet"
        case .offline: "Herd offline"
        }
    }

    static func detail(for state: HerdPulseContentState?) -> String {
        guard let state else { return "Start Pulse to monitor your herd" }
        if state.attentionCount > 0 {
            return "\(state.attentionCount) blocked · \(state.workingCount) working"
        }
        if state.readyCount > 0 {
            return "\(state.readyCount) ready · \(state.workingCount) working"
        }
        return "\(state.workspaceCount) spaces · \(state.workingCount) working"
    }

    static func labelAccessibility(for state: HerdPulseContentState?) -> String {
        guard let state else { return "Herd Pulse off" }
        return switch state.phase {
        case .attention: "\(state.attentionCount) agents need you"
        case .ready: "\(state.readyCount) agents ready"
        case .working: "\(state.workingCount) agents working"
        case .resting: "All agents quiet"
        case .offline: "Herd Pulse offline"
        }
    }

    static func workspaceSummary(for state: HerdPulseContentState?) -> String {
        "· \(state?.workspaceCount ?? 0) spaces"
    }

    static func connectionTitle(for connection: HerdPulseConnection?) -> String {
        switch connection {
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .demo: "Demo"
        case .offline: "Offline"
        case nil: "Off"
        }
    }

    static func connectionColor(for connection: HerdPulseConnection?) -> Color {
        switch connection {
        case .live: HerdPulseTheme.signal
        case .reconnecting: HerdPulseTheme.accent
        case .demo, .offline, nil: HerdPulseTheme.mist
        }
    }
}
