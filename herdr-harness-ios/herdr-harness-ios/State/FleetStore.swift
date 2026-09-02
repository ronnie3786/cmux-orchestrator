import Foundation
import Observation

/// Fleet on iPhone is READ-ONLY. The Mac harness can sync, install, adopt, and
/// remove; this store has no action API to call — `POST /api/v1/fleet/sync`
/// and `POST /api/v1/fleet/action` are not reachable from the phone at all.
/// The display projection still drops every connection detail before it
/// reaches a view.
@MainActor
@Observable
final class FleetStore {
    var machines: [FleetMachineSnapshot]
    var items: [FleetInventoryItem] = []
    var selectedFilter: FleetInventoryFilter = .all
    var differencesOnly = false
    var searchText = ""
    var isLoading = false
    var lastRefreshAt: Date?
    var machineErrors: [String: String] = [:]

    private let isDemoMode: Bool
    private var clients: [String: HerdrAPIClient]

    private struct FleetFetchResult: Sendable {
        let machineID: String
        let response: FleetResponse?
        let errorMessage: String?
    }

    /// Builds Fleet from the same persisted machine list as the main shell.
    /// Tokens are read through `KeychainStore`, and only valid
    /// `ServerConfiguration`s receive an API client. The display projection
    /// intentionally drops every connection detail before it reaches a view.
    convenience init(model: HerdrAppModel) {
        var clients: [String: HerdrAPIClient] = [:]
        if !model.isDemoMode {
            for machine in model.machines {
                let token = KeychainStore.value(for: "api-token.\(machine.id)")
                guard let configuration = ServerConfiguration(
                    urlString: machine.urlString,
                    token: token
                ) else { continue }
                clients[machine.id] = HerdrAPIClient(configuration: configuration)
            }
        }

        self.init(
            machines: model.machines,
            connectionStates: Dictionary(
                uniqueKeysWithValues: model.machines.map {
                    ($0.id, model.connectionState(forMachine: $0.id))
                }
            ),
            isDemoMode: model.isDemoMode,
            clients: clients
        )
    }

    /// A test and preview seam that keeps the store independent from app
    /// setup. Production callers should generally use `init(model:)`.
    init(
        machines sourceMachines: [HerdrMachine],
        connectionStates: [String: ConnectionState] = [:],
        isDemoMode: Bool = false,
        clients: [String: HerdrAPIClient] = [:]
    ) {
        self.isDemoMode = isDemoMode
        self.clients = clients
        self.machines = sourceMachines.enumerated().map { index, machine in
            let role = Self.role(for: machine, index: index)
            let kind = Self.kind(for: machine, role: role)
            let state = connectionStates[machine.id] ?? (isDemoMode ? .demo : .disconnected)
            return FleetMachineSnapshot(
                id: machine.id,
                role: role,
                kind: kind,
                online: state == .live || state == .demo
            )
        }

        if isDemoMode {
            apply(FleetFixtures.response(for: self.machines), fallbackMachineID: nil)
        }
    }

    var filteredItems: [FleetInventoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { item in
                guard let category = selectedFilter.category else { return true }
                return item.category == category
            }
            .filter { item in
                guard differencesOnly else { return true }
                return hasDifference(item)
            }
            .filter { item in
                guard !query.isEmpty else { return true }
                return item.name.localizedStandardContains(query)
                    || (item.summary?.localizedStandardContains(query) ?? false)
            }
            .sorted {
                if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var totalItemCount: Int { items.count }
    var differenceCount: Int { items.count(where: hasDifference) }
    var onlineCount: Int { machines.count(where: \.online) }
    var driftCount: Int { machines.reduce(0) { $0 + $1.driftCount } }

    func state(for item: FleetInventoryItem, machineID: String) -> FleetMachineItemState {
        item.machineStates[machineID]
            ?? FleetMachineItemState(
                ownership: .unmanaged,
                authCheckAvailable: false,
                installable: false
            )
    }

    func hasDifference(_ item: FleetInventoryItem) -> Bool {
        machines.contains { machine in
            let state = item.machineStates[machine.id]
                ?? FleetMachineItemState(
                    ownership: .unmanaged,
                    authCheckAvailable: false,
                    installable: false
                )
            return state.drift || state.state == .missing || state.state == .outdated || state.state == .drifted || state.state == .failed
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            lastRefreshAt = .now
        }

        if isDemoMode {
            apply(FleetFixtures.response(for: machines), fallbackMachineID: nil)
            return
        }

        machineErrors = [:]
        let results = await withTaskGroup(of: FleetFetchResult.self, returning: [FleetFetchResult].self) { group in
            for machine in machines {
                guard let client = clients[machine.id] else { continue }
                group.addTask {
                    do {
                        return FleetFetchResult(
                            machineID: machine.id,
                            response: try await client.fetchFleet(),
                            errorMessage: nil
                        )
                    } catch {
                        return FleetFetchResult(
                            machineID: machine.id,
                            response: nil,
                            errorMessage: Self.userFacingError(error)
                        )
                    }
                }
            }
            var results: [FleetFetchResult] = []
            for await result in group { results.append(result) }
            return results
        }

        for result in results {
            if let response = result.response {
                apply(response, fallbackMachineID: result.machineID)
                setMachineOnline(true, id: result.machineID)
                setMachineLastSync(response.generatedAt, id: result.machineID)
                setMachineError(nil, id: result.machineID)
            } else {
                setMachineOnline(false, id: result.machineID)
                setMachineError(result.errorMessage, id: result.machineID)
            }
        }
        for machine in machines where clients[machine.id] == nil {
            setMachineOnline(false, id: machine.id)
            setMachineError("No connection configured for this machine.", id: machine.id)
        }
    }

    private func apply(_ response: FleetResponse, fallbackMachineID: String?) {
        if let summary = response.machine {
            // A response returned by a client is scoped to the machine that
            // made that request. The server's optional machine id is useful
            // for aggregate payloads, but must not redirect a single-machine
            // response into another saved card.
            let summaryID = fallbackMachineID ?? (summary.machineID.isEmpty ? nil : summary.machineID)
            if let summaryID { updateMachine(summary, id: summaryID) }
            if let fallbackMachineID { setMachineOnline(true, id: fallbackMachineID) }
        }
        if let fallbackMachineID {
            // Some older servers put the one summary in `machines` rather
            // than `machine`. Keep the request identity authoritative here as
            // well. Item state is handled by the same rule below.
            if response.machine == nil, let summary = response.machines.first {
                updateMachine(summary, id: fallbackMachineID)
            }
        } else {
            for summary in response.machines {
                guard !summary.machineID.isEmpty else { continue }
                updateMachine(summary, id: summary.machineID)
            }
        }

        if response.machines.isEmpty, let fallbackMachineID {
            setMachineOnline(true, id: fallbackMachineID)
        }
        if let fallbackMachineID, let generatedAt = response.generatedAt {
            setMachineLastSync(generatedAt, id: fallbackMachineID)
        }

        var merged = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var replacedMachineIDs = Set<String>()
        if let fallbackMachineID {
            // Never let machine ids embedded in a single-machine payload
            // clear or overwrite a different local card.
            replacedMachineIDs.insert(fallbackMachineID)
        } else {
            if let summaryID = response.machine?.machineID, !summaryID.isEmpty {
                replacedMachineIDs.insert(summaryID)
            }
            for summary in response.machines where !summary.machineID.isEmpty {
                replacedMachineIDs.insert(summary.machineID)
            }
            for serverItem in response.items {
                replacedMachineIDs.formUnion(serverItem.machineStates.keys)
            }
        }

        // A per-machine Fleet response is a complete snapshot. Clear that
        // machine's old cells first so catalog removals do not linger, while
        // leaving every other machine's state intact.
        for machineID in replacedMachineIDs {
            for itemID in Array(merged.keys) {
                merged[itemID]?.machineStates.removeValue(forKey: machineID)
            }
        }

        let knownMachineIDs = Set(machines.map(\.id))
        for serverItem in response.items {
            let hadExistingItem = merged[serverItem.id] != nil
            var item = merged[serverItem.id] ?? serverItem
            item.name = serverItem.name
            item.category = serverItem.category
            item.summary = serverItem.summary ?? item.summary
            item.version = serverItem.version ?? item.version
            // These fields are machine-specific in the backend response. The
            // safe global values are retained only as compatibility fallbacks;
            // cells always read their own FleetMachineItemState.
            item.ownership = item.ownership == .managed ? serverItem.ownership : item.ownership
            item.canAdopt = item.canAdopt || serverItem.canAdopt
            item.status = serverItem.status
            item.installed = serverItem.installed
            item.current = serverItem.current
            item.drifted = serverItem.drifted
            item.missing = serverItem.missing
            item.authCheckAvailable = serverItem.authCheckAvailable ?? item.authCheckAvailable
            item.installable = serverItem.installable ?? item.installable
            if let fallbackMachineID {
                // GET /api/v1/fleet and the sync/action responses are
                // intentionally single-machine payloads. `serverItem` does
                // not carry a machineStates map in that contract. Always
                // materialize the item under the requesting machine id,
                // rather than checking the merged item: after the first
                // response it already contains another machine's state, which
                // previously caused later responses to be silently dropped.
                // If this is a new row, discard any optional embedded map as
                // well. A single-machine response cannot prove that another
                // key belongs to a different locally configured machine.
                if !hadExistingItem {
                    item.machineStates.removeAll(keepingCapacity: true)
                } else {
                    // Keep known cells already collected from other saved
                    // machines, while dropping stale or server-only keys.
                    item.machineStates = item.machineStates.filter {
                        knownMachineIDs.contains($0.key)
                    }
                }
                item.machineStates[fallbackMachineID] = state(for: serverItem)
            } else {
                for (machineID, state) in serverItem.machineStates {
                    item.machineStates[machineID] = state
                }
            }
            merged[item.id] = item
        }
        // Items are shared catalog rows. Keep one as long as at least one
        // configured machine still reports it.
        items = Array(merged.values.filter { !$0.machineStates.isEmpty })
        recalculateMachineCounts()
    }

#if DEBUG
    /// Test seam for complete-snapshot replacement and pruning behavior.
    func applyForTesting(_ response: FleetResponse, fallbackMachineID: String? = nil) {
        apply(response, fallbackMachineID: fallbackMachineID)
    }
#endif

    private func updateMachine(_ summary: FleetMachineSummary, id: String) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[index].online = summary.online
        machines[index].skillsCount = summary.skillsCount
        machines[index].piExtensionsCount = summary.piExtensionsCount
        machines[index].cliCount = summary.cliCount
        machines[index].itemCount = summary.itemCount ?? summary.skillsCount + summary.piExtensionsCount + summary.cliCount
        machines[index].driftCount = summary.driftCount
        machines[index].lastSyncAt = summary.lastSyncAt
        machines[index].error = summary.error
    }

    private func setMachineOnline(_ online: Bool, id: String) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[index].online = online
    }

    private func setMachineLastSync(_ lastSyncAt: String?, id: String) {
        guard let lastSyncAt,
              !lastSyncAt.isEmpty,
              let index = machines.firstIndex(where: { $0.id == id })
        else { return }
        machines[index].lastSyncAt = lastSyncAt
    }

    private func setMachineError(_ message: String?, id: String) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[index].error = message
        if let message, !message.isEmpty {
            machineErrors[id] = message
        } else {
            machineErrors.removeValue(forKey: id)
        }
    }

    private func state(for item: FleetInventoryItem) -> FleetMachineItemState {
        let inferredState: FleetInstallState
        if item.status != .unknown {
            inferredState = item.status
        } else if item.missing == true {
            inferredState = .missing
        } else if item.drifted == true {
            inferredState = .drifted
        } else if item.installed == true || item.current == true {
            inferredState = .installed
        } else {
            // A missing status is not evidence of installation. Keep the
            // cell visibly unchecked until the server tells us more.
            inferredState = .unknown
        }
        let authError: String?
        if let auth = item.auth, auth.required, auth.configured == false {
            authError = "Auth required"
        } else {
            authError = nil
        }
        let authCheckAvailable: Bool
        if let value = item.authCheckAvailable {
            authCheckAvailable = value
        } else if let auth = item.auth, let value = auth.checkAvailable {
            authCheckAvailable = value
        } else {
            authCheckAvailable = item.auth != nil
        }
        return FleetMachineItemState(
            state: inferredState,
            version: item.version,
            drift: item.drifted == true || inferredState == .drifted,
            error: authError,
            ownership: item.ownership,
            canAdopt: item.canAdopt,
            auth: item.auth,
            authCheckAvailable: authCheckAvailable,
            installable: item.installable
        )
    }

    private func recalculateMachineCounts() {
        for index in machines.indices {
            let machineID = machines[index].id
            let machineItems = items.filter { $0.machineStates[machineID] != nil }
            machines[index].itemCount = machineItems.count
            machines[index].skillsCount = machineItems.count(where: { $0.category == .skills })
            machines[index].piExtensionsCount = machineItems.count(where: { $0.category == .piExtensions })
            machines[index].cliCount = machineItems.count(where: { $0.category == .cli })
            machines[index].driftCount = machineItems.count(where: {
                guard let state = $0.machineStates[machineID] else { return false }
                return state.drift || state.state == .missing || state.state == .outdated || state.state == .drifted || state.state == .failed
            })
        }
    }

    private static func role(for machine: HerdrMachine, index: Int) -> FleetMachineRole {
        let name = machine.name.lowercased()
        let url = machine.urlString.lowercased()
        if name.contains("devbox") || name.contains("dev box") || url.contains("devbox") {
            return .devBox
        }
        if name.contains("rocketbot") || name.contains("studio") {
            return .thisMac
        }
        // The saved Work Mac can be named Doximity Mac while its endpoint is
        // localhost. Keep this branch name-aware rather than assuming order.
        if name.contains("work") || name.contains("doximity") || name.contains("ronniesity")
            || url.contains("ronniesity") {
            return .workMac
        }
        if url.contains("localhost") || url.contains("127.0.0.1") {
            return .workMac
        }
        // A single unnamed machine is still the local node. For a larger
        // unknown fleet, deterministic Node labels prevent leaking names.
        return index == 0 ? .thisMac : .node
    }

    private static func kind(for machine: HerdrMachine, role: FleetMachineRole) -> FleetMachineKind {
        switch role {
        case .thisMac: return .macStudio
        case .devBox: return .iMac
        case .workMac: return .macBookPro
        case .node:
            let identity = "\(machine.name) \(machine.urlString)".lowercased()
            if identity.contains("imac") { return .iMac }
            if identity.contains("book") || identity.contains("mbp") { return .macBookPro }
            return .macStudio
        }
    }

    nonisolated private static func userFacingError(_ error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .server:
                return "The server could not read Fleet from this machine."
            case .noActiveConnection:
                return "The machine is not connected."
            default:
                return "Fleet could not read this machine."
            }
        }
        return "Fleet could not read this machine."
    }
}

enum FleetFixtures {
    static func response(for machines: [FleetMachineSnapshot]) -> FleetResponse {
        let ids = machines.map(\.id)
        let localID = machines.first(where: { $0.role == .thisMac })?.id ?? ids.first
        let devBoxID = machines.first(where: { $0.role == .devBox })?.id
        let workID = machines.first(where: { $0.role == .workMac })?.id

        var itemStates: [[String: FleetMachineItemState]] = []
        func states(
            local: FleetMachineItemState,
            devBox: FleetMachineItemState,
            work: FleetMachineItemState
        ) -> [String: FleetMachineItemState] {
            var result: [String: FleetMachineItemState] = [:]
            if let localID { result[localID] = local }
            if let devBoxID { result[devBoxID] = devBox }
            if let workID { result[workID] = work }
            return result
        }

        itemStates.append(states(
            local: FleetMachineItemState(state: .installed, version: "2.4.0"),
            devBox: FleetMachineItemState(state: .installed, version: "2.4.0"),
            work: FleetMachineItemState(state: .outdated, version: "2.3.1", drift: true)
        ))
        itemStates.append(states(
            local: FleetMachineItemState(state: .installed, version: "1.8.2"),
            devBox: FleetMachineItemState(state: .missing),
            work: FleetMachineItemState(state: .installed, version: "1.8.2")
        ))
        itemStates.append(states(
            local: FleetMachineItemState(state: .missing, drift: true, ownership: .external, installable: false),
            devBox: FleetMachineItemState(state: .missing, drift: true, ownership: .external, installable: false),
            work: FleetMachineItemState(state: .installed, version: "4.1.0", ownership: .external, installable: false)
        ))
        itemStates.append(states(
            local: FleetMachineItemState(state: .installed, version: "3.2.0"),
            devBox: FleetMachineItemState(state: .installed, version: "3.2.0"),
            work: FleetMachineItemState(state: .installed, version: "3.2.0")
        ))
        itemStates.append(states(
            local: FleetMachineItemState(
                state: .installed,
                version: "1.0.0",
                ownership: .unmanaged,
                canAdopt: true
            ),
            devBox: FleetMachineItemState(state: .missing, ownership: .unmanaged),
            work: FleetMachineItemState(state: .missing, ownership: .unmanaged)
        ))

        let items = [
            FleetInventoryItem(
                id: "skill:reviewer",
                name: "reviewer",
                category: .skills,
                summary: "Review changes with the same guardrails everywhere.",
                version: "2.4.0",
                machineStates: itemStates[0]
            ),
            FleetInventoryItem(
                id: "pi:send-to-herdr",
                name: "send-to-herdr",
                category: .piExtensions,
                summary: "Route a Pi turn into a Herdr workspace.",
                version: "1.8.2",
                machineStates: itemStates[1]
            ),
            FleetInventoryItem(
                id: "cli:slack",
                name: "slack",
                category: .cli,
                summary: "Send and inspect Slack work from the terminal.",
                version: "4.1.0",
                ownership: .external,
                machineStates: itemStates[2]
            ),
            FleetInventoryItem(
                id: "cli:herdr",
                name: "herdr",
                category: .cli,
                summary: "The Herdr command-line companion.",
                version: "3.2.0",
                machineStates: itemStates[3]
            ),
            FleetInventoryItem(
                id: "skill:local-playbook",
                name: "local-playbook",
                category: .skills,
                summary: "A matching local skill ready to manage.",
                version: "1.0.0",
                ownership: .unmanaged,
                canAdopt: true,
                status: .installed,
                installed: true,
                current: true,
                machineStates: itemStates[4]
            ),
        ]

        let summaries = machines.map { machine in
            let machineItems = items.filter { $0.machineStates[machine.id] != nil }
            let drift = machineItems.count(where: {
                guard let state = $0.machineStates[machine.id] else { return false }
                return state.drift || state.state == .missing || state.state == .outdated
            })
            return FleetMachineSummary(
                machineID: machine.id,
                role: machine.role.rawValue,
                online: true,
                skillsCount: machineItems.count(where: { $0.category == .skills }),
                piExtensionsCount: machineItems.count(where: { $0.category == .piExtensions }),
                cliCount: machineItems.count(where: { $0.category == .cli }),
                itemCount: machineItems.count,
                driftCount: drift,
                lastSyncAt: "2026-09-01T15:20:00Z"
            )
        }
        return FleetResponse(machines: summaries, items: items, generatedAt: "2026-09-01T15:20:00Z")
    }
}
