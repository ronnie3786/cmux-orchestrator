import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class HerdPulseCoordinator {
    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var statusText = "Off"
    private(set) var backgroundUpdatesText = "Start Pulse to monitor your herd"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let operationGate = HerdPulseOperationGate()
    @ObservationIgnored private var aggregate = HerdPulseAggregate(
        workspaces: [],
        connectionState: .disconnected
    )
    @ObservationIgnored private var registrationClient: HerdPulseRegistrationClient?
    @ObservationIgnored private var registrationConnection: ActiveServerConnection?
    @ObservationIgnored private var observedActivityID: String?
    @ObservationIgnored private var observedPushToken: String?
    @ObservationIgnored private var serverRegisteredPushToken: String?
    @ObservationIgnored private var pushTokenTask: Task<Void, Never>?
    @ObservationIgnored private var activityStateTask: Task<Void, Never>?
    @ObservationIgnored private var registrationRetryTask: Task<Void, Never>?
    @ObservationIgnored private var registrationGeneration = 0
    @ObservationIgnored private var lastContentState: HerdPulseAttributes.ContentState?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func synchronize(context: HerdPulseSyncContext) async {
        await operationGate.acquire()
        if !Task.isCancelled {
            await performSynchronization(context: context)
        }
        await operationGate.release()
    }

    func toggle() async {
        guard !isBusy else { return }
        isBusy = true
        await operationGate.acquire()

        if isRunning || !Self.activityIDs().isEmpty {
            defaults.set(false, forKey: "herdr.herdPulse.enabled")
            await stopPulse()
        } else {
            defaults.set(true, forKey: "herdr.herdPulse.enabled")
            await performSynchronization(
                context: HerdPulseSyncContext(
                    aggregate: aggregate,
                    serverConnection: registrationConnection
                )
            )
        }

        await operationGate.release()
        isBusy = false
    }

    private func performSynchronization(context: HerdPulseSyncContext) async {
        let aggregateChanged = aggregate != context.aggregate
        let revealSessionTitlesChanged = aggregate.revealSessionTitles != context.aggregate.revealSessionTitles
        aggregate = context.aggregate
        var activityIDs = Self.activityIDs()

        await switchRegistrationServer(
            to: context.serverConnection,
            activityIDs: activityIDs
        )

        guard defaults.bool(forKey: "herdr.herdPulse.enabled") || !activityIDs.isEmpty else {
            setInactiveStatus()
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            defaults.set(false, forKey: "herdr.herdPulse.enabled")
            await stopPulse(unavailable: true)
            return
        }

        if activityIDs.count > 1 {
            for duplicateID in activityIDs.dropFirst() {
                await unregister(activityID: duplicateID, client: registrationClient)
                await Self.endActivity(
                    id: duplicateID,
                    contentState: aggregate.contentState(),
                    dismissalPolicy: .immediate
                )
            }
            activityIDs = Array(activityIDs.prefix(1))
        }

        let activityID: String
        if let existingID = activityIDs.first {
            activityID = existingID
        } else {
            do {
                let state = aggregate.contentState()
                activityID = try await Self.requestActivity(
                    state: state,
                    staleDate: staleDate(for: state.connection),
                    relevanceScore: relevanceScore(for: state)
                )
                lastContentState = state
            } catch {
                defaults.set(false, forKey: "herdr.herdPulse.enabled")
                isRunning = false
                statusText = "Couldn’t start"
                backgroundUpdatesText = error.localizedDescription
                return
            }
        }

        guard !Task.isCancelled else {
            await unregister(activityID: activityID, client: registrationClient)
            await Self.endActivity(
                id: activityID,
                contentState: aggregate.contentState(),
                dismissalPolicy: .immediate
            )
            return
        }

        isRunning = true
        statusText = aggregate.phase.displayTitle
        await observePushTokens(activityID: activityID)
        if revealSessionTitlesChanged {
            await reregisterPushTokenForSessionTitlePreference(activityID: activityID)
        }
        if aggregateChanged || lastContentState == nil {
            await updateActivity(id: activityID)
        }
    }

    private func updateActivity(id activityID: String) async {
        let state = aggregate.contentState()
        lastContentState = state
        statusText = state.phase.displayTitle
        await Self.updateActivity(
            id: activityID,
            contentState: state,
            staleDate: staleDate(for: state.connection),
            relevanceScore: relevanceScore(for: state)
        )
    }

    private func stopPulse(unavailable: Bool = false) async {
        await stopActivityObservation()
        let activityIDs = Self.activityIDs()
        for activityID in activityIDs {
            await unregister(activityID: activityID, client: registrationClient)
            await Self.endActivity(
                id: activityID,
                contentState: aggregate.contentState(),
                dismissalPolicy: .immediate
            )
        }

        observedActivityID = nil
        observedPushToken = nil
        serverRegisteredPushToken = nil
        lastContentState = nil
        isRunning = false
        if unavailable {
            statusText = "Unavailable"
            backgroundUpdatesText = "Enable Live Activities in iOS Settings"
        } else {
            setInactiveStatus()
        }
    }

    private func switchRegistrationServer(
        to connection: ActiveServerConnection?,
        activityIDs: [String]
    ) async {
        guard connection != registrationConnection else { return }

        let oldClient = registrationClient
        let oldObservedActivityID = observedActivityID
        let oldObservedPushToken = observedPushToken

        await stopActivityObservation()
        if let oldClient {
            for activityID in activityIDs {
                let token = activityID == oldObservedActivityID
                    ? oldObservedPushToken ?? Self.currentPushToken(activityID: activityID)
                    : Self.currentPushToken(activityID: activityID)
                try? await oldClient.unregister(
                    activityID: activityID,
                    pushToken: token
                )
            }
        }

        registrationConnection = connection
        registrationClient = connection.map {
            HerdPulseRegistrationClient(configuration: $0.configuration)
        }
        observedActivityID = nil
        observedPushToken = nil
        serverRegisteredPushToken = nil
        if connection == nil, isRunning {
            backgroundUpdatesText = "Open Herdr for updates, demo runs locally"
        }
    }

    private func observePushTokens(activityID: String) async {
        if observedActivityID == activityID,
           pushTokenTask != nil,
           activityStateTask != nil {
            return
        }
        await stopActivityObservation()

        registrationGeneration += 1
        let generation = registrationGeneration
        observedActivityID = activityID
        observedPushToken = nil
        serverRegisteredPushToken = nil
        let receiver = HerdPulseTokenReceiver(
            coordinator: self,
            activityID: activityID,
            generation: generation
        )
        pushTokenTask = Task {
            await Self.listenForPushTokens(activityID: activityID) { token in
                await receiver.receive(token)
            }
        }
        let stateReceiver = HerdPulseActivityStateReceiver(
            coordinator: self,
            activityID: activityID,
            generation: generation
        )
        activityStateTask = Task {
            await Self.listenForActivityState(activityID: activityID) { state in
                await stateReceiver.receive(state)
            }
        }

        if let token = Self.currentPushToken(activityID: activityID) {
            await receivePushToken(
                token,
                activityID: activityID,
                generation: generation
            )
        } else if registrationClient == nil {
            backgroundUpdatesText = "Open Herdr for updates, demo runs locally"
        } else {
            backgroundUpdatesText = "Waiting for an ActivityKit push token"
        }
    }

    private func stopActivityObservation() async {
        registrationGeneration += 1
        let tokenTask = pushTokenTask
        let stateTask = activityStateTask
        let retryTask = registrationRetryTask
        pushTokenTask = nil
        activityStateTask = nil
        registrationRetryTask = nil
        tokenTask?.cancel()
        stateTask?.cancel()
        retryTask?.cancel()
        await tokenTask?.value
        await retryTask?.value
        await stateTask?.value
    }

    private func reregisterPushTokenForSessionTitlePreference(activityID: String) async {
        guard activityID == observedActivityID, let token = observedPushToken else { return }
        let retryTask = registrationRetryTask
        registrationRetryTask = nil
        retryTask?.cancel()
        await retryTask?.value
        guard activityID == observedActivityID, observedPushToken == token else { return }
        serverRegisteredPushToken = nil
        await receivePushToken(token, activityID: activityID, generation: registrationGeneration)
    }

    func receivePushToken(
        _ token: String,
        activityID: String,
        generation: Int
    ) async {
        guard generation == registrationGeneration,
              activityID == observedActivityID,
              isRunning,
              defaults.bool(forKey: "herdr.herdPulse.enabled")
        else { return }

        let previous = observedPushToken
        guard previous != token ||
                (registrationRetryTask == nil && serverRegisteredPushToken != token)
        else { return }
        guard let client = registrationClient else {
            observedPushToken = token
            backgroundUpdatesText = "Open Herdr for updates, demo runs locally"
            return
        }

        let previousRetry = registrationRetryTask
        registrationRetryTask = nil
        previousRetry?.cancel()
        await previousRetry?.value
        guard generation == registrationGeneration else { return }

        if let previous {
            try? await client.unregister(activityID: activityID, pushToken: previous)
        }
        guard generation == registrationGeneration else { return }

        observedPushToken = token
        serverRegisteredPushToken = nil
        backgroundUpdatesText = "Registering with Herdr for background updates"
        let receiver = HerdPulseRegistrationReceiver(
            coordinator: self,
            activityID: activityID,
            pushToken: token,
            generation: generation
        )
        registrationRetryTask = Task {
            await Self.registerWithRetry(
                client: client,
                activityID: activityID,
                pushToken: token,
                revealSessionTitles: aggregate.revealSessionTitles,
                receiver: receiver
            )
        }
    }

    func receiveRegistrationAttempt(
        _ attempt: HerdPulseRegistrationAttempt,
        activityID: String,
        pushToken: String,
        generation: Int
    ) async {
        guard generation == registrationGeneration,
              activityID == observedActivityID,
              pushToken == observedPushToken,
              isRunning,
              defaults.bool(forKey: "herdr.herdPulse.enabled")
        else { return }

        switch attempt {
        case let .succeeded(capability):
            registrationRetryTask = nil
            serverRegisteredPushToken = pushToken
            backgroundUpdatesText = switch capability {
            case .configured:
                "Registered with Herdr, APNs delivery not yet verified"
            case .unavailable:
                "Registered with Herdr, server APNs is not configured"
            case .unknown:
                "Registered with Herdr, APNs status unavailable"
            }
        case let .failed(willRetry, retryDelay):
            if willRetry, let retryDelay {
                backgroundUpdatesText = "Herdr registration failed, retrying in \(Self.seconds(retryDelay))s"
            } else {
                registrationRetryTask = nil
                serverRegisteredPushToken = nil
                backgroundUpdatesText = "Herdr registration failed, keep Herdr open for updates"
            }
        }
    }

    func scheduleActivityStateCleanup(
        _ state: ActivityState,
        activityID: String,
        generation: Int
    ) {
        // The observation task must finish before cleanup awaits its value.
        // Scheduling a separate weak task prevents the observer from awaiting
        // itself when ActivityKit reports an ended or dismissed state.
        Task { @MainActor [weak self] in
            await self?.receiveActivityState(
                state,
                activityID: activityID,
                generation: generation
            )
        }
    }

    private func receiveActivityState(
        _ state: ActivityState,
        activityID: String,
        generation: Int
    ) async {
        guard state == .ended || state == .dismissed else { return }
        await operationGate.acquire()

        guard generation == registrationGeneration,
              activityID == observedActivityID
        else {
            await operationGate.release()
            return
        }

        let client = registrationClient
        let token = observedPushToken ?? Self.currentPushToken(activityID: activityID)
        await stopActivityObservation()
        if let client {
            try? await client.unregister(activityID: activityID, pushToken: token)
        }

        defaults.set(false, forKey: "herdr.herdPulse.enabled")
        observedActivityID = nil
        observedPushToken = nil
        serverRegisteredPushToken = nil
        lastContentState = nil
        isRunning = false
        statusText = "Off"
        backgroundUpdatesText = "Live Activity ended in iOS, start Pulse to resume"
        await operationGate.release()
    }

    private func unregister(
        activityID: String,
        client: HerdPulseRegistrationClient?
    ) async {
        guard let client else { return }
        let token = activityID == observedActivityID
            ? observedPushToken ?? Self.currentPushToken(activityID: activityID)
            : Self.currentPushToken(activityID: activityID)
        try? await client.unregister(activityID: activityID, pushToken: token)
    }

    private func setInactiveStatus() {
        statusText = "Off"
        backgroundUpdatesText = "Start Pulse to monitor your herd"
    }

    private func staleDate(for connection: HerdPulseConnection) -> Date {
        if connection == .offline { return .now }
        return .now.addingTimeInterval(15 * 60)
    }

    private func relevanceScore(for state: HerdPulseAttributes.ContentState) -> Double {
        switch state.phase {
        case .attention: 100
        case .ready: 80
        case .working: 50
        case .resting: 20
        case .offline: 10
        }
    }

    nonisolated private static func activityIDs() -> [String] {
        Activity<HerdPulseAttributes>.activities.compactMap { activity in
            switch activity.activityState {
            case .ended, .dismissed:
                nil
            default:
                activity.id
            }
        }
    }

    nonisolated private static func seconds(_ duration: Duration) -> Int64 {
        max(duration.components.seconds, 1)
    }

    nonisolated private static func currentPushToken(activityID: String) -> String? {
        Activity<HerdPulseAttributes>.activities
            .first(where: { $0.id == activityID })?
            .pushToken?
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @concurrent
    nonisolated private static func requestActivity(
        state: HerdPulseAttributes.ContentState,
        staleDate: Date,
        relevanceScore: Double
    ) async throws -> String {
        let now = Date.now
        let activity = try Activity.request(
            attributes: HerdPulseAttributes(
                pulseID: UUID().uuidString,
                startedAt: Int(now.timeIntervalSince1970)
            ),
            content: ActivityContent(
                state: state,
                staleDate: staleDate,
                relevanceScore: relevanceScore
            ),
            pushType: .token
        )
        return activity.id
    }

    @concurrent
    nonisolated private static func updateActivity(
        id activityID: String,
        contentState: HerdPulseAttributes.ContentState,
        staleDate: Date,
        relevanceScore: Double
    ) async {
        guard let activity = Activity<HerdPulseAttributes>.activities.first(where: {
            $0.id == activityID
        }) else { return }
        let content = ActivityContent(
            state: contentState,
            staleDate: staleDate,
            relevanceScore: relevanceScore
        )
        await activity.update(content)
    }

    @concurrent
    nonisolated private static func endActivity(
        id activityID: String,
        contentState: HerdPulseAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        guard let activity = Activity<HerdPulseAttributes>.activities.first(where: {
            $0.id == activityID
        }) else { return }
        let content = ActivityContent(state: contentState, staleDate: nil)
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }

    @concurrent
    nonisolated private static func listenForPushTokens(
        activityID: String,
        receive: @escaping @Sendable (String) async -> Void
    ) async {
        guard let activity = Activity<HerdPulseAttributes>.activities.first(where: {
            $0.id == activityID
        }) else { return }
        let updates = activity.pushTokenUpdates
        for await tokenData in updates {
            guard !Task.isCancelled else { return }
            let token = tokenData.map { String(format: "%02x", $0) }.joined()
            await receive(token)
        }
    }

    @concurrent
    nonisolated private static func listenForActivityState(
        activityID: String,
        receive: @escaping @Sendable (ActivityState) async -> Void
    ) async {
        guard let activity = Activity<HerdPulseAttributes>.activities.first(where: {
            $0.id == activityID
        }) else { return }
        if activity.activityState == .ended || activity.activityState == .dismissed {
            await receive(activity.activityState)
            return
        }
        for await state in activity.activityStateUpdates {
            guard !Task.isCancelled else { return }
            if state == .ended || state == .dismissed {
                await receive(state)
                return
            }
        }
    }

    @concurrent
    nonisolated private static func registerWithRetry(
        client: HerdPulseRegistrationClient,
        activityID: String,
        pushToken: String,
        revealSessionTitles: Bool,
        receiver: HerdPulseRegistrationReceiver,
        policy: HerdPulseRegistrationRetryPolicy = .standard
    ) async {
        var failureCount = 0
        while !Task.isCancelled {
            do {
                let capability = try await client.register(
                    activityID: activityID,
                    pushToken: pushToken,
                    revealSessionTitles: revealSessionTitles
                )
                guard !Task.isCancelled else { return }
                await receiver.receive(.succeeded(capability))
                return
            } catch is CancellationError {
                return
            } catch {
                failureCount += 1
                let willRetry = policy.shouldRetry(error)
                let delay = willRetry ? policy.delay(afterFailure: failureCount) : nil
                await receiver.receive(.failed(willRetry: willRetry, retryDelay: delay))
                guard willRetry, let delay else { return }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
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
