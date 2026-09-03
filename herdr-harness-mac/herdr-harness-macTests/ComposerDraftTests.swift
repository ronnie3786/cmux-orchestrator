import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Per-pane composer drafts")
struct ComposerDraftTests {
    @Test("Each pane keeps its own draft")
    func draftsAreKeyedByPane() {
        let model = makeModel()
        model.setComposerDraft("for pane a", for: "m1|a")
        model.setComposerDraft("for pane b", for: "m1|b")

        #expect(model.composerDraft(for: "m1|a") == "for pane a")
        #expect(model.composerDraft(for: "m1|b") == "for pane b")
        // Switching to a chat you have never typed in gives a blank field.
        #expect(model.composerDraft(for: "m1|c").isEmpty)
    }

    @Test("A blank draft is dropped rather than stored")
    func blankDraftsAreNotKept() {
        let model = makeModel()
        model.setComposerDraft("something", for: "m1|a")
        #expect(model.composerDrafts["m1|a"] != nil)

        // Sending clears the field; that should not leave an entry behind for
        // every pane the user has ever visited.
        model.setComposerDraft("", for: "m1|a")
        #expect(model.composerDrafts["m1|a"] == nil)

        model.setComposerDraft("   \n  ", for: "m1|a")
        #expect(model.composerDrafts["m1|a"] == nil)
    }

    @Test("Removing a machine takes only its own drafts")
    func removingAMachineIsScoped() {
        let model = makeModel()
        model.setComposerDraft("mine", for: "demo1|a")
        model.setComposerDraft("theirs", for: "other|a")

        model.removeMachine(id: "demo1")

        #expect(model.composerDraft(for: "demo1|a").isEmpty)
        #expect(model.composerDraft(for: "other|a") == "theirs")
    }

    private func makeModel() -> HerdrAppModel {
        let suiteName = "ComposerDraftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
    }
}
