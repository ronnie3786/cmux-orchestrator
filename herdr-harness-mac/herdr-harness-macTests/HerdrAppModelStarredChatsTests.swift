import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr app model starred chats")
struct HerdrAppModelStarredChatsTests {
    @MainActor
    @Test("Toggling a starred chat persists local state")
    func togglesAndPersistsStarredChat() {
        let key = "herdr.sidebar.starredChats"
        let paneID = "test:starred-pane"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"])
        model.toggleStarredChat(paneID)

        #expect(model.starredChatIDs.contains(paneID))
        #expect(UserDefaults.standard.stringArray(forKey: key)?.contains(paneID) == true)

        model.toggleStarredChat(paneID)

        #expect(!model.starredChatIDs.contains(paneID))
        #expect(UserDefaults.standard.stringArray(forKey: key)?.contains(paneID) != true)
    }
}
