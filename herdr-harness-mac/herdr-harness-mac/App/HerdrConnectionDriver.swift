import Foundation

/// Owns the background work whose lifetime is the *process*, not the window.
///
/// On iOS the app and its single scene had the same lifetime, so the root view
/// could hold the `/api/v1/events` loop in a `.task` and be right. On the Mac
/// the window is closable while the app keeps running behind the menu-bar
/// extra — and the whole reason this port drops the APNs stack is that "a
/// menu-bar process stays alive with the event stream connected"
/// (`NotificationManager.registerForRemoteNotifications`). A stream that dies
/// with the window would silently break local alerts and freeze Herd Pulse on
/// a stale "Live" reading.
///
/// So the tasks live here, held by the `App` for as long as the process runs.
/// The window only *tells* the driver when something changed; it never owns the
/// work.
@MainActor
final class HerdrConnectionDriver {
    private var connectionTask: Task<Void, Never>?
    private var pulseTask: Task<Void, Never>?
    private var startedGeneration: Int?

    /// Starts the event stream, and restarts it when the server identity
    /// changes. Idempotent, so the window may call it on every appearance.
    func syncConnection(model: HerdrAppModel) {
        guard model.hasCompletedSetup else {
            connectionTask?.cancel()
            connectionTask = nil
            startedGeneration = nil
            return
        }

        guard startedGeneration != model.connectionGeneration || connectionTask == nil else {
            return
        }

        startedGeneration = model.connectionGeneration
        connectionTask?.cancel()
        connectionTask = Task { await model.runConnection() }
    }

    /// Feeds Herd Pulse from the same fleet snapshot the window renders.
    ///
    /// iOS drove this from a `.task(id: context)` on the root view — fine when
    /// the view is immortal. Here the context has to keep being recomputed
    /// while no window exists, so the driver samples it instead. The comparison
    /// keeps the actual `synchronize` calls change-driven, exactly as before.
    func startPulse(model: HerdrAppModel, pulse: HerdPulseCoordinator) {
        guard pulseTask == nil else { return }

        pulseTask = Task {
            var lastContext: HerdPulseSyncContext?
            while !Task.isCancelled {
                let context = HerdPulseSyncContext(
                    aggregate: HerdPulseAggregate(
                        workspaces: model.workspaces,
                        connectionState: model.connectionState
                    ),
                    serverConnection: model.activeServerConnection
                )
                if context != lastContext {
                    lastContext = context
                    await pulse.synchronize(context: context)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
