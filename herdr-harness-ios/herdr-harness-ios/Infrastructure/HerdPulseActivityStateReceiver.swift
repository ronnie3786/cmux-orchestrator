import ActivityKit

struct HerdPulseActivityStateReceiver: Sendable {
    private weak var coordinator: HerdPulseCoordinator?
    private let activityID: String
    private let generation: Int

    @MainActor
    init(
        coordinator: HerdPulseCoordinator,
        activityID: String,
        generation: Int
    ) {
        self.coordinator = coordinator
        self.activityID = activityID
        self.generation = generation
    }

    func receive(_ state: ActivityState) async {
        await coordinator?.scheduleActivityStateCleanup(
            state,
            activityID: activityID,
            generation: generation
        )
    }
}
