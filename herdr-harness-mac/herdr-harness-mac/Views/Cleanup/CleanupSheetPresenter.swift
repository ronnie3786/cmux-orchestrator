import Observation

@MainActor
@Observable
final class CleanupSheetPresenter {
    var target: CleanupSheetTarget?
    private(set) var controller: CleanupRunController?
    private var presentedTargetID: String?

    func present(_ target: CleanupSheetTarget, using model: HerdrAppModel) {
        if controller == nil || presentedTargetID != target.id {
            controller = model.makeCleanupController(for: target)
            presentedTargetID = target.id
        }
        self.target = target
    }
}
