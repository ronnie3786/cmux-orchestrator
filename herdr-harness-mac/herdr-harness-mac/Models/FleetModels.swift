import Foundation

/// The three inventory families Herdr can reconcile across a machine fleet.
enum FleetInventoryCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case skills
    case piExtensions = "pi_extensions"
    case cli

    var id: String { rawValue }

    var label: String {
        switch self {
        case .skills: "Skills"
        case .piExtensions: "Pi Extensions"
        case .cli: "CLI"
        }
    }

    var symbol: String {
        switch self {
        case .skills: "wand.and.stars"
        case .piExtensions: "puzzlepiece.extension"
        case .cli: "chevron.left.forwardslash.chevron.right"
        }
    }

    init(rawValue: String) {
        switch rawValue.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "skill", "skills": self = .skills
        case "pi", "pi_extension", "pi_extensions", "piextensions", "extensions": self = .piExtensions
        default: self = .cli
        }
    }
}

enum FleetItemOwnership: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case managed
    case unmanaged
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .managed: "Managed"
        case .unmanaged: "Unmanaged"
        case .external: "External"
        }
    }
}

enum FleetInstallState: String, Codable, Hashable, Sendable {
    case installed
    case missing
    case outdated
    case drifted
    case unknown
    case failed

    var label: String {
        switch self {
        case .installed: "Installed"
        case .missing: "Not installed"
        case .outdated: "Update available"
        case .drifted: "Drifted"
        case .unknown: "Not checked"
        case .failed: "Action failed"
        }
    }

    init(backendStatus: String) {
        switch backendStatus.lowercased() {
        case "current", "installed": self = .installed
        case "missing", "not_installed": self = .missing
        case "drifted", "drift": self = .drifted
        case "outdated", "update_available": self = .outdated
        case "failed", "error": self = .failed
        default: self = .unknown
        }
    }
}

enum FleetMachineRole: String, Codable, Hashable, Sendable {
    case thisMac = "this_mac"
    case devBox = "dev_box"
    case workMac = "work_mac"
    case node

    var label: String {
        switch self {
        case .thisMac: "This Mac"
        case .devBox: "DevBox"
        case .workMac: "Work Mac"
        case .node: "Node"
        }
    }
}

enum FleetMachineKind: String, Codable, Hashable, Sendable {
    case macStudio = "mac_studio"
    case iMac = "imac"
    case macBookPro = "macbook_pro"

    var label: String {
        switch self {
        case .macStudio: "Mac Studio"
        case .iMac: "iMac"
        case .macBookPro: "MacBook Pro"
        }
    }

    var assetName: String {
        switch self {
        case .macStudio: "FleetMachineMacStudio"
        case .iMac: "FleetMachineIMac"
        case .macBookPro: "FleetMachineMacBookPro"
        }
    }
}

/// The safe, display-ready machine projection used by Fleet views. It
/// intentionally contains no URL, hostname, username, or filesystem path.
struct FleetMachineSnapshot: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let role: FleetMachineRole
    let kind: FleetMachineKind
    var online: Bool
    var itemCount: Int
    var skillsCount: Int
    var piExtensionsCount: Int
    var cliCount: Int
    var driftCount: Int
    var lastSyncAt: String?
    var error: String?

    var displayName: String { role.label }
    var statusLabel: String { online ? "Online" : "Offline" }
    var countSummary: String {
        "\(itemCount) item\(itemCount == 1 ? "" : "s")"
    }

    init(
        id: String,
        role: FleetMachineRole,
        kind: FleetMachineKind,
        online: Bool = false,
        itemCount: Int = 0,
        skillsCount: Int = 0,
        piExtensionsCount: Int = 0,
        cliCount: Int = 0,
        driftCount: Int = 0,
        lastSyncAt: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.online = online
        self.itemCount = itemCount
        self.skillsCount = skillsCount
        self.piExtensionsCount = piExtensionsCount
        self.cliCount = cliCount
        self.driftCount = driftCount
        self.lastSyncAt = lastSyncAt
        self.error = error
    }
}

struct FleetAuthStatus: Codable, Equatable, Hashable, Sendable {
    /// `nil` means the server has not established auth state yet. Keeping
    /// that distinct from `false` prevents a preflight inventory read from
    /// presenting a misleading "Auth required" warning.
    var configured: Bool?
    var required: Bool
    var message: String?
    var status: String?
    var checkAvailable: Bool?

    init(
        configured: Bool? = nil,
        required: Bool = false,
        message: String? = nil,
        status: String? = nil,
        checkAvailable: Bool? = nil
    ) {
        self.configured = configured
        self.required = required
        self.message = message
        self.status = status
        self.checkAvailable = checkAvailable
    }

    enum CodingKeys: String, CodingKey {
        case configured
        case required
        case message
        case status
        case checkAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var configuredValue: Bool?
        do {
            configuredValue = try container.decodeIfPresent(Bool.self, forKey: .configured)
        } catch {
            configuredValue = nil
        }
        var statusValue: String?
        do {
            statusValue = try container.decodeIfPresent(String.self, forKey: .status)
        } catch {
            statusValue = nil
        }
        configured = configuredValue
            ?? Self.configuredValue(for: statusValue)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        message = try container.decodeIfPresent(String.self, forKey: .message)
        status = statusValue
        checkAvailable = try container.decodeIfPresent(Bool.self, forKey: .checkAvailable)
    }

    private static func configuredValue(for status: String?) -> Bool? {
        switch status?.lowercased() {
        case "configured", "ok", "authenticated": return true
        case "missing", "failed", "unavailable": return false
        default: return nil
        }
    }
}

enum FleetInventoryFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case skills
    case piExtensions = "pi_extensions"
    case cli

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .skills: "Skills"
        case .piExtensions: "Pi Extensions"
        case .cli: "CLI"
        }
    }

    var category: FleetInventoryCategory? {
        switch self {
        case .all: nil
        case .skills: .skills
        case .piExtensions: .piExtensions
        case .cli: .cli
        }
    }
}

/// A single machine's view of an inventory item. The server may omit optional
/// fields when an item is absent, so the decoder intentionally fills in safe
/// defaults instead of dropping the whole inventory response.
struct FleetMachineItemState: Codable, Equatable, Hashable, Sendable {
    var state: FleetInstallState
    var version: String?
    var drift: Bool
    var progress: Double?
    var error: String?
    var ownership: FleetItemOwnership
    var canAdopt: Bool
    var auth: FleetAuthStatus?
    var authCheckAvailable: Bool
    var installable: Bool?

    init(
        state: FleetInstallState = .unknown,
        version: String? = nil,
        drift: Bool = false,
        progress: Double? = nil,
        error: String? = nil,
        ownership: FleetItemOwnership = .managed,
        canAdopt: Bool = false,
        auth: FleetAuthStatus? = nil,
        authCheckAvailable: Bool = false,
        installable: Bool? = nil
    ) {
        self.state = state
        self.version = version
        self.drift = drift
        self.progress = progress
        self.error = error
        self.ownership = ownership
        self.canAdopt = canAdopt
        self.auth = auth
        self.authCheckAvailable = authCheckAvailable
        self.installable = installable
    }

    enum CodingKeys: String, CodingKey {
        case state
        case status
        case version
        case drift
        case isDrift = "is_drift"
        case progress
        case error
        case ownership
        case managed
        case canAdopt
        case canAdoptSnake = "can_adopt"
        case auth
        case authCheckAvailable = "auth_check_available"
        case authCheckAvailableCamel = "authCheckAvailable"
        case checkAvailable
        case installable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawState = try container.decodeIfPresent(String.self, forKey: .state)
            ?? container.decodeIfPresent(String.self, forKey: .status)
            ?? FleetInstallState.unknown.rawValue
        state = FleetInstallState(backendStatus: rawState)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        drift = try container.decodeIfPresent(Bool.self, forKey: .drift)
            ?? container.decodeIfPresent(Bool.self, forKey: .isDrift)
            ?? false
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        let managedValue = try container.decodeIfPresent(Bool.self, forKey: .managed)
        let ownershipValue = try container.decodeIfPresent(String.self, forKey: .ownership)?.lowercased()
        if managedValue == true || ownershipValue == FleetItemOwnership.managed.rawValue {
            ownership = .managed
        } else if ownershipValue == FleetItemOwnership.external.rawValue
                    || ownershipValue == "readonly"
                    || ownershipValue == "read_only"
                    || ownershipValue == "unclassified"
                    || ownershipValue == "orphan" {
            ownership = .external
        } else if managedValue == false
                    || ownershipValue == FleetItemOwnership.unmanaged.rawValue
                    || ownershipValue == "not_installed" {
            ownership = .unmanaged
        } else {
            // Missing ownership is not proof that Herdr owns the target. Keep
            // the state read-only until the server explicitly says managed.
            ownership = .unmanaged
        }
        canAdopt = try container.decodeIfPresent(Bool.self, forKey: .canAdopt)
            ?? container.decodeIfPresent(Bool.self, forKey: .canAdoptSnake)
            ?? false
        auth = try container.decodeIfPresent(FleetAuthStatus.self, forKey: .auth)
        let explicitAuthCheck = try container.decodeIfPresent(Bool.self, forKey: .authCheckAvailable)
        let camelAuthCheck = try container.decodeIfPresent(Bool.self, forKey: .authCheckAvailableCamel)
        let nestedAuthCheck = try container.decodeIfPresent(Bool.self, forKey: .checkAvailable)
        if let explicitAuthCheck {
            authCheckAvailable = explicitAuthCheck
        } else if let camelAuthCheck {
            authCheckAvailable = camelAuthCheck
        } else if let nestedAuthCheck {
            authCheckAvailable = nestedAuthCheck
        } else if let auth, let checkAvailable = auth.checkAvailable {
            authCheckAvailable = checkAvailable
        } else {
            authCheckAvailable = auth != nil
        }
        installable = try container.decodeIfPresent(Bool.self, forKey: .installable)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state.rawValue, forKey: .state)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(drift, forKey: .drift)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(ownership.rawValue, forKey: .ownership)
        try container.encode(canAdopt, forKey: .canAdopt)
        try container.encodeIfPresent(auth, forKey: .auth)
        try container.encode(authCheckAvailable, forKey: .authCheckAvailableCamel)
        try container.encodeIfPresent(installable, forKey: .installable)
    }
}

struct FleetInventoryItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var category: FleetInventoryCategory
    var summary: String?
    var version: String?
    var ownership: FleetItemOwnership
    var canAdopt: Bool
    var auth: FleetAuthStatus?
    var authCheckAvailable: Bool?
    var installable: Bool?
    var status: FleetInstallState
    var installed: Bool?
    var current: Bool?
    var drifted: Bool?
    var missing: Bool?
    var machineStates: [String: FleetMachineItemState]

    init(
        id: String,
        name: String,
        category: FleetInventoryCategory,
        summary: String? = nil,
        version: String? = nil,
        ownership: FleetItemOwnership = .managed,
        canAdopt: Bool = false,
        auth: FleetAuthStatus? = nil,
        authCheckAvailable: Bool? = nil,
        installable: Bool? = nil,
        status: FleetInstallState = .unknown,
        installed: Bool? = nil,
        current: Bool? = nil,
        drifted: Bool? = nil,
        missing: Bool? = nil,
        machineStates: [String: FleetMachineItemState] = [:]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.summary = summary
        self.version = version
        self.ownership = ownership
        self.canAdopt = canAdopt
        self.auth = auth
        self.authCheckAvailable = authCheckAvailable
        self.installable = installable
        self.status = status
        self.installed = installed
        self.current = current
        self.drifted = drifted
        self.missing = missing
        self.machineStates = machineStates
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case kind
        case type
        case summary
        case description
        case version
        case ownership
        case managed
        case canAdopt
        case canAdoptSnake = "can_adopt"
        case auth
        case authCheckAvailable = "authCheckAvailable"
        case authCheckAvailableSnake = "auth_check_available"
        case checkAvailable
        case installable
        case status
        case installed
        case current
        case drifted
        case missing
        case source
        case machineStates = "machine_states"
        case machineStatesCamel = "machineStates"
        case machines
    }

    private struct MachineStateEntry: Decodable {
        let machineID: String
        let state: FleetMachineItemState

        enum CodingKeys: String, CodingKey {
            case machineID = "machine_id"
            case machineIDCamel = "machineID"
            case id
            case state
            case status
            case version
            case drift
            case isDrift = "is_drift"
            case progress
            case error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            machineID = try container.decodeIfPresent(String.self, forKey: .machineID)
                ?? container.decodeIfPresent(String.self, forKey: .machineIDCamel)
                ?? container.decodeIfPresent(String.self, forKey: .id)
                ?? ""
            if let decoded = try? container.decode(FleetMachineItemState.self, forKey: .state) {
                state = decoded
            } else {
                state = FleetMachineItemState(
                    state: FleetInstallState(backendStatus: try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"),
                    version: try container.decodeIfPresent(String.self, forKey: .version),
                    drift: try container.decodeIfPresent(Bool.self, forKey: .drift)
                        ?? container.decodeIfPresent(Bool.self, forKey: .isDrift)
                        ?? false,
                    progress: try container.decodeIfPresent(Double.self, forKey: .progress),
                    error: try container.decodeIfPresent(String.self, forKey: .error)
                )
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        let rawCategory = try container.decodeIfPresent(String.self, forKey: .category)
            ?? container.decodeIfPresent(String.self, forKey: .kind)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? FleetInventoryCategory.cli.rawValue
        category = FleetInventoryCategory(rawValue: rawCategory)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
            ?? container.decodeIfPresent(String.self, forKey: .description)
        version = try container.decodeIfPresent(String.self, forKey: .version)

        let managedValue = try container.decodeIfPresent(Bool.self, forKey: .managed)
        let ownershipValue = try container.decodeIfPresent(String.self, forKey: .ownership)?.lowercased()
        if managedValue == true || ownershipValue == FleetItemOwnership.managed.rawValue {
            ownership = .managed
        } else if ownershipValue == FleetItemOwnership.external.rawValue
                    || ownershipValue == "readonly"
                    || ownershipValue == "read_only"
                    || ownershipValue == "unclassified"
                    || ownershipValue == "orphan" {
            ownership = .external
        } else if managedValue == false
                    || ownershipValue == FleetItemOwnership.unmanaged.rawValue
                    || ownershipValue == "not_installed" {
            ownership = .unmanaged
        } else if let source = try container.decodeIfPresent(String.self, forKey: .source) {
            ownership = source.lowercased() == FleetItemOwnership.managed.rawValue ? .managed : .unmanaged
        } else {
            // A partial inventory response must never grant destructive
            // controls merely because ownership was omitted.
            ownership = .unmanaged
        }
        canAdopt = try container.decodeIfPresent(Bool.self, forKey: .canAdopt)
            ?? container.decodeIfPresent(Bool.self, forKey: .canAdoptSnake)
            ?? false
        auth = try container.decodeIfPresent(FleetAuthStatus.self, forKey: .auth)
        authCheckAvailable = try container.decodeIfPresent(Bool.self, forKey: .authCheckAvailable)
            ?? container.decodeIfPresent(Bool.self, forKey: .authCheckAvailableSnake)
            ?? container.decodeIfPresent(Bool.self, forKey: .checkAvailable)
        installable = try container.decodeIfPresent(Bool.self, forKey: .installable)
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        status = FleetInstallState(backendStatus: rawStatus)
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed)
        current = try container.decodeIfPresent(Bool.self, forKey: .current)
        drifted = try container.decodeIfPresent(Bool.self, forKey: .drifted)
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing)

        if let states = try container.decodeIfPresent([String: FleetMachineItemState].self, forKey: .machineStates) {
            machineStates = states
        } else if let states = try container.decodeIfPresent([String: FleetMachineItemState].self, forKey: .machineStatesCamel) {
            machineStates = states
        } else if let states = try container.decodeIfPresent([MachineStateEntry].self, forKey: .machines) {
            machineStates = Dictionary(uniqueKeysWithValues: states.compactMap { entry in
                entry.machineID.isEmpty ? nil : (entry.machineID, entry.state)
            })
        } else {
            machineStates = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(category.rawValue, forKey: .category)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(ownership.rawValue, forKey: .ownership)
        try container.encode(canAdopt, forKey: .canAdopt)
        try container.encodeIfPresent(auth, forKey: .auth)
        try container.encodeIfPresent(authCheckAvailable, forKey: .authCheckAvailable)
        try container.encodeIfPresent(installable, forKey: .installable)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(installed, forKey: .installed)
        try container.encodeIfPresent(current, forKey: .current)
        try container.encodeIfPresent(drifted, forKey: .drifted)
        try container.encodeIfPresent(missing, forKey: .missing)
        try container.encode(machineStates, forKey: .machineStates)
    }
}

struct FleetMachineSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { machineID }
    var machineID: String
    var role: String?
    var online: Bool
    var skillsCount: Int
    var piExtensionsCount: Int
    var cliCount: Int
    var itemCount: Int?
    var driftCount: Int
    var lastSyncAt: String?
    var error: String?

    init(
        machineID: String,
        role: String? = nil,
        online: Bool = false,
        skillsCount: Int = 0,
        piExtensionsCount: Int = 0,
        cliCount: Int = 0,
        itemCount: Int? = nil,
        driftCount: Int = 0,
        lastSyncAt: String? = nil,
        error: String? = nil
    ) {
        self.machineID = machineID
        self.role = role
        self.online = online
        self.skillsCount = skillsCount
        self.piExtensionsCount = piExtensionsCount
        self.cliCount = cliCount
        self.itemCount = itemCount
        self.driftCount = driftCount
        self.lastSyncAt = lastSyncAt
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id"
        case machineIDCamel = "machineID"
        case id
        case role
        case online
        case connected
        case skillsCount = "skills_count"
        case skillsCountCamel = "skillsCount"
        case piExtensionsCount = "pi_extensions_count"
        case piExtensionsCountCamel = "piExtensionsCount"
        case cliCount = "cli_count"
        case cliCountCamel = "cliCount"
        case itemCount = "item_count"
        case itemCountCamel = "itemCount"
        case driftCount = "drift_count"
        case driftCountCamel = "driftCount"
        case lastSyncAt = "last_sync_at"
        case lastSyncAtCamel = "lastSyncAt"
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try container.decodeIfPresent(String.self, forKey: .machineID)
            ?? container.decodeIfPresent(String.self, forKey: .machineIDCamel)
            ?? container.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role)
        online = try container.decodeIfPresent(Bool.self, forKey: .online)
            ?? container.decodeIfPresent(Bool.self, forKey: .connected)
            ?? false
        skillsCount = try container.decodeIfPresent(Int.self, forKey: .skillsCount)
            ?? container.decodeIfPresent(Int.self, forKey: .skillsCountCamel)
            ?? 0
        piExtensionsCount = try container.decodeIfPresent(Int.self, forKey: .piExtensionsCount)
            ?? container.decodeIfPresent(Int.self, forKey: .piExtensionsCountCamel)
            ?? 0
        cliCount = try container.decodeIfPresent(Int.self, forKey: .cliCount)
            ?? container.decodeIfPresent(Int.self, forKey: .cliCountCamel)
            ?? 0
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
            ?? container.decodeIfPresent(Int.self, forKey: .itemCountCamel)
        driftCount = try container.decodeIfPresent(Int.self, forKey: .driftCount)
            ?? container.decodeIfPresent(Int.self, forKey: .driftCountCamel)
            ?? 0
        lastSyncAt = try container.decodeIfPresent(String.self, forKey: .lastSyncAt)
            ?? container.decodeIfPresent(String.self, forKey: .lastSyncAtCamel)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machineID, forKey: .machineID)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encode(online, forKey: .online)
        try container.encode(skillsCount, forKey: .skillsCount)
        try container.encode(piExtensionsCount, forKey: .piExtensionsCount)
        try container.encode(cliCount, forKey: .cliCount)
        try container.encodeIfPresent(itemCount, forKey: .itemCount)
        try container.encode(driftCount, forKey: .driftCount)
        try container.encodeIfPresent(lastSyncAt, forKey: .lastSyncAt)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// `GET /api/v1/fleet` is deliberately a small, privacy-safe contract. It
/// contains inventory metadata and machine ids only. Hostnames, addresses,
/// paths, account names, and diagnostics are not part of the response shown by
/// the Fleet UI.
struct FleetCatalogSummary: Codable, Equatable, Sendable {
    var available: Bool
    var revision: String?
    var syncedAt: String?
    var skillsCount: Int
    var piExtensionsCount: Int
    var cliCount: Int

    enum CodingKeys: String, CodingKey {
        case available
        case revision
        case syncedAt
        case itemCounts
    }

    private struct ItemCounts: Codable, Sendable {
        var skills: Int?
        var piExtensions: Int?
        var cli: Int?
    }

    init(
        available: Bool = false,
        revision: String? = nil,
        syncedAt: String? = nil,
        skillsCount: Int = 0,
        piExtensionsCount: Int = 0,
        cliCount: Int = 0
    ) {
        self.available = available
        self.revision = revision
        self.syncedAt = syncedAt
        self.skillsCount = skillsCount
        self.piExtensionsCount = piExtensionsCount
        self.cliCount = cliCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        syncedAt = try container.decodeIfPresent(String.self, forKey: .syncedAt)
        let counts = try container.decodeIfPresent(ItemCounts.self, forKey: .itemCounts)
        skillsCount = counts?.skills ?? 0
        piExtensionsCount = counts?.piExtensions ?? 0
        cliCount = counts?.cli ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encodeIfPresent(syncedAt, forKey: .syncedAt)
        try container.encode(
            ItemCounts(skills: skillsCount, piExtensions: piExtensionsCount, cli: cliCount),
            forKey: .itemCounts
        )
    }
}

struct FleetResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var catalogRevision: String?
    var catalog: FleetCatalogSummary?
    var machine: FleetMachineSummary?
    var machines: [FleetMachineSummary]
    var items: [FleetInventoryItem]
    var generatedAt: String?
    var error: String?

    init(
        ok: Bool = true,
        catalogRevision: String? = nil,
        catalog: FleetCatalogSummary? = nil,
        machine: FleetMachineSummary? = nil,
        machines: [FleetMachineSummary] = [],
        items: [FleetInventoryItem] = [],
        generatedAt: String? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.catalogRevision = catalogRevision
        self.catalog = catalog
        self.machine = machine
        self.machines = machines
        self.items = items
        self.generatedAt = generatedAt
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case catalogRevision
        case catalog
        case machine
        case machines
        case items
        case inventory
        case skills
        case piExtensions
        case cli
        case cliRecipes
        case generatedAt = "generated_at"
        case generatedAtCamel = "generatedAt"
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        catalogRevision = try container.decodeIfPresent(String.self, forKey: .catalogRevision)
        catalog = try container.decodeIfPresent(FleetCatalogSummary.self, forKey: .catalog)
        machine = try container.decodeIfPresent(FleetMachineSummary.self, forKey: .machine)
        machines = try container.decodeIfPresent([FleetMachineSummary].self, forKey: .machines) ?? []
        let directItems = try container.decodeIfPresent([FleetInventoryItem].self, forKey: .items) ?? []
        let skillItems: [FleetInventoryItem] = try container.decodeIfPresent([FleetInventoryItem].self, forKey: .skills) ?? []
        let extensionItems: [FleetInventoryItem] = try container.decodeIfPresent([FleetInventoryItem].self, forKey: .piExtensions) ?? []
        let cliItems: [FleetInventoryItem] = try container.decodeIfPresent([FleetInventoryItem].self, forKey: .cli) ?? []
        let recipeItems: [FleetInventoryItem] = try container.decodeIfPresent([FleetInventoryItem].self, forKey: .cliRecipes) ?? []
        let categoryItems = skillItems + extensionItems + cliItems + recipeItems
        let nestedItems: [FleetInventoryItem] = try container.decodeIfPresent([FleetInventoryItem].self, forKey: .inventory) ?? []
        var uniqueItems: [String: FleetInventoryItem] = [:]
        for item in directItems + categoryItems + nestedItems { uniqueItems[item.id] = item }
        items = Array(uniqueItems.values)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .generatedAtCamel)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(catalogRevision, forKey: .catalogRevision)
        try container.encodeIfPresent(catalog, forKey: .catalog)
        try container.encodeIfPresent(machine, forKey: .machine)
        try container.encode(machines, forKey: .machines)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(generatedAt, forKey: .generatedAtCamel)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

enum FleetAction: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case install
    case manage = "adopt"
    case update
    case remove
    case authCheck = "checkAuth"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .install: "Install"
        case .manage: "Manage"
        case .update: "Update"
        case .remove: "Remove"
        case .authCheck: "Auth check"
        }
    }

    var symbol: String {
        switch self {
        case .install: "arrow.down.circle"
        case .manage: "hand.raised.circle"
        case .update: "arrow.triangle.2.circlepath"
        case .remove: "trash"
        case .authCheck: "checkmark.shield"
        }
    }
}

struct FleetSyncRequest: Encodable, Sendable {
    init() {}
}

struct FleetActionRequest: Encodable, Sendable {
    var itemID: String
    var action: FleetAction

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case action
    }
}

struct FleetActionResponse: Decodable, Sendable {
    var ok: Bool
    var action: FleetAction?
    var item: FleetInventoryItem?
    var catalogRevision: String?
    var message: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case action
        case item
        case catalogRevision
        case message
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        if let actionRaw = try container.decodeIfPresent(String.self, forKey: .action) {
            action = FleetAction(rawValue: actionRaw)
                ?? (actionRaw.lowercased() == "auth_check" ? .authCheck : .install)
        } else {
            action = nil
        }
        item = try container.decodeIfPresent(FleetInventoryItem.self, forKey: .item)
        catalogRevision = try container.decodeIfPresent(String.self, forKey: .catalogRevision)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

struct FleetSyncResponse: Decodable, Sendable {
    var ok: Bool
    var fleet: FleetResponse
    var items: [FleetInventoryItem]
    var machine: FleetMachineSummary?
    var catalogRevision: String?
    var message: String?
    var error: String?

    init(from decoder: Decoder) throws {
        fleet = try FleetResponse(from: decoder)
        ok = fleet.ok
        items = fleet.items
        machine = fleet.machine
        catalogRevision = fleet.catalogRevision
        message = fleet.error
        error = fleet.error
    }
}
