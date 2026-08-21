import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Herdr app model starred chats", .serialized)
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

    @MainActor
    @Test("Refreshing one machine preserves another machine's stars")
    func reconcilesStarsPerMachine() {
        let defaults = UserDefaults.standard
        let previousStars = defaults.object(forKey: "herdr.sidebar.starredChats")
        defer {
            if let previousStars { defaults.set(previousStars, forKey: "herdr.sidebar.starredChats") }
            else { defaults.removeObject(forKey: "herdr.sidebar.starredChats") }
        }
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"])
        model.starredChatIDs = ["machine-a|old", "machine-b|keep"]
        model.reconcileStarredChats(machineID: "machine-a", serverStarredRawIDs: ["fresh"])
        #expect(model.starredChatIDs == ["machine-a|fresh", "machine-b|keep"])
        model.reconcileStarredChats(machineID: "machine-a", serverStarredRawIDs: nil)
        #expect(model.starredChatIDs == ["machine-a|fresh", "machine-b|keep"])
    }

    @MainActor
    @Test("Removing a machine purges only its slices")
    func removesMachineSlices() {
        let defaults = UserDefaults.standard
        let previousStars = defaults.object(forKey: "herdr.sidebar.starredChats")
        let previousCollapsed = defaults.object(forKey: "herdr.sidebar.collapsedWorkspaces")
        defer {
            if let previousStars { defaults.set(previousStars, forKey: "herdr.sidebar.starredChats") }
            else { defaults.removeObject(forKey: "herdr.sidebar.starredChats") }
            if let previousCollapsed { defaults.set(previousCollapsed, forKey: "herdr.sidebar.collapsedWorkspaces") }
            else { defaults.removeObject(forKey: "herdr.sidebar.collapsedWorkspaces") }
        }
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"])
        model.removeMachine(id: "demo1")
        #expect(!model.workspaces.contains { $0.machineID == "demo1" })
        #expect(!model.alerts.contains { $0.machineID == "demo1" })
        #expect(model.workspaces.contains { $0.machineID == "demo2" })
    }
}
