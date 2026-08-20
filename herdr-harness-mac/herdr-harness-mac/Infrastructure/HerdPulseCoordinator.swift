import Foundation
import Observation

/// Herd Pulse for Mac.
///
/// ActivityKit does not exist on macOS, so the Live Activity becomes a
/// `MenuBarExtra` (see `MenuBar/HerdPulseMenuBar.swift`). A menu-bar process
/// stays alive with the event stream connected, which is the only reason the
/// iOS build needed APNs push tokens — so the whole registration stack
/// (client, receivers, retry policy, generation guards) is gone.
///
/// What is preserved on purpose: the observable surface, `synchronize(context:)`
/// / `toggle()`, the `HerdPulseOperationGate` serialization, and the
/// `"herdr.herdPulse.enabled"` defaults key — so the root view's
/// `.task(id: herdPulseContext)` wiring ports unchanged.
@MainActor
@Observable
final class HerdPulseCoordinator {
    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var statusText = "Off"
    private(set) var backgroundUpdatesText = "Start Pulse to monitor your herd"

    /// Aggregate-only snapshot the menu bar renders. `nil` while Pulse is off.
    private(set) var contentState: HerdPulseContentState?

    /// Binding source for `MenuBarExtra(isInserted:)`. Reads mirror `isRunning`;
    /// writes arrive when the user drags the item out of the menu bar, which is
    /// the Mac equivalent of iOS ending a Live Activity behind the app's back.
    var isMenuBarInserted: Bool {
        get { isRunning }
        set {
            guard newValue != isRunning else { return }
            defaults.set(newValue, forKey: "herdr.herdPulse.enabled")
            if newValue {
                startPulse()
            } else {
                stopPulse(removedFromMenuBar: true)
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let operationGate = HerdPulseOperationGate()
    @ObservationIgnored private var aggregate = HerdPulseAggregate(
        workspaces: [],
        connectionState: .disconnected
    )
    @ObservationIgnored private var serverConnection: ActiveServerConnection?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func synchronize(context: HerdPulseSyncContext) async {
        await operationGate.acquire()
        if !Task.isCancelled {
            performSynchronization(context: context)
        }
        await operationGate.release()
    }

    func toggle() async {
        guard !isBusy else { return }
        isBusy = true
        await operationGate.acquire()

        if isRunning {
            defaults.set(false, forKey: "herdr.herdPulse.enabled")
            stopPulse()
        } else {
            defaults.set(true, forKey: "herdr.herdPulse.enabled")
            performSynchronization(
                context: HerdPulseSyncContext(
                    aggregate: aggregate,
                    serverConnection: serverConnection
                )
            )
        }

        await operationGate.release()
        isBusy = false
    }

    private func performSynchronization(context: HerdPulseSyncContext) {
        let aggregateChanged = aggregate != context.aggregate
        aggregate = context.aggregate
        serverConnection = context.serverConnection

        guard defaults.bool(forKey: "herdr.herdPulse.enabled") else {
            guard isRunning || contentState != nil else { return }
            stopPulse()
            return
        }

        // Republish only on a real change so the menu bar does not redraw on
        // every poll — the iOS build guarded its activity updates the same way.
        guard aggregateChanged || !isRunning || contentState == nil else { return }
        startPulse()
    }

    private func startPulse() {
        let state = aggregate.contentState()
        contentState = state
        isRunning = true
        statusText = state.phase.displayTitle
        backgroundUpdatesText = "Pulse lives in your menu bar"
    }

    private func stopPulse(removedFromMenuBar: Bool = false) {
        contentState = nil
        isRunning = false
        statusText = "Off"
        backgroundUpdatesText = removedFromMenuBar
            ? "Pulse left the menu bar, start Pulse to resume"
            : "Start Pulse to monitor your herd"
    }
}

private extension HerdPulsePhase {
    var displayTitle: String {
        switch self {
        case .attention: "Needs you"
        case .ready: "Ready to review"
        case .working: "Herd working"
        case .resting: "All quiet"
        case .offline: "Last known"
        }
    }
}
