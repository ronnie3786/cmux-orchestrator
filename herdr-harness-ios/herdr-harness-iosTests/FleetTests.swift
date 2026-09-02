import Foundation
import Testing
@testable import herdr_harness_ios

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
        #expect(store.machines.map(\.displayName) == ["Work Mac", "RocketBot", "DevBox"])
    }

    @Test("Fleet on iOS exposes no mutating surface")
    func readOnlySurface() {
        // A compile-time guard: if someone re-adds syncFleet/performFleetAction
        // or the action models, this file stops building and the reviewer has
        // to say why the phone can now change a machine.
        //
        // The Mac gives /fleet/sync and /fleet/action a 150 s budget because it
        // holds those POSTs open. iOS leaves both on the shared 15 s default
        // precisely because nothing here calls them.
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/fleet", method: "GET") == 15)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/fleet/sync", method: "POST") == 15)
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

private final class FleetStoreURLProtocol: URLProtocol, @unchecked Sendable {
    static let router = FleetStoreURLRouter()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
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

    func configure(responses: [String: Data], failingHosts: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        outcomes = responses.mapValues(Outcome.success)
        for host in failingHosts {
            outcomes[host] = .failure
        }
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
    }
}
