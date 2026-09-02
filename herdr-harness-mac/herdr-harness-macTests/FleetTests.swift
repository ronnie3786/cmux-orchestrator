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

    @Test("Decodes sync reconciliation counts and bounded item outcomes")
    func decodesSyncReconciliation() throws {
        let data = Data(
            """
            {
              "ok": true,
              "items": [],
              "reconciliation": {
                "counts": {
                  "total": 3,
                  "eligible": 3,
                  "attempted": 2,
                  "updated": 1,
                  "restored": 1,
                  "unchanged": 1,
                  "skipped": 0,
                  "current": 1,
                  "skippedDrifted": 0,
                  "failed": 0,
                  "rollbackRestored": 0
                },
                "items": [
                  {
                    "itemId": "skill:reviewer",
                    "status": "updated",
                    "outcome": "updated",
                    "state": "current",
                    "action": "update",
                    "target": "~/.agents/skills/reviewer",
                    "rollback": { "restored": true }
                  }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(FleetSyncResponse.self, from: data)
        let reconciliation = try #require(response.reconciliation)
        #expect(reconciliation.counts.updated == 1)
        #expect(reconciliation.counts.restored == 1)
        #expect(reconciliation.counts.unchanged == 1)
        #expect(reconciliation.counts.attempted == 2)
        let outcome = try #require(reconciliation.items.first)
        #expect(outcome.itemID == "skill:reviewer")
        #expect(outcome.status == "updated")
        #expect(outcome.rollbackRestored == true)
        #expect(response.fleet.items.isEmpty)
    }

    @Test("Keeps older sync responses compatible when reconciliation is absent")
    func decodesSyncWithoutReconciliation() throws {
        let data = Data(
            """
            {"ok":true,"items":[{"id":"skill:reviewer","type":"skill","name":"reviewer","status":"current"}]}
            """.utf8
        )

        let response = try JSONDecoder().decode(FleetSyncResponse.self, from: data)
        #expect(response.reconciliation == nil)
        #expect(response.fleet.items.map { $0.id } == ["skill:reviewer"])
    }

    @Test("Rejects incomplete, bounded, and inconsistent reconciliation counts")
    func rejectsInvalidSyncReconciliationCounts() throws {
        let valid: [String: Any] = [
            "total": 3,
            "eligible": 3,
            "attempted": 2,
            "updated": 1,
            "restored": 1,
            "unchanged": 1,
            "skipped": 0,
            "failed": 0,
            "current": 1,
            "rollbackRestored": 0,
            "skippedDrifted": 0,
        ]

        var missingField = valid
        missingField.removeValue(forKey: "failed")
        var negative = valid
        negative["updated"] = -1
        var huge = valid
        huge["total"] = FleetReconciliationCounts.maximumValue + 1
        var partitionMismatch = valid
        partitionMismatch["unchanged"] = 0
        partitionMismatch["current"] = 0
        var currentMismatch = valid
        currentMismatch["current"] = 0
        var skippedDriftMismatch = valid
        skippedDriftMismatch["skipped"] = 1
        skippedDriftMismatch["skippedDrifted"] = 2
        var rollbackMismatch = valid
        rollbackMismatch["failed"] = 0
        rollbackMismatch["rollbackRestored"] = 1
        var eligibilityMismatch = valid
        eligibilityMismatch["eligible"] = 2
        var attemptedMismatch = valid
        attemptedMismatch["attempted"] = 1

        let invalidCounts: [[String: Any]] = [
            [:],
            missingField,
            negative,
            huge,
            partitionMismatch,
            currentMismatch,
            skippedDriftMismatch,
            rollbackMismatch,
            eligibilityMismatch,
            attemptedMismatch,
        ]

        for counts in invalidCounts {
            let response: [String: Any] = [
                "ok": true,
                "items": [],
                "reconciliation": ["counts": counts],
            ]
            let data = try JSONSerialization.data(withJSONObject: response)
            let decoded = try JSONDecoder().decode(FleetSyncResponse.self, from: data)
            #expect(decoded.reconciliation == nil)
        }
    }

    @Test("Caps oversized reconciliation outcomes at 1024 items")
    func capsOversizedSyncReconciliationOutcomes() throws {
        let outcome: [String: Any] = ["status": "unchanged"]
        let outcomes = Array(repeating: outcome, count: FleetReconciliation.maximumDecodedItems + 1)
        let counts: [String: Any] = [
            "total": FleetReconciliation.maximumDecodedItems,
            "eligible": FleetReconciliation.maximumDecodedItems,
            "attempted": 0,
            "updated": 0,
            "restored": 0,
            "unchanged": FleetReconciliation.maximumDecodedItems,
            "skipped": 0,
            "failed": 0,
            "current": FleetReconciliation.maximumDecodedItems,
            "rollbackRestored": 0,
            "skippedDrifted": 0,
        ]
        let response: [String: Any] = [
            "ok": true,
            "items": [],
            "reconciliation": ["counts": counts, "items": outcomes],
        ]

        let data = try JSONSerialization.data(withJSONObject: response)
        let decoded = try JSONDecoder().decode(FleetSyncResponse.self, from: data)
        #expect(decoded.reconciliation?.items.count == FleetReconciliation.maximumDecodedItems)
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

    @Test("Merges arbitrary-order single-machine snapshots into three independent cards")
    func mergesIndependentSingleMachineSnapshots() throws {
        let machines = [
            HerdrMachine(id: "work", name: "Work Mac", urlString: "https://work.example"),
            HerdrMachine(id: "studio", name: "RocketBot", urlString: "https://studio.example"),
            HerdrMachine(id: "dev", name: "DevBox", urlString: "https://dev.example"),
        ]
        let store = FleetStore(machines: machines)
        let snapshots = Dictionary(uniqueKeysWithValues: machines.map { machine in
            (machine.id, makeLargeSingleMachineResponse(machineID: machine.id))
        })

        // Task-group completion is intentionally nondeterministic in
        // production. Applying the same three responses in a non-display
        // order reproduces the original bug, where only the first response
        // received any machineStates entries.
        for machineID in ["dev", "work", "studio"] {
            store.applyForTesting(try #require(snapshots[machineID]), fallbackMachineID: machineID)
        }

        #expect(store.items.count == 186)
        #expect(store.machines.map(\.itemCount) == [186, 186, 186])
        #expect(store.machines.map(\.skillsCount) == [172, 172, 172])
        #expect(store.machines.map(\.piExtensionsCount) == [7, 7, 7])
        #expect(store.machines.map(\.cliCount) == [7, 7, 7])
        #expect(store.machines.map(\.online) == [true, true, true])

        let representative = try #require(store.items.first(where: { $0.id == "skill:item-0" }))
        #expect(Set(representative.machineStates.keys) == Set(["work", "studio", "dev"]))
        #expect(store.state(for: representative, machineID: "work").state == .installed)
        #expect(store.state(for: representative, machineID: "studio").state == .outdated)
        #expect(store.state(for: representative, machineID: "dev").state == .missing)

        // A later refresh/sync can complete in a different order. It must
        // replace each requested machine's cells without dropping the others.
        for machineID in ["studio", "dev", "work"] {
            store.applyForTesting(try #require(snapshots[machineID]), fallbackMachineID: machineID)
        }

        #expect(store.items.count == 186)
        #expect(store.machines.map(\.itemCount) == [186, 186, 186])
        #expect(store.items.allSatisfy { Set($0.machineStates.keys) == Set(["work", "studio", "dev"]) })
    }

    @Test("A single-machine payload cannot redirect item state into another card")
    func scopesEmbeddedStatesToRequestingMachine() throws {
        let machines = [
            HerdrMachine(id: "work", name: "Work Mac", urlString: "https://work.example"),
            HerdrMachine(id: "studio", name: "RocketBot", urlString: "https://studio.example"),
        ]
        let store = FleetStore(machines: machines)
        let item = FleetInventoryItem(
            id: "skill:scoped",
            name: "scoped",
            category: .skills,
            status: .installed,
            installed: true,
            current: true,
            machineStates: [
                // A server-side machine key is not a local Herdr machine id.
                // The request's client identity must remain authoritative.
                "server-machine": FleetMachineItemState(state: .missing)
            ]
        )

        store.applyForTesting(FleetResponse(items: [item]), fallbackMachineID: "work")

        let scoped = try #require(store.items.first)
        #expect(Set(scoped.machineStates.keys) == Set(["work"]))
        #expect(store.state(for: scoped, machineID: "work").state == .installed)
        #expect(store.state(for: scoped, machineID: "studio").state == .unknown)
    }

    @Test("A failed machine refresh preserves last-known cells and other machine state")
    func failedMachineRefreshPreservesLastKnownCells() async throws {
        let machines = [
            HerdrMachine(id: "work", name: "Work Mac", urlString: "https://work.example"),
            HerdrMachine(id: "studio", name: "RocketBot", urlString: "https://studio.example"),
            HerdrMachine(id: "dev", name: "DevBox", urlString: "https://dev.example"),
        ]
        let responses = Dictionary(uniqueKeysWithValues: machines.map { machine in
            (URL(string: machine.urlString)!.host!, try! JSONEncoder().encode(makeLargeSingleMachineResponse(machineID: machine.id)))
        })
        FleetStoreURLProtocol.router.configure(responses: responses, failingHosts: ["dev.example"])
        defer { FleetStoreURLProtocol.router.reset() }

        let clients = Dictionary(uniqueKeysWithValues: machines.map { machine in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FleetStoreURLProtocol.self]
            let client = HerdrAPIClient(
                configuration: ServerConfiguration(urlString: machine.urlString, token: "test")!,
                session: URLSession(configuration: configuration)
            )
            return (machine.id, client)
        })
        let store = FleetStore(
            machines: machines,
            connectionStates: Dictionary(uniqueKeysWithValues: machines.map { ($0.id, ConnectionState.live) }),
            clients: clients
        )

        // Seed a complete, known-good matrix first. The subsequent refresh
        // fails only for DevBox, matching the production error path where a
        // failed task never calls apply().
        for machineID in ["work", "studio", "dev"] {
            store.applyForTesting(
                makeLargeSingleMachineResponse(machineID: machineID),
                fallbackMachineID: machineID
            )
        }
        let before = try #require(store.items.first(where: { $0.id == "skill:item-0" }))

        await store.refresh()

        #expect(store.machines.first(where: { $0.id == "dev" })?.online == false)
        #expect(store.machines.first(where: { $0.id == "work" })?.online == true)
        #expect(store.machines.first(where: { $0.id == "studio" })?.online == true)
        let after = try #require(store.items.first(where: { $0.id == before.id }))
        #expect(Set(after.machineStates.keys) == Set(["work", "studio", "dev"]))
        #expect(after.machineStates["dev"] == before.machineStates["dev"])
        #expect(after.machineStates["work"]?.state == .installed)
        #expect(after.machineStates["studio"]?.state == .outdated)
    }

    @Test("Reports all machines in sync for successful no-op reconciliation")
    func syncAllReportsNoOpSuccess() async {
        let machines = syncTestMachines()
        configureSyncResponses(for: machines)
        defer { FleetStoreURLProtocol.router.reset() }
        let store = makeSyncStore(machines: machines)

        await store.syncAll()

        #expect(store.notice == "All machines are in sync")
        #expect(store.machines.allSatisfy { $0.online })
        for machine in machines {
            #expect(FleetStoreURLProtocol.router.requestPaths(for: host(for: machine)) == ["/api/v1/fleet/sync"])
        }
    }

    @Test("Aggregates updates and restores without hiding successful machines")
    func syncAllAggregatesUpdatesAndRestores() async {
        let machines = syncTestMachines()
        configureSyncResponses(
            for: machines,
            counts: [
                "studio": FleetReconciliationCounts(updated: 1, restored: 1),
                "dev": FleetReconciliationCounts(updated: 2),
            ]
        )
        defer { FleetStoreURLProtocol.router.reset() }
        let store = makeSyncStore(machines: machines)

        await store.syncAll()

        #expect(store.notice == "Synced 3 of 3 machines: 3 updated, 1 restored")
        #expect(store.machines.allSatisfy { $0.online })
    }

    @Test("Reports preserved local edits and item failures without marking machines offline")
    func syncAllReportsDriftAndItemFailures() async {
        let machines = syncTestMachines()
        configureSyncResponses(
            for: machines,
            counts: [
                "studio": FleetReconciliationCounts(skipped: 2, skippedDrifted: 2),
                "dev": FleetReconciliationCounts(failed: 1),
            ]
        )
        defer { FleetStoreURLProtocol.router.reset() }
        let store = makeSyncStore(machines: machines)

        await store.syncAll()

        #expect(store.notice == "Synced 3 of 3 machines: 2 local edits preserved, 1 item failure")
        #expect(store.machines.allSatisfy { $0.online })
        #expect(!(store.notice ?? "").contains("/"))
    }

    @Test("Reports guarded skips separately from preserved local edits")
    func syncAllReportsGuardedSkips() async {
        let machines = syncTestMachines()
        configureSyncResponses(
            for: machines,
            counts: ["studio": FleetReconciliationCounts(skipped: 1)]
        )
        defer { FleetStoreURLProtocol.router.reset() }
        let store = makeSyncStore(machines: machines)

        await store.syncAll()

        #expect(store.notice == "Synced 3 of 3 machines: 1 guarded item skipped")
        #expect(store.machines.allSatisfy { $0.online })
    }

    @Test("Reports reachable machine count when one configured machine is offline")
    func syncAllReportsMixedConnectivity() async {
        let machines = syncTestMachines()
        configureSyncResponses(for: machines, failingHosts: [host(for: machines[1])])
        defer { FleetStoreURLProtocol.router.reset() }
        let store = makeSyncStore(machines: machines)

        await store.syncAll()

        #expect(store.notice == "Synced 2 of 3 machines")
        #expect(store.machines.first(where: { $0.id == "studio" })?.online == true)
        #expect(store.machines.first(where: { $0.id == "dev" })?.online == false)
        #expect(store.machines.first(where: { $0.id == "work" })?.online == true)
    }

    @Test("Treats a 2xx application failure as reachable but unsuccessful")
    func syncAllReportsApplicationFailureOnline() async {
        let machines = syncTestMachines()
        let failedHost = host(for: machines[1])
        configureSyncResponses(for: machines, applicationFailureHosts: [failedHost])
        defer { FleetStoreURLProtocol.router.reset() }
        let store = makeSyncStore(machines: machines)

        await store.syncAll()

        #expect(store.notice == "Synced 2 of 3 machines")
        #expect(store.machines.first(where: { $0.id == machines[1].id })?.online == true)
        #expect(store.machines.first(where: { $0.id == machines[1].id })?.error == "The server could not complete that Fleet action.")
    }

    @Test("Does not claim all machines are in sync for older responses without reconciliation")
    func syncAllKeepsBackwardsCompatibleNotice() async {
        let machines = syncTestMachines()
        configureSyncResponses(for: machines, includeReconciliation: false)
        defer { FleetStoreURLProtocol.router.reset() }
        let store = makeSyncStore(machines: machines)

        await store.syncAll()

        #expect(store.notice == "Synced 3 of 3 machines")
        #expect(store.machines.allSatisfy { $0.online })
    }

    @Test("Does not claim all machines are current when reconciliation is invalid")
    func syncAllKeepsNeutralNoticeForInvalidReconciliation() async throws {
        let machines = syncTestMachines()
        let response = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "items": [],
            "reconciliation": ["counts": [:]],
        ] as [String: Any])
        let responses = Dictionary(uniqueKeysWithValues: machines.map { (host(for: $0), response) })
        FleetStoreURLProtocol.router.configure(responses: responses, failingHosts: [])
        defer { FleetStoreURLProtocol.router.reset() }
        let store = makeSyncStore(machines: machines)

        await store.syncAll()

        #expect(store.notice == "Synced 3 of 3 machines")
        #expect(store.machines.allSatisfy { $0.online })
    }

    @Test("Does not claim an empty configured fleet is in sync")
    func syncAllReportsNoConfiguredMachines() async {
        let store = FleetStore(machines: [])

        await store.syncAll()

        #expect(store.notice == "No machines configured")
    }

    @Test("Saturates reconciliation totals across machines instead of overflowing")
    func saturatesReconciliationTotalsAcrossMachines() {
        var totals = FleetSyncTotals()
        totals.add(FleetReconciliationCounts(updated: Int.max, skipped: Int.max))
        totals.add(FleetReconciliationCounts(updated: 1, skipped: 1))

        #expect(totals.updated == Int.max)
        #expect(totals.skipped == Int.max)
    }

    private func syncTestMachines() -> [HerdrMachine] {
        [
            HerdrMachine(id: "studio", name: "RocketBot", urlString: "https://studio.example"),
            HerdrMachine(id: "dev", name: "DevBox", urlString: "https://dev.example"),
            HerdrMachine(id: "work", name: "Work Mac", urlString: "https://work.example"),
        ]
    }

    private func makeSyncStore(machines: [HerdrMachine]) -> FleetStore {
        let clients = Dictionary(uniqueKeysWithValues: machines.map { machine in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FleetStoreURLProtocol.self]
            let client = HerdrAPIClient(
                configuration: ServerConfiguration(urlString: machine.urlString, token: "test")!,
                session: URLSession(configuration: configuration)
            )
            return (machine.id, client)
        })
        return FleetStore(
            machines: machines,
            connectionStates: Dictionary(uniqueKeysWithValues: machines.map { ($0.id, ConnectionState.live) }),
            clients: clients
        )
    }

    private func configureSyncResponses(
        for machines: [HerdrMachine],
        counts: [String: FleetReconciliationCounts] = [:],
        includeReconciliation: Bool = true,
        failingHosts: Set<String> = [],
        applicationFailureHosts: Set<String> = []
    ) {
        let responses = Dictionary(uniqueKeysWithValues: machines.map { machine in
            (
                host(for: machine),
                makeSyncResponseData(
                    machineID: machine.id,
                    counts: normalizedSyncCounts(counts[machine.id] ?? FleetReconciliationCounts()),
                    includeReconciliation: includeReconciliation,
                    ok: !applicationFailureHosts.contains(host(for: machine))
                )
            )
        })
        FleetStoreURLProtocol.router.configure(responses: responses, failingHosts: failingHosts)
    }

    private func host(for machine: HerdrMachine) -> String {
        URL(string: machine.urlString)?.host ?? machine.urlString
    }

    private func makeSyncResponseData(
        machineID: String,
        counts: FleetReconciliationCounts,
        includeReconciliation: Bool,
        ok: Bool = true
    ) -> Data {
        var response: [String: Any] = [
            "ok": ok,
            "machine": [
                "machineID": machineID,
                "online": true,
                "skillsCount": 0,
                "piExtensionsCount": 0,
                "cliCount": 0,
                "itemCount": 0,
                "driftCount": 0,
            ],
            "items": [],
            "generatedAt": "2026-09-02T00:00:00Z",
        ]
        if includeReconciliation {
            response["reconciliation"] = [
                "counts": [
                    "total": counts.total,
                    "eligible": counts.eligible,
                    "attempted": counts.attempted,
                    "updated": counts.updated,
                    "restored": counts.restored,
                    "unchanged": counts.unchanged,
                    "skipped": counts.skipped,
                    "failed": counts.failed,
                    "current": counts.current,
                    "rollbackRestored": counts.rollbackRestored,
                    "skippedDrifted": counts.skippedDrifted,
                ],
                "items": [],
            ]
        }
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private func normalizedSyncCounts(_ counts: FleetReconciliationCounts) -> FleetReconciliationCounts {
        let statusTotal = counts.updated + counts.restored + counts.unchanged + counts.skipped + counts.failed
        let total = counts.total == 0 ? statusTotal : counts.total
        let eligible = counts.eligible == 0 && total > 0 ? total : counts.eligible
        let attempted = counts.attempted == 0 ? counts.updated + counts.restored + counts.failed : counts.attempted
        let current = counts.current == 0 ? counts.unchanged : counts.current
        return FleetReconciliationCounts(
            total: total,
            eligible: eligible,
            attempted: attempted,
            updated: counts.updated,
            restored: counts.restored,
            unchanged: counts.unchanged,
            skipped: counts.skipped,
            failed: counts.failed,
            current: current,
            rollbackRestored: counts.rollbackRestored,
            skippedDrifted: counts.skippedDrifted
        )
    }

    private func makeLargeSingleMachineResponse(machineID: String) -> FleetResponse {
        let status: FleetInstallState
        let installed: Bool
        let current: Bool
        let drifted: Bool
        let missing: Bool
        switch machineID {
        case "studio":
            status = .outdated
            installed = true
            current = false
            drifted = true
            missing = false
        case "dev":
            status = .missing
            installed = false
            current = false
            drifted = false
            missing = true
        default:
            status = .installed
            installed = true
            current = true
            drifted = false
            missing = false
        }

        let items = (0..<186).map { index -> FleetInventoryItem in
            let category: FleetInventoryCategory
            switch index {
            case 0..<172: category = .skills
            case 172..<179: category = .piExtensions
            default: category = .cli
            }
            let prefix: String
            switch category {
            case .skills: prefix = "skill"
            case .piExtensions: prefix = "pi"
            case .cli: prefix = "cli"
            }
            return FleetInventoryItem(
                id: "\(prefix):item-\(index)",
                name: "item-\(index)",
                category: category,
                version: "\(machineID)-v1",
                ownership: status == .missing ? .unmanaged : .managed,
                installable: category != .cli,
                status: status,
                installed: installed,
                current: current,
                drifted: drifted,
                missing: missing
            )
        }
        return FleetResponse(items: items, generatedAt: "2026-09-02T00:00:00Z")
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

private final class FleetStoreURLProtocol: URLProtocol, @unchecked Sendable {
    static let router = FleetStoreURLRouter()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.router.record(request)
        guard let host = request.url?.host,
              let outcome = Self.router.outcome(for: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch outcome {
        case .failure:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case let .success(data):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class FleetStoreURLRouter: @unchecked Sendable {
    enum Outcome {
        case success(Data)
        case failure
    }

    private let lock = NSLock()
    private var outcomes: [String: Outcome] = [:]
    private var pathsByHost: [String: [String]] = [:]

    func configure(responses: [String: Data], failingHosts: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        outcomes = responses.mapValues(Outcome.success)
        pathsByHost = [:]
        for host in failingHosts {
            outcomes[host] = .failure
        }
    }

    func record(_ request: URLRequest) {
        guard let host = request.url?.host,
              let path = request.url?.path
        else { return }
        lock.lock()
        defer { lock.unlock() }
        pathsByHost[host, default: []].append(path)
    }

    func requestPaths(for host: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return pathsByHost[host] ?? []
    }

    func outcome(for host: String) -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcomes[host]
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        outcomes = [:]
        pathsByHost = [:]
    }
}
