import Foundation

enum HarnessSettingsStore {
    private static let serverURLKey = "cmuxHarnessServerURL"
    private static let serverSourcesKey = "cmuxHarnessServerSources"
    private static let selectedServerSourceIDKey = "cmuxHarnessSelectedServerSourceID"
    private static let tailscaleHostKey = "cmuxHarnessTailscaleHost"
    private static let harnessWebTokenKey = "cmuxHarnessWebToken"
    private static let lastSelectedWorkspaceIDKey = "cmuxHarnessLastSelectedWorkspaceID"
    private static let detailDraftsKey = "cmuxHarnessDetailDrafts"
    private static let demoServerURLInfoKey = "CMUXDemoServerURL"
    private static let localDemoModeKey = "cmuxHarnessLocalDemoMode"

    static var demoServerURL: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: demoServerURLInfoKey) as? String ?? ""
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            #if DEBUG
            return "http://localhost:9097/harness"
            #else
            return ""
            #endif
        }
        return HarnessAPI.normalizedBaseURL(trimmed)
    }

    static var serverURL: String? {
        get {
            activeServerSource?.urlString ?? legacyServerURL
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: serverURLKey)
                serverSources = []
                selectedServerSourceID = nil
                return
            }
            let normalized = HarnessAPI.normalizedBaseURL(newValue)
            if normalized.isEmpty {
                UserDefaults.standard.removeObject(forKey: serverURLKey)
                serverSources = []
                selectedServerSourceID = nil
            } else {
                _ = saveServerSource(id: selectedServerSourceID, name: "", urlString: normalized)
            }
        }
    }

    static var serverSources: [HarnessServerSource] {
        get {
            let decodedSources: [HarnessServerSource]
            if let data = UserDefaults.standard.data(forKey: serverSourcesKey),
               let sources = try? JSONDecoder().decode([HarnessServerSource].self, from: data) {
                decodedSources = sources
            } else {
                decodedSources = []
            }

            let sanitizedSources = sanitizedServerSources(decodedSources)
            if !sanitizedSources.isEmpty {
                return sanitizedSources
            }

            guard let legacyServerURL else { return [] }
            return [
                HarnessServerSource(
                    name: HarnessServerSource.fallbackName(for: legacyServerURL),
                    urlString: legacyServerURL
                )
            ]
        }
        set {
            let sources = sanitizedServerSources(newValue)
            guard !sources.isEmpty else {
                UserDefaults.standard.removeObject(forKey: serverSourcesKey)
                UserDefaults.standard.removeObject(forKey: selectedServerSourceIDKey)
                UserDefaults.standard.removeObject(forKey: serverURLKey)
                return
            }
            guard let data = try? JSONEncoder().encode(sources) else { return }
            UserDefaults.standard.set(data, forKey: serverSourcesKey)

            let selectedID = selectedServerSourceID
            if let selectedID, sources.contains(where: { $0.id == selectedID }) {
                UserDefaults.standard.set(selectedID, forKey: selectedServerSourceIDKey)
            } else {
                UserDefaults.standard.set(sources[0].id, forKey: selectedServerSourceIDKey)
            }
            if let activeSource = activeServerSource ?? sources.first {
                UserDefaults.standard.set(activeSource.urlString, forKey: serverURLKey)
            }
        }
    }

    static var selectedServerSourceID: String? {
        get {
            let sources = serverSources
            guard !sources.isEmpty else { return nil }
            guard let selectedID = UserDefaults.standard.string(forKey: selectedServerSourceIDKey),
                  sources.contains(where: { $0.id == selectedID }) else {
                return sources[0].id
            }
            return selectedID
        }
        set {
            guard let newValue, serverSources.contains(where: { $0.id == newValue }) else {
                UserDefaults.standard.removeObject(forKey: selectedServerSourceIDKey)
                return
            }
            UserDefaults.standard.set(newValue, forKey: selectedServerSourceIDKey)
            if let source = serverSources.first(where: { $0.id == newValue }) {
                UserDefaults.standard.set(source.urlString, forKey: serverURLKey)
            }
        }
    }

    static var activeServerSource: HarnessServerSource? {
        let sources = serverSources
        guard !sources.isEmpty else { return nil }
        guard let selectedServerSourceID else { return sources[0] }
        return sources.first { $0.id == selectedServerSourceID } ?? sources[0]
    }

    @discardableResult
    static func saveServerSource(id: String?, name: String, urlString: String) -> HarnessServerSource? {
        let normalizedURL = HarnessAPI.normalizedBaseURL(urlString)
        guard !normalizedURL.isEmpty else { return nil }

        let source = HarnessServerSource(name: name, urlString: normalizedURL)
        var sources = serverSources
        let insertionIndex = id
            .flatMap { editingID in sources.firstIndex { $0.id == editingID } }
            ?? sources.count
        sources.removeAll { existingSource in
            existingSource.id == id || existingSource.id == source.id
        }
        sources.insert(source, at: min(insertionIndex, sources.count))

        serverSources = sources
        selectedServerSourceID = source.id
        UserDefaults.standard.set(source.urlString, forKey: serverURLKey)
        return source
    }

    @discardableResult
    static func deleteServerSource(id: String) -> HarnessServerSource? {
        var sources = serverSources
        sources.removeAll { $0.id == id }
        serverSources = sources
        if let selectedID = selectedServerSourceID,
           let selectedSource = sources.first(where: { $0.id == selectedID }) {
            return selectedSource
        }
        selectedServerSourceID = sources.first?.id
        return activeServerSource
    }

    static var isLocalDemoMode: Bool {
        get {
            UserDefaults.standard.bool(forKey: localDemoModeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: localDemoModeKey)
        }
    }

    static var tailscaleHost: String {
        get {
            UserDefaults.standard.string(forKey: tailscaleHostKey) ?? ""
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: tailscaleHostKey)
            } else {
                UserDefaults.standard.set(value, forKey: tailscaleHostKey)
            }
        }
    }

    static var harnessWebToken: String {
        get {
            UserDefaults.standard.string(forKey: harnessWebTokenKey) ?? ""
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: harnessWebTokenKey)
            } else {
                UserDefaults.standard.set(value, forKey: harnessWebTokenKey)
            }
        }
    }

    static var lastSelectedWorkspaceID: String? {
        get {
            guard let value = UserDefaults.standard.string(forKey: lastSelectedWorkspaceIDKey),
                  !value.isEmpty else {
                return nil
            }
            return value
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: lastSelectedWorkspaceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastSelectedWorkspaceIDKey)
            }
        }
    }

    static var detailDrafts: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: detailDraftsKey),
                  let drafts = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return drafts
        }
        set {
            let drafts = newValue.filter { !$0.value.isEmpty }
            guard !drafts.isEmpty else {
                UserDefaults.standard.removeObject(forKey: detailDraftsKey)
                return
            }
            guard let data = try? JSONEncoder().encode(drafts) else { return }
            UserDefaults.standard.set(data, forKey: detailDraftsKey)
        }
    }

    static func detailDraft(for workspaceID: String?) -> String {
        guard let workspaceID else { return "" }
        return detailDrafts[workspaceID] ?? ""
    }

    private static var legacyServerURL: String? {
        guard let value = UserDefaults.standard.string(forKey: serverURLKey) else {
            return nil
        }
        let normalized = HarnessAPI.normalizedBaseURL(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func sanitizedServerSources(_ sources: [HarnessServerSource]) -> [HarnessServerSource] {
        var sanitizedSources: [HarnessServerSource] = []
        var seenIDs = Set<String>()
        for source in sources {
            let normalizedURL = HarnessAPI.normalizedBaseURL(source.urlString)
            guard !normalizedURL.isEmpty else { continue }
            let sanitizedSource = HarnessServerSource(
                name: source.name,
                urlString: normalizedURL
            )
            guard !seenIDs.contains(sanitizedSource.id) else { continue }
            sanitizedSources.append(sanitizedSource)
            seenIDs.insert(sanitizedSource.id)
        }
        return sanitizedSources
    }
}
