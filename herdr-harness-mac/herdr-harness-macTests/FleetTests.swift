import Foundation
import Testing
import SwiftUI
@testable import herdr_harness_mac

@Suite("Fleet contract and store", .serialized)
@MainActor
struct FleetTests {
    @Test("Decodes one-machine inventory without leaking machine metadata")
    func decodesMachineInventory() throws {
        let data = Data(
            """
            {
              "ok": true,
              "catalogRevision": "rev-42",
              "machine": { "platform": "Darwin", "release": "25.0", "architecture": "arm64", "herdrSession": "private" },
              "items": [
                { "id": "skill:reviewer", "type": "skill", "name": "reviewer", "status": "current", "installed": true, "current": true, "drifted": false, "missing": false, "managed": true, "ownership": "managed", "version": "2.4.0" },
                { "id": "skill:adoptable", "type": "skill", "name": "adoptable", "status": "current", "installed": true, "current": true, "managed": false, "ownership": "unmanaged", "canAdopt": true, "version": "1.0.0" },
                { "id": "cli:slack", "type": "cli", "name": "slack", "status": "missing", "installed": false, "current": false, "drifted": false, "missing": true, "managed": false, "ownership": "not_installed", "installable": false, "authCheckAvailable": false, "auth": { "configured": null, "required": true, "checkAvailable": true, "status": "notChecked" } }
              ],
              "generatedAt": "2026-09-01T15:20:00Z"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(FleetResponse.self, from: data)
        #expect(response.ok)
        #expect(response.catalogRevision == "rev-42")
        #expect(response.items.count == 3)
        #expect(response.machine?.machineID == "")

        let adoptable = try #require(response.items.first(where: { $0.id == "skill:adoptable" }))
        #expect(adoptable.category == .skills)
        #expect(adoptable.ownership == .unmanaged)
        #expect(adoptable.canAdopt)

        let slack = try #require(response.items.first(where: { $0.id == "cli:slack" }))
        #expect(slack.category == .cli)
        #expect(slack.installable == false)
        #expect(slack.auth?.configured == nil)
        #expect(slack.auth?.status == "notChecked")
    }

    @Test("Preserves missing and auth-unknown states instead of assuming installed")
    func preservesSafeUnknowns() throws {
        let data = Data(
            """
            {
              "status": "missing",
              "managed": false,
              "ownership": "unmanaged",
              "auth": { "configured": null, "required": true, "checkAvailable": true, "status": "notChecked" }
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(FleetMachineItemState.self, from: data)
        #expect(state.state == .missing)
        #expect(state.ownership == .unmanaged)
        #expect(state.auth?.configured == nil)
        #expect(state.authCheckAvailable)
    }

    @Test("Maps read-only backend ownership classifications to external")
    func decodesReadOnlyOwnershipClassifications() throws {
        let classifications = ["readonly", "read_only", "unclassified", "orphan"]

        for classification in classifications {
            let state = try JSONDecoder().decode(
                FleetMachineItemState.self,
                from: Data("{\"ownership\":\"\(classification)\"}".utf8)
            )
            #expect(state.ownership == .external)

            let item = try JSONDecoder().decode(
                FleetInventoryItem.self,
                from: Data("{\"id\":\"skill:\(classification)\",\"type\":\"skill\",\"ownership\":\"\(classification)\"}".utf8)
            )
            #expect(item.ownership == .external)
        }
    }

    @Test("Maps saved machine names to safe device labels and exactly one card each")
    func mapsMachineKinds() {
        let source = [
            HerdrMachine(id: "work", name: "Doximity Mac", urlString: "http://localhost:9092"),
            HerdrMachine(id: "studio", name: "RocketBot", urlString: "https://rocketbot.tailnet"),
            HerdrMachine(id: "dev", name: "DevBox-MacBook-Pro", urlString: "https://devbox.tailnet"),
        ]
        let store = FleetStore(
            machines: source,
            connectionStates: ["work": .live, "studio": .live, "dev": .disconnected]
        )

        #expect(store.machines.count == source.count)
        #expect(store.machines.map(\.role) == [.workMac, .thisMac, .devBox])
        #expect(store.machines.map(\.kind) == [.macBookPro, .macStudio, .iMac])
        #expect(store.machines.map(\.displayName) == ["Work Mac", "This Mac", "DevBox"])
    }

    @Test("Encodes the backend action contract without a client machine id")
    func encodesActionRequest() throws {
        let data = try JSONEncoder().encode(
            FleetActionRequest(itemID: "cli:slack", action: .authCheck)
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["itemId"] as? String == "cli:slack")
        #expect(object["action"] as? String == "checkAuth")
        #expect(object["machineId"] == nil)
    }

    @Test("Leaves enough time for long-running Fleet operations")
    func fleetRequestTimeouts() {
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/fleet", method: "GET") == 15)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/fleet/sync", method: "POST") == 150)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/fleet/action", method: "POST") == 150)
    }

    @Test("Manage adopts a matching unmanaged demo item and keeps external items read-only")
    func managesAndProtectsItems() async throws {
        let machines = [
            HerdrMachine(id: "studio", name: "RocketBot", urlString: "http://localhost:9092"),
            HerdrMachine(id: "dev", name: "DevBox", urlString: "http://devbox:9092"),
            HerdrMachine(id: "work", name: "Doximity Mac", urlString: "http://localhost:9093"),
        ]
        let store = FleetStore(
            machines: machines,
            connectionStates: Dictionary(uniqueKeysWithValues: machines.map { ($0.id, ConnectionState.demo) }),
            isDemoMode: true
        )
        let adoptable = try #require(store.items.first(where: { $0.id == "skill:local-playbook" }))
        #expect(store.state(for: adoptable, machineID: "studio").ownership == .unmanaged)
        #expect(store.state(for: adoptable, machineID: "studio").canAdopt)

        await store.perform(.manage, itemID: adoptable.id, machineID: "studio")
        let managed = try #require(store.items.first(where: { $0.id == adoptable.id }))
        #expect(store.state(for: managed, machineID: "studio").ownership == .managed)
        #expect(store.state(for: managed, machineID: "studio").canAdopt == false)

        let external = try #require(store.items.first(where: { $0.id == "cli:slack" }))
        await store.perform(.remove, itemID: external.id, machineID: "studio")
        #expect(store.error(for: external.id, machineID: "studio")?.contains("read-only") == true)
    }

    @Test("Prunes a removed machine item without dropping another machine's state")
    func prunesRemovedMachineItemWhilePreservingOtherMachineState() throws {
        let machines = [
            HerdrMachine(id: "machine-a", name: "Machine A", urlString: "http://machine-a:9092"),
            HerdrMachine(id: "machine-b", name: "Machine B", urlString: "http://machine-b:9092"),
        ]
        let store = FleetStore(machines: machines)

        store.applyForTesting(
            FleetResponse(items: [
                FleetInventoryItem(
                    id: "skill:removed",
                    name: "Removed",
                    category: .skills,
                    machineStates: [
                        "machine-a": FleetMachineItemState(state: .installed)
                    ]
                ),
                FleetInventoryItem(
                    id: "skill:shared",
                    name: "Shared",
                    category: .skills,
                    machineStates: [
                        "machine-a": FleetMachineItemState(state: .installed),
                        "machine-b": FleetMachineItemState(state: .outdated)
                    ]
                )
            ])
        )

        store.applyForTesting(
            FleetResponse(items: [
                FleetInventoryItem(
                    id: "skill:shared",
                    name: "Shared",
                    category: .skills,
                    machineStates: [
                        "machine-a": FleetMachineItemState(state: .installed)
                    ]
                )
            ]),
            fallbackMachineID: "machine-a"
        )

        #expect(store.items.map(\.id) == ["skill:shared"])
        let shared = try #require(store.items.first)
        #expect(store.state(for: shared, machineID: "machine-b").state == .outdated)
    }
}

@Suite("Fleet management renders", .serialized)
@MainActor
struct FleetRenderTests {
    private func fleetRenderModel() -> HerdrAppModel {
        let model = HerdrRenderFixtures.demoModel()
        model.machines.append(
            HerdrMachine(
                id: "fleet-devbox",
                name: "DevBox",
                urlString: "https://devbox.tailnet"
            )
        )
        return model
    }

    @Test("Constellation and inventory matrix render at the roomy sheet size")
    func rendersFleetSheet() async throws {
        let model = fleetRenderModel()
        let result = try await HerdrRenderHarness.render(
            "fleet-management-sheet.png",
            size: CGSize(width: 1_180, height: 820)
        ) {
            FleetManagementSheet(model: model)
        }
        result.expectSubstantial()
    }

    @Test("Compact Fleet sheet render remains substantial")
    func rendersAccessibleFleetSheet() async throws {
        let model = fleetRenderModel()
        let result = try await HerdrRenderHarness.render(
            "fleet-management-sheet-accessible.png",
            size: CGSize(width: 940, height: 700)
        ) {
            FleetManagementSheet(model: model)
        }
        result.expectSubstantial()
    }

    @Test("Selected machine render keeps the public-safe constellation overlay")
    func rendersSelectedFleetMachine() async throws {
        let model = fleetRenderModel()
        let result = try await HerdrRenderHarness.render(
            "fleet-management-sheet-selected.png",
            size: CGSize(width: 1_180, height: 820)
        ) {
            FleetManagementSheet(model: model, initiallySelectedMachineID: "demo1")
        }
        result.expectSubstantial()
    }
}
