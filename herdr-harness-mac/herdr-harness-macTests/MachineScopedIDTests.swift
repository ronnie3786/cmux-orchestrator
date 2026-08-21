import Testing
@testable import herdr_harness_mac

@Suite("Machine scoped IDs")
struct MachineScopedIDTests {
    @Test("Compose and split preserve raw IDs")
    func roundTrip() {
        let rawID = "workspace:tab.pane_value-1"
        let parts = MachineScopedID.split(MachineScopedID.compose(machineID: "machine-1", rawID: rawID))
        #expect(parts?.machineID == "machine-1")
        #expect(parts?.rawID == rawID)
    }

    @Test("Split uses the first separator")
    func firstSeparator() {
        let parts = MachineScopedID.split("machine|raw|suffix")
        #expect(parts?.machineID == "machine")
        #expect(parts?.rawID == "raw|suffix")
    }
}
