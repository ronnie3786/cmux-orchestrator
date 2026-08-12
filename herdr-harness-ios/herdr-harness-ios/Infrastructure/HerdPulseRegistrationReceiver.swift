import Foundation

struct HerdPulseRegistrationReceiver: Sendable {
    private weak var coordinator: HerdPulseCoordinator?
    private let activityID: String
    private let pushToken: String
    private let generation: Int

    @MainActor
    init(
        coordinator: HerdPulseCoordinator,
        activityID: String,
        pushToken: String,
        generation: Int
    ) {
        self.coordinator = coordinator
        self.activityID = activityID
        self.pushToken = pushToken
        self.generation = generation
    }

    func receive(_ attempt: HerdPulseRegistrationAttempt) async {
        await coordinator?.receiveRegistrationAttempt(
            attempt,
            activityID: activityID,
            pushToken: pushToken,
            generation: generation
        )
    }
}
